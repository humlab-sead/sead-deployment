"""
Answers the webclient's chatbox. A message becomes a turn; a turn is one or more runs of a
Pydantic AI agent against the model.

Most turns use the browser. The agent's tools don't run here (client_tools.py) - when the
model calls one, the run ends with the call deferred, the browser is asked to run it, and
when it posts the result back a new run carries on from the stored conversation. Nothing is
kept running in between, so a browser that takes its time, or never comes back, holds no
model run open.

The browser speaks the same protocol as it did with the Node version of this service: post
a message, get back either the reply or one action to run, post that action's result, and
repeat until the reply comes.
"""
import asyncio
import json
import logging
import re
import time
from collections import deque
from dataclasses import dataclass, field, replace
from urllib.parse import urlsplit

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic_ai import Agent, CancellationToken, Conversation, DeferredToolRequests, ModelRetry, UsageLimits
from pydantic_ai.capabilities import PrepareTools
from pydantic_ai.exceptions import RunCancelled, UnexpectedModelBehavior, UsageLimitExceeded
from pydantic_ai.messages import PartDeltaEvent, PartStartEvent, TextPart, TextPartDelta, ThinkingPart, ToolCallPart
from pydantic_ai.usage import RunUsage

from .client_tools import CLIENT_TOOLS
from .config import CONVERSATION_ID_PATTERN
from .limits import RateLimiter, origin_allowed, resolve_client_ip
from .model import ModelProbe, build_model, fetch_served_model, model_settings
from .prompt import build_prompt, describe_client_state, load_instructions
from .reply_guard import guard_reply

log = logging.getLogger("sead_agent")

#A chat message is the only thing we ever accept, so the body stays small
MAX_BODY_BYTES = 64 * 1024
#How much of a failed browser command's error message is passed on to the model
MAX_CLIENT_ERROR_LENGTH = 2000
#How many times the model may get a tool call wrong - bad arguments, say - and be told so,
#before the turn gives up
TOOL_RETRIES = 3
#A tool call written out as text, in one of the formats models are trained on. The local
#model sometimes does this instead of calling the tool, and the server passes it on as
#the answer - which would put raw markup in front of the user.
TOOL_CALL_MARKUP = re.compile(r"</?tool_calls?>|<function=|</function>|<\|tool_call|\[TOOL_CALLS\]", re.IGNORECASE)


#A browser that asks for this gets the answer as it is written - see stream_answer
STREAM_MEDIA_TYPE = "application/x-ndjson"
#How often the text written so far is sent on, at most. Each line carries the whole text,
#so sending it on every token would only repeat it.
STREAM_INTERVAL = 0.05

#What the user is told when the model is reachable but does not get to an answer
GAVE_UP_REPLY = ("I wasn't able to work that out within the steps I can take for one message. "
                 "Anything I already changed on the page is still applied. Could you ask again more "
                 "narrowly - one place, period or kind of data at a time?")


@dataclass
class TurnBudget:
    """What each run of a turn is told about the turn so far - see hide_tools_when_spent."""
    actions_left: int


async def hide_tools_when_spent(ctx, tool_defs):
    """
    A turn that has used its browser actions gets no more tools, so the model's only move
    is to answer with what it has. Asking it to stop does not work reliably - it will narrow
    a range one step at a time for as long as it is allowed to.
    """
    if ctx.deps is not None and ctx.deps.actions_left <= 0:
        return []
    return tool_defs


def budget_spent_note(ctx):
    """
    Taking the tools away is not enough on its own: a model that still wants to act writes
    its tool calls out as text instead. Saying why the tools are gone gets an answer.
    """
    if ctx.deps is not None and ctx.deps.actions_left <= 0:
        return ("You have used all the actions this message allows, and no tools are available now. "
                "Answer the user in plain text with what you have found so far, and say what is left undone.")
    return ""


def reject_tool_call_markup(output):
    if isinstance(output, str) and TOOL_CALL_MARKUP.search(output):
        raise ModelRetry("Your reply contained a tool call written out as text, which the user would see as it is. "
                         "Call the tool through the tool interface instead, or answer in plain text.")
    return output


