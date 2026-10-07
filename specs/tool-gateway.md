# Tool gateway specification

The tool gateway sits between the bot bridges and the models. Each agent gets one OpenAI-compatible endpoint. Behind that endpoint the gateway picks the agent's model, offers the tools the agent is allowed to use, runs the tool loop and returns the final answer. Permissions, budgets and the data-residency boundary are enforced in this one place, so no bot bridge has to be trusted with them. This repo ships no implementation of the gateway. You build your own from this spec, or choose an existing one that meets it, and chapter 04 deploys your build.

## Conventions

**MUST** marks a requirement that chapter 04 and the privacy rules in the README depend on. A gateway that misses one does not meet this spec. **SHOULD** marks a requirement you can skip with a known cost, stated in its reason. **MAY** marks an option a gateway is free to take or leave. A MAY needs no acceptance test.

Values marked "spec choice" (some defaults, the timeouts and the environment variable names `TOOL_GATEWAY_CONFIG` and `TOOL_GATEWAY_LOG_DIR`) are this spec's picks. Chapter 04 relies on them, so keep them unless you also change the chapter's templates.

Every acceptance test carries one of two labels:

- `passed on reference implementation (YYYY-MM-DD)`: the test was run against the reference deployment on that date with a request that changes nothing and spends no tokens.
- `untested`: the test has not been run against the reference deployment. Tests that would change config, stop a service or spend tokens are never run there.

The passing tests were sent from the host over a loopback port (`127.0.0.1:8101`) instead of from a container on the Docker network. The requests and the expected responses are the same.

### Test helpers

The gateway publishes no host port. All examples reach it as `tool-gateway:8101` from inside the Docker network, either with `docker compose exec <any service with curl> curl ...` or with a throwaway curl container on the compose network `mesh_mesh`. The tests use these shell functions, run from the repo root. They need `jq` on the host.

```bash
mesh_curl() { docker run --rm --network mesh_mesh curlimages/curl "$@"; }
# $1 agent id, $2 request body
ask() { mesh_curl -s -X POST -H 'Content-Type: application/json' -d "$2" "http://tool-gateway:8101/agents/$1/v1/chat/completions"; }
# Print the whole tool-call log.
gw_log() { docker compose exec -T tool-gateway sh -c 'cat /var/log/tool-gateway/*'; }
```

`gw_log` and the S6 test need `sh`, `cat` and `stat` in your image. If it has none, define `gw_log` to read the files under `$MESH_DATA_DIR/tool-gateway-logs` on the host instead, with `sudo` on Linux.

To read only the log lines one test writes, count the lines first with `before=$(gw_log | wc -l)`, send the request, then read `gw_log | tail -n +$((before + 1))`.

Most tests use a fake upstream instead of a real model, so they spend no tokens and give the same answer every time. Start a request-recording mock server on the network:

```bash
docker run -d --rm --name fake-upstream --network mesh_mesh mockserver/mockserver
```

Then add a provider and a test agent to your gateway config and restart the gateway:

```yaml
upstream_providers:
  fake:
    base_url: http://fake-upstream:1080/v1
    api_key_env: null
    data_residency: local
agents:
  test-agent:
    upstream: fake
    model_id: configured-model
    tools: [kb_search]
    max_tool_iterations: 3
    max_response_tokens: 256
```

These functions set what the fake upstream answers and read back what the gateway sent it:

