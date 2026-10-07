# Tool gateway

> **What this role must provide**
>
> - One endpoint per agent, so a bot bridge points at a single URL and nothing else decides its model.
> - Tool permissions per agent. An agent never sees or runs a tool it is not listed for.
> - A data-residency boundary, checked before any request is served: a hosted model can never be given a tool that reads local data.
> - A daily token budget per agent that survives a restart.
> - Scoped secrets. Provider and search keys reach the gateway's container and no other container.
> - A health endpoint and a log of every tool call.

## Build your gateway

This repo ships no gateway. The requirements above are written as a testable spec in [`specs/tool-gateway.md`](../specs/tool-gateway.md). Build your own from it, or pick an existing gateway that meets it, then build an image and set its tag as `TOOL_GATEWAY_IMAGE` in `.env`. The MUST tier is enough to continue. The SHOULD tier adds metrics, a per-source quota and reasoning handling, and you can add it later.

The compose template uses the image's own `curl` for its container healthcheck. If your image has none, replace the `test` line with any probe of `GET /health`.

## Configure

The templates for this chapter are in `templates/04-tool-gateway/`. `gateway-config.yaml` is a complete example of the config schema in the spec, with two agents.

- `local-agent` uses the local model runtime. It may use `web_search` and `kb_search`.
- `cloud-agent` uses a hosted provider. It may use `web_search` only.

The residency rule in plain words: every model endpoint and every tool source is labeled with where its data goes. A model that runs on your machine is `local`, a hosted one is `cloud`. A tool that reads your data is `local`, a tool that touches only public data is `public`. An agent on a `cloud` endpoint that lists a `local` tool is a mistake a gateway built to the spec will not run with. It exits at startup and says which agent, which endpoint and which tool. The same check runs again whenever a model names a tool, so a hosted model cannot reach a local tool by guessing its name.

`kb_search` stays in the config even though its service arrives in chapter 06. Its source is marked `required: false`, so the gateway boots without it and keeps retrying.

The keys live in `.env`, which the README has you set to mode 600 so only you can read it. Compose reads `.env` to fill in the compose files, and that alone puts no value into a container. `./render.sh` copies the two keys the config names, the hosted provider key and the search key, into the gateway's own env file, `gateway.env`, and only the gateway's compose entry loads that file into a container. A compromised bot bridge then leaks no provider or search key. Your shell also holds the keys after `set -a; . ./.env; set +a` in the chapters that use it, so close that shell when you are done.

Open `.env` and fill in the chapter 04 values.

- Set `TOOL_GATEWAY_IMAGE` to the tag of your build.
- Keep `LOCAL_MODEL` as it is. `CLOUD_MODEL` can keep its default if you skip the cloud agent. Set it to a model your hosted provider offers if you add one.
- Replace both `change-me` keys. A placeholder works for a first start, but the web search tool and the cloud agent need real keys. With a hosted provider, set a spending limit on its key. The reference deployment uses OpenRouter for the hosted provider and Brave Search for the search API. For another hosted provider, change its `base_url` in the config and keep the key names. The `web` source is a built-in adapter for one search API, so another search API needs its own adapter in your build. The source's optional `url` only moves the address of the API that its adapter already speaks.

Create the gateway's two data directories. One holds its counters, the other its log, which can contain message text.

```bash
sudo mkdir -p "$MESH_DATA_DIR"/tool-gateway "$MESH_DATA_DIR"/tool-gateway-logs
sudo chown "$MESH_UID:$MESH_GID" "$MESH_DATA_DIR"/tool-gateway "$MESH_DATA_DIR"/tool-gateway-logs
sudo chmod 700 "$MESH_DATA_DIR"/tool-gateway-logs
```

The gateway runs as the same user and group as the homeserver, so it can write to both directories.

> **macOS:** Run these commands without `sudo` and skip the `chown`, with `MESH_DATA_DIR` set to a folder in your home directory as in chapter 02.

## Start and re-point the agent

Render the templates and open `compose.yaml`. Uncomment the two include lines for chapter 04. Then start the gateway.

```bash
./render.sh
chmod 600 rendered/04-tool-gateway/gateway.env
docker compose up -d tool-gateway
docker compose ps tool-gateway
```