class SessionBusy(Exception):
    """A second message arrived for a conversation whose last message is still being answered."""


@dataclass
class Session:
    """A remembered conversation, or a one-off one for a request that sent no conversation id."""
    key: str | None
    conversation: Conversation | None = None
    busy: bool = True
    last_used: float = field(default_factory=time.time)


@dataclass
class ClientAction:
    id: str
    tool_call_id: str
    command: str
    args: dict
    sent_at: float = 0.0
    #For the timing log, which measures real time whatever clock the service is given
    sent_perf: float = 0.0


@dataclass
class Turn:
    """One message being answered, from the moment it arrives until the reply goes out."""
    id: str
    session: Session
    client_ip: str
    deadline: float
    #The host of the page that asked, which the reply may always link to
    origin_host: str | None = None
    #The conversation as the last run left it, paused on the calls in `queue`
    conversation: Conversation | None = None
    #Calls from the last run not yet sent to the browser, in the order the model made them
    queue: deque = field(default_factory=deque)
    #The one call the browser is running now
    outstanding: ClientAction | None = None
    #tool call id -> what the browser reported, for the run that resumes the turn
    results: dict = field(default_factory=dict)
    action_count: int = 0
    action_sequence: int = 0
    #Set while a run is in flight, so an abort can stop it
    cancel: CancellationToken | None = None
    #Set while a browser that asked for a stream is waiting on this turn: takes each line
    #to send it as the answer is written
    emit: object = None
    aborted: bool = False
    finished: bool = False
    #Where the time went, for the line logged when the turn ends: in the model, or waiting
    #for the browser
    started_perf: float = field(default_factory=time.perf_counter)
    model_seconds: float = 0.0
    browser_seconds: float = 0.0
    runs: int = 0
    commands: list = field(default_factory=list)
    usage: RunUsage | None = None


def error_response(status, message):
    return JSONResponse(status_code=status, content={"error": message})