```bash
fake_reply() { mesh_curl -s -X PUT http://fake-upstream:1080/mockserver/expectation -d "$1"; }
fake_requests() { mesh_curl -s -X PUT 'http://fake-upstream:1080/mockserver/retrieve?type=REQUESTS&format=JSON'; }
fake_reset() { mesh_curl -s -X PUT http://fake-upstream:1080/mockserver/reset; }
# Answer every request with a plain text reply that reports 15 tokens.
fake_text() {
  fake_reply '{"priority": 0, "httpRequest": {"method": "POST", "path": "/v1/chat/completions"},
    "httpResponse": {"body": {"type": "JSON", "json": {"model": "fake",
      "choices": [{"index": 0, "message": {"role": "assistant", "content": "done"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}}}}'
}
# The same plain text reply with no usage object.
fake_text_no_usage() {
  fake_reply '{"priority": 0, "httpRequest": {"method": "POST", "path": "/v1/chat/completions"},
    "httpResponse": {"body": {"type": "JSON", "json": {"model": "fake",
      "choices": [{"index": 0, "message": {"role": "assistant", "content": "done"}, "finish_reason": "stop"}]}}}}'
}
# Answer the next $2 requests with a call to tool $1. The message carries a reasoning field.
fake_tool_call() {
  fake_reply '{"priority": 10, "times": {"remainingTimes": '"$2"'},
    "httpRequest": {"method": "POST", "path": "/v1/chat/completions"},
    "httpResponse": {"body": {"type": "JSON", "json": {"model": "fake",
      "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {"role": "assistant", "content": "",
        "reasoning": "internal notes",
        "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "'"$1"'", "arguments": "{\"query\": \"test\"}"}}]}}],
      "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}}}}'
}
```

`fake_requests | jq '.[-1].body.json'` is the last request body the gateway sent upstream. Run `fake_reset` before each test. Remove the test agent and the fake provider when you are done.

Agent ids in examples are `local-agent` (a local upstream), `cloud-agent` (a hosted upstream) and the temporary `test-agent`. Tool names are `web_search` (public data) and `kb_search` (local data).

## Interfaces

**Callers.** Bot bridges call the gateway with OpenAI-compatible Chat Completions requests at `POST /agents/{id}/v1/chat/completions`. A bridge only needs its base URL set to `http://tool-gateway:8101/agents/<id>/v1`. The gateway does not authenticate callers. It relies on network isolation: only containers on its Docker network can reach it, and any of them can call any agent. See [LIMITATIONS.md](../LIMITATIONS.md).

**Upstreams.** Every model the gateway calls speaks OpenAI-compatible Chat Completions at `<base_url>/chat/completions`, with tool calling in the OpenAI format (`tools`, `tool_choice`, `tool_calls` and `role: tool` messages). The local model runtime and a hosted provider both qualify.

**Tool sources.** A tool source is either an MCP server reached over streamable HTTP, or a built-in HTTP adapter that the gateway implements for one HTTP API. The reference has one built-in adapter, for a web search API. The gateway converts each source's tools to OpenAI function schemas before offering them to a model.

## Configuration schema

The gateway reads one YAML file. The path is set by the environment variable `TOOL_GATEWAY_CONFIG` (spec choice), and chapter 04 mounts it at `/config/config.yaml`. A complete example is `templates/04-tool-gateway/gateway-config.yaml`.

Secrets never appear in this file. A key names the environment variable that holds the secret, and the gateway reads that variable at startup. If a named variable is unset, the gateway exits before serving.

### Top level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `global_hard_iteration_cap` | integer | `10` (spec choice) | Upper limit on upstream calls per request for every agent. An agent's own `max_tool_iterations` cannot exceed it. |
| `upstream_providers` | map | required | Model endpoints, keyed by a name of your choice. |
| `tool_sources` | map | `{}` | Tool providers, keyed by a name of your choice. |
| `agents` | map | required | Agents, keyed by agent id. The id is the `{id}` in the endpoint path. |

### `upstream_providers.<name>`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `base_url` | string | required | OpenAI-compatible base URL, such as `http://host.docker.internal:11434/v1`. The gateway appends `/chat/completions`. |
| `api_key_env` | string or null | `null` | Name of the environment variable holding the provider's API key, sent as a bearer token. `null` for a local runtime that needs no key. |
| `data_residency` | `local` or `cloud` | required | `local` if requests stay on your machine, `cloud` if they leave it. A missing or other value aborts boot. |
| `timeout_seconds` | number | `60` (spec choice) | How long to wait for one upstream response. Set it long for a local runtime that loads models on demand (see Reference implementation notes). |

