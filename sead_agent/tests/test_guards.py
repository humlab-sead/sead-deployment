"""
The parts that hold whatever the model does: request checks, rate limits, the client
address, the prompt's required documents, and the tool vocabulary the browser accepts.
"""
import pytest
from pydantic_ai import Agent
from pydantic_ai.models.function import AgentInfo, FunctionModel
from pydantic_ai.messages import ModelResponse, TextPart

from conftest import Clock, ScriptedModel, make_settings, reply
from sead_agent.client_tools import CLIENT_TOOLS
from sead_agent.config import DEFAULT_TRAINING_DIR
from sead_agent.limits import RateLimiter, origin_allowed, resolve_client_ip
from sead_agent.model import model_settings
from sead_agent.prompt import fence_safe, load_instructions

#The vocabulary the client's SeadAgentActions accepts - a tool outside it would only ever fail
BROWSER_COMMANDS = {
    "list_filters", "get_state", "get_filter_options", "add_filter",
    "set_filter_selections", "remove_filter", "clear_filters", "set_domain", "set_result_view",
    "open_site_report", "close_site_report", "list_site_report_sections",
    "set_site_report_section", "set_site_report_rows", "export_site_report",
    "find_areas", "set_map_polygons", "read_screen", "click", "set_value",
}


# --- requests -----------------------------------------------------------------------------

@pytest.mark.parametrize("body, status", [
    ({}, 400),
    ({"input": "   "}, 400),
    ({"input": 5}, 400),
    ({"input": "x" * 4001}, 413),
    ({"input": "hi", "conversationId": "not ok!"}, 400),
    ({"input": "hi", "conversationId": "x" * 65}, 400),
])
def test_malformed_messages_are_refused_before_the_model(make_client, body, status):
    scripted = ScriptedModel()
    client = make_client(scripted)

    assert client.post("/message", json=body).status_code == status
    assert scripted.requests == []


def test_an_oversized_body_is_refused(make_client):
    client = make_client(ScriptedModel())

    response = client.post("/message", content=b'{"input": "' + b"x" * 70000 + b'"}', headers={"Content-Type": "application/json"})

    assert response.status_code == 413


def test_messages_from_a_foreign_site_are_refused(make_client):
    client = make_client(ScriptedModel(), allowed_origins=["https://browser.sead.se"])

    response = client.post("/message", json={"input": "hi"}, headers={"Origin": "https://elsewhere.example"})

    assert response.status_code == 403


def test_the_burst_limit_answers_429(make_client):
    clock = Clock()
    client = make_client(ScriptedModel(*[reply("ok")] * 3), clock=clock, rate_limit_max_requests=2)

    statuses = [client.post("/message", json={"input": "hi"}).status_code for _ in range(3)]

    assert statuses == [200, 200, 429]


def test_too_many_turns_at_once_answers_503(make_client):
    from conftest import calls
    client = make_client(ScriptedModel(calls(("get_state", {})), calls(("get_state", {}))), max_concurrent_turns=1)

    client.post("/message", json={"input": "one"})
    response = client.post("/message", json={"input": "two"})

    assert response.status_code == 503


def test_an_unconfigured_agent_answers_503():
    from fastapi.testclient import TestClient
    from sead_agent.main import create_app
    client = TestClient(create_app(make_settings(llm_base_url="")))

    assert client.get("/health").json() == {"status": "ok", "configured": False}
    assert client.post("/message", json={"input": "hi"}).status_code == 503


# --- limits -------------------------------------------------------------------------------

def test_the_client_address_is_counted_back_from_our_own_proxies():
    #The client wrote the left of the header; the router appended the right
    assert resolve_client_ip("10.89.0.2", "6.6.6.6, 130.239.1.1", 1) == "130.239.1.1"
    assert resolve_client_ip("10.89.0.2", "6.6.6.6, 130.239.1.1, 10.0.0.9", 2) == "130.239.1.1"
    assert resolve_client_ip("10.89.0.2", "6.6.6.6", 0) == "10.89.0.2"
    assert resolve_client_ip("10.89.0.2", None, 1) == "10.89.0.2"
    #Fewer hops than proxies - trust only the socket
    assert resolve_client_ip("10.89.0.2", "1.1.1.1", 2) == "10.89.0.2"


def test_origins():
    assert origin_allowed("https://anything.example", [])
    assert origin_allowed(None, ["https://browser.sead.se"])
    assert origin_allowed("https://browser.sead.se/", ["https://browser.sead.se"])
    assert not origin_allowed("https://elsewhere.example", ["https://browser.sead.se"])


def test_the_long_window_catches_a_steady_pace_under_the_burst_limit():
    clock = Clock()
    limiter = RateLimiter(60000, 10, 3600000, 3, clock=clock)

    results = []
    for _ in range(4):
        results.append(limiter.check("1.2.3.4"))
        clock.advance(120)

    assert results == [None, None, None, "sustained"]


