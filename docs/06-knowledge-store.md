# Knowledge store

> **What this role must provide**
>
> - A document store that agents can write to under their own name, so every agent-written document has an honest author.
> - A vector index for search by meaning, with the search running on your machine.
> - Both local. Neither calls a hosted service, and no cloud agent can reach either one.

## Reference: AFFiNE and Qdrant

The reference deployment uses AFFiNE as the document store and Qdrant as the vector index. Any document store with an MCP server and any vector index that scribe's adapter can talk to fills the same roles.

Run AFFiNE from its own self-hosting compose file, not from this repo. Follow the [AFFiNE self-hosting guide](https://docs.affine.pro/self-host-affine), pin the image to `0.27.0`, and never bind its port to `0.0.0.0`. On Linux the MCP server reaches it through `host.docker.internal`, which is the Docker bridge address, so bind the store to that address (the same pattern as the model runtime in chapter 01) or attach it to the mesh network. A loopback-only bind serves only your own browser and the MCP server cannot reach it. On macOS, Docker Desktop's `host.docker.internal` reaches loopback, so a loopback bind works. Create the workspace and a human owner account there.

To open the store in a browser from your laptop or phone, including when the host is a headless Linux machine, publish it over the overlay network the same way as the homeserver in chapter 02 and the call services in chapter 02b. Map a new HTTPS port on the overlay name to the address the store is bound to. With the reference overlay network, on Linux with the store on the Docker bridge address:

```bash
tailscale serve --bg --https=8450 http://172.17.0.1:3010
```

On macOS, with a loopback bind, use `http://127.0.0.1:3010` as the target. The store then opens at `https://<HS_HOST>:8450` from every device on the overlay network. That full URL is the one to use in links (see below), and if the store has a setting for its own external address, set it to the same URL. With another overlay network, use its own HTTPS proxy with the same mapping.

The rest of this chapter assumes the store answers at the address you put in `KNOWLEDGE_STORE_URL`.

The vector index and the store's MCP server come from `templates/06-knowledge-store/compose.yaml`. Qdrant is a plain container with one data directory. Create it first.

```bash
sudo mkdir -p "$MESH_DATA_DIR"/vector-index/snapshots
sudo chown -R "$MESH_UID:$MESH_GID" "$MESH_DATA_DIR"/vector-index
```

The template sets `QDRANT__TELEMETRY_DISABLED` to `"true"` for the vector index, because Qdrant otherwise sends anonymized usage telemetry to its vendor. If you substitute another index, or run the knowledge store from its upstream compose file, check its documentation for telemetry and turn it off the same way.

Both services run as the same user and group as the homeserver. Qdrant writes its storage and snapshot directories, and the snapshot directory sits inside the storage one so one `chown` covers both. The MCP server keeps no files. If an image you substitute refuses to run as that user, remove the `user` line for it and give its data directory the owner the image documents.

> **macOS:** Run the `mkdir` without `sudo` and skip the `chown`, with `MESH_DATA_DIR` set to a folder in your home directory as in chapter 02.

## An account for the agents

Create a second user in the knowledge store, only for agents. Every document an agent writes then shows that user as its author, and a person can tell machine edits from human ones. Keep a human as the owner of the workspace and add the agent user as a member with edit rights. If you ever revoke the agent, the workspace and everything in it stays under a human owner.

Put the agent user's email and a generated password in `.env` as `KNOWLEDGE_AGENT_EMAIL` and `KNOWLEDGE_AGENT_PASSWORD` (`openssl rand -hex 32` makes a good password). Copy the workspace id from the store's address bar into `KNOWLEDGE_WORKSPACE_ID`.

## The MCP server

The reference runs a third-party MCP server for AFFiNE, pinned in `.env` as `KNOWLEDGE_MCP_TAG`. It logs in as the agent user, then offers tools to search, read and write documents. Fill in the rest of the chapter 06 block of `.env`: `QDRANT_TAG` and `KNOWLEDGE_STORE_URL`, which is the store's address as seen from inside a container. `host.docker.internal` reaches a service on the host, and on Linux the template's `extra_hosts` line makes that name work.

Three facts about this server shape the template.

- **Its healthcheck needs an override.** The image probes `localhost`, which resolves to an IPv6 address while the server listens on IPv4, so it reports unhealthy while working. The template probes `127.0.0.1` instead.
- **It has no authentication.** Anyone who can reach its port acts as the agent user. The template publishes no port, and only services on the mesh network can reach it. Never add a `ports` entry for it.
- **Links must use one host name.** The store blocks requests from origins it does not know. A link that scribe or an agent writes into a document has to use the full overlay URL of the store, such as `https://<HS_HOST>:8450`, the one you open it by in your browser, or the link will not open.

Render the templates and open `compose.yaml`. Uncomment the two include lines for chapter 06. Then start both services.

```bash
./render.sh
docker compose up -d vector-index knowledge-mcp
docker compose ps
```

## Turn on scribe's memory

Scribe files into the store and indexes links when you fill in two sections of its config. Edit `templates/05-scribe/scribe-config.yaml`.

First, create a document in the store that will hold the digests, and a table that will hold the to-dos. Copy their ids from their addresses.

Under `vector_index`, set the index address. The collection name and the embedding setting already match the reference.

```yaml
vector_index:
  url: http://vector-index:6333
  collection: links
  embedding: in_process
```

`in_process` means link text is embedded inside scribe's own process and goes to no endpoint. That keeps the residency promise of chapter 05 without further setup. The other value, `runtime`, sends the text to your local model runtime's `/embeddings` endpoint and needs an `embedding_model` too.

Under `knowledge_store`, turn filing on and set the keys.

```yaml
knowledge_store:
  enabled: true
  url: http://knowledge-mcp:8103/mcp
  workspace_id: <your workspace id>
  digest_parent: <id of the digests document>
  todos_target: <id of the to-do table>
```

Render and restart scribe. The config is read once at startup.

```bash
./render.sh
docker compose restart scribe
```

Filing is best effort. If the store or the MCP server is down, a digest still succeeds, its rows stay unfiled, and the next run files them. Scribe also keeps raw message text until the matching summary is filed, within the retention cap from chapter 05, so a short outage loses nothing. The link index is a copy. To rebuild it, delete the collection (`links` by default) from the index, then restart scribe, which re-indexes every link from its store. Or stop `vector-index`, delete its directory, start it again, then restart scribe, in that order.

## Link titles (optional)

By default scribe stores each link with only its URL, room and note, and contacts no linked site. To have it fetch each page's title and description, which makes link search work better, set this in `templates/05-scribe/scribe-config.yaml`:

```yaml
links:
  fetch_metadata: true
```

Turning it on adds an outbound path. For every link saved in a room, by `!link` or from a digest, scribe sends a request from your host to the linked site, which learns your host's public address and the time. That includes private share links pasted in a private room. A build that meets S3 in the spec refuses addresses on your own networks, so a link cannot make scribe call your services. Leave it off if your rooms share links you would not open from the host yourself. Render and restart scribe after the change.

## Let an agent write on request (optional)

The gateway config from chapter 04 already lists a `kb` tool source that maps the server's `search_docs` tool to `kb_search`, so search works as shipped. To let the agent write, add entries under the `kb` tool list in `templates/04-tool-gateway/gateway-config.yaml`, then add their `expose_as` names to `tools` under `local-agent`.

Each entry has a `source_name` (the server's tool) and an `expose_as` (the name the agent sees), in the same shape as the search entry. Use these pairs.

- `create_doc_from_markdown` exposed as `kb_create_doc`
- `append_markdown` exposed as `kb_append`
- `add_database_row` exposed as `kb_add_row`

The source keeps `data_residency: local`. Add these tools to `local-agent` only. Never add them to `cloud-agent`: a gateway built to the spec refuses to start when a cloud agent lists a local tool. Documents the agent creates carry the agent user as author. Render and restart the gateway with `docker compose restart tool-gateway`.

## Verify

Check the services first.

```bash
docker compose ps vector-index knowledge-mcp
```

Both show as running, and `knowledge-mcp` shows as healthy after its first check. Then check each path with your scribe build.

- **Filing.** In a group room, send three messages as an admin and run `!digest`. A document for the current month appears under the digests document, with a section headed by today's date and the room name.
- **Link index.** Run `!link https://example.com/ a page about gardening`. Search for it by meaning, with different words such as "plants", through your scribe build. The link comes back.
- **Agent search.** In a room with `local-agent`, ask it to search the knowledge base for the digest you just filed. The gateway log shows a `kb_search` call with status `ok`.
- **The residency check.** Add `kb_search` to `cloud-agent` in the gateway config, run `./render.sh`, and restart the gateway. It exits at startup and names the agent and the tool, and Docker keeps restarting it. Remove the line, render and restart again.