### `tool_sources.<name>`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `type` | `mcp` or `http` | required | `mcp` for an MCP server over streamable HTTP. `http` for a built-in adapter. |
| `url` | string | required for `mcp` | The MCP endpoint, such as `http://knowledge-mcp:8103/mcp`. For `http` it overrides the adapter's built-in API address. |
| `api_key_env` | string | none | Name of the environment variable holding the source's API key, for sources that need one. |
| `required` | boolean | `false` | If `true`, the gateway refuses to boot when the source cannot be reached at startup, and `/health/deep` returns 503 while it is unreachable. If `false`, the gateway boots without the source and keeps retrying. |
| `data_residency` | `local` or `public` | required | `local` if the source reads or writes data on your machine, `public` if it only touches public data. A missing or other value aborts boot. |
| `quota` | map | none | Optional cap on calls to this source. |
| `limit` (inside `quota`) | integer | required | Number of calls allowed per period, counted across all agents. |
| `period` (inside `quota`) | `day` or `month` | required | The counting window, a UTC calendar day or a UTC calendar month. |
| `tools` | list | required | The tools this source exposes to agents. |
| `tools[].source_name` | string | required | The tool's name at the source (for MCP, its name in `tools/list`). |
| `tools[].expose_as` | string | required | The name models and the agents' `tools` lists use. A name used by two sources aborts boot. |
| `tools[].description_override` | string | none | Replaces the source's own tool description in the schema offered to the model. |

### `agents.<id>`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `upstream` | string | required | A key in `upstream_providers`. An unknown name aborts boot. |
| `model_id` | string | required | The model sent upstream. It replaces whatever `model` the caller sent. |
| `tools` | list of strings | `[]` | Exposed tool names this agent may use. A name no source exposes aborts boot. Tools not listed here are never offered to the agent and never run for it. |
| `temperature` | number or null | `null` | Used when the caller sends no `temperature`. `null` leaves it to the caller and the upstream. |
| `max_tool_iterations` | integer | `5` (spec choice) | Upstream calls allowed per request for this agent, capped by `global_hard_iteration_cap`. |
| `max_response_tokens` | integer or null | `null` | Ceiling on `max_tokens` sent upstream. A missing or larger caller value is replaced by this one. `null` means no ceiling. |
| `daily_token_budget` | integer or null | `null` | Total tokens this agent may use per UTC day. `null` means no budget. |
| `system_prompt_suffix` | string | none | Text appended to the caller's system message, or sent as the system message if the caller sent none. |
| `extra_params` | map | `{}` | Fields set on every upstream request for this agent. They override the caller's values for the same keys. |

## Requirements

Each requirement has a reason and an acceptance test. The test gives the request, the expected status and the shape of the body or the log lines.

### MUST

**M1. One endpoint per agent.** The gateway serves `POST /agents/{id}/v1/chat/completions` for every agent in config and returns 404 for any other id.
Reason: a bot bridge points at one URL, and the URL alone decides which model, tools and budget apply.
Test: `mesh_curl -s -i -X POST -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"hi"}]}' http://tool-gateway:8101/agents/no-such-agent/v1/chat/completions`. Expect 404 with body `{"detail": "unknown agent: no-such-agent"}`.
Label: passed on reference implementation (2026-10-04). Like every passed label here, the request was sent from the host over a loopback port, not from a container (see Conventions).

**M2. Request validation and caller-supplied tools.** A body that is not valid JSON returns 400. A body whose `messages` is missing or is not an array returns 400 with a `detail` containing `messages`. Neither is sent upstream. The gateway ignores any `tools` and `tool_choice` the caller sends: the agent's config decides which tools are offered, and the gateway sets `tool_choice` itself.
Reason: a broken request fails fast and costs nothing, and a caller cannot widen an agent's tools.
Test (bad JSON): `mesh_curl -s -i -X POST -H 'Content-Type: application/json' -d '{not json' http://tool-gateway:8101/agents/local-agent/v1/chat/completions`. Expect 400 with body `{"detail": "invalid JSON: <parser message>"}`.
Label: passed on reference implementation (2026-10-04).
Test (messages): `ask local-agent '{}'` and `ask local-agent '{"messages":"hi"}'`. Expect 400 for both, each with a `detail` containing `messages`.
Label: untested.
Test (caller tools): `fake_text`, then `ask test-agent '{"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"web_search","parameters":{"type":"object"}}}],"tool_choice":"required"}'`. Expect `fake_requests | jq -c '.[-1].body.json | [[.tools[].function.name], .tool_choice]'` to print `[["kb_search"],"auto"]`.
Label: untested.

