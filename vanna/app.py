import os
from typing import List

from vanna import Agent, AgentConfig
from vanna.core.registry import ToolRegistry
from vanna.core.user import RequestContext, User, UserResolver
from vanna.integrations.chromadb import ChromaAgentMemory
from vanna.integrations.openai import OpenAILlmService
from vanna.integrations.postgres import PostgresRunner
from vanna.servers.fastapi import VannaFastAPIServer
from vanna.tools import RunSqlTool
from vanna.tools.agent_memory import (
    SaveQuestionToolArgsTool,
    SaveTextMemoryTool,
    SearchSavedCorrectToolUsesTool,
)

try:
    from vanna.tools import VisualizeDataTool
except Exception:  # pragma: no cover - optional dependency path
    VisualizeDataTool = None


class SeadCookieUserResolver(UserResolver):
    def __init__(self, cookie_name: str = "vanna_email", admin_emails: List[str] | None = None):
        self.cookie_name = cookie_name
        self.admin_emails = {email.strip().lower() for email in (admin_emails or []) if email.strip()}

    async def resolve_user(self, request_context: RequestContext) -> User:
        user_email = request_context.get_cookie(self.cookie_name) or "guest@local"
        normalized_email = user_email.strip().lower()
        groups = ["admin", "user"] if normalized_email in self.admin_emails else ["user"]
        return User(
            id=normalized_email,
            username=normalized_email,
            email=normalized_email,
            group_memberships=groups,
            metadata={"remote_addr": request_context.remote_addr},
        )


def parse_csv(value: str) -> List[str]:
    return [x.strip() for x in value.split(",") if x.strip()]


def build_agent() -> Agent:
    openai_api_key = os.getenv("OPENAI_API_KEY")
    if not openai_api_key:
        raise RuntimeError("OPENAI_API_KEY must be set")

    llm = OpenAILlmService(
        api_key=openai_api_key,
        model=os.getenv("VANNA_OPENAI_MODEL", os.getenv("OPENAI_MODEL", "gpt-4o-mini")),
    )

    sql_runner = PostgresRunner(
        host=os.getenv("VANNA_DB_HOST", "postgresql"),
        port=int(os.getenv("VANNA_DB_PORT", "5432")),
        database=os.getenv("VANNA_DB_NAME", os.getenv("DATABASE_NAME", "sead_staging")),
        user=os.getenv("VANNA_DB_USER", os.getenv("DATABASE_READ_ONLY_USER", "sead_ro")),
        password=os.getenv("VANNA_DB_PASSWORD", os.getenv("DATABASE_READ_ONLY_PASSWORD", "")),
    )

    memory = ChromaAgentMemory(
        persist_directory=os.getenv("VANNA_CHROMA_DIR", "/var/lib/vanna/chroma"),
        collection_name=os.getenv("VANNA_CHROMA_COLLECTION", "tool_memories"),
    )

    tools = ToolRegistry()
    tools.register_local_tool(RunSqlTool(sql_runner=sql_runner), access_groups=["admin", "user"])
    tools.register_local_tool(SaveQuestionToolArgsTool(), access_groups=["admin"])
    tools.register_local_tool(SearchSavedCorrectToolUsesTool(), access_groups=["admin", "user"])
    tools.register_local_tool(SaveTextMemoryTool(), access_groups=["admin", "user"])

    if VisualizeDataTool is not None:
        tools.register_local_tool(VisualizeDataTool(), access_groups=["admin", "user"])

    admin_emails = parse_csv(os.getenv("VANNA_ADMIN_EMAILS", "admin@local"))
    user_resolver = SeadCookieUserResolver(
        cookie_name=os.getenv("VANNA_EMAIL_COOKIE", "vanna_email"),
        admin_emails=admin_emails,
    )

    agent = Agent(
        llm_service=llm,
        tool_registry=tools,
        user_resolver=user_resolver,
        agent_memory=memory,
        config=AgentConfig(
            stream_responses=True,
            temperature=float(os.getenv("VANNA_TEMPERATURE", "1.0")),
        ),
    )
    return agent


def build_app():
    agent = build_agent()
    server = VannaFastAPIServer(
        agent,
        config={
            "dev_mode": False,
            "cors": {
                "enabled": True,
                "allow_origins": parse_csv(os.getenv("VANNA_CORS_ALLOW_ORIGINS", "*")) or ["*"],
                "allow_credentials": True,
                "allow_methods": ["*"],
                "allow_headers": ["*"],
            },
        },
    )
    return server.create_app()


app = build_app()
