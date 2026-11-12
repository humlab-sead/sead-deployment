"""
Everything the agent can be told through its environment. All of it is a SEAD_AGENT_*
variable, documented in the deployment's .env-example.
"""
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[2]

#Every document in the training directory is named NN_name.md, and the number is the
#order it takes in the prompt - see prompt.py
DEFAULT_TRAINING_DIR = SERVICE_ROOT / "training"

CONVERSATION_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def env_int(name, default):
    """
    An integer setting. Unset, unparseable and zero all mean the default, as they did when
    this service was written in Node (`parseInt(...) || default`) - a deployment that wrote
    0 there was getting the default, and should keep getting it.
    """
    try:
        value = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return value if value != 0 else default


def env_str(name, default=""):
    value = os.environ.get(name)
    return value if value else default


@dataclass
class Settings:
    llm_provider: str = "local"
    #The OpenAI-compatible server serving the model. For local this is vLLM, SGLang,
    #llama.cpp, Ollama and friends. For OpenAI, empty means https://api.openai.com/v1.
    #Setting this is what enables the local endpoint; OpenAI also requires an API key.
    llm_base_url: str = ""
    #A local server usually ignores the key, but one is always sent. OpenAI must get a real key.
    llm_api_key: str = "local"
    #Local can leave this empty to use whatever the server reports. OpenAI defaults to Luna.
    llm_model: str = ""
    thinking_level: str = "low"

    #The answer goes in a chatbox, not into a document. Capping it keeps one request from
    #occupying the GPU for an essay, which is the cheapest way to abuse an open endpoint -
    #"write me a novel" costs the asker one line and costs us minutes of inference.
    max_output_tokens: int = 4096
    #The same cap over a whole turn. A turn is several model requests - one per step
    #between browser actions - so the per-request cap alone lets one message produce
    #many times that.
    max_turn_output_tokens: int = 16384
    #How many model requests one message may take, tool steps and corrections included.
    #A model that has got itself into a loop stops here rather than at the timeout.
    max_model_requests: int = 30

    #How long we wait for the whole turn, browser round trips included
    turn_timeout_ms: int = 120000
    #This endpoint is unauthenticated and every request occupies the GPU behind the local
    #model, so cap the size of a message, the messages per client, and the parallel turns
    max_input_length: int = 4000
    rate_limit_window_ms: int = 60000
    rate_limit_max_requests: int = 10
    #A second window over the first. Ten messages in a minute is someone using the chatbox;
    #ten messages a minute kept up for an hour is someone using us as their own model server,
    #and only a longer window can tell the two apart.
    rate_limit_long_window_ms: int = 3600000
    rate_limit_long_max_requests: int = 60
    max_concurrent_turns: int = 2

    #How many proxies of our own stand between the client and this service - the router, plus
    #anything in front of it. It decides which entry of X-Forwarded-For we believe, and every
    #per-client limit rests on getting that right: see limits.resolve_client_ip.
    trusted_proxy_count: int = 1
    #Origins allowed to post here. Empty means any, which is the right default for a public
    #database - set it where the chatbox has one known home.
    allowed_origins: list = field(default_factory=list)
    #Hosts a reply may link to, besides the page the chatbox is on - see reply_guard.py
    link_hosts: list = field(default_factory=lambda: ["sead.se", "doi.org"])

    #A conversation is kept between messages so the agent remembers what was said. They're
    #small, but not free, so they're capped.
    max_sessions: int = 20
    session_ttl_ms: int = 900000

    #How long we wait for the browser to run one command, and how many commands one turn
    #may ask for. Real questions take one to nine; beyond that the model is usually
    #searching by trial and error, and the user is waiting for it.
    client_action_timeout_ms: int = 60000
    max_client_actions: int = 12
    #The browser's state summary travels with every message; this caps what we will relay
    max_client_state_length: int = 4000

    #How long a model reachability probe may take, and how long its answer is reused
    model_probe_timeout_ms: int = 5000
    model_probe_cache_ms: int = 15000

    #Everything the model is told about SEAD lives in here as markdown, and is mounted rather
    #than baked in, so the context can be edited without rebuilding the image
    training_dir: Path = DEFAULT_TRAINING_DIR
    #Replaces NN_instructions.md; the operating limits around it are loaded either way
    instructions_file: str = ""

    @property
    def use_openai(self):
        return self.llm_provider == "openai"

    @classmethod
    def from_env(cls):
        provider = env_str("SEAD_AGENT_LLM_PROVIDER", "local").strip().lower()
        if provider not in ("local", "openai"):
            raise ValueError("Unsupported SEAD_AGENT_LLM_PROVIDER '"+provider+"'; use 'local' or 'openai'.")
        use_openai = provider == "openai"

        trusted_proxies = os.environ.get("SEAD_AGENT_TRUSTED_PROXY_COUNT", "")
        try:
            trusted_proxy_count = int(trusted_proxies)
        except ValueError:
            trusted_proxy_count = 1

        return cls(
            llm_provider=provider,
            llm_base_url=env_str("SEAD_AGENT_LLM_BASE_URL", "https://api.openai.com/v1" if use_openai else "").rstrip("/"),
            llm_api_key=env_str("SEAD_AGENT_LLM_API_KEY", "" if use_openai else "local"),
            llm_model=env_str("SEAD_AGENT_LLM_MODEL", "gpt-6-luna" if use_openai else ""),
            #GPT-6 Luna only supports Chat Completions function calling with reasoning disabled
            thinking_level=env_str("SEAD_AGENT_THINKING_LEVEL", "off" if use_openai else "low"),
            max_output_tokens=env_int("SEAD_AGENT_MAX_OUTPUT_TOKENS", 4096),
            max_turn_output_tokens=env_int("SEAD_AGENT_MAX_TURN_OUTPUT_TOKENS", 16384),
            max_model_requests=env_int("SEAD_AGENT_MAX_MODEL_REQUESTS", 30),
            turn_timeout_ms=env_int("SEAD_AGENT_TIMEOUT_MS", 120000),
            max_input_length=env_int("SEAD_AGENT_MAX_INPUT_LENGTH", 4000),
            rate_limit_window_ms=env_int("SEAD_AGENT_RATE_LIMIT_WINDOW_MS", 60000),
            rate_limit_max_requests=env_int("SEAD_AGENT_RATE_LIMIT_MAX_REQUESTS", 10),
            rate_limit_long_window_ms=env_int("SEAD_AGENT_RATE_LIMIT_LONG_WINDOW_MS", 3600000),
            rate_limit_long_max_requests=env_int("SEAD_AGENT_RATE_LIMIT_LONG_MAX_REQUESTS", 60),
            max_concurrent_turns=env_int("SEAD_AGENT_MAX_CONCURRENT_TURNS", 2),
            trusted_proxy_count=trusted_proxy_count,
            allowed_origins=[origin.strip().rstrip("/") for origin in env_str("SEAD_AGENT_ALLOWED_ORIGINS").split(",") if origin.strip()],
            link_hosts=[host.strip().lower() for host in env_str("SEAD_AGENT_LINK_HOSTS", "sead.se,doi.org").split(",") if host.strip()],
            max_sessions=env_int("SEAD_AGENT_MAX_SESSIONS", 20),
            session_ttl_ms=env_int("SEAD_AGENT_SESSION_TTL_MS", 900000),
            client_action_timeout_ms=env_int("SEAD_AGENT_CLIENT_ACTION_TIMEOUT_MS", 60000),
            max_client_actions=env_int("SEAD_AGENT_MAX_CLIENT_ACTIONS", 12),
            max_client_state_length=env_int("SEAD_AGENT_MAX_CLIENT_STATE_LENGTH", 4000),
            model_probe_timeout_ms=env_int("SEAD_AGENT_MODEL_PROBE_TIMEOUT_MS", 5000),
            model_probe_cache_ms=env_int("SEAD_AGENT_MODEL_PROBE_CACHE_MS", 15000),
            training_dir=Path(env_str("SEAD_AGENT_TRAINING_DIR", str(DEFAULT_TRAINING_DIR))),
            instructions_file=env_str("SEAD_AGENT_INSTRUCTIONS_FILE"),
        )

    def is_configured(self):
        return len(self.llm_base_url) > 0 and (not self.use_openai or (len(self.llm_api_key) > 0 and self.llm_api_key != "local"))