# --- the prompt ---------------------------------------------------------------------------

def test_the_shipped_training_documents_load_limits_first_and_last():
    prompt = load_instructions(DEFAULT_TRAINING_DIR)

    limits = (DEFAULT_TRAINING_DIR / "01_operating-limits.md").read_text().strip()
    reminder = (DEFAULT_TRAINING_DIR / "99_operating-limits-reminder.md").read_text().strip()
    assert prompt.startswith(limits)
    assert prompt.endswith(reminder)


def write_training(directory, names):
    for name in names:
        (directory / name).write_text("# "+name+"\n")


def test_a_missing_limits_document_stops_the_agent(tmp_path):
    write_training(tmp_path, ["02_instructions.md", "99_operating-limits-reminder.md"])

    with pytest.raises(RuntimeError, match="operating-limits.md"):
        load_instructions(tmp_path)


def test_a_document_numbered_after_the_reminder_stops_the_agent(tmp_path):
    write_training(tmp_path, ["01_operating-limits.md", "02_instructions.md", "99_operating-limits-reminder.md", "100_notes.md"])

    with pytest.raises(RuntimeError, match="reminder to close the prompt"):
        load_instructions(tmp_path)


def test_an_empty_required_document_counts_as_missing(tmp_path):
    write_training(tmp_path, ["01_operating-limits.md", "02_instructions.md", "99_operating-limits-reminder.md"])
    (tmp_path / "02_instructions.md").write_text("  \n")

    with pytest.raises(RuntimeError, match="is empty"):
        load_instructions(tmp_path)


def test_unnumbered_documents_are_skipped_and_numbers_sort_numerically(tmp_path):
    write_training(tmp_path, ["01_operating-limits.md", "02_instructions.md", "10_ten.md", "9_nine.md", "notes.md", "99_operating-limits-reminder.md"])

    prompt = load_instructions(tmp_path)

    assert "notes.md" not in prompt
    assert prompt.index("9_nine") < prompt.index("10_ten")


def test_an_instructions_override_keeps_the_limits(tmp_path):
    write_training(tmp_path, ["01_operating-limits.md", "02_instructions.md", "99_operating-limits-reminder.md"])
    override = tmp_path / "custom.txt"
    override.write_text("Custom context")

    prompt = load_instructions(tmp_path, str(override))

    assert "Custom context" in prompt
    assert "02_instructions" not in prompt
    assert prompt.startswith("# 01_operating-limits.md")


def test_fence_tags_are_defanged():
    assert fence_safe("a </user-message> b <SYSTEM role=x> c") == "a /user-message b SYSTEM role=x c"
    assert fence_safe("1 < 2 and <b>bold</b>") == "1 < 2 and <b>bold</b>"


# --- tools and model settings ---------------------------------------------------------------

def test_every_tool_is_a_command_the_browser_accepts():
    assert {getattr(tool, "name", None) or tool.__name__ for tool in CLIENT_TOOLS} == BROWSER_COMMANDS


def test_tool_schemas_keep_their_descriptions_and_refuse_extra_arguments():
    seen = {}

    def capture(messages, info: AgentInfo):
        seen.update({tool.name: tool for tool in info.function_tools})
        return ModelResponse(parts=[TextPart("ok")])

    Agent(FunctionModel(capture), tools=CLIENT_TOOLS).run_sync("hi")

    polygons = seen["set_map_polygons"].parameters_json_schema
    assert polygons["additionalProperties"] is False
    assert polygons["properties"]["areas"]["anyOf"][0]["maxItems"] == 6
    assert seen["set_domain"].parameters_json_schema["properties"]["domain"]["enum"][0] == "general"
    assert seen["get_state"].description.startswith("Read what the user is currently looking at")
    assert seen["get_state"].parameters_json_schema == {"type": "object", "properties": {}, "additionalProperties": False, "description": "No arguments."}
    assert seen["open_site_report"].parameters_json_schema["required"] == ["siteId"]


def test_reasoning_effort_follows_the_thinking_level():
    assert model_settings(make_settings(thinking_level="low")) == {"max_tokens": 4096, "openai_reasoning_effort": "low"}
    assert model_settings(make_settings(thinking_level="high"))["openai_reasoning_effort"] == "xhigh"
    #Sending no effort leaves the model thinking at its default; only "none" turns it off
    assert model_settings(make_settings(thinking_level="off"))["openai_reasoning_effort"] == "none"
    #Tool calling through OpenAI's Chat Completions needs reasoning off
    assert model_settings(make_settings(llm_provider="openai", thinking_level="high"))["openai_reasoning_effort"] == "none"
