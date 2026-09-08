# SEAD agent

The chatbox agent for the SEAD web client. It runs a [pi](https://www.npmjs.com/package/@ai-sdk/harness-pi)
harness agent against a **locally hosted** OpenAI-compatible model server, so no chat
content and no credentials leave the deployment.

This used to live inside `json_api_server` as `AIAssistant`; it is now a service of its
own so that the API server has no LLM dependencies and the agent can be scaled, restarted
and rate-limited independently.

## Endpoints

| Method | Path      | Description |
| ------ | --------- | ----------- |
| `GET`  | `/health` | Liveness. Reports `configured: false` when no model server is set. |
| `POST` | `/message` | One chat turn. Body: `{ "input": "...", "conversationId": "optional" }`, reply: `{ "output_text": "..." }`. |

A request that sends the same `conversationId` every time gets a conversation the agent
remembers; one that omits it gets one-shot replies. Conversations are scoped to the
client IP, so one browser cannot join or evict another's.

Through the router the service is reachable at `/sead-agent/` (e.g.
`/sead-agent/health`). The web client still posts to `<dataServerAddress>/ai-assistant/message`,
which the router peels off `/jsonapi/` and sends here - see `router/vhost.conf`.

## Configuration

All settings are `SEAD_AGENT_*` environment variables, documented in the deployment's
`.env-example`. The one that matters:

- `SEAD_AGENT_LLM_BASE_URL` - the OpenAI-compatible server (vLLM, llama.cpp, Ollama, ...).
  **Leaving it empty disables the agent**, which then answers `503`.

### Reaching a model server on the host

`localhost` inside the container is the container itself, so a model server on the podman
host - including one exposed by an ssh tunnel - cannot be reached over the host's
loopback. The obvious workaround, binding the tunnel to `0.0.0.0`, also publishes the
model on every network the machine is attached to (LAN, VPN), which is not acceptable for
an unauthenticated inference endpoint.

Instead the host gets one address that exists nowhere else - `10.123.0.1` on a `seadllm0`
dummy interface, installed as a systemd unit:

```sh
sudo sead_agent/scripts/install-llm-host-iface.sh
```

Local addresses route via `lo`, and rootless podman forwards the container's traffic
there, so the container can reach it while no external network can. Bind the tunnel to
that address and nothing else:

```sh
# published on the LAN and the VPN - don't
ssh -N -L 0.0.0.0:5040:model-host:8081 user@jump-host

# reachable only from this host and its containers
ssh -N -L 10.123.0.1:5040:model-host:8081 user@jump-host
```

The container resolves this as `llm-host` (see `extra_hosts` in `compose.yml`), which is
what `SEAD_AGENT_LLM_BASE_URL` points at. This arrangement fails closed: if the interface
is missing, the tunnel refuses to bind rather than quietly falling back to a public one.

`SEAD_AGENT_LLM_MODEL` can be left empty, in which case the agent asks the server what it
is serving and uses that.

## Safety

The endpoint is unauthenticated and every request occupies the GPU behind the local model,
so message size, per-IP request rate, parallel turns and remembered conversations are all
capped (see the `SEAD_AGENT_MAX_*` and `SEAD_AGENT_RATE_LIMIT_*` settings).

pi's builtin file and shell tools are switched off by default. When enabled with
`SEAD_AGENT_ENABLE_SANDBOX_TOOLS=true` they only ever reach a throwaway in-memory sandbox
that contains nothing of this container's filesystem.

## Running

```sh
podman compose up -d --build sead_agent
podman compose logs -f sead_agent
curl http://localhost:${SEAD_AGENT_PORT:-8585}/health
```
