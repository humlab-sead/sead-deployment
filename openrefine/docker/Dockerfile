# Dockerfile
FROM eclipse-temurin:17-jre-jammy

# Use the real tarball URL (not the post_download tracker)
ARG OPENREFINE_VERSION=3.9.5
ARG OPENREFINE_URL="https://github.com/OpenRefine/OpenRefine/releases/download/${OPENREFINE_VERSION}/openrefine-linux-${OPENREFINE_VERSION}.tar.gz"

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tar bash \
    && rm -rf /var/lib/apt/lists/*

# Download & install OpenRefine
RUN set -eux; \
    mkdir -p /opt; \
    curl -fL "${OPENREFINE_URL}" -o /tmp/openrefine.tgz; \
    tar -xzf /tmp/openrefine.tgz -C /opt; \
    mv /opt/openrefine-* /opt/openrefine; \
    rm -f /tmp/openrefine.tgz

# Non-root user + workspace dir
RUN useradd -r -u 10001 -g root -d /opt/openrefine -s /usr/sbin/nologin openrefine \
 && mkdir -p /data \
 && chown -R openrefine:root /opt/openrefine /data \
 && chmod -R g=u /opt/openrefine /data

ENV REFINE_HOST=0.0.0.0 \
    REFINE_PORT=3333 \
    WORKSPACE_DIR=/data \
    MEMORY=2G

EXPOSE 3333
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${REFINE_PORT}/" >/dev/null || exit 1

RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'exec /opt/openrefine/refine -i "${REFINE_HOST}" -p "${REFINE_PORT}" -d "${WORKSPACE_DIR}" -m "${MEMORY}"' \
  > /usr/local/bin/docker-entrypoint.sh \
  && chmod +x /usr/local/bin/docker-entrypoint.sh

USER openrefine
WORKDIR /opt/openrefine
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
