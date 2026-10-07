# Scribe

> **What this role must provide**
>
> - A Matrix bot with its own account and its own encryption identity, so it reads encrypted rooms like any other member.
> - Reads only the rooms it is invited to, and only from the moment it joins.
> - A local store that is the source of truth for every summary, to-do and link. Nothing else holds data that the store lacks.
> - A silent daily digest of each room, written by a local model and stored, not posted.
> - Commands that only the people you list can run.

## Build your scribe

This repo ships no scribe. The requirements above are written as a testable spec in [`specs/scribe.md`](../specs/scribe.md). Build your own from it, or pick an existing bot that meets it, then build an image and set its tag as `SCRIBE_IMAGE` in `.env`. Implement the MUST tier to continue. The SHOULD tier (filing into a knowledge store and the link index) is what chapter 06 turns on, and the optional reminders and weekly roll-up can wait.

`templates/05-scribe/scribe-config.yaml` is a complete example of the config schema in the spec. It points the model calls at the local runtime from chapter 00 and marks them `local`. The knowledge store is off and the link index has no URL, so scribe keeps everything in its own store until chapter 06 fills those in. Scribe reads the file once at startup, so every change needs a restart.

Open `.env` and fill in the chapter 05 values.

- Set `SCRIBE_IMAGE` to the tag of your build.
- Set `SCRIBE_TIMEZONE` to an IANA name such as `UTC`. Digest dates and the schedule follow it.
- Generate `SCRIBE_PASSWORD` with `openssl rand -hex 32`. It must match the password you give the account below, and scribe uses it for its first login only.
- `LOCAL_MODEL` from chapter 03 is the digest model. Keep it, or change it to another model your runtime has pulled.

In `templates/05-scribe/scribe-config.yaml`, the `admins` list holds `@alice` as a stand-in for your own account. Replace it with your Matrix id. `admins` is a list, so add every person who may run commands or invite scribe.

## Create the account and start

Registration is closed, so create the account with the shared secret, the same way as for the bot in chapter 03. Load `.env` into your shell first.

```bash
set -a; . ./.env; set +a
docker compose exec homeserver register_new_matrix_user -c /config/homeserver.yaml -u scribe -p "$SCRIBE_PASSWORD" --no-admin http://localhost:8008
```

Scribe is a plain member, never an admin. As in chapter 03, you can leave out `-p` and paste the password when asked, which keeps it out of the host's process list. Create its data directory. It holds the database and scribe's encryption identity.

```bash
sudo mkdir -p "$MESH_DATA_DIR"/scribe
sudo chown "$MESH_UID:$MESH_GID" "$MESH_DATA_DIR"/scribe
```

Scribe runs as the same user and group as the homeserver, so it can write to its directory. It is the only writer of the database, and any other tool that wants to read the data opens the file read-only.

> **macOS:** Run the `mkdir` without `sudo` and skip the `chown`, with `MESH_DATA_DIR` set to a folder in your home directory as in chapter 02.

Render the templates and open `compose.yaml`. Uncomment the two include lines for chapter 05. Then start scribe.

```bash
./render.sh
docker compose up -d scribe
docker compose logs scribe
```

The first start logs in once and saves the device. Every later start restores that device and does not log in again. The `crypto` folder inside the data directory is scribe's identity: if you lose it, scribe comes back as a new device that cannot read anything sent before. Back the directory up with the rest of `MESH_DATA_DIR`.

If you change the config later, run `docker compose restart scribe` after a render.

## Invite it

Invite `@scribe:<SERVER_NAME>` to each group room you want digested. It joins any room on the `allowlist` whoever invites it, unless the room is on the `denylist`, which always wins. For every other room, only a user in `admins` can invite it, and it declines everyone else. It ignores direct rooms for digests, so a one-to-one chat with scribe is for commands only. A room needs more than two joined members to count as a group room. Scribe reads nothing sent before it joined, and everyone in the room can see when it arrived.

To keep a room out for good, put its id on the `denylist` under `rooms`. Entries are room ids that start with `!`. Aliases are refused at startup.

Verify scribe in Element the way you did the bot in chapter 03, so its replies show as trusted.

## Silent by default

A scheduled digest is stored and posted nowhere. At 07:00 in your time zone, scribe summarizes each room that has at least three new messages, writes the summary and its to-dos to its store, and says nothing in the room. The only messages scribe sends unasked are the optional weekly roll-up, if you set `weekly_schedule`, and reminders, if your build has them. Everything else is a reply to an admin who ran a command or addressed it.

To get a digest now, send `!digest` in a room as an admin. Scribe replies there with the summary. How you read stored digests otherwise depends on your build. The spec requires the store and leaves the view to you, and chapter 06 files digests into a document store you can open and edit.

Raw message text is purged once a message is older than `raw_message_days` (three by default) and its room-day summary is stored, is not marked for regeneration, and is filed too if filing is on. Whatever its state, a message is purged once it is older than twice `raw_message_days` and at least one day old, so a quiet room that never reaches the digest threshold keeps its raw text up to that cap. Summaries stay.

## Verify

These checks come from the MUST tier of the spec. The spec's acceptance tests carry exact commands and expected output, and they need helpers (`mx`, `say`, `sdb`) and two test users. Load them as the spec describes. Several need a build of your own to exist, so run them against your image. Nothing here is verified against a shipped scribe, because this repo has none.

First, check that scribe logged in and stays up.

```bash
docker compose ps scribe
docker compose logs scribe
```

The log shows a login on the first start and no repeating errors. Then in Element, as the admin you listed, create a group room with one other person, invite `@scribe`, and wait a few seconds for it to join.

- **Buffering and the digest (M3, M6).** Send four plain messages, then `!digest`. Scribe replies with a summary, and `sdb "select count(*) from messages where room_id = '<room id>' and status = 'summarized'"` prints `4`.
- **Silence (M7).** Wait through a scheduled run, or set a schedule a few minutes ahead and restart. The room gets no new message from scribe.
- **Admins only (M8).** Have the other person send `!digest`. Scribe does not reply, and its log shows `ignored command from non-admin`.
- **One device (M1).** Run the key query from the spec before and after `docker compose restart scribe`. The list holds the same single device both times.
- **No double counting (M3).** Send three messages, stop scribe, delete `$MESH_DATA_DIR/scribe/crypto/sync_token` and start it again. The first sync replays recent events, and the message count must still be three. The spec has the exact test.

The M2 invite rules, M5 undecryptable messages, M10 residency and M11 startup checks each have their own test in the spec. Run those against your build before you rely on it, and note that the spec marks all of its tests as not yet run on the reference deployment.
