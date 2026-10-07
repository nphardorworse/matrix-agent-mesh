# Homeserver

> **What this role must provide**
>
> - A Matrix homeserver with end-to-end encryption.
> - A database the homeserver supports.
> - Delegation, so user IDs use your domain while the server lives on the overlay network.
> - A client that works on phones.

## Reference: Synapse with Postgres

The reference deployment runs Synapse with Postgres. Any homeserver that meets the four requirements in the box works, and the rest of the repo only needs the Matrix client API from it. The templates in `templates/02-homeserver/` are for Synapse.

## Configure

Open `.env` and fill in the chapter 02 values.

- Generate each of `POSTGRES_PASSWORD`, `REGISTRATION_SHARED_SECRET`, `MACAROON_SECRET_KEY` and `FORM_SECRET` with `openssl rand -hex 32`. Use a different value for each.
- Set `MESH_DATA_DIR` to an absolute path outside the repo.
- Set `MESH_UID` and `MESH_GID` to the user and group that own that directory.

> **macOS:** Use a folder in your home directory, such as `$HOME/mesh-data` written out in full (run `echo $HOME/mesh-data` to see it), and run the `mkdir` and `chown` commands below without `sudo`. The macOS root volume is read-only, so the `/srv` default cannot be created, and Docker Desktop shares `/Users` with containers by default. Set `MESH_UID` and `MESH_GID` to the output of `id -u` and `id -g`.

Render the templates.

```bash
./render.sh
```

Open `compose.yaml` and uncomment the two include lines (`- path:` and `env_file:`) for chapter 02. Then create the data directories and give them to that user.

```bash
set -a; . ./.env; set +a
sudo mkdir -p "$MESH_DATA_DIR/postgres" "$MESH_DATA_DIR/homeserver"
sudo chown "$MESH_UID:$MESH_GID" "$MESH_DATA_DIR/homeserver"
```

The Postgres image sets the ownership of its own directory on first start.

## Generate the signing key

The homeserver signs everything it sends with one key. Generate it before the first start. With `.env` loaded in your shell as above, run:

```bash
docker compose run --rm --user "$MESH_UID:$MESH_GID" --entrypoint python homeserver -m synapse.app.homeserver --config-path /config/homeserver.yaml --generate-keys
```

The command also starts the database container, which is expected. It writes `/data/signing.key` as the data owner and exits. That file is the one thing you cannot replace. Lose it and the server's identity is gone. Back it up with the rest of `MESH_DATA_DIR`.

> **Note:** Tested on macOS with Docker Desktop and Synapse v1.152.1. The first run also pulls the images, so expect a lot of output.

## Start

```bash
docker compose up -d
docker compose logs -f homeserver
```

Wait until the log says the homeserver is listening on port 8008, then press Ctrl+C.

## Publish over the overlay network

Run the proxy command from chapter 01. It gives the homeserver an HTTPS address on the overlay network and keeps the container port on loopback. On Linux, add `sudo` unless you set yourself as the operator in chapter 01. With another overlay network, use its own HTTPS proxy to forward port 8448 to `127.0.0.1:8008`.

```bash
tailscale serve --bg --https=8448 http://127.0.0.1:8008
```

## Delegation

User IDs look like `@alice:example.com`, but the server lives at `HS_HOST`. Two small JSON files on your domain tell clients where to go. `./render.sh` produced them in `rendered/02-homeserver/static-host/`. Upload that folder to the static host so these addresses work:

- `https://<WELLKNOWN_HOST>/.well-known/matrix/client`
- `https://<WELLKNOWN_HOST>/.well-known/matrix/server`

Both files need the JSON content type and an `Access-Control-Allow-Origin: *` header. The `_headers` file sets them on static hosts that read such a file. Other static hosts would serve `_headers` as a public file, so leave it out of the upload there and set the same two headers in the host's own way.

> **Warning:** Both public files, `client` and `server`, contain your overlay host name. Give the machine a neutral name.

## Create accounts

Registration is closed. Create the first account as an admin.

```bash
docker compose exec homeserver register_new_matrix_user -c /config/homeserver.yaml -u alice -a http://localhost:8008
```

The command asks for a password. Create other people the same way without `-a`, and answer no when it asks whether to make them an admin. Bots get their accounts the same way in chapter 03.

## Room defaults

Encryption is on by default for every new room, because `homeserver.yaml` sets `encryption_enabled_by_default_for_room_type: all`. The server applies it when a room is created, so changing the setting later does not touch existing rooms. Once a room is encrypted, it stays encrypted.

For rooms that contain agents, set history visibility to "members since invited", so a newly invited member reads nothing from before the invite. Set power levels so agents are ordinary members and only people can change room settings. Both are per-room settings in the client, made by a room admin. In Element on a laptop, open the room settings: history visibility is under Security & Privacy ("Who can read history?"), and power levels are under Roles & Permissions. Element X shows similar settings in the room details on recent versions. If yours does not, use Element on a laptop for this step.

## Plain users, not an appservice

Each agent is a normal Matrix user with its own login and its own device. End-to-end encryption then works with no bridging extensions, and there is no registration file to keep in sync with the homeserver.

## The client

The reference client is Element X. It needs native sliding sync, which recent Synapse versions provide. On the reference deployment, Element X on phone and desktop logs in with a password against Synapse 1.152.1 with no separate auth service. The macOS smoke test checked password login through the client API only and did not run Element X. `VERSIONS.md` records this. Every client device must be on the overlay network.

## Phone notifications

Notifications to phones leave the overlay network. The homeserver sends each one to the client vendor's push gateway, which passes it to Apple or Google. The template sets `push: {include_content: false}` in `homeserver.yaml`, so a notification carries room and event IDs and an unread count, never message text or sender names. The phone then fetches the message itself over the overlay network. The metadata (which device gets a notification, and when) still passes through those services.

## Opening federation later

Federation is closed. To open it, set `federation_domain_whitelist` to `null`, publish port 8448 on a public address, point `.well-known/matrix/server` at that public host, and test with the Matrix federation tester. This changes the privacy rules in [the intro](00-intro.md), because the host is then reachable from the internet.

## Verify

Fetch both delegation files from anywhere.

```bash
curl -s https://<WELLKNOWN_HOST>/.well-known/matrix/client | jq .
curl -s https://<WELLKNOWN_HOST>/.well-known/matrix/server | jq .
```

The client file shows your `HS_HOST` as the base URL, and the server file shows `HS_HOST` with port 8448. Check the headers of both.

```bash
curl -sI https://<WELLKNOWN_HOST>/.well-known/matrix/client
curl -sI https://<WELLKNOWN_HOST>/.well-known/matrix/server
```

Each response includes `content-type: application/json` and `access-control-allow-origin: *`.

From a device on the overlay network, ask the homeserver for its versions.

```bash
curl -s https://<HS_HOST>:8448/_matrix/client/versions | jq .versions
```

The output is a list of Matrix versions. Then log in as `@alice:<SERVER_NAME>` from a phone, create a room and invite a second account you created under Create accounts. The room shows the encryption shield.
