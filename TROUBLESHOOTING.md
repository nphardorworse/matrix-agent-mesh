# Troubleshooting

Entries are keyed by what you see. Each gives the cause, the fix and the chapter that covers the setup. For design limits that are not faults, see [LIMITATIONS.md](LIMITATIONS.md).

## A bot replies to every message in a shared room

**Cause.** The bot decides whether to answer everything from the number of members in the room when it joins, and never checks again. A room that held one person and the bot at that moment keeps answering all messages after a second agent arrives, and agents then reply to each other.

**Fix.** In every room with more than one agent, send `!local config room text-generation set-prefix-requirement-type command_prefix`, using each bot's own prefix. The bot then answers only messages that start with its prefix.

See [chapter 03](docs/03-first-persona.md), "Rooms with more than one agent".

## A bot's messages show as unverified, or it cannot read earlier history

**Cause.** The bot's data directory was lost, emptied or pointed somewhere new, so it logged in as a new device with new keys. A new device has no keys for messages sent before it existed, and your client has not verified it.

**Fix.** Restore the directory from a backup, then restart the bot. If there is no backup, accept that earlier messages stay unreadable to the bot, verify the new device from your client, and keep the directory on persistent storage with the rest of `MESH_DATA_DIR`. The recovery passphrase restores keys that the homeserver still holds. It cannot create keys that never reached it. The scribe behaves the same way: with `device.json` present and its `crypto` folder unusable, a correct build exits with a message about the crypto store rather than creating a second device.

See [chapter 03](docs/03-first-persona.md), "Encryption and verification", and [chapter 05](docs/05-scribe.md).

## The first reply after a quiet period takes several seconds

**Cause.** The model runtime unloaded the idle model, and the first request waits for it to load again. Two agents on two different models also swap each other out, as [LIMITATIONS.md](LIMITATIONS.md) describes.

**Fix.** Keep the model loaded with a timer that sends a tiny request every 25 minutes, as chapter 03 shows, or give every local agent the same model. Raise the upstream timeout if requests that chain several tool turns hit it.

See [chapter 03](docs/03-first-persona.md), "Keeping the model warm".

## Containers cannot reach the model runtime

**Cause.** On Linux, a container reaches the host through the Docker bridge, and a runtime listening only on `127.0.0.1` refuses that traffic. A host firewall can also drop traffic from the Compose networks, which sit on their own bridges. Services that call the runtime also need the `host.docker.internal` entry in `extra_hosts`.

**Fix.** Bind the runtime to the Docker bridge address (find it with `ip -4 addr show docker0`), order it after Docker, allow the runtime port from each Docker subnet in the firewall, and run host-side checks against the bridge address from then on. On macOS no change is needed.

See [chapter 01](docs/01-private-network.md), "Reaching the model runtime from containers".

## A service bound to loopback cannot be reached from another container on Linux

**Cause.** Loopback inside a container is the container itself, and loopback on the host is not on the Docker bridge. A service bound to `127.0.0.1` on the host answers only processes on the host. On macOS, Docker Desktop's `host.docker.internal` reaches loopback, so the same setup works there and fails on Linux.

**Fix.** Bind the service to the Docker bridge address, or attach it to the `mesh` network and call it by service name. Do not bind it to `0.0.0.0` unless a host firewall limits its port to the Docker networks, as chapter 01 describes for the model runtime. This applies to the model runtime and to the knowledge store.

See [chapter 01](docs/01-private-network.md) and [chapter 06](docs/06-knowledge-store.md).

## `tailscale serve` asks for certificates, or fails with a certificate error

**Cause.** HTTPS certificates are not enabled for the overlay network, or MagicDNS is off. The command needs both.

**Fix.** In the overlay network's admin console, turn on MagicDNS and enable HTTPS certificates, then run the `tailscale serve` command again. Other overlay networks have a matching switch for certificates.

See [chapter 01](docs/01-private-network.md), step 4.

## Calls fail at the token step

**Cause.** Either the `federation` resource was removed from the homeserver listener, or the `call-auth` container cannot resolve or reach the homeserver. The call auth service verifies identity with the homeserver's OpenID endpoint, which that resource serves, so it is needed even while federation is closed. It reaches the homeserver by the overlay name it learns from the `.well-known` file, and overlay DNS names sometimes do not resolve inside containers.

**Fix.** Put the `federation` resource back in `homeserver.yaml`, render and restart the homeserver. If the container cannot reach the homeserver, run the throwaway container check from chapter 02b and fix container DNS until it returns the versions list, for example by pointing the container at a resolver that knows the overlay names.

See [chapter 02b](docs/02b-calls.md), "How call auth works".

## Calls stop working after a reboot