**M3. The gateway owns the model choice and the response cap.** The upstream request always carries the agent's `model_id`, whatever `model` the caller sent. When `max_response_tokens` is set, the upstream `max_tokens` never exceeds it.
Reason: a misconfigured bridge cannot switch an agent to a different or more expensive model, or ask for an unbounded reply.
Test: `fake_text`, then `ask test-agent '{"model":"some-other-model","max_tokens":100000,"messages":[{"role":"user","content":"hi"}]}'`. Expect `fake_requests | jq -c '.[-1].body.json | [.model, .max_tokens]'` to print `["configured-model",256]`.
Label: untested.

**M4. Multi-turn tool loop with an iteration cap.** The gateway offers the agent's tools, runs every tool call the model returns, appends the results as `role: tool` messages and calls the upstream again, until the model answers without tool calls. It makes at most `min(max_tool_iterations, global_hard_iteration_cap)` upstream calls per request. When the agent has tools, every call before the last allowed one sends `tool_choice: "auto"`, and the last allowed call sends `tool_choice: "none"`. If that last response still contains tool calls, the gateway drops them and returns the response's text content, or the fixed text `The request could not be completed within the tool-call limit.` when the content is empty. The response to the caller is a standard Chat Completions body with one assistant message, no `tool_calls`, `finish_reason: "stop"`, and a `usage` object whose `prompt_tokens`, `completion_tokens` and `total_tokens` are the sums over every upstream call in the loop.
Reason: the bridge sees one request and one answer with the true cost, and a model that keeps calling tools cannot run up cost without limit.
Test (normal loop): `fake_tool_call kb_search 1` and `fake_text`, then `ask test-agent '{"messages":[{"role":"user","content":"Search the knowledge base for test."}]}'`. Expect `jq -c '[.choices[0].message.content, .usage.total_tokens]'` on the response to print `["done",30]`, and `fake_requests | jq '.[-1].body.json.messages | map(select(.role == "tool")) | length'` to print `1`.
Label: untested.
Test (cap): set `max_tool_iterations: 2` on `test-agent` and restart. `fake_tool_call kb_search 5` and `fake_text`, then send the same request. Expect `fake_requests | jq 'length'` to print `2`, `fake_requests | jq -r '.[-1].body.json.tool_choice'` to print `none`, and the response's `choices[0].message.content` to be `The request could not be completed within the tool-call limit.` with `usage.total_tokens` equal to `30`.
Label: untested.

**M5. Streaming requests are rejected.** A request with `stream: true` returns 400 with a `detail` containing `stream`, before any upstream call. A gateway MAY instead support streaming by streaming only the final answer after the tool loop; if it does, it states that choice in its own documentation.
Reason: the tool loop needs whole upstream responses, and a clear 400 is better than a stream the bridge cannot parse.
Test: `mesh_curl -s -i -X POST -H 'Content-Type: application/json' -d '{"stream":true,"messages":[{"role":"user","content":"hi"}]}' http://tool-gateway:8101/agents/local-agent/v1/chat/completions`. Expect 400 with a body such as `{"detail": "stream: true is not supported"}`.
Label: untested. The reference bot bridge does not send `stream: true`.

**M6. The privacy boundary and the tool names are checked at config load.** Before serving any request, the gateway validates the config and exits with a nonzero status and a clear message if any of these holds:

- An agent whose upstream has `data_residency: cloud` lists a tool exposed by a source with `data_residency: local`. The message contains `privacy boundary` and names the agent, the upstream and the tool.
- An agent lists a tool name that no source exposes. The message contains `unknown tool` and names the agent and the tool.
- Two sources expose the same name. The message contains `duplicate tool` and names the tool and both sources.
- A provider or tool source has no `data_residency`, or a value outside its allowed set. The message contains `data_residency` and names the provider or source.

