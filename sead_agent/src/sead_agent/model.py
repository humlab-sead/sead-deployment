"""
The language model the agent talks to: a locally hosted OpenAI-compatible server by
default, or the OpenAI API itself.
"""
import logging
import time
from urllib.parse import quote

import httpx
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.profiles import merge_profile
from pydantic_ai.profiles.openai import OpenAIModelProfile
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.settings import ModelSettings

log = logging.getLogger("sead_agent")

#Which reasoning_effort each SEAD_AGENT_THINKING_LEVEL is sent as
LOCAL_REASONING_EFFORTS = {
    #The local server advertises only low/medium/xhigh; sending "high" or "minimal" verbatim
    #is a 400. "none" is accepted, and is the only way to turn thinking off: sending no
    #effort at all leaves the model at its default, which thinks more than "low" does.
    "off": "none",
    "minimal": "low",
    "low": "low",
    "medium": "medium",
    "high": "xhigh",
    "xhigh": "xhigh",
    "max": "xhigh",
}


def reasoning_effort(settings):
    if settings.use_openai:
        #GPT-6 Luna supports reasoning, but Chat Completions function calling is currently
        #supported only with reasoning_effort="none". The SEAD chatbox depends on function
        #tools, so every requested effort is pinned to none here.
        return "none"
    return LOCAL_REASONING_EFFORTS.get(settings.thinking_level.strip().lower(), "low")


def model_settings(settings):
    result = ModelSettings(max_tokens=settings.max_output_tokens)
    effort = reasoning_effort(settings)
    if effort is not None:
        result["openai_reasoning_effort"] = effort
    return result


def build_model(settings, model_id):
    provider = OpenAIProvider(base_url=settings.llm_base_url, api_key=settings.llm_api_key)
    profile = None
    if not settings.use_openai:
        #Most local servers take the older max_tokens field; OpenAI wants max_completion_tokens
        profile = merge_profile(provider.model_profile(model_id), OpenAIModelProfile(openai_chat_supports_max_completion_tokens=False))
    return OpenAIChatModel(model_id, provider=provider, profile=profile)


async def fetch_served_model(settings):
    """
    Asks the server what it is serving, so the model name doesn't have to be kept in sync with
    the deployment by hand.
    """
    async with httpx.AsyncClient(timeout=settings.model_probe_timeout_ms / 1000) as client:
        response = await client.get(settings.llm_base_url+"/models", headers={"Authorization": "Bearer "+settings.llm_api_key})
    if response.status_code != 200:
        raise RuntimeError("Failed to list models at "+settings.llm_base_url+"/models: HTTP "+str(response.status_code))
    payload = response.json()
    data = payload.get("data") if isinstance(payload, dict) else None
    model = data[0] if isinstance(data, list) and data else None
    if not isinstance(model, dict) or not model.get("id"):
        raise RuntimeError("No models served at "+settings.llm_base_url+"/models")
    return model["id"]


class ModelProbe:
    """
    Asks the model server what it is serving. Briefly cached, so opening the chatbox
    repeatedly - or several people doing so at once - doesn't turn into a stream of requests
    at the model.
    """

    def __init__(self, settings, clock=time.time):
        self.settings = settings
        self.clock = clock
        #(at, result) from the last probe
        self.last = None

    async def check(self):
        now = self.clock()
        if self.last and now - self.last[0] < self.settings.model_probe_cache_ms / 1000:
            return self.last[1]

        settings = self.settings
        try:
            models_url = settings.llm_base_url+"/models"
            if settings.use_openai and settings.llm_model:
                models_url += "/"+quote(settings.llm_model, safe="")
            async with httpx.AsyncClient(timeout=settings.model_probe_timeout_ms / 1000) as client:
                response = await client.get(models_url, headers={"Authorization": "Bearer "+settings.llm_api_key})
            if response.status_code != 200:
                raise RuntimeError("HTTP "+str(response.status_code))
            payload = response.json()
            model = payload if isinstance(payload, dict) and payload.get("id") else None
            if model is None and isinstance(payload, dict) and isinstance(payload.get("data"), list) and payload["data"]:
                model = payload["data"][0]
            if not isinstance(model, dict) or not model.get("id"):
                raise RuntimeError("the server reports no models")
            result = {"reachable": True, "id": model["id"]}
        except Exception as error:
            #Logged in full here, but reported to the browser in general terms - the detail
            #names our model server and its configuration
            log.warning("SEAD agent model probe failed: %s", error)
            result = {"reachable": False, "error": "The language model is not responding."}

        self.last = (now, result)
        return result
