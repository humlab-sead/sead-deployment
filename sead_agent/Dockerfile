FROM docker.io/node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /sead_agent

# Dependencies first, so a change to the agent source doesn't reinstall them
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY src ./src
# Baked in so the image is self-contained; compose mounts over this so the context can be
# edited and picked up with a restart rather than a rebuild
COPY training ./training

# SEAD_AGENT_DIR is where pi regenerates its model catalog on every startup, so it
# points somewhere disposable and writable by the unprivileged user below
ENV NODE_ENV=production \
    SEAD_AGENT_PORT=8585 \
    SEAD_AGENT_DIR=/tmp/sead-agent-pi

EXPOSE 8585

# Liveness only - the agent is up before the model server it talks to has to be
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8585/health || exit 1

# Nothing here needs root, and the pi sandbox is in-process
USER node

CMD ["node", "src/index.js"]
