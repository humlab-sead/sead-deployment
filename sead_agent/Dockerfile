FROM docker.io/python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /sead_agent

# Dependencies first, so a change to the agent source doesn't reinstall them
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY src ./src
# Baked in so the image is self-contained; compose mounts over this so the context can be
# edited and picked up with a restart rather than a rebuild
COPY training ./training

ENV PYTHONPATH=/sead_agent/src \
    PYTHONUNBUFFERED=1 \
    PYDANTIC_AI_NO_BANNER=1 \
    SEAD_AGENT_PORT=8585

EXPOSE 8585

# Liveness only - the agent is up before the model server it talks to has to be
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:${SEAD_AGENT_PORT}/health || exit 1

# Nothing here needs root
RUN useradd --system --no-create-home sead_agent
USER sead_agent

# One process: conversations and turns waiting on a browser live in its memory, so a second
# worker would not know about the first one's. --no-proxy-headers keeps uvicorn from
# rewriting the client address from X-Forwarded-For - the agent does that itself, counting
# back from its own proxies (limits.resolve_client_ip). On SIGTERM, turns in flight get 15
# seconds to finish.
CMD ["sh", "-c", "exec uvicorn --factory sead_agent.main:create_app --host 0.0.0.0 --port ${SEAD_AGENT_PORT} --no-proxy-headers --timeout-graceful-shutdown 15"]
