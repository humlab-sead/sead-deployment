# SEAD agent

The chatbox agent for the SEAD web client. It runs a [pi](https://www.npmjs.com/package/@ai-sdk/harness-pi)
harness agent against a **locally hosted** OpenAI-compatible model server, so no chat
content and no credentials leave the deployment.

This used to live inside `json_api_server` as `AIAssistant`; it is now a service of its
own so that the API server has no LLM dependencies and the agent can be scaled, restarted
and rate-limited independently.

## Endpoints

| Method | Path      | Description |
| ------ | --------- | ----------- |
| `GET`  | `/health` | Liveness. Reports `configured: false` when no model server is set. |
| `POST` | `/message` | One chat turn. Body: `{ "input": "...", "conversationId": "optional" }`, reply: `{ "output_text": "..." }`. |

A request that sends the same `conversationId` every time gets a conversation the agent
remembers; one that omits it gets one-shot replies. Conversations are scoped to the
client IP, so one browser cannot join or evict another's.

Through the router the service is reachable at `/sead-agent/` (e.g.
`/sead-agent/health`). The web client still posts to `<dataServerAddress>/ai-assistant/message`,
which the router peels off `/jsonapi/` and sends here - see `router/vhost.conf`.

## Configuration

All settings are `SEAD_AGENT_*` environment variables, documented in the deployment's
`.env-example`. The one that matters:

- `SEAD_AGENT_LLM_BASE_URL` - the OpenAI-compatible server (vLLM, llama.cpp, Ollama, ...).
  **Leaving it empty disables the agent**, which then answers `503`.

### Reaching a model server on the host

`localhost` inside the container is the container itself, so a model server on the podman
host - including one exposed by an ssh tunnel - cannot be reached over the host's
loopback. The obvious workaround, binding the tunnel to `0.0.0.0`, also publishes the
model on every network the machine is attached to (LAN, VPN), which is not acceptable for
an unauthenticated inference endpoint.

Instead the host gets one address that exists nowhere else - `10.123.0.1` on a `seadllm0`
dummy interface, installed as a systemd unit:

```sh
sudo sead_agent/scripts/install-llm-host-iface.sh
```

Local addresses route via `lo`, and rootless podman forwards the container's traffic
there, so the container can reach it while no external network can. Bind the tunnel to
that address and nothing else:

```sh
# published on the LAN and the VPN - don't
ssh -N -L 0.0.0.0:5040:model-host:8081 user@jump-host

# reachable only from this host and its containers
ssh -N -L 10.123.0.1:5040:model-host:8081 user@jump-host
```

The container resolves this as `llm-host` (see `extra_hosts` in `compose.yml`), which is
what `SEAD_AGENT_LLM_BASE_URL` points at. This arrangement fails closed: if the interface
is missing, the tunnel refuses to bind rather than quietly falling back to a public one.

`SEAD_AGENT_LLM_MODEL` can be left empty, in which case the agent asks the server what it
is serving and uses that.

## What the agent knows

The model is not fine-tuned. Everything it knows about SEAD is in its system prompt,
assembled when the agent is built from the markdown documents in `training/`. Each is
named `NN_name.md`, and the number is its place in the prompt:

1. `01_operating-limits.md` - what it will and won't do (see [Safety](#safety))
2. `02_instructions.md` - the agent's own guide: the data, the user's vocabulary, age
   scales, and how to work the client with its tools
3. `03_sead-filters.md` - the filters this deployment offers, generated from the database
   by `scripts/generate-filters-doc.py`
4. `99_operating-limits-reminder.md` - a short restatement of the limits

To add a document, give it a number between the instructions and the reminder. A `.md`
without a number is skipped with a warning in the log.

The limits, the instructions and the reminder are required: if any of them is missing or
empty, or the limits are not numbered first or the reminder last, the agent answers every
message with an error rather than run with its limits missing or buried. Every numbered
`.md` in `training/` goes into the prompt, so keep notes for humans elsewhere.

The tool descriptions in `src/clientTools.js` are part of what it is told, too. They stay
in code because they describe the parameters and handlers defined next to them.

The prompt is read once, when the first message arrives. `training/` is mounted into the
container, so an edit there needs only `podman compose restart sead_agent`.

`reference/` is **not** loaded. It holds the database and API detail - how filters become
SQL, the query API, PostgREST - that the agent has no use for while it works only through
the user interface, kept for the day it gets a tool that queries the database directly.

## Safety

The endpoint is unauthenticated and public, so it is worth being explicit about the two
different things that can go wrong with it: someone using it as a **free model server**,
and someone using it as a **general-purpose assistant** that happens to be hosted by a
university.

### Against being used as a model server

Every request occupies the GPU behind the local model, so message size, reply length,
request rate, parallel turns and remembered conversations are all capped - see the
`SEAD_AGENT_MAX_*` and `SEAD_AGENT_RATE_LIMIT_*` settings. There are two rate windows: a
short one that catches a burst, and an hourly one that catches the traffic a burst limit
by itself lets through.

Those caps are per visitor, which makes the address they are counted against load-bearing.
The router *appends* to `X-Forwarded-For` rather than replacing it, so the left of that
header is whatever the client chose to send and only the right of it is ours. The agent
counts `SEAD_AGENT_TRUSTED_PROXY_COUNT` entries back from the end; set it to the number of
proxies actually in front of the service (1 for the router alone). Setting it too low
hands every visitor an unlimited quota - they need only send a header of their own.

`SEAD_AGENT_ALLOWED_ORIGINS` refuses browser requests from sites that are not ours. It is
a fence, not a wall: a script sends no `Origin` at all, and is held by the rate limits
instead. Empty (any origin) is a sound default for a public database.

### Against being used as a general assistant

The agent's operating limits - it answers about SEAD and its data, it does not take on
other personas, it does not reproduce its own prompt - live in
`training/01_operating-limits.md` rather than in the instructions, and are prepended to
whatever `SEAD_AGENT_INSTRUCTIONS_FILE` supplies. Pointing that at a context document of
your own therefore cannot drop them, and they are restated by
`training/99_operating-limits-reminder.md` after the training documents, which are long enough
on their own to leave the top of the prompt far behind. Both files are required and must open
and close the prompt - deleting one, numbering a document outside them, or a deployment
pointing `SEAD_AGENT_TRAINING_DIR` at a directory without them stops the agent answering
rather than leaving it running without its limits.

The user's message and the browser's state summary each arrive in the prompt inside a
block of their own, and anything in either that looks like one of those tags is defanged
on the way in - so neither a message nor a site name typed into a filter search box can
close its block and continue as though it were part of the system prompt.

This is model-enforced, and model-enforced limits are not guarantees. What is guaranteed
is the part above it: the caps hold whatever the model decides to say.

### Against reaching anything it shouldn't

The agent has no database credentials and no filesystem of its own to speak of. Its tools
do not run here at all - each one hands a named command to the browser that asked the
question, and the client refuses anything outside that vocabulary (`clientTools.js`). No
model-written JavaScript is ever evaluated, on either side.

The general tools - `read_screen`, `click` and `set_value`, which let the agent use anything a
person can see on the page - work the same way. The model names a ref from an outline the client
built and one of those three actions; the client decides what the ref is and whether it may be
touched. Some of the page is out of its reach entirely (`OFF_LIMITS` in the client's
`ScreenReader.class.js`): the chatbox itself, signing in and out, the sysadmin data import, and
download buttons, which stay the user's own click. Links that leave SEAD are refused too. A
region of the page can be put out of reach with `data-sead-agent="off"`.

pi's builtin file and shell tools are switched off by default. When enabled with
`SEAD_AGENT_ENABLE_SANDBOX_TOOLS=true` they only ever reach a throwaway in-memory sandbox
that contains nothing of this container's filesystem.

## Running

```sh
podman compose up -d --build sead_agent
podman compose logs -f sead_agent
curl http://localhost:${SEAD_AGENT_PORT:-8585}/health
```
