# Limitations

This page lists what the design as documented does not do, so you can decide what to add before you rely on it. Each limit holds for any workspace built from these chapters. Where a fix exists, the section ends with it.

## The overlay network is one trust boundary

Only devices you have joined can reach overlay-bound services, and every joined device can reach all of them. A lost or compromised laptop is inside the boundary and can talk to whatever the host binds to the overlay address. Chapter 01 covers the binding rule.

Three metadata paths sit outside that boundary and stay open whatever you configure:

- The overlay network's coordination service sees device names, addresses and when each device is online. It does not see the traffic between devices.
- Certificate transparency logs are public, and the HTTPS certificates for the homeserver name the overlay host and the overlay network.
- Mobile push goes through the client vendor's gateway to Apple or Google. The template's `include_content: false` setting keeps message text out of notifications, so what passes is room and event IDs, an unread count, and which device is notified and when.

Fix path: write access rules in the overlay network so only the devices and ports that need each other can connect, and remove devices you no longer use. Optionally, add a bearer token check to services you build yourself. Choose a neutral machine name, because the name cannot be hidden from the logs. The metadata paths have no fix inside this design. Turning off push removes that path and also removes phone notifications.

## No authentication inside the Docker network

The tool gateway and the knowledge MCP server publish no host port, and neither checks who calls it. Any container on the `mesh` network can call any agent through the gateway, including a cloud agent that spends money on a hosted provider, and can act as the agent user in the knowledge store through the MCP server. A container you add later, or a compromised one, gets that access by being on the network.

Fix path: put each service you add on its own network, and attach it to `mesh` only if it must call a service there. The services in this repo need `mesh` as shipped. The bot bridges and the scribe call the homeserver, the bridges call the gateway, the gateway and the scribe call the knowledge MCP server, and the scribe calls the vector index. Moving any of them off `mesh` breaks those calls. Optional hardening: no chapter provides it, but you can add a bearer token check to your own gateway build and give each bot bridge its own token, which also lets you revoke one agent. Keep the daily token budget and the provider's spending limit in place, because they cap the cost when something misuses a paid agent.

## The gateway is a single point of failure

Every agent that points at the gateway stops answering when it is down, including agents that use only the local model. The scribe talks to the model runtime directly and keeps working.

Fix path: the chapter 03 bot, pointed straight at the model runtime, is the fallback. Set `LOCAL_AGENT_BASE_URL` back to the value of `MODEL_RUNTIME_URL`, render, and run `docker compose restart bot-bridge-local-agent`. The agent then answers without tools, budgets or the call log until you point it back. Running the gateway under a restart policy with its health check keeps most outages short.

## One warm model at a time

Accelerator memory is limited, so the runtime usually holds one model loaded. An agent that uses a different model makes the runtime unload the first and load the second, and the first reply after the swap waits for the load. Two agents on two models trade the slot back and forth.

Fix path: give every local agent the same model, keep it loaded with the timer in chapter 03, or pick a smaller model that leaves room for a second. A second machine running its own runtime is the other way out, with its address set as another upstream in the gateway.

## The tool-call log has no rotation

The gateway appends one line per tool call and per upstream response, and nothing in this design trims the file. It grows without limit and can hold message text, so the directory is mode 700.

Fix path: rotate the directory with the host's log tools, such as `logrotate` with `copytruncate`, or build rotation into your gateway. Decide how long you keep it, because deleting old lines also deletes your record of what agents did.

## Backups are out of scope

This repo contains no backup procedure. Protect these files, which live under `MESH_DATA_DIR`:

| What | Where | If lost |
|---|---|---|
| Homeserver signing key | `homeserver/signing.key` | The server's identity is gone and cannot be replaced. |
| Bot encryption stores | `bot-<agent>/`, one per agent | The bot returns as a new, unverified device that cannot read earlier messages. |
| Scribe encryption store | `scribe/crypto/` | Scribe returns as a new device that cannot read earlier messages. |
| Scribe database | `scribe/scribe.db` | Every summary, to-do and link that is not also filed in the knowledge store is gone. |
| Homeserver database volume | `postgres/` | Rooms, accounts and message history are gone. |

The vector index needs no backup, because the scribe rebuilds it from its database. The knowledge store has its own data to protect, and its self-hosting guide covers that.

Fix path: take a copy of the whole of `MESH_DATA_DIR` on a schedule, to a disk that the host does not own. Stop the homeserver and scribe first or use the database's own dump tool, because copying a live database file can produce a copy that does not open. Keep the copy private, since it holds encryption keys and message text. Test a restore once on a spare machine.

## The public well-known files name the overlay host

The `client` and `server` files on the static host are public, and each contains the delegated host name. Anyone can fetch them and learn the overlay host name, as they can from the certificate logs. Knowing the name does not let anyone connect.

Fix path: give the machine a neutral name before you generate certificates, because a name already in the logs stays there. If the overlay network lets you choose its own name, choose one that does not identify you.

## Federation is closed

The homeserver lists no domains it may federate with, so it talks to no other server and users here cannot join rooms elsewhere or be invited from outside. To open it, set `federation_domain_whitelist` to `null`, publish port 8448 on a public address, point `.well-known/matrix/server` at that public host, and test with the Matrix federation tester. This changes the privacy rules: the host becomes reachable from the internet and its rooms can reach other servers. The rule of no port on a public address no longer holds, so you take on patching and watching a public service. The listener keeps its federation resource, so no restructuring is needed. See [chapter 02](docs/02-homeserver.md).

## Acceptance tests that are not marked passed are untested

The specs for the gateway and the scribe carry acceptance tests with exact commands. A test that the spec does not mark as passed has not been run against the reference deployment. Passing them is your job, because the repo ships neither component. Run every MUST test against your build before you rely on it.

## Chapters 04 to 06 deploy your own builds

The repo cannot vouch for the gateway, the scribe or the filing and search in chapter 06, because it ships no code for them and pins no version of them. Chapter 06 also depends on your scribe build for filing and link search. `VERSIONS.md` says what was tested where. Treat each of these components as untested until your build passes its spec.

## Raw message text stays up to the retention cap in quiet rooms

The scribe deletes raw message text after `raw_message_days` once the room-day summary is stored and filed. A room that never reaches the digest threshold produces no summary, so its raw text stays until the cap of twice `raw_message_days` (six days by default) and is purged then. Summaries stay indefinitely.

Fix path: lower `raw_message_days` in `templates/05-scribe/scribe-config.yaml`, render, then restart the scribe with `docker compose restart scribe`. A shorter window means less raw text on disk, and also less time to regenerate a summary that went wrong. See [chapter 05](docs/05-scribe.md).