The `chmod` keeps the rendered file with your keys readable by you alone. The service shows as `starting` until the first health check passes, which can take up to 30 seconds, and then as healthy. Now point the chapter 03 agent at it. In `.env`, change the value of `LOCAL_AGENT_BASE_URL`.

```
LOCAL_AGENT_BASE_URL=http://tool-gateway:8101/agents/local-agent/v1
```

Render again and restart the bot. The config is a mounted file, so only a restart makes the bot read it.

```bash
./render.sh
docker compose restart bot-bridge-local-agent
```

The bot keeps its Matrix identity, because its `bot-local-agent` store is untouched. Only the address it sends conversations to changed, and the gateway now picks the model, offers the tools and enforces the budget.

## Add a cloud agent (optional)

This step is opt-in. A cloud agent sends conversation text to a hosted provider, so leave it out if nothing in your rooms may leave your machine. If you add one, its daily token budget and its response cap in the config bound the cost.

The cloud agent is a second bot, set up like the first in chapter 03.

1. Copy `templates/03-first-persona/local-agent.yaml` to `templates/03-first-persona/cloud-agent.yaml`. Change `mxid_localpart` to `cloud-agent`, the name to "Cloud agent", `command_prefix` and the `!local` in the prompt to `!cloud`, and `model_id` to `__CLOUD_MODEL__`. Replace the four secret tokens with `__CLOUD_AGENT_PASSWORD__`, `__CLOUD_AGENT_RECOVERY_PASSPHRASE__`, `__CLOUD_AGENT_SESSION_KEY__` and `__CLOUD_AGENT_CONFIG_KEY__`. Set `base_url` to `http://tool-gateway:8101/agents/cloud-agent/v1`.
2. In `templates/03-first-persona/compose.yaml`, copy the `bot-bridge-local-agent` service as `bot-bridge-cloud-agent`. Mount its own store, `${MESH_DATA_DIR:?}/bot-cloud-agent:/data`, and `./cloud-agent.yaml` as its config.
3. Add the four `CLOUD_AGENT_*` values to `.env`, each generated with `openssl rand -hex 32`, and set `CLOUD_MODEL` to a model your hosted provider offers.
4. Create the data directory the same way as in chapter 03. Load `.env` again with `set -a; . ./.env; set +a` and register the account with the chapter 03 command, using `-u cloud-agent -p "$CLOUD_AGENT_PASSWORD"`. Then render and run `docker compose up -d`.

Each agent keeps its own account, device and keys, and the gateway knows them only by endpoint. A room that holds both agents needs the prefix setting from chapter 03, with `!cloud` as the second prefix.

## Verify

None of these tests needs a paid key. They run from inside the Docker network, because the gateway publishes no port. Load the helper from the spec and run the rest from the repo root.

```bash
mesh_curl() { docker run --rm --network mesh_mesh curlimages/curl "$@"; }
```

Check that the gateway is alive and its sources answer.

```bash
mesh_curl -s -i http://tool-gateway:8101/health
mesh_curl -s -i http://tool-gateway:8101/health/deep
```

The first returns 200 with `{"status": "ok"}`. The second returns 200 as well. Until chapter 06 runs, its body lists `kb_search` under `unavailable`, because that source is optional and not up yet. It may list `web_search` too while `SEARCH_API_KEY` is a placeholder. Next, check that an unknown agent and a broken body fail cleanly.

```bash
mesh_curl -s -i -X POST -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"hi"}]}' http://tool-gateway:8101/agents/no-such-agent/v1/chat/completions
mesh_curl -s -i -X POST -H 'Content-Type: application/json' -d '{not json' http://tool-gateway:8101/agents/local-agent/v1/chat/completions
```

The first returns 404 with `{"detail": "unknown agent: no-such-agent"}`. The second returns 400 with a `detail` that starts with `invalid JSON:`.

Now ask `@local-agent` from your Matrix client a question that needs a web search, such as the latest release of a tool you use. This check needs a real search key and a running local model that supports tool calling. Read the tool-call log afterwards.