An agent with no tools passes. An agent on a `local` upstream may use both `public` and `local` tools.
Reason: no running state exists in which a hosted model can call a tool that reads local data, and a typo or a missing residency cannot quietly change what an agent can reach.
Tests: make each change below on its own, run `docker compose restart tool-gateway`, and expect the gateway to exit (Docker keeps restarting it under `restart: unless-stopped`) and `docker compose logs tool-gateway` to contain the given text. Revert after each.

| Change | Expected text |
|---|---|
| `tools: [web_search, kb_search]` under `cloud-agent` | `privacy boundary` |
| `tools: [web_search, no_such_tool]` under `local-agent` | `unknown tool` |
| a copy of the `kb` source under a second name, such as `kb2`, with the same `tools` list | `duplicate tool` |
| delete the `data_residency` line from the `kb_search` source | `data_residency` |

Label: untested (all four).

**M7. Tools are checked again at call time.** When the model calls a tool that is not in the agent's `tools`, or a name that no source exposes, the gateway never runs it. It returns the tool result `{"error": "tool not available to this agent"}` to the model, logs the call with status `denied`, and the loop continues.
Reason: the boot check covers the config, and this check covers a model that names a tool it was never offered. Without it, a hosted model could reach a local tool by guessing its name.
Test: `fake_tool_call web_search 1` and `fake_text`, then `ask test-agent '{"messages":[{"role":"user","content":"hi"}]}'` (`test-agent` has only `kb_search`). Expect 200 with content `done`, `fake_requests | jq -r '.[-1].body.json.messages[] | select(.role == "tool") | .content'` to contain `tool not available to this agent`, and the new log lines to include one with `"tool_name": "web_search"` and `"status": "denied"`. Repeat with `fake_tool_call no_such_tool 1` and expect the same, with `"tool_name": "no_such_tool"`.
Label: untested.

**M8. Per-agent daily token budget.** The gateway adds up the tokens of every upstream response for each agent per UTC day, in a store that survives a restart. It uses `usage.total_tokens` when the upstream reports it. When the upstream omits `usage`, it counts an estimate of the prompt and completion characters divided by 4, and marks that log line with the note `usage_estimated`. A request for an agent whose total has reached `daily_token_budget` returns 429 with a `Retry-After` header giving the seconds until the next UTC midnight, and is not sent upstream. The check runs before each upstream call, so a request that crosses the budget mid-loop returns what it has, and the agent can overshoot its budget by at most one upstream response. That early return follows the same rule as M4's last call: the gateway drops any tool calls in the last response and returns its text content, or the fixed text from M4 when the content is empty, as a 200 response.
Reason: a chatty or looping agent has a hard daily cost ceiling that a restart does not reset, and the header stops a client from retrying in a tight loop.
Test (budget and restart): set `daily_token_budget: 20` on `test-agent` and restart. `fake_text`, then send `ask test-agent '{"messages":[{"role":"user","content":"hi"}]}'` three times. Expect the first two to return 200 (15 and then 30 tokens counted) and the third to return 429 with a `Retry-After` header and a body `{"detail": "<message naming test-agent and the budget>"}`. Run `docker compose restart tool-gateway`, send it again, and expect 429.
Label: untested.
Test (estimate): remove `daily_token_budget`, restart, run `fake_reset` and `fake_text_no_usage`. Send one request. Expect a new log line with `"tool_name": "__upstream"`, `"note": "usage_estimated"` and an `upstream_usage.total_tokens` above 0.
Label: untested.

**M9. Scoped secrets.** The gateway's environment holds only the keys named by `api_key_env` in its config, plus its own non-secret settings.
Reason: the gateway holds paid keys, and no other service needs them. A compromised bot bridge or scribe then leaks no provider or search key.
Test: `docker compose exec tool-gateway env | cut -d= -f1`. Expect only the variable names your config references and the gateway's own settings, such as `TOOL_GATEWAY_CONFIG` and `TOOL_GATEWAY_LOG_DIR`.
Label: untested.

**M10. Shallow health.** `GET /health` returns 200 whenever the process is serving, without calling any upstream or tool source.
Reason: the container healthcheck needs a cheap answer that does not depend on other services.
Test: `mesh_curl -s -i http://tool-gateway:8101/health`. Expect 200 with body `{"status": "ok"}`.
Label: passed on reference implementation (2026-10-04).

