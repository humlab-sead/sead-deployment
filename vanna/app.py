import os
import re
from typing import List

from vanna import Agent, AgentConfig
from vanna.core.agent.agent import DefaultSystemPromptBuilder
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


PUBLIC_SCHEMA = "public"
SEAD_SYSTEM_PROMPT = """
SEAD domain context:
- You are answering questions about the Strategic Environmental Archaeology Database, not the public web.
- Interpret "site" and "sites" as archaeological site records in `public.tbl_sites` unless the user explicitly says website, web page, URL, or domain.
- SEAD domain table names use the `tbl_` prefix. Do not invent unprefixed natural-language tables such as `samples`, `sites`, or `datasets`.
- Interpret "sample" and "samples" as physical sample records in `public.tbl_physical_samples`.
- To answer sample questions for a site, join `public.tbl_sites` -> `public.tbl_sample_groups` -> `public.tbl_physical_samples`.
- If a guessed relation does not exist, recover by using the trained public schema catalog and `tbl_` term mappings; do not ask the user to provide table names.
- For requests such as "a few sites", "some random sites", or "examples of sites", query `public.tbl_sites` and return site identifiers and names.
- If the user asks for "random" rows, use PostgreSQL `ORDER BY random()` with a sensible `LIMIT` when no count is given.
- Treat common words according to the SEAD archaeological database context before applying general web meanings.
""".strip()
BLOCKED_SCHEMA_REFERENCE_RE = re.compile(
    r'(?i)(?<![\w"])(?:"?(?:facet|information_schema|pg_catalog|pg_toast)"?)\s*\.'
)
IDENTIFIER_RE = r'(?:"[^"]+"|[A-Za-z_][\w$]*)'
TABLE_REFERENCE_RE = re.compile(
    rf"(?i)\b(?:from|join|update|into|delete\s+from|alter\s+table|copy)\s+"
    rf"(?:only\s+)?({IDENTIFIER_RE})(?:\s*\.\s*({IDENTIFIER_RE}))?"
)


def normalize_identifier(identifier: str) -> str:
    identifier = identifier.strip()
    if identifier.startswith('"') and identifier.endswith('"'):
        return identifier[1:-1].replace('""', '"')
    return identifier.lower()


def validate_public_select_sql(sql: str) -> None:
    stripped = sql.strip()
    statement = stripped.rstrip(";").strip()
    if not statement:
        raise ValueError("SQL cannot be empty.")

    if ";" in statement:
        raise ValueError("Only one SELECT statement may be executed.")

    if statement.split(None, 1)[0].upper() != "SELECT":
        raise ValueError("Only SELECT statements against the public schema are allowed.")

    if BLOCKED_SCHEMA_REFERENCE_RE.search(statement):
        raise ValueError("Only the public schema is available to this assistant.")

    for match in TABLE_REFERENCE_RE.finditer(statement):
        schema_or_table, table = match.groups()
        if table and normalize_identifier(schema_or_table) != PUBLIC_SCHEMA:
            raise ValueError("Only relations in the public schema may be queried.")


class PublicSchemaPostgresRunner(PostgresRunner):
    async def run_sql(self, args, context):
        validate_public_select_sql(args.sql)
        return await super().run_sql(args, context)


class SeadSystemPromptBuilder(DefaultSystemPromptBuilder):
    async def build_system_prompt(self, user, tools):
        prompt = await super().build_system_prompt(user, tools)
        if prompt:
            return f"{prompt}\n\n{SEAD_SYSTEM_PROMPT}"
        return SEAD_SYSTEM_PROMPT


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

    sql_runner = PublicSchemaPostgresRunner(
        host=os.getenv("VANNA_DB_HOST", "postgresql"),
        port=int(os.getenv("VANNA_DB_PORT", "5432")),
        database=os.getenv("VANNA_DB_NAME", os.getenv("DATABASE_NAME", "sead_staging")),
        user=os.getenv("VANNA_DB_USER", os.getenv("DATABASE_READ_ONLY_USER", "sead_ro")),
        password=os.getenv("VANNA_DB_PASSWORD", os.getenv("DATABASE_READ_ONLY_PASSWORD", "")),
        options="-c search_path=public,pg_catalog -c default_transaction_read_only=on",
    )

    memory = ChromaAgentMemory(
        persist_directory=os.getenv("VANNA_CHROMA_DIR", "/var/lib/vanna/chroma"),
        collection_name=os.getenv("VANNA_CHROMA_COLLECTION", "tool_memories"),
    )

    tools = ToolRegistry()
    tools.register_local_tool(
        RunSqlTool(
            sql_runner=sql_runner,
            custom_tool_description="Execute one read-only SELECT query against SEAD PostgreSQL public schema relations only.",
        ),
        access_groups=["admin", "user"],
    )
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
        system_prompt_builder=SeadSystemPromptBuilder(),
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