```bash
docker compose exec -T tool-gateway sh -c 'cat /var/log/tool-gateway/*'
```

This needs `sh` and `cat` in your image. If it has neither, read the files under `$MESH_DATA_DIR/tool-gateway-logs` on the host instead, with `sudo` on Linux.

A line with `"tool_name": "web_search"` and `"status": "ok"` shows the tool ran, and a line with `"tool_name": "__upstream"` carries the token usage.

Trigger the privacy refusal. In `templates/04-tool-gateway/gateway-config.yaml`, change the `cloud-agent` tools to `[web_search, kb_search]`, then render and restart the gateway. The gateway reads its config once at startup, so a restart is what makes it notice.

```bash
./render.sh
docker compose restart tool-gateway
docker compose logs tool-gateway
```

The gateway exits, and Docker keeps restarting it because of its restart policy, so `docker compose ps tool-gateway` shows it restarting. The log contains `privacy boundary`, with the agent, the endpoint and the tool named. Revert the change, render again and run `docker compose restart tool-gateway`. The gateway starts again.

Last, test the budget and the call-time check with a fake upstream, which needs no model and spends no tokens. Start a mock server on the network and wait until it answers.

```bash
docker run -d --rm --name fake-upstream --network mesh_mesh mockserver/mockserver
until mesh_curl -s -o /dev/null -X PUT http://fake-upstream:1080/mockserver/status; do sleep 2; done
```

Add this to `gateway-config.yaml`, with a new entry under `upstream_providers` and two under `agents`, then render and restart the gateway. `deny-agent` has no budget, so the budget test does not block it.

```yaml
  fake:
    base_url: http://fake-upstream:1080/v1
    api_key_env: null
    data_residency: local
```

```yaml
  test-agent:
    upstream: fake
    model_id: configured-model
    tools: []
    daily_token_budget: 20
  deny-agent:
    upstream: fake
    model_id: configured-model
    tools: []
```

Make the fake upstream answer every request with a reply that reports 15 tokens, then ask `test-agent` three times.

```bash
mesh_curl -s -X PUT http://fake-upstream:1080/mockserver/expectation -d '{"httpRequest": {"method": "POST", "path": "/v1/chat/completions"}, "httpResponse": {"body": {"type": "JSON", "json": {"model": "fake", "choices": [{"index": 0, "message": {"role": "assistant", "content": "done"}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}}}}'
ask_test() { mesh_curl -s -i -X POST -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"hi"}]}' http://tool-gateway:8101/agents/test-agent/v1/chat/completions; }
for i in 1 2 3; do ask_test | head -1; done
```

The output is three status lines: 200, 200 and 429. The first two requests count 15 and 30 tokens, and the third is refused before it reaches the upstream. Run `ask_test` once more to see the whole third response: the `Retry-After` header holds the seconds until UTC midnight, and the `detail` names `test-agent` and its budget. Then run `docker compose restart tool-gateway` and `ask_test | head -1` again. It is still 429, because the count survives a restart.

Now check that a tool the model names is refused at call time. Make the fake upstream answer the next request with a call to `web_search`, which `deny-agent` is not listed for, then ask `deny-agent` once and read the log.

```bash
mesh_curl -s -X PUT http://fake-upstream:1080/mockserver/expectation -d '{"priority": 10, "times": {"remainingTimes": 1}, "httpRequest": {"method": "POST", "path": "/v1/chat/completions"}, "httpResponse": {"body": {"type": "JSON", "json": {"model": "fake", "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {"role": "assistant", "content": "", "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "web_search", "arguments": "{\"query\": \"test\"}"}}]}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}}}}'
mesh_curl -s -X POST -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"hi"}]}' http://tool-gateway:8101/agents/deny-agent/v1/chat/completions
docker compose exec -T tool-gateway sh -c 'cat /var/log/tool-gateway/*' | grep deny-agent
```

The reply is a normal answer with the content `done`, and the log holds a line with `"tool_name": "web_search"` and `"status": "denied"`. The gateway never called the search API. Stop the mock server with `docker stop fake-upstream`, remove the fake provider, `test-agent` and `deny-agent` from the config, render, and run `docker compose restart tool-gateway`.