**Cause.** The call media ports are bound to the overlay IP. After a reboot Docker can start before the overlay interface has its address, and publishing fails.

**Fix.** On Linux, order Docker after the overlay client with a systemd drop-in, or allow non-local binds with `net.ipv4.ip_nonlocal_bind=1`. Then run `docker compose up -d` to start the services that failed.

See [chapter 01](docs/01-private-network.md), "The binding rule", and [chapter 02b](docs/02b-calls.md).

## The knowledge MCP container shows unhealthy but works

**Cause.** The image probes `localhost`, which resolves to an IPv6 address, while the server listens on IPv4 only. The probe fails although the server answers.

**Fix.** Use the template's healthcheck, which probes `127.0.0.1`. If you wrote your own compose entry, change the probe address the same way.

See [chapter 06](docs/06-knowledge-store.md), "The MCP server".

## Links written by the scribe or an agent do not open in the browser

**Cause.** The knowledge store blocks requests from origins it does not know. A link that uses a short host name, rather than the full overlay name you open the store by, comes from an unknown origin.

**Fix.** Publish the store on the overlay network with an HTTPS mapping, as chapter 06 shows (for example `tailscale serve --bg --https=8450` to the store's bound address), and use that full overlay URL, such as `https://<HS_HOST>:8450`, in every link the scribe or an agent writes. It is the same address your browser shows. Fix links that are already filed by editing them in the store.

See [chapter 06](docs/06-knowledge-store.md), "The MCP server".

## A local model leaks its reasoning into answers, or runs for minutes

**Cause.** Some local models that receive their own reasoning back start echoing it into the answer and stop using tool results. A think flag sent to the runtime's OpenAI-compatible endpoint may not be honored, so reasoning stays always on and a request that chains several tool turns takes minutes.

**Fix.** Use the runtime's reasoning-effort setting, passed as `reasoning_effort` through the gateway, rather than a think flag. Make the gateway strip `reasoning` and `reasoning_content` from assistant messages before it sends them upstream, as the gateway spec requires of its SHOULD tier, and set an upstream timeout long enough for the slowest chain.

See [chapter 04](docs/04-tool-gateway.md) and the "Reasoning toggle and reasoning stripping" test in [the gateway spec](specs/tool-gateway.md).

## A weekly job fires on the wrong day

**Cause.** Scheduler libraries disagree on weekday numbers. A numeric weekday can mean Sunday in one library and Monday in another, so `1` or `0` fires a day off.

**Fix.** Write weekday names in the cron expression, such as `mon` or `mon-fri`, and never numbers. Check the schedule against the time zone in the config, since digest dates follow it. Restart the scribe after a change.

See [chapter 05](docs/05-scribe.md) and [the scribe spec](specs/scribe.md).

## The homeserver will not start

**Cause.** Usually the database was created without C collation, or the signing key belongs to another user. Synapse refuses a database with another collation, and the collation cannot be changed after creation. A key generated without `--user` is typically owned by root, so the homeserver cannot read or write `/data/signing.key`.

**Fix.** Read `docker compose logs homeserver` to see which. For collation, stop the stack, delete the empty `postgres` data directory so the template's `--lc-collate=C --lc-ctype=C` flags apply on the next first start, and start again. Deleting the directory destroys data, so do it only on a new install and restore from a dump otherwise. For the key, load `.env` with `set -a; . ./.env; set +a`, then run `sudo chown "$MESH_UID:$MESH_GID" "$MESH_DATA_DIR"/homeserver/signing.key`, or regenerate it before the first start with the command from chapter 02.

See [chapter 02](docs/02-homeserver.md).

## A config change does not take effect

**Cause.** Services read mounted config files once at startup, and `docker compose restart` reads them again. Values from `.env` are baked into a container when it is created, so a restart keeps the old ones. You also have to run `./render.sh` after editing a template or `.env`, because the services read the files in `rendered/`.

**Fix.** After editing a template, run `./render.sh` and then `docker compose restart <service>`. After editing `.env`, run `./render.sh` and then `docker compose up -d`, which recreates the services whose values changed.

See [chapter 04](docs/04-tool-gateway.md) and [chapter 05](docs/05-scribe.md).

## `./render.sh` reports unfilled tokens

**Cause.** A template holds a `__NAME__` token with no value in `.env`, or the value is empty, or the name is misspelled. The script lists each file and line that still holds a token and exits without finishing.

**Fix.** Add or correct the variable named in the message in `.env`, in the same spelling as the token, then run `./render.sh` again. `./render.sh --check` renders to a temporary folder and reports the same list without touching `rendered/`. Chapter-specific tokens need the chapter's values filled in, so a token from a chapter you have not reached yet means that chapter's block of `.env` is still empty.

See [README](README.md), "Placeholders", and [`.env.example`](.env.example).
