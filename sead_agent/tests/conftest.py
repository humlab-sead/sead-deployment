import os

#Pydantic AI prints a banner on the first run unless told not to
os.environ.setdefault("PYDANTIC_AI_NO_BANNER", "1")

import pytest
from fastapi.testclient import TestClient
from pydantic_ai.messages import ModelResponse, RetryPromptPart, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import FunctionModel

from sead_agent.config import DEFAULT_TRAINING_DIR, Settings
from sead_agent.main import create_app


class ScriptedModel:
    """
    Stands in for the language model. Each step is a function of the messages so far that
    returns the model's response - a reply, or tool calls - and every request it was sent is
    kept, so a test can check what the model was told.
    """

    def __init__(self, *steps):
        self.steps = list(steps)
        self.requests = []
        self.model = FunctionModel(self.respond, model_name="scripted")

    def respond(self, messages, info):
        self.requests.append(messages)
        if not self.steps:
            raise AssertionError("The model was asked for more steps than the test scripted")
        step = self.steps.pop(0)
        return step(messages) if callable(step) else step

    def last_parts(self, kind=None):
        """The parts of the last request sent to the model - what it has just been told."""
        parts = self.requests[-1][-1].parts
        return [part for part in parts if kind is None or isinstance(part, kind)]


def reply(text):
    return ModelResponse(parts=[TextPart(text)])


def calls(*tool_calls):
    """One model step calling tools: each a (name, args) pair, or (name, args, call id)."""
    parts = []
    for index, call in enumerate(tool_calls):
        name, args = call[0], call[1]
        call_id = call[2] if len(call) > 2 else name+"-"+str(index)
        parts.append(ToolCallPart(name, args, tool_call_id=call_id))
    return ModelResponse(parts=parts)


class Clock:
    def __init__(self, now=1_000_000.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


def make_settings(**overrides):
    values = dict(llm_base_url="http://model.invalid/v1", training_dir=DEFAULT_TRAINING_DIR, trusted_proxy_count=0)
    values.update(overrides)
    return Settings(**values)


@pytest.fixture
def make_client():
    def factory(scripted, clock=None, **settings):
        app = create_app(make_settings(**settings), model=scripted.model)
        if clock is not None:
            service = app.state.sead_agent
            service.clock = clock
            service.rate_limiter.clock = clock
        return TestClient(app)
    return factory


__all__ = ["ScriptedModel", "reply", "calls", "Clock", "make_settings", "RetryPromptPart", "ToolReturnPart", "UserPromptPart"]