**M11. Deep health and required sources.** A source with `required: true` that cannot be reached at startup aborts boot. Each `GET /health/deep` call probes every tool source, with a timeout of 5 seconds (spec choice) per source. An MCP source is probed by listing its tools. An HTTP adapter is probed with a cheap request the adapter defines, which never counts against `quota`. The response is:

- 200 with `{"status": "ok"}` when every source answers.
- 200 with `{"status": "ok", "unavailable": [<exposed tool names>]}` when only sources with `required: false` fail.
- 503 with `{"status": "degraded", "unavailable": [<exposed tool names>]}` when any source with `required: true` fails.

The `unavailable` list always holds every exposed tool name whose source failed the probe, required or not.
Reason: the status code tells a monitor whether the gateway lost something it cannot work without, and the list tells an operator every tool agents have lost, without reading logs.
Test (healthy): `mesh_curl -s -i http://tool-gateway:8101/health/deep`. Expect 200 with body `{"status": "ok"}`.
Label: passed on reference implementation (2026-10-04).
Test (optional source down): with `required: false` on the `kb_search` source, run `docker compose stop knowledge-mcp` and repeat the request. Expect 200 with body `{"status": "ok", "unavailable": ["kb_search"]}`. Run `docker compose start knowledge-mcp`.
Label: untested.
Test (required source down): set `required: true` on the `kb_search` source, restart the gateway while `knowledge-mcp` runs, then stop `knowledge-mcp` and repeat the request. Expect 503 with body `{"status": "degraded", "unavailable": ["kb_search"]}`. Start the service and revert the change.
Label: untested.

**M12. Every tool call is logged.** The gateway appends one JSONL line per tool call, including denied ones, and one per upstream response, in the format under Tool-call log.
Reason: the README promises that you can read back what each agent did, with which tool, and what it cost.
Test: with `knowledge-mcp` running, `fake_tool_call kb_search 1` and `fake_text`, then `before=$(gw_log | wc -l)` and `ask test-agent '{"messages":[{"role":"user","content":"Search the knowledge base for test."}]}'`. Expect `gw_log | tail -n +$((before + 1)) | jq -c '[.agent_id, .tool_name, .status, (.upstream_usage | if . then .total_tokens else null end)]'` to print these three lines, in any order:

```
["test-agent","__upstream","ok",15]
["test-agent","kb_search","ok",null]
["test-agent","__upstream","ok",15]
```

Label: untested.

### SHOULD

**S1. Optional per-source quota.** When a source has `quota`, the gateway counts calls to it per period across all agents, in a store that survives a restart. Once the limit is reached, a tool call returns the tool result `{"error": "<tool> quota exhausted; do not retry this turn"}` to the model instead of calling the source, and logs it with status `quota`. The request itself still succeeds.
Reason: a metered API cannot run past its plan, and the model learns to answer without the tool instead of retrying. Skipping this leaves the API's own billing as the only limit.
Test: set `quota: {limit: 0, period: day}` on the `kb_search` source and restart. `fake_tool_call kb_search 1` and `fake_text`, then `before=$(gw_log | wc -l)` and `ask test-agent '{"messages":[{"role":"user","content":"Search the knowledge base for test."}]}'`. Expect 200 with content `done`, the new log lines to include `"tool_name": "kb_search"` with `"status": "quota"`, and the tool message in `fake_requests | jq '.[-1].body.json.messages'` to contain `quota exhausted`. Revert the change.
Label: untested.

**S2. Metrics endpoint.** `GET /metrics` returns request counts and latencies in the Prometheus text format.
Reason: request rates and error rates can be graphed without parsing the log. Skipping it leaves the log as the only record.
Test: `mesh_curl -s -i http://tool-gateway:8101/metrics`. Expect 200 with a `Content-Type` starting with `text/plain` and lines starting with `# HELP`.
Label: untested.

