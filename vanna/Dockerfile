FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN python -m pip install --upgrade pip && \
    python -m pip install -r requirements.txt

COPY app.py ./app.py
COPY scripts ./scripts
COPY training ./training

ENV VANNA_PORT=8000 \
    VANNA_CHROMA_DIR=/var/lib/vanna/chroma \
    VANNA_TRAINING_DIR=/app/training \
    VANNA_SNAPSHOT_DIR=/var/lib/vanna/snapshots \
    VANNA_OPS_DIR=/var/lib/vanna/ops \
    VANNA_CACHE_DIR=/var/lib/vanna/cache \
    XDG_CACHE_HOME=/var/lib/vanna/cache \
    HF_HOME=/var/lib/vanna/cache

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