class SeadAgentService:
    def __init__(self, settings, model=None, clock=time.time):
        self.settings = settings
        #A model handed in from outside - a test model - is used as is, instead of asking
        #the configured server what it serves
        self.model_override = model
        self.clock = clock
        self.rate_limiter = RateLimiter(settings.rate_limit_window_ms, settings.rate_limit_max_requests,
                                        settings.rate_limit_long_window_ms, settings.rate_limit_long_max_requests, clock=clock)
        self.model_probe = ModelProbe(settings, clock=clock)
        #conversation key -> Session
        self.sessions = {}
        #turn id -> Turn
        self.turns = {}
        self.turn_sequence = 0
        self.active_turns = 0
        #Built on the first message rather than at boot, so a model server that is still
        #starting up doesn't hold up the service coming online
        self.agent = None
        self.agent_lock = asyncio.Lock()
        self.usage_limits = UsageLimits(
            request_limit=settings.max_model_requests,
            output_tokens_limit=settings.max_turn_output_tokens,
        )

    def is_configured(self):
        return self.model_override is not None or self.settings.is_configured()

    def register(self, app: FastAPI):
        @app.get("/health")
        async def health():
            #Liveness only, and deliberately so: this is the container's healthcheck, and the
            #agent being up is not the same question as the model being up. Ask /status for that.
            return {"status": "ok", "configured": self.is_configured()}

        @app.get("/status")
        async def status():
            """
            Whether the agent can actually answer right now - which means asking the model
            server, not just checking that a URL was configured. The chatbox calls this when it
            opens, so a model that is down is reported before the user types a question rather
            than after.
            """
            if not self.is_configured():
                return {"status": "ok", "configured": False,
                        "model": {"reachable": False, "error": "No language model is configured for this deployment."}}
            if self.model_override is not None:
                return {"status": "ok", "configured": True, "model": {"reachable": True, "id": self.model_override.model_name}}
            return {"status": "ok", "configured": True, "model": await self.model_probe.check()}

        app.post("/message")(self.post_message)
        app.post("/message/action-result")(self.post_action_result)
        app.post("/message/abort")(self.post_abort)

    # --- requests ---------------------------------------------------------------------

    async def read_body(self, request):
        body = await request.body()
        if len(body) > MAX_BODY_BYTES:
            return None, error_response(413, "Request body is too large.")
        if len(body) == 0:
            return {}, None
        try:
            payload = json.loads(body)
        except ValueError:
            return None, error_response(400, "Request body is not valid JSON.")
        return (payload if isinstance(payload, dict) else {}), None

    def client_ip(self, request):
        return resolve_client_ip(request.client.host if request.client else None,
                                 request.headers.get("x-forwarded-for"), self.settings.trusted_proxy_count)

    def check_origin(self, request):
        return origin_allowed(request.headers.get("origin"), self.settings.allowed_origins)

    async def post_message(self, request: Request):
        if not self.check_origin(request):
            log.warning("SEAD agent refused a message from origin %s", request.headers.get("origin"))
            return error_response(403, "This assistant does not answer requests from this site.")
        if not self.is_configured():
            log.warning("SEAD agent request received but no language model is configured")
            return error_response(503, "The SEAD agent is not configured on this server.")

        body, error = await self.read_body(request)
        if error:
            return error

        user_input = body.get("input")
        if not isinstance(user_input, str) or len(user_input.strip()) == 0:
            return error_response(400, "Missing or empty 'input' in request body.")
        if len(user_input) > self.settings.max_input_length:
            return error_response(413, "Message is too long. The maximum is "+str(self.settings.max_input_length)+" characters.")

        #Optional - a client that sends the same id with every message gets a conversation
        #the agent remembers, one that doesn't gets one-shot replies
        conversation_id = body.get("conversationId")
        if conversation_id is not None and (not isinstance(conversation_id, str) or not CONVERSATION_ID_PATTERN.match(conversation_id)):
            return error_response(400, "Invalid 'conversationId'.")

        #Only requests that are actually about to occupy the model count against the budget,
        #so a malformed message doesn't eat a user's quota
        client_ip = self.client_ip(request)
        limited = self.rate_limiter.check(client_ip)
        if limited:
            log.info("SEAD agent %s rate limit hit for IP: %s", limited, client_ip)
            if limited == "sustained":
                #Said plainly, because the one person who legitimately hits this should know
                #it is a quota and not a glitch to retry through
                return error_response(429, "You have reached this assistant's hourly message limit. It runs on a shared model, so usage is capped per visitor - please come back later.")
            return error_response(429, "Too many requests. Please wait a moment before trying again.")

        #Turns waiting on a browser that went away still count until they're swept
        self.sweep_turns()
        if self.active_turns >= self.settings.max_concurrent_turns:
            return error_response(503, "The SEAD agent is busy right now. Please try again in a moment.")

        #Where the browser says the user is. Untrusted like any request body, so it is
        #size-capped and passed through as data the model reads, never as instructions it
        #follows.
        client_state = describe_client_state(body.get("state"), self.settings.max_client_state_length)

        try:
            agent = await self.get_agent()
            session = self.acquire_session(conversation_id, client_ip)
        except SessionBusy:
            return error_response(429, "Your previous message is still being answered.")
        except Exception:
            log.exception("SEAD agent could not start a turn")
            return error_response(502, "The SEAD agent could not be reached.")

        turn = self.begin_turn(session, client_ip)
        turn.origin_host = urlsplit(request.headers.get("origin") or "").hostname
        #Usage limits are per message: the conversation carries what earlier messages used,
        #so this turn starts counting from nothing
        conversation = replace(session.conversation, usage=RunUsage()) if session.conversation else None
        prompt = build_prompt(user_input, client_state)
        return await self.respond(request, turn, lambda: self.run_leg(turn, agent, user_prompt=prompt, conversation=conversation))

    async def post_action_result(self, request: Request):
        """
        The other half of a client action. The browser ran what the model asked for and posts
        the outcome here; once every call from the model's last step has an answer, a new run
        carries the turn on from where the last one stopped.
        """
        if not self.check_origin(request):
            return error_response(403, "This assistant does not answer requests from this site.")
        body, error = await self.read_body(request)
        if error:
            return error

        self.sweep_turns()
        turn = self.turns.get(body.get("turnId"))
        #Scoped to the client address for the same reason conversations are: one browser must
        #not be able to answer, or derail, another's turn
        if turn is None or turn.client_ip != self.client_ip(request):
            log.warning("SEAD agent got a result for turn %s which is no longer active", body.get("turnId"))
            return error_response(404, "That request is no longer active. Please send your message again.")

        action = turn.outstanding
        if action is None or action.id != body.get("actionId"):
            #Either it already timed out, or this is a duplicate post
            log.warning("SEAD agent got a result for action %s which is not outstanding (turn %s)", body.get("actionId"), turn.id)
            return error_response(409, "That action is no longer awaited.")
        turn.outstanding = None
        turn.browser_seconds += time.perf_counter() - action.sent_perf

        #A command the browser could not run is not a failure of the turn - the model is told
        #what went wrong and can pick a different approach
        client_error = body.get("error")
        if isinstance(client_error, str) and len(client_error) > 0:
            turn.results[action.tool_call_id] = {"ok": False, "error": client_error[:MAX_CLIENT_ERROR_LENGTH]}
        else:
            turn.results[action.tool_call_id] = {"ok": True, "result": body.get("result")}

        agent = await self.get_agent()
        return await self.respond(request, turn, lambda: self.next_action_or_resume(turn, agent))

    async def post_abort(self, request: Request):
        """
        The user closed the chatbox. Drop the turn rather than leaving the model occupying the
        GPU until it times out on its own.
        """
        body, error = await self.read_body(request)
        turn = self.turns.get(body.get("turnId")) if body else None
        if turn is not None and turn.client_ip == self.client_ip(request):
            turn.aborted = True
            if turn.cancel is not None:
                #The run raises RunCancelled, and the request waiting on it answers 504
                turn.cancel.cancel()
            else:
                #Waiting on the browser - nothing is running, so there is nothing to stop
                self.finish_turn(turn, "aborted")
        return {"status": "ok"}

    # --- streaming --------------------------------------------------------------------

    async def respond(self, request, turn, leg):
        """
        Answers one leg of a turn - `leg` produces the answer. A browser that asks for a stream
        gets it as it is written; any other gets the answer in one piece, as before streaming
        existed, so a client and a service of different ages still work together.
        """
        if STREAM_MEDIA_TYPE not in (request.headers.get("accept") or ""):
            return await leg()
        #The router passes the stream on as it comes (router/vhost.conf); the header asks the
        #same of any nginx in a deployment where the router is set up differently
        return StreamingResponse(self.stream_answer(turn, leg), media_type=STREAM_MEDIA_TYPE,
                                 headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"})

    async def stream_answer(self, turn, leg):
        """
        The leg's answer as lines of JSON: {"type": "status", ...} while the model thinks,
        {"type": "text", "text": ...} with the whole reply written so far, and last the answer
        the leg would have given in one piece. An error can no longer change the HTTP status
        once lines have been sent, so it is that last line instead: {"status": "error",
        "httpStatus": ..., "error": ...}.
        """
        queue = asyncio.Queue()
        turn.emit = queue.put_nowait
        task = asyncio.create_task(leg())
        try:
            while True:
                waiting = asyncio.ensure_future(queue.get())
                done, _ = await asyncio.wait({waiting, task}, return_when=asyncio.FIRST_COMPLETED)
                if waiting in done:
                    yield json.dumps(waiting.result(), ensure_ascii=False)+"\n"
                    continue
                waiting.cancel()
                break
            while not queue.empty():
                yield json.dumps(queue.get_nowait(), ensure_ascii=False)+"\n"
            answer = task.result()
        finally:
            #The browser may have gone away mid-stream; the turn carries on regardless, and
            #the next leg sets this again if that browser comes back
            turn.emit = None

        if isinstance(answer, JSONResponse):
            answer = {"status": "error", "httpStatus": answer.status_code, **json.loads(answer.body)}
        yield json.dumps(answer, ensure_ascii=False)+"\n"

    def stream_handler(self, turn):
        """
        Follows the model as it writes, and passes on what the user should see: that it is
        thinking, and the reply so far. Every text line has been through the same filter as
        the finished reply, so the stream can show nothing the reply would not.
        """
        allowed_hosts = self.allowed_link_hosts(turn)

        def emit(event):
            if turn.emit is not None:
                turn.emit(event)

        async def handle(ctx, events):
            text = ""
            sent = ""
            sent_at = 0.0
            async for event in events:
                if isinstance(event, PartStartEvent):
                    if isinstance(event.part, ThinkingPart):
                        emit({"type": "status", "text": "Thinking…"})
                        continue
                    if isinstance(event.part, ToolCallPart):
                        #What it said before deciding to call a tool was it thinking out loud,
                        #not the answer - take it back
                        text = ""
                        if sent:
                            emit({"type": "text", "text": ""})
                            sent = ""
                        continue
                    if not isinstance(event.part, TextPart):
                        continue
                    text += event.part.content
                elif isinstance(event, PartDeltaEvent) and isinstance(event.delta, TextPartDelta):
                    text += event.delta.content_delta
                else:
                    continue

                now = time.perf_counter()
                if now - sent_at < STREAM_INTERVAL:
                    #The finished answer follows anyway, so a skipped update is never lost
                    continue
                shown = self.streamable(text, allowed_hosts)
                if shown != sent:
                    emit({"type": "text", "text": shown})
                    sent = shown
                    sent_at = now

        return handle

    @staticmethod
    def streamable(text, allowed_hosts):
        """The part of a reply being written that may be shown yet."""
        if TOOL_CALL_MARKUP.search(text):
            #It is about to be sent back to the model, not to the user
            return ""
        #An image or link is taken out as soon as it is complete; until then it is not one, and
        #renders as the text it is
        return guard_reply(text, allowed_hosts)[0].strip()

    def allowed_link_hosts(self, turn):
        return self.settings.link_hosts + ([turn.origin_host] if turn.origin_host else [])

    # --- turns ------------------------------------------------------------------------

    def begin_turn(self, session, client_ip):
        self.turn_sequence += 1
        now = self.clock()
        turn = Turn(
            id="t"+str(self.turn_sequence)+"-"+format(int(now * 1000), "x"),
            session=session,
            client_ip=client_ip,
            #The whole multi-leg turn gets one deadline, so a browser that keeps answering
            #slowly can't pin a session open indefinitely
            deadline=now + self.settings.turn_timeout_ms / 1000,
        )
        self.turns[turn.id] = turn
        self.active_turns += 1
        return turn

    async def run_leg(self, turn, agent, user_prompt=None, conversation=None, deferred_tool_results=None):
        """
        One run of the agent: from a new message, or from the browser's answers to the calls
        the last run stopped on. It ends with either the reply or more calls for the browser.
        """
        remaining = turn.deadline - self.clock()
        if remaining <= 0 or turn.aborted:
            self.finish_turn(turn, "aborted or timed out")
            return error_response(504, "The SEAD agent did not respond in time.")

        turn.cancel = CancellationToken()
        run_started = time.perf_counter()
        try:
            result = await agent.run(
                user_prompt,
                conversation=conversation,
                deferred_tool_results=deferred_tool_results,
                deps=TurnBudget(actions_left=self.settings.max_client_actions - turn.action_count),
                usage_limits=self.usage_limits,
                timeout=remaining,
                cancellation_token=turn.cancel,
                event_stream_handler=self.stream_handler(turn) if turn.emit else None,
            )
        except RunCancelled:
            #Either the user closed the chatbox or we ran out of time
            self.finish_turn(turn, "aborted or timed out")
            return error_response(504, "The SEAD agent did not respond in time.")
        except (UnexpectedModelBehavior, UsageLimitExceeded) as error:
            #The model is reachable but did not get to an answer - kept writing tool calls as
            #text, or used up the turn's requests or tokens. Saying the agent "could not be
            #reached" would be wrong, and the user may be looking at filters it changed.
            log.warning("SEAD agent turn %s gave up: %s", turn.id, error)
            self.finish_turn(turn, "gave up")
            return {"status": "complete", "turnId": turn.id, "output_text": GAVE_UP_REPLY}
        except Exception:
            #Logged here in full, but reported to the browser in general terms - the detail can
            #name our model, its host and its configuration
            log.exception("SEAD agent turn %s failed", turn.id)
            self.finish_turn(turn, "failed")
            return error_response(502, "The SEAD agent could not be reached.")
        finally:
            turn.cancel = None
            turn.model_seconds += time.perf_counter() - run_started
            turn.runs += 1

        #A run started from the conversation carries on counting from what the turn's
        #earlier runs used, so this is the whole turn's usage so far
        turn.usage = result.usage
        if turn.aborted:
            self.finish_turn(turn, "aborted")
            return error_response(504, "The SEAD agent did not respond in time.")

        output = result.output
        if isinstance(output, DeferredToolRequests):
            self.queue_client_actions(turn, result.conversation, output)
            return await self.next_action_or_resume(turn, agent)

        #Only the answer belongs in the chatbox. The model's reasoning arrives as parts of its
        #own and isn't in the output, and anything it said before deciding to call a tool
        #("Let me check the domain...") ended a run that is already behind us.
        reply = output.strip() if isinstance(output, str) else ""
        if len(reply) == 0:
            log.error("SEAD agent turn %s failed: the model returned no answer", turn.id)
            self.finish_turn(turn, "failed with no answer")
            return error_response(502, "The SEAD agent could not be reached.")

        reply, removed = guard_reply(reply, self.allowed_link_hosts(turn))
        if removed:
            log.warning("SEAD agent turn %s: took out of the reply: %s", turn.id, "; ".join(removed))

        #Only a turn that finished is remembered. One that failed leaves the conversation as
        #it was before the message, rather than half-way through a tool call.
        turn.session.conversation = result.conversation
        self.finish_turn(turn, "complete")
        #The turn id goes with the reply too, so a reply can be matched to its line in the log
        return {"status": "complete", "turnId": turn.id, "output_text": reply}

    def queue_client_actions(self, turn, conversation, requests):
        turn.conversation = conversation
        turn.results = {}
        turn.queue.clear()
        for call in requests.calls:
            #A model that has got itself into a loop shouldn't be able to drive the user's
            #interface indefinitely
            if turn.action_count >= self.settings.max_client_actions:
                turn.results[call.tool_call_id] = {
                    "ok": False,
                    "error": "Too many client actions in one turn ("+str(self.settings.max_client_actions)+"). Answer with what you already know.",
                }
                continue
            turn.action_count += 1
            turn.action_sequence += 1
            turn.commands.append(call.tool_name)
            metadata = requests.metadata.get(call.tool_call_id) or {}
            turn.queue.append(ClientAction(
                id="a"+str(turn.action_sequence),
                tool_call_id=call.tool_call_id,
                command=call.tool_name,
                args=metadata.get("args", {}),
            ))

    async def next_action_or_resume(self, turn, agent):
        """
        The model can ask for several things in one step. The browser runs them one at a time,
        in the order they were asked for, and the turn resumes once all of them have answers.
        """
        if turn.queue:
            action = turn.queue.popleft()
            action.sent_at = self.clock()
            action.sent_perf = time.perf_counter()
            turn.outstanding = action
            return {
                "status": "action_required",
                "turnId": turn.id,
                "action": {"id": action.id, "command": action.command, "args": action.args},
            }

        results = turn.conversation.deferred_tool_requests.build_results(calls=turn.results)
        return await self.run_leg(turn, agent, conversation=turn.conversation, deferred_tool_results=results)

    def finish_turn(self, turn, outcome="ended"):
        """Retires a turn once its reply (or failure) has been handed to the browser."""
        if turn.finished:
            return
        turn.finished = True
        turn.queue.clear()
        turn.outstanding = None
        self.turns.pop(turn.id, None)
        self.active_turns -= 1
        self.release_session(turn.session)
        self.log_turn(turn, outcome)

    def log_turn(self, turn, outcome):
        """
        One line per turn saying where its time went - in the model or waiting for the
        browser - and what the model spent, which is what to look at when replies are slow.
        """
        usage = turn.usage or RunUsage()
        log.info(
            "SEAD agent turn %s %s in %.1fs: model %.1fs over %d run(s), %d request(s), %d in / %d out tokens; browser %.1fs for %d action(s)%s",
            turn.id, outcome, time.perf_counter() - turn.started_perf,
            turn.model_seconds, turn.runs, usage.requests, usage.input_tokens, usage.output_tokens,
            turn.browser_seconds, len(turn.commands), (": "+", ".join(turn.commands)) if turn.commands else "",
        )

    def sweep_turns(self):
        """
        Drops turns whose browser stopped answering - a closed tab, a reload mid-turn. Runs off
        the request path rather than a timer, so an idle server doesn't keep waking up.
        """
        now = self.clock()
        action_timeout = self.settings.client_action_timeout_ms / 1000
        for turn in list(self.turns.values()):
            if turn.cancel is not None:
                #A run is in flight, and has its own deadline
                continue
            waited_too_long = turn.outstanding is not None and now - turn.outstanding.sent_at > action_timeout
            if waited_too_long or now > turn.deadline:
                if turn.outstanding is not None:
                    log.warning("SEAD agent timed out waiting for the browser to run %s (turn %s)", turn.outstanding.command, turn.id)
                self.finish_turn(turn, "dropped, the browser stopped answering")

    # --- the agent and its sessions ------------------------------------------------------

    async def get_agent(self):
        """
        Builds the agent on first use and reuses it afterwards. A failed attempt isn't kept, so
        a model server that comes up late is picked up by the next request.
        """
        if self.agent is not None:
            return self.agent
        async with self.agent_lock:
            if self.agent is None:
                self.agent = await self.build_agent()
        return self.agent

    async def build_agent(self):
        settings = self.settings
        if self.model_override is not None:
            model = self.model_override
        else:
            model_id = settings.llm_model or await fetch_served_model(settings)
            model = build_model(settings, model_id)
            log.info("SEAD agent using %s model %s at %s", settings.llm_provider, model_id, settings.llm_base_url)

        agent = Agent(
            model,
            #A run ends either with the reply or with calls for the browser to run
            output_type=[str, DeferredToolRequests],
            instructions=load_instructions(settings.training_dir, settings.instructions_file),
            tools=CLIENT_TOOLS,
            deps_type=TurnBudget,
            capabilities=[PrepareTools(hide_tools_when_spent)],
            model_settings=model_settings(settings),
            retries=TOOL_RETRIES,
        )
        agent.output_validator(reject_tool_call_markup)
        agent.instructions(budget_spent_note)
        return agent

    def acquire_session(self, conversation_id, client_ip):
        """
        Hands back the conversation's session, creating it if needed. Requests without a
        conversation id get a session of their own that is thrown away after the reply.
        """
        if not conversation_id:
            return Session(key=None, last_used=self.clock())

        #Scope the id to the client so one browser can't join, or evict, another's conversation
        key = client_ip+"|"+conversation_id
        self.sweep_sessions()

        session = self.sessions.get(key)
        if session is not None:
            if session.busy:
                raise SessionBusy()
            session.busy = True
            session.last_used = self.clock()
            return session

        session = Session(key=key, last_used=self.clock())
        self.sessions[key] = session
        return session

    def release_session(self, session):
        session.busy = False
        session.last_used = self.clock()

    def sweep_sessions(self):
        """Drops idle conversations, then the oldest ones if we're over the cap."""
        now = self.clock()
        ttl = self.settings.session_ttl_ms / 1000
        for key, session in list(self.sessions.items()):
            if not session.busy and now - session.last_used > ttl:
                del self.sessions[key]

        if len(self.sessions) < self.settings.max_sessions:
            return
        evictable = sorted((session for session in self.sessions.values() if not session.busy), key=lambda session: session.last_used)
        for session in evictable:
            if len(self.sessions) < self.settings.max_sessions:
                break
            del self.sessions[session.key]