**S3. One MCP session per tool call.** The gateway opens a new MCP session for each tool call and closes it afterward. It refreshes each MCP source's tool list on a fixed interval of its choosing, so tools added or removed at the source appear or disappear without a gateway restart. A failed tool call alone does not mark a tool unavailable.
Reason: a new session per call costs little (about 50 ms in the reference) and removes all session retry logic when an MCP server restarts. A single failed call does not hide a tool from the model until the next refresh.
Test: with `kb_search` working, run `docker compose restart knowledge-mcp` without restarting the gateway. Wait until `docker compose ps knowledge-mcp` shows it healthy, then for one more tool-list refresh interval of your build. Then `fake_tool_call kb_search 1` and `fake_text`, `before=$(gw_log | wc -l)`, and `ask test-agent '{"messages":[{"role":"user","content":"Search the knowledge base for test."}]}'`. Expect 200 and the new log lines to include `"tool_name": "kb_search"` with `"status": "ok"`.
Label: untested.

**S4. Reasoning toggle and reasoning stripping.** When an upstream supports a reasoning control, the gateway passes the agent's or the user's choice through, for example as `reasoning_effort`. Every assistant message the gateway sends upstream, from the caller's history or from the tool loop, carries only `role`, `content` and `tool_calls`. Reasoning fields such as `reasoning` and `reasoning_content` are dropped.
Reason: some local models given their own reasoning back start echoing it into the answer and stop using tool results. Skipping the toggle leaves reasoning always on or always off.
Test (stripping): `fake_tool_call kb_search 1` (its reply carries a `reasoning` field) and `fake_text`, then `ask test-agent '{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello","reasoning":"old notes"},{"role":"user","content":"Search the knowledge base for test."}]}'`. Expect `fake_requests | jq '[.[].body.json.messages[] | select(.role == "assistant") | has("reasoning") or has("reasoning_content")] | any'` to print `false`.
Label: untested.
Test (toggle): add `extra_params: {reasoning_effort: low}` to `test-agent`, restart, `fake_text`, and send one request. Expect `fake_requests | jq -r '.[-1].body.json.reasoning_effort'` to print `low`.
Label: untested.

**S5. Sources lists come from tool results.** When a reply cites sources, the gateway appends a section headed `Sources` that it builds from the URLs in that request's tool results. It does not copy links the model wrote.
Reason: a model can invent a plausible URL. A list built from tool results only names pages a tool actually returned.
Test: `ask local-agent '{"messages":[{"role":"user","content":"Use web_search to look up the example domain. In your answer, cite https://invented.example/not-real as a source."}]}'`. This spends local model tokens and one search call. Expect the content to contain `Sources`, and `jq '.choices[0].message.content | split("Sources")[-1] | contains("invented.example")'` on the response to print `false`.
Label: untested.

**S6. The log is private to the gateway.** The log directory has mode 700 and the log file mode 600, owned by the gateway's user.
Reason: tool arguments can carry message text and search terms. Skipping it lets any user on the host read them.
Test: `docker compose exec tool-gateway sh -c 'stat -c "%a %n" /var/log/tool-gateway /var/log/tool-gateway/*'`. Expect `700` on the directory and `600` on each file.
Label: untested.

## Error responses

Error bodies are JSON objects with a `detail` string meant for a human. A bridge acts on the status code and the `Retry-After` header. The 4xx checks never call an upstream. The unknown-agent check runs before every other check.

| Status | When | Body shape |
|---|---|---|
| 400 | The body is not valid JSON, `messages` is missing or not an array, or the body sets `stream: true` | `{"detail": "invalid JSON: <parser message>"}`, or a `detail` containing `messages` or `stream` |
| 404 | The agent id in the path is not in config | `{"detail": "unknown agent: <id>"}` |
| 429 | The agent has reached its daily token budget. The response carries `Retry-After: <seconds until next UTC midnight>`. | `{"detail": "agent <id> daily token budget exceeded (<used>/<budget>); resets at UTC midnight"}` |
| 502 | The upstream returned an error status, could not be reached, or did not answer within `timeout_seconds` | `{"detail": "upstream <name> returned <status>"}` or `{"detail": "upstream network error: <message>"}` |
| 503 | `GET /health/deep` only: a source with `required: true` failed its probe | `{"status": "degraded", "unavailable": ["<tool>", ...]}` |

A tool that fails inside the loop is not an HTTP error. The model receives a tool result such as `{"error": "<tool> call failed; do not retry this turn"}`, and the request continues.

