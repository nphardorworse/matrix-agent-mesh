# First persona

> **What this role must provide**
>
> - A Matrix bot that logs in as its own user.
> - End-to-end encryption, so it can read and write in encrypted rooms.
> - A connection to an OpenAI-compatible endpoint, which it sends the conversation to and reads the reply from.

## Reference: baibot

Any Matrix bot that speaks an OpenAI-compatible API works. The reference deployment uses baibot, and the templates in `templates/03-first-persona/` are for it. In this chapter the bot talks straight to the model runtime from chapter 00. Chapter 04 points the same setting at the tool gateway instead.

## Why each agent is its own user

Every agent gets its own Matrix account, and with it its own device and its own encryption identity. Permissions are then set per agent: you can invite one agent to a room and keep another out, and a room admin can change what each may do. The room also shows who said what, because every message carries the sender's name and a verification state.

## Configure

Open `.env` and fill in the chapter 03 values before you create the account, because the account takes its password from there.

- Copy the tag for `BAIBOT_TAG` from `VERSIONS.md`.
- Set `LOCAL_MODEL` to a model your runtime has pulled and that supports tool calling.
- Check `MODEL_RUNTIME_URL`, the runtime's address as containers reach it. The example value is the reference runtime's default port through `host.docker.internal`, set up in chapter 01 (on Linux, the runtime must listen on the Docker bridge address). If your runtime uses another port or path, change it, and set `LOCAL_AGENT_BASE_URL` to the same value. Chapter 04 changes `LOCAL_AGENT_BASE_URL` to the gateway.
- Generate each of the four secrets with `openssl rand -hex 32`.

In `templates/03-first-persona/local-agent.yaml`, `admin_patterns` holds `@alice` as a stand-in for your own account. Replace it with your own Matrix id. Users who match `admin_patterns` administer the bot.

## Create the bot account

Registration is closed, so create the account with the shared secret, the same way as in chapter 02. Load `.env` into your shell first, so the command uses the password you just generated.

```bash
set -a; . ./.env; set +a
docker compose exec homeserver register_new_matrix_user -c /config/homeserver.yaml -u local-agent -p "$LOCAL_AGENT_PASSWORD" --no-admin http://localhost:8008
```

The bot is a plain member, never an admin. The password shows in the host's process list while the command runs. On a host that other people log in to, leave out `-p` and paste the value from `.env` when the command asks for it.

## Start

Create the bot's data directory.

```bash
sudo mkdir -p "$MESH_DATA_DIR"/bot-local-agent
sudo chown "$MESH_UID:$MESH_GID" "$MESH_DATA_DIR"/bot-local-agent
```

The bot runs as the same user and group as the homeserver, so it can write to its store. The `chown` gives it the directory.

> **macOS:** Run the `mkdir` without `sudo` and skip the `chown`, with `MESH_DATA_DIR` set to a folder in your home directory as in chapter 02.

Render the templates and open `compose.yaml`. Uncomment the two include lines (`- path:` and `env_file:`) for chapter 03. Then start it.

```bash
./render.sh
docker compose up -d
```

## Encryption and verification

The `bot-local-agent` directory is the bot's identity. It holds the keys for its device and for every room it has joined. The recovery passphrase lets the bot restore its keys from the homeserver, and `recovery_reset_allowed: false` stops it from replacing them on its own.

Verify the bot from your client so its messages show as trusted. In Element, open the bot's profile from the room member list and start a verification. If you lose the store, the bot comes back as a new, unverified device that cannot read messages from before the loss. Back the directory up with the rest of `MESH_DATA_DIR`.

## Rooms with more than one agent

The reference bot decides whether to reply to every message from the number of members in the room when it joins, and it never checks again. A room that held one person and one bot when the bot joined keeps answering everything after a second agent arrives, and the two agents then reply to each other. In every room with more than one agent, send this command:

```
!local config room text-generation set-prefix-requirement-type command_prefix
```

After that, the bot answers only messages that start with its prefix, `!local`.

## Keeping the model warm

If your runtime unloads idle models, the first reply after a quiet period waits while the model loads (5 to 15 seconds on the reference deployment). This step is optional. A timer that sends a tiny request every 25 minutes keeps the model loaded. The script below uses the reference runtime's API (Ollama) at the address in `RUNTIME`, which the service sets. Other runtimes need their own equivalent. Systemd timers are Linux-only. On macOS, use a launchd agent or skip this step.

```bash
mkdir -p ~/bin
cat > ~/bin/keep-warm.sh <<'SCRIPT'
#!/bin/bash
# MODEL and RUNTIME come from the service below. -f makes an error status fail the run.
curl -fsS "$RUNTIME/api/generate" -d "{\"model\": \"$MODEL\", \"keep_alive\": \"30m\"}" > /dev/null
SCRIPT
chmod +x ~/bin/keep-warm.sh
```

Run it from a systemd user timer.

```ini
# ~/.config/systemd/user/keep-warm.service
[Service]
Type=oneshot
# Set MODEL to the value of LOCAL_MODEL in your .env.
Environment=MODEL=qwen3:8b
# The runtime's address as the host reaches it: the Docker bridge address from chapter 01.
Environment=RUNTIME=http://172.17.0.1:11434
ExecStart=%h/bin/keep-warm.sh

# ~/.config/systemd/user/keep-warm.timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=25min

[Install]
WantedBy=timers.target
```

Enable it with `systemctl --user daemon-reload` and `systemctl --user enable --now keep-warm.timer`. A failed request shows in `journalctl --user -u keep-warm.service`. Run `loginctl enable-linger $USER` once so user timers run without a login session and return after a reboot.

## Verify

Check that the bot logged in.

```bash
docker compose logs bot-bridge-local-agent
```

The log shows a successful login and no repeating errors. Then, from your client, create a room and invite `@local-agent:<SERVER_NAME>`. Send a message that mentions it, or one that starts with `!local`. The bot replies. After you verify it, the reply shows the encryption shield and a verified sender.