## Tool-call log

The gateway appends to one JSONL file in the directory set by `TOOL_GATEWAY_LOG_DIR` (spec choice; chapter 04 uses `/var/log/tool-gateway`). The file name is up to your build. Each line is one JSON object:

| Field | Type | Meaning |
|---|---|---|
| `ts` | number | Unix time in seconds, with fractions. |
| `agent_id` | string | The agent that made the call. |
| `tool_name` | string | The tool name the model called, or `__upstream` for a line that records one upstream response. |
| `args_truncated` | string | The call's arguments serialized as JSON, cut to the first 500 characters. `"{}"` on upstream lines. |
| `status` | string | One of the values below. Always `ok` on upstream lines. |
| `latency_ms` | integer | Time the tool call took. `0` on upstream lines and on calls that were never sent. |
| `upstream_usage` | object or null | The upstream's `usage` object as reported, including a `cost` field when the provider reports one, or the estimate from M8. `null` on tool lines. |
| `note` | string or null | Extra detail: `usage_estimated` (M8), or `args_unparseable_json` when the model sent arguments that were not valid JSON. |

Status values on tool lines:

| Status | Trigger |
|---|---|
| `ok` | The source returned a result. |
| `error` | The source returned an error, or the call failed for any reason not listed below, such as a refused connection or a rate limit from the source's API. |
| `timeout` | The source did not answer within 30 seconds (spec choice). |
| `quota` | The source's quota was exhausted, so the call was not sent (S1). |
| `denied` | The tool is not in the agent's `tools`, or no source exposes the name, so the call was not sent (M7). |
| `unavailable` | The source was marked unavailable by its last tool-list refresh, so the call was not sent. |

Example lines, one tool call and one upstream response:

```json
{"ts": 1767225600.123, "agent_id": "local-agent", "tool_name": "web_search", "args_truncated": "{\"query\": \"example query\"}", "status": "ok", "latency_ms": 412, "upstream_usage": null, "note": null}
{"ts": 1767225601.456, "agent_id": "local-agent", "tool_name": "__upstream", "args_truncated": "{}", "status": "ok", "latency_ms": 0, "upstream_usage": {"prompt_tokens": 812, "completion_tokens": 64, "total_tokens": 876}, "note": null}
```

The log is not rotated by the gateway. Rotate it with the host's tools or accept that it grows.

## Reference implementation notes

These describe the reference deployment's gateway on the date above. They are not part of the contract.

- **Timeouts.** The reference sets one upstream timeout per provider: 240 seconds for the local runtime and 60 seconds for the hosted provider. A local runtime can take tens of seconds to load a model after it has been unloaded, and a request that chains several tool turns with reasoning turned on can take minutes. The reference sets these in code by provider name; this spec moves them to `timeout_seconds`.
- **Reasoning fields.** The local runtime in the reference does not support the hosted provider's `reasoning` request field, so the gateway removes it from requests to the local runtime. The local agent's reasoning toggle is a per-message marker that the user types, which the gateway removes from the message and maps to the OpenAI `reasoning_effort` field.
- **Parameter merging.** The upstream request starts from the caller's body. The gateway then sets `model`, sets every `extra_params` key (overriding the caller), adds `temperature` only when the caller sent none, and lowers `max_tokens` to `max_response_tokens` when the caller's value is missing or larger.
- **Budget.** The reference keeps the daily token counter and the search quota counter in small database files under its data directory. It checks the budget before the request and before every upstream call in the loop, and returns the last response it has when the budget runs out mid-loop.
- **MCP sessions.** A new streamable HTTP session per tool call costs about 50 ms of connection and initialization in the reference, small next to model latency. Tool lists refresh every 30 seconds. MCP tool results are cut to 4096 characters.
- **Search quota.** The reference's web search quota is 1800 calls per UTC month, under the search provider's free tier.
- **Config differences.** The reference's built-in search adapter uses its own type name and a `monthly_budget` key in place of `type: http` and `quota`. Schema details in this spec that differ from the reference are untested.
- **Reply footer.** The reference appends the names of the tools used, and a reasoning marker, to the end of the final answer. This is a display choice for chat and is not required.
