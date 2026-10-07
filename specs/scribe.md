# Scribe specification

Scribe is a Matrix bot that reads the rooms it is in, writes a silent daily digest of each room, and keeps a searchable memory of the links people share. It has its own Matrix account and its own encryption identity, so it reads end-to-end encrypted rooms like any other member. It keeps everything in one local store on your machine and summarizes with a local model by default. This repo ships no implementation of scribe. You build your own from this spec, or choose an existing bot that meets it. Chapter 05 deploys your build of the MUST tier, and chapter 06 turns on the SHOULD tier: filing into a knowledge store and a link index.

## Conventions

**MUST** marks a requirement that chapter 05 and the privacy rules in the README depend on. A scribe that misses one does not meet this spec. **SHOULD** marks a requirement you can skip with a known cost, stated in its reason. Chapter 06 assumes every SHOULD. **MAY** marks an option a scribe is free to take or leave. The optional features (reminders and the weekly roll-up) are MAY as a whole, but a build that offers one meets its requirement in full, so they carry acceptance tests.

Values marked "spec choice" (some defaults, limits and timeouts, the file and table names, and the environment variable names `SCRIBE_CONFIG` and `SCRIBE_PASSWORD`) are this spec's picks. Chapter 05 and the tests rely on them, so keep them unless you also change the chapter's templates and the tests.

Every acceptance test carries one of two labels:

- `passed on reference implementation (YYYY-MM-DD)`: the test was run against the reference deployment on that date with a request that changes nothing.
- `untested`: the test has not been run against the reference deployment.

The tests write the server name as `example.com` in Matrix ids, such as `@alice:example.com` and `@scribe:example.com`. Replace it with your `SERVER_NAME` in every user id. Links such as `https://example.com/` are real public URLs and stay as written.

Every test in this spec is `untested`. Each one posts to a room, restarts or reconfigures scribe, or reads its database, and none of that is done on the reference deployment.

### Test helpers

Scribe publishes no port. The tests reach the homeserver as `homeserver:8008` from a throwaway curl container on the compose network `mesh_mesh`, and read scribe's database with a throwaway container that opens it read-only. Run them from the repo root after `set -a; . ./.env; set +a`, with `jq` and `python3` on the host.

The SQL in the tests is the reference harness: it assumes the SQLite file and the table and column names under Storage model. A build that uses another store provides its own read-only query helper in place of `sdb` that answers the same questions over the same logical fields.

The tests need two users: `@alice:example.com`, listed in `admins`, and `@bob:example.com`, not listed. Put their access tokens in `ALICE_TOKEN` and `BOB_TOKEN` (in Element Web or Desktop: Settings, Help & About, Access Token). They also need these rooms, created in Element by `@alice`, with the room ids (Room settings, Advanced) in shell variables:

- `ROOM`: a group room with `@alice`, `@bob` and `@scribe` joined.
- `ROOM2`: a second group room with the same three members.
- `DM`: a direct room with only `@alice` and `@scribe`.

```bash
SCRIBE_ID='@scribe:example.com'
MSG_EVENT="m.room.message"; TEXT_TYPE="m.text"
mesh_curl() { docker run --rm --network mesh_mesh curlimages/curl "$@"; }
# $1 token, $2 method, $3 path under /_matrix/client/v3, $4 optional JSON body
mx() {
  set -- "$1" "$2" "http://homeserver:8008/_matrix/client/v3$3" "$4"
  if [ -n "$4" ]; then
    mesh_curl -s -X "$2" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$4" "$3"
  else
    mesh_curl -s -X "$2" -H "Authorization: Bearer $1" "$3"
  fi
}
# $1 token, $2 room id, $3 text. Prints the new event id.
say() { mx "$1" PUT "/rooms/$2/send/$MSG_EVENT/t$RANDOM$RANDOM" \
  "$(jq -cn --arg t "$TEXT_TYPE" --arg b "$3" '{msgtype: $t, body: $b}')" | jq -r .event_id; }
# Number of events scribe has sent among the last 100 in room $1.
scribe_posts() { mx "$ALICE_TOKEN" GET "/rooms/$1/messages?dir=b&limit=100" \
  | jq --arg s "$SCRIBE_ID" '[.chunk[] | select(.sender == $s)] | length'; }
# Run one SQL query against scribe's database, read-only, as the data owner, so any
# side files SQLite creates stay writable by scribe.
sdb() { docker run --rm -v "$MESH_DATA_DIR/scribe:/data" alpine \
  sh -c 'apk add -q sqlite su-exec >/dev/null && su-exec "$2" sqlite3 -readonly /data/scribe.db "$1"' \
  sh "$1" "$MESH_UID:$MESH_GID"; }
# The point id of a link: $1 room id, $2 normalized URL.
point_id() { echo "$1 $2" | python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, input()))'; }
```

`say` sends a plain, unencrypted event. The homeserver accepts it in an encrypted room too, and scribe treats it like a decrypted message (M3), so most tests need no encryption-capable client. Scribe's replies in an encrypted room are encrypted, so a test that checks a reply's text reads it in Element as `@alice`. Tests that need encryption say so and use Element.

Some tests replace the model runtime with a request-recording mock server, as the gateway spec does:

```bash
docker run -d --rm --name fake-runtime --network mesh_mesh mockserver/mockserver
fake_reset() { mesh_curl -s -X PUT http://fake-runtime:1080/mockserver/reset; }
fake_requests() { mesh_curl -s -X PUT 'http://fake-runtime:1080/mockserver/retrieve?type=REQUESTS&format=JSON'; }
# Answer every chat completion with the digest JSON in $1.
fake_digest() {
  mesh_curl -s -X PUT http://fake-runtime:1080/mockserver/expectation -d "$(jq -cn --arg c "$1" \
    '{httpRequest: {method: "POST", path: "/v1/chat/completions"},
      httpResponse: {body: {type: "JSON", json: {model: "fake", choices: [{index: 0,
        message: {role: "assistant", content: $c}, finish_reason: "stop"}]}}}}')"
}
# Text of every chat completion request since the last reset, one JSON string per request.
fake_prompts() { fake_requests | jq -c '.[] | select(.path == "/v1/chat/completions") | .body.json.messages | tostring'; }
```

To use it, set the `model_runtime` `url` to `http://fake-runtime:1080/v1` and restart scribe. Unless a test says otherwise, register `fake_digest '{"summary": "talked", "todos": [], "notes": {}}'` after each `fake_reset`. A test that changes the config reverts it afterward. "Restart scribe" means `docker compose restart scribe`.

## Configuration schema

Scribe reads one YAML file. The path is set by the environment variable `SCRIBE_CONFIG` (spec choice), and chapter 05 mounts it at `/config/config.yaml`. A complete example is `templates/05-scribe/scribe-config.yaml`. Scribe reads the file once at startup. A change takes effect on the next restart.

Secrets never appear in this file. The only secret scribe needs is its Matrix password, read from `SCRIBE_PASSWORD` (spec choice) for the first login only (M1). If an adapter needs a credential, it reads it from an environment variable that your build names. Any error listed under M11 makes scribe exit with a nonzero status before it syncs.

### Top level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `homeserver_url` | string | required | Client API base URL, such as `http://homeserver:8008`. |
| `user_id` | string | required | Scribe's full Matrix user id, such as `@scribe:example.com`. |
| `device_name` | string | `scribe` | Display name of the device created at the first login. |
| `store_path` | string | required | Directory for the saved device (`device.json`), the saved sync position (`sync_token`) and the encryption store (file names are spec choices). Scribe is its only user. |
| `db_path` | string | required | Path of the local store, a SQLite file (spec choice), such as `/data/scribe.db`. |
| `rooms` | map | `{}` | Which rooms scribe joins and buffers. See below. |
| `admins` | list of strings | required | Full Matrix user ids allowed to run commands and get answers. At least one. |
| `digest` | map | required | Schedule, time zone and model for digests. See below. |
| `retention` | map | `{}` | How long raw message text is kept. See below. |
| `model_runtime` | map | required | The model runtime every model call goes to. See below. |
| `vector_index` | map | none | The link index adapter (S2). Absent or `url: null` turns the index off. |
| `knowledge_store` | map | `{enabled: false}` | The knowledge store adapter (S1). |
| `links` | map | `{fetch_metadata: false}` | Whether scribe fetches the pages that shared links point to (S3). See below. |

### `rooms`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `allowlist` | list of room ids | `[]` | If empty, every group room scribe has joined is in scope. If not empty, only these rooms are in scope. |
| `denylist` | list of room ids | `[]` | Rooms never in scope, whatever the allowlist says. Scribe declines invites to them and ignores everything in them. |

Entries are room ids, which start with `!`. An alias (starting with `#`) aborts boot, because an alias can be moved to a different room. A room on both lists is denied.

### `digest`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `schedule` | string | required | Five-field cron expression for the scheduled digest, such as `0 7 * * *`. The day-of-week field takes `*` or the names `mon` to `sun` (ranges and lists allowed, such as `mon-fri`). A number there aborts boot (M11). |
| `timezone` | string | required | IANA time zone name, such as `UTC`. Every schedule, digest date and reminder time is in this zone. The container's `TZ` and the host's zone play no part. |
| `window_hours` | integer | `24` | The shortest period a digest reports on (M6). From 1 to 720. |
| `min_messages` | integer | `3` | A scheduled run leaves a room alone while it has fewer pending messages than this. At least 1. `!digest` ignores it. |
| `model` | string | required | Model id sent to the model runtime. |
| `weekly_schedule` | string or null | `null` | Cron expression for the optional weekly roll-up (O2), with the same rules as `schedule`. `null` turns it off. |

### `retention`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `raw_message_days` | integer | `3` | Days a message's text is kept once its summary is stored and filed (S4). `0` purges that text at the end of each scheduled run. Every message's text is purged after twice this many days, and after at least 1 day, whatever its state. From 0 to 365. |

### `model_runtime`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `url` | string | required | OpenAI-compatible base URL, such as `http://host.docker.internal:11434/v1`. Scribe appends `/chat/completions`, and `/embeddings` when `vector_index` has `embedding: runtime`. |
| `data_residency` | `local` or `cloud` | required | `local` if requests stay on your machine, `cloud` if they leave it. The same vocabulary as the gateway's upstream providers. See M10. |

### `vector_index`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `url` | string or null | `null` | Base URL of the vector index, such as `http://vector-index:6333`. |
| `collection` | string | `links` | Name of the collection that holds link points. |
| `embedding` | `in_process` or `runtime` | `in_process` | Where link texts are embedded (M10). `in_process`: a model inside scribe's own process. `runtime`: the model runtime's `/embeddings` endpoint, allowed only when the runtime's `data_residency` is `local`. |
| `embedding_model` | string | required for `runtime` | Model id sent to `/embeddings`. |

### `knowledge_store`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | `false` | Turns filing on (S1). When `false`, the other keys are ignored. |
| `url` | string | required when enabled | The endpoint your `KnowledgeSink` adapter talks to, such as an MCP server in front of the store. |
| `workspace_id` | string | required when enabled | The workspace or space in the store that scribe writes to. |
| `digest_parent` | string | required when enabled | The document or folder under which scribe creates its digest documents. |
| `todos_target` | string | required when enabled | Where `add_todo` puts to-dos, such as the id of a table or list in the store. |

### `links`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `fetch_metadata` | boolean | `false` | When `true`, scribe fetches each saved link's page for its title and description, under every rule in Link fetching rules. Each fetch is an outbound request from your host to the linked site. When `false`, a link row stores only the URL, room and note (with the sender, source message and time), `title` and `description` stay null, and scribe makes no request to any URL from chat. |

## Storage model

The local store is one SQLite file at `db_path`. Scribe is its only writer. Any other process (a dashboard, an MCP server that answers questions from it, the tests) opens it read-only. Table and column names below are spec choices, used by the tests.

**Single source of truth.** Every summary, to-do, link and reminder exists first in this store. The link index and the knowledge store hold copies. Scribe writes a row here before it writes the copy, and every copy can be rebuilt from the store. Losing the vector index or the knowledge store loses nothing. Losing this file loses everything that is not in a copy, so back it up (see [LIMITATIONS.md](../LIMITATIONS.md)).

| Table | Fields | Rules |
|---|---|---|
| `messages` | `event_id` (unique), `room_id`, `sender`, `ts` (origin server time, ms), `body` (null after purge), `status` (`pending`, `summarized` or `redacted`), `summary_date` | One row per buffered message. Inserting an `event_id` that exists changes nothing. A purged row keeps everything but `body` for 30 days (spec choice), so a replay of that event is still recognized. |
| `undecryptable` | `event_id` (unique), `room_id`, `sender`, `ts`, `session_id`, `first_seen`, `resolved_at` | One row per encrypted event scribe could not decrypt. No content. Kept for 30 days. |
| `summaries` | `room_id`, `date` (local `YYYY-MM-DD`), `room_name`, `text`, `message_count`, `undecryptable_count`, `needs_regeneration`, `created_at`, `updated_at`, `filed_at` | Unique on (`room_id`, `date`). `filed_at` is null until the knowledge store accepts the current text. |
| `todos` | `id`, `room_id`, `text`, `assignee`, `due`, `status` (`open` or `done`), `summary_date`, `created_at`, `filed_at` | No two open to-dos in a room share the same text after trimming and case folding. Scribe never closes a to-do; marking one done is up to you. |
| `links` | `id`, `room_id`, `url` (normalized), `title`, `description`, `note`, `sender`, `source_event_id`, `saved_at`, `point_id`, `indexed_at` | Unique on (`room_id`, `url`): the same URL shared in two rooms is two rows, each with its own note. `source_event_id` is the message a digest found the link in, null for `!link`. `point_id` is the deterministic id from Link fetching rules. `indexed_at` is null until the vector index confirms the point. |
| `digest_runs` | `id`, `room_id`, `date`, `trigger` (`scheduled` or `command`), `scheduled_for`, `period_start`, `started_at`, `finished_at`, `status` (`ok`, `nothing_new`, `below_minimum` or `failed`), `summarized_count`, `undecryptable_count`, `error` | One row per room per run. |
| `reminders` | `id`, `room_id`, `created_by`, `text`, `due_at` (UTC, seconds), `status` (`pending`, `sent`, `canceled` or `failed`), `created_at`, `sent_at` | Only with O1. |

**What persists across restarts.** Everything in `store_path` (the device, its encryption keys and the sync position) and everything in `db_path` (the tables above). Nothing else does. The schedule is computed from the config and `digest_runs` at startup. A digest run interrupted by a restart leaves its messages `pending`, because scribe changes a message's status in the same transaction that stores the summary, so the next run covers them again.

**Rebuilding the link index.** At startup, and whenever a run finds the index reachable after it was down, scribe compares the index with the store. If the collection is missing or holds fewer points than `links` has rows with `indexed_at` set, scribe drops the collection, creates it again and indexes every row in `links`. Otherwise it indexes only the rows with `indexed_at` null. Indexing one row means: build the text from `title`, `description` and `note` (or the URL alone when all three are empty), embed it, upsert it under `point_id` with the payload `{url, title, note, room_id}`, then set `indexed_at`. Because `point_id` depends only on the room and the URL, indexing a row twice leaves one point. To force a full rebuild, delete the collection in the vector index and restart scribe.

## Requirements

Each requirement has a reason and an acceptance test. A test gives the input and the exact result to expect.

### MUST

**M1. One persistent device.** At its first start, when `store_path` has no `device.json`, scribe logs in with `SCRIBE_PASSWORD`, creates one device named `device_name`, and saves its user id, device id and access token in `device.json` with mode 600. On every later start it restores that device and its encryption store and does not log in again. If `device.json` exists but the encryption store cannot be opened, scribe exits with a nonzero status and a message containing `crypto store` and the path. It never creates a second device on its own. It saves its sync position in `sync_token` after the events of each sync are stored, so a restart resumes where it stopped.
Reason: room keys are sent to a device. A new device cannot read anything sent before it existed, and silently making one would lose history without anyone noticing.
Test (same device): `mx "$ALICE_TOKEN" POST /keys/query '{"device_keys": {"@scribe:example.com": []}}' | jq -c '.device_keys["@scribe:example.com"] | keys'`, restart scribe, wait 30 seconds, and run it again. Expect the same one-element list both times.
Label: untested.
Test (lost store): `docker compose stop scribe`, move every file in `$MESH_DATA_DIR/scribe/crypto` except `device.json` to a backup directory, `docker compose up -d scribe`. Expect scribe to exit (Docker keeps restarting it under `restart: unless-stopped`) and `docker compose logs scribe` to contain `crypto store`. Move the files back and start scribe.
Label: untested.

**M2. Joining rooms.** Scribe accepts an invite when the room is not on `denylist` and either the inviter is in `admins` or the room is on `allowlist`. It declines every other invite and logs a line with the room id and the inviter. A room is in scope when scribe has joined it, it is not on `denylist`, it is on `allowlist` (or `allowlist` is empty), and it has more than two joined members. A room with two members is a direct room and is never in scope. Scribe stays in a room that later leaves scope and ignores its new messages. Messages it already stored from that room follow the retention cap (S4). Scribe never reads or stores anything sent in a room before it joined.
Reason: only someone trusted decides which conversations scribe records, and a one-to-one chat with scribe is for commands and stays out of the digest. People in a room can see when scribe joined, so its memory starts there.
Test: `@bob` creates a room in Element and invites `@scribe`. Expect, within 30 seconds, `mx "$BOB_TOKEN" GET "/rooms/<that room id>/members" | jq -r --arg s "$SCRIBE_ID" '.chunk[] | select(.state_key == $s) | .content.membership'` to print `leave`. `@alice` creates a room, sends `before join`, then invites `@scribe`. Expect the same query with `ALICE_TOKEN` to print `join`, and `sdb "select count(*) from messages where body = 'before join'"` to print `0`.
Label: untested.

**M3. Buffering messages.** Scribe stores every text message and emote in an in-scope room as a `pending` row in `messages`, whether it arrived encrypted and was decrypted or arrived unencrypted. It skips its own messages, notices, media, and any message that starts with a command word from the Commands section. It strips a reply's quoted fallback (the leading lines that start with `> `, up to the first blank line) before storing. An event id already in `messages` changes nothing, including a row whose text was purged.

An edit replaces the stored text of the original event if that row is still `pending`, and is otherwise ignored. The edit event itself is never stored as a message.

A redaction clears the stored text of the original event and sets its status to `redacted`. If the event was already summarized, scribe marks the summary for that room and date `needs_regeneration`. The next run of that room writes the summary again from the date's stored messages without the redacted one (M6 step 7). Links found in the redacted message (`source_event_id`) are deleted from `links` and from the index. To-dos already created from it are kept, because a to-do cannot be traced to a single message.
Reason: the digest must count each message once, whatever the sync delivers, and a message its author deleted must leave scribe's memory as far as scribe can trace it.
Test (dedup across a replay): send `dedup one`, `dedup two` and `dedup three` with `say`, wait 10 seconds, `docker compose stop scribe`, delete `$MESH_DATA_DIR/scribe/crypto/sync_token`, `docker compose start scribe`, and wait 60 seconds. The first sync without a saved position delivers the room's recent events again. Expect `sdb "select count(*) from messages where body like 'dedup %'"` to print `3`.
Label: untested.
Test (commands and scope): `say "$ALICE_TOKEN" "$ROOM" '!link list'` and `say "$ALICE_TOKEN" "$DM" 'direct hello'`. Expect `sdb "select count(*) from messages where body in ('!link list', 'direct hello')"` to print `0`.
Label: untested.
Test (redaction before a digest): `e=$(say "$ALICE_TOKEN" "$ROOM" "secret to delete")`, wait 10 seconds, then `mx "$ALICE_TOKEN" PUT "/rooms/$ROOM/redact/$e/r$RANDOM" '{}'`. Expect, after 10 seconds, `sdb "select coalesce(body, 'NULL'), status from messages where event_id = '$e'"` to print `NULL|redacted`.
Label: untested.
Test (redaction after a digest): use the fake runtime. Send `plan alpha`, `secret beta https://example.com/beta` and `plan gamma`, keeping the second event id in `e`, and run `!digest` in `ROOM` as `@alice`. Redact `e` as above, run `fake_reset`, register the default reply, and run `!digest` again. Expect `fake_prompts | tail -n 1` to contain `plan alpha` and `plan gamma` and not `secret beta`, `sdb "select needs_regeneration from summaries where room_id = '$ROOM' order by updated_at desc limit 1"` to print `0`, and `sdb "select count(*) from links where room_id = '$ROOM' and url = 'https://example.com/beta'"` to print `0`.
Label: untested.

**M4. Messages sent while scribe is offline.** After a restart, scribe processes every event in its first sync, which resumes from the saved position, exactly like events that arrive later. When a sync reports a limited (gapped) timeline for a room, scribe pages back through that room's history until it reaches an event id already in `messages`, the saved position, scribe's own join to the room, or events older than 7 days (spec choice), and buffers what it finds under M3. An event id found only in `undecryptable` does not stop the paging. The digest catches up on all of it (M6).
Reason: a restart or an outage must not drop the messages sent in the meantime. Without paging back, a busy room loses everything beyond the homeserver's per-sync limit.
Test: `docker compose stop scribe`, then `for i in $(seq 1 30); do say "$ALICE_TOKEN" "$ROOM" "offline $i" >/dev/null; done`, then `docker compose start scribe` and wait 60 seconds. Expect `sdb "select count(*) from messages where body like 'offline %'"` to print `30`. Run `!digest` in `ROOM` and expect `sdb "select count(*) from messages where body like 'offline %' and status = 'summarized'"` to print `30`.
Label: untested.

**M5. Messages scribe cannot decrypt.** When scribe receives an encrypted event it cannot decrypt, it stores one row in `undecryptable` (event id, room, sender, time and session id, no content), logs a line containing `undecryptable` and the event id, and requests the room key from the sender's devices once. A digest counts the room's unresolved rows in its period, stores the count in the run and in the summary, and adds the line `Messages in this period that could not be decrypted: N.` to the summary text when N is above 0.
Reason: a gap in a digest must be visible. Silently summarizing half a conversation reads as the whole of it.
Test (needs encryption): in Element, as `@alice` in `ROOM`, turn on "Never send encrypted messages to unverified sessions" for this room, make sure scribe's device is unverified, and send `hidden one`. Expect `sdb "select count(*) from undecryptable where room_id = '$ROOM'"` to print at least `1`, and `docker compose logs scribe` to contain `undecryptable`. Then send three plain messages with `say`, run `!digest` in `ROOM` as `@alice`, and expect `sdb "select undecryptable_count from digest_runs where room_id = '$ROOM' order by id desc limit 1"` to print `1` and `sdb "select text from summaries where room_id = '$ROOM' order by updated_at desc limit 1"` to end with `Messages in this period that could not be decrypted: 1.` Turn the setting off again.
Label: untested.

**M6. The digest run.** A digest run of one room at time T works like this:

1. The run's date D is the calendar date of T in `timezone`. The run's period starts at L, the earlier of T minus `window_hours` and the end of the room's last run with status `ok`, and ends at T. L is stored as `period_start` and used for the undecryptable count (M5).
2. The run covers every `pending` message of the room with `ts` before T, however old. Messages older than L exist only after a backfill (M4), a late key (S6) or a run that failed, and are included like the rest. Scribe never drops a pending message because of its age. Only the retention cap (S4) removes its text.
3. If the summary for (room, D) or for an earlier date of the room is marked `needs_regeneration`, step 7 runs first.
4. If no message is covered, the run ends with status `nothing_new` and calls no model. A scheduled run that covers fewer messages than `min_messages` ends with status `below_minimum`, calls no model, and leaves them pending, so they are counted again by the next run.
5. Otherwise scribe sends the covered messages, oldest first, in batches of at most 300 (spec choice), to the model runtime. For each batch it asks for a JSON object with a `summary` string, a `todos` list (each with `text` and optional `assignee` and `due`) and a `notes` map from URL to a short note. It joins the batch summaries with blank lines. The links of the run are every `http` or `https` URL in the text of the covered messages, normalized as in Link fetching rules, each saved for this room with the message it came from. URLs the model returns that are not among them are dropped. The model's note for a URL becomes the link's `note` only if the link has none.
6. In one transaction, scribe writes the summary for (room, D), the new to-dos, the new links and the run record, and marks the covered messages `summarized` with `summary_date` D. If a summary for (room, D) already exists, the new text is appended to it after a blank line and `filed_at` is reset to null.
7. Regeneration: scribe sends the stored, non-redacted messages with that `summary_date`, as in step 5, replaces the summary text with the result, clears `needs_regeneration` and resets `filed_at` to null. If some of those messages were purged, the new summary is made from the ones left and ends with the line `Part of this summary was removed after a message was deleted.` If no non-redacted message is left for that room and date, scribe deletes the summary row instead and, when filing is enabled, replaces the body of its filed section with `Removed.` (S1), because the adapter has no delete.
8. If the model's answer is not valid JSON of that shape, scribe retries the batch once. If it fails again, or the runtime cannot be reached, returns an error status (such as 404 for an unknown model) or does not answer within 300 seconds (spec choice), the run ends with status `failed` and the error, and every message and summary stays as it was before the run.

Runs are serialized. A schedule firing while a run is in progress starts after it ends, and several such firings collapse into one. A scheduled run covers every in-scope room, one after another. A failure in one room does not stop the others. At startup, if the most recent time `schedule` fired is later than the start of every scheduled run in `digest_runs`, scribe runs it once immediately. Cron times are local times in `timezone`. A time that does not exist on a daylight-saving change fires at the first minute after the gap. A time that occurs twice fires once, at its first occurrence.
Reason: these rules decide every case a builder would otherwise guess: which messages a digest covers, what happens in a quiet room, on a second run the same day, after a restart, after downtime longer than the window, and when the model fails. No message is summarized twice, and none is lost because a run failed or the room was quiet.
Test (date): send three messages and run `!digest` in `ROOM` as `@alice`. Expect `sdb "select date from summaries where room_id = '$ROOM' order by updated_at desc limit 1"` to print today's date in `timezone`, and the three messages to be `summarized`.
Label: untested.
Test (quiet room): set `schedule: "* * * * *"` and `min_messages: 3`, and restart. Send `quiet 1` and `quiet 2`, wait 90 seconds. Expect `sdb "select status from digest_runs where room_id = '$ROOM' order by id desc limit 1"` to print `below_minimum`. Send `quiet 3` and `quiet 4`, wait 90 seconds. Expect the same query to print `ok`, `sdb "select summarized_count from digest_runs where room_id = '$ROOM' and status = 'ok' order by id desc limit 1"` to print `4`, and all four messages to be `summarized`. Revert.
Label: untested.
Test (failed run, then catch-up): use the fake runtime with no reply registered, so it answers 404. Send three messages and run `!digest` in `ROOM`. Expect, in Element, a reply starting `digest failed: model runtime returned 404`, `sdb "select status from digest_runs where room_id = '$ROOM' order by id desc limit 1"` to print `failed`, and the three messages to be `pending`. Register the default reply and run `!digest` again. Expect the three messages to be `summarized`.
Label: untested.
Test (invented link): with the fake runtime, `fake_digest '{"summary": "talked", "todos": [], "notes": {"https://invented.example/x": "made up"}}'`, then send `see https://example.com/a/b/?x=1#top`, `ok` and `thanks`, and run `!digest` in `ROOM`. Expect `sdb "select url from links where room_id = '$ROOM'"` to include `https://example.com/a/b?x=1` and not `https://invented.example/x`.
Label: untested.
Test (startup catch-up): set `schedule` to fire two minutes from now, stop scribe before it fires, start it three minutes later. Expect, within 60 seconds of the start, `sdb "select count(*) from digest_runs where trigger = 'scheduled' and started_at > strftime('%s','now') - 300"` to print at least `1`.
Label: untested.

**M7. Silent by default.** A scheduled digest stores its results and posts nothing. Scribe sends a room message only in these cases: a reply to an admin's command (Commands), an answer to an admin who addressed it (S5), a reminder an admin set (O1), and the weekly roll-up when `weekly_schedule` is set (O2). It sends no typing notices except while preparing an answer, and no read receipts.
Reason: a bot that summarizes into the room every morning becomes noise, and people stop reading the room.
Test: set `schedule: "* * * * *"`, `min_messages: 1` and `weekly_schedule: null`, and restart. Note `before=$(scribe_posts "$ROOM")`. Send two messages with `say`, wait 150 seconds. Expect `sdb "select count(*) from digest_runs where room_id = '$ROOM' and trigger = 'scheduled' and status = 'ok'"` to print at least `1` and `scribe_posts "$ROOM"` to print the same number as `before`. Revert.
Label: untested.

**M8. Admins and commands.** An admin is a user whose full Matrix id is in `admins`, compared exactly. Scribe runs a command (see Commands) only when an admin sends it in a joined room that is not on `denylist`. A command from anyone else gets no reply, is not buffered, and produces one log line containing `ignored command from non-admin` and the sender.
Reason: commands reveal what scribe stored, so only the people who run it may use them. Silence toward everyone else gives nothing away.
Test: note `before=$(scribe_posts "$ROOM")`, then `say "$BOB_TOKEN" "$ROOM" '!link list'` and wait 15 seconds. Expect `scribe_posts "$ROOM"` to print `before`, and `docker compose logs scribe` to contain `ignored command from non-admin @bob:example.com`.
Label: untested.

**M9. The local store is the single source of truth.** Scribe keeps all state in `store_path` and `db_path` as described under Storage model. It writes a row to the store before any copy, it is the only writer of `db_path`, and it can rebuild the link index from the store alone.
Reason: there is one place to back up and one place to read. A broken index or knowledge store is repaired from the store.
Test: with S2 built, run `!link https://example.com/ home` in `ROOM`, then delete the collection in the vector index (for the reference index: `mesh_curl -s -X DELETE http://vector-index:6333/collections/links`), restart scribe and wait 60 seconds. Expect `sdb "select indexed_at is not null from links where room_id = '$ROOM' and url = 'https://example.com/'"` to print `1`, and the index to hold the point (for the reference index: `mesh_curl -s "http://vector-index:6333/collections/links/points/$(point_id "$ROOM" https://example.com/)" | jq -r .result.payload.url` prints `https://example.com/`).
Label: untested.

**M10. Every model call matches the data's residency.** Every chat completion scribe makes (digests, answers, reminder parsing) goes to the `model_runtime` `url`, whose residency is the `model_runtime` `data_residency`. The key has no default: a missing or unknown value aborts boot with a message containing `data_residency`. This spec requires the value explicitly and has no default. The gateway spec also requires `data_residency` on every upstream provider. With `cloud`, scribe logs one line at startup containing `cloud model runtime` and the URL. The runtime may be a tool gateway agent endpoint, in which case the residency is that agent's upstream residency.

Embeddings always stay on the machine. With `embedding: in_process`, the default, scribe embeds inside its own process and sends link text to no endpoint. With `embedding: runtime`, it posts to the `model_runtime` `url` plus `/embeddings` and nowhere else, and boot aborts with a message containing `embedding` when the runtime's `data_residency` is `cloud`. Scribe has no setting for any other embedding endpoint.
Reason: room messages are the most private data in this setup. Sending them off the machine takes a line in the config that someone wrote on purpose, and link notes never leave even then.
Test (residency required): delete the `data_residency` line under `model_runtime` and run `docker compose restart scribe`. Expect scribe to exit (Docker keeps restarting it under `restart: unless-stopped`) and `docker compose logs scribe` to contain `data_residency`. Revert.
Label: untested.
Test (cloud embeddings refused): set `data_residency: cloud` under `model_runtime` and `embedding: runtime` under `vector_index`, and run `docker compose restart scribe`. Expect scribe to exit (Docker keeps restarting it under `restart: unless-stopped`) and the logs to contain `embedding`. Revert.
Label: untested.
Test (in-process embeddings): with the fake runtime, `embedding: in_process` and S2 built, run `fake_reset` and `!link https://example.com/ embed test` in `ROOM`, and wait 15 seconds. Expect `fake_requests | jq '[.[] | select(.path | endswith("/embeddings"))] | length'` to print `0` and the link's `indexed_at` to be set.
Label: untested.

**M11. The config is checked at startup.** Scribe exits with a nonzero status and a message containing the given text if any of these holds:

| Change | Expected text |
|---|---|
| `schedule: "0 7 * * 1"` | `weekday names` |
| `timezone: Mars/Olympus` | `timezone` |
| `#general:example.com` added to `allowlist` | `room id` |
| `admins: []` | `admins` |
| `window_hours: 0` | `window_hours` |
| `data_residency: maybe` under `model_runtime` | `data_residency` |
| `embedding: runtime` under `vector_index` with no `embedding_model` | `embedding_model` |
| `knowledge_store` with `enabled: true` and no `todos_target` | `todos_target` |

Reason: a numeric weekday means Sunday in one cron library and Monday in another, and an unknown time zone or a moved alias silently changes when and what scribe digests.
Test: make each change on its own, run `docker compose restart scribe`, and expect scribe to exit (Docker keeps restarting it) and `docker compose logs scribe` to contain the text. Revert after each.
Label: untested (all eight).

**M12. Behavior when a dependency is down.** Scribe keeps running when any dependency fails, and never loses a message because of it:

| Down | Effect |
|---|---|
| Model runtime unreachable, timing out, or answering with an error status (such as 404 for an unknown model) | The digest run of each room ends `failed` (M6). Messages stay pending, and the next successful run covers them however long the outage lasted. `!digest` replies `digest failed: model runtime unreachable` or `digest failed: model runtime returned <status>`. An answer (S5) replies `I can't answer right now: the model runtime is unavailable.` Reminder commands in the fixed format of O1 still work. |
| Vector index | Links are still stored with `indexed_at` null and indexed when the index is back (Storage model). Answers fall back to a text search over `links`, with the same room scope (M13). |
| Knowledge store | The digest still succeeds. Summaries and to-dos keep `filed_at` null and are filed by a later run (S1). Raw text of their messages is kept until they are filed or the retention cap applies (S4). |
| Homeserver | Sync retries with a delay that doubles from 2 to 60 seconds (spec choice). Scheduled runs still run. A post that fails is logged and dropped, except a reminder, which stays pending (O1). |
| Local store (database locked past the busy timeout, disk full, file not writable) | Scribe logs a line containing `store write failed`, does not save the sync position past the events it could not store, and retries the same sync after 10 seconds (spec choice). A digest run that cannot write ends `failed` without changing any message. A command gets the reply `storage error, try again later` when the reply itself can be sent. |

Reason: a digest is worth less than the messages it is made from, so every failure leaves the messages in place for the next try.
Test (model runtime): the failed-run test in M6.
Label: untested.
Test (local store): write a compose override `ro.yaml` that mounts the data directory read-only. A read-only mount works whatever user your build runs as, while a permission change does not stop a build that runs as root:

```yaml
services:
  scribe:
    volumes:
      - ${MESH_DATA_DIR:?}/scribe:/data:ro
```

Run `docker compose -f compose.yaml -f ro.yaml up -d scribe`, send `while locked` with `say`, and wait 20 seconds. Expect `docker compose logs scribe` to contain `store write failed`. Run `docker compose up -d scribe` to restore the writable mount and wait 30 seconds. Expect `sdb "select count(*) from messages where body = 'while locked'"` to print `1`.
Label: untested.
Test (knowledge store): see S1 and S4.

**M13. Room isolation.** Content from one room never appears in output shown in another room. Content means a room's messages, summaries, to-dos, links and link notes. Output means command replies (`!digest <room>`, `!digest all`, `!link list`), answers (S5), the weekly roll-up (O2) and link attribution (a link saved in two rooms is two rows, each with its own note and room). In a group room, scribe uses only that room's own content. In a direct room with an admin, scribe uses only the content of rooms the admin is joined to when the command or question arrives, and of that direct room itself. Every lookup in the store and the index passes this room filter (S2 `search`). A reply about a room outside that scope is a status line or a refusal, never content.
Reason: the members of one room have not agreed to share their conversation with another room's members, and an admin who left a room has given up seeing it.
Test (link list): `!link https://example.com/only-one note-one` in `ROOM` and `!link https://example.com/only-two note-two` in `ROOM2`, both as `@alice`, then `!link list` in `ROOM2`. Expect the reply (in Element) to contain `only-two` and not `only-one`.
Label: untested.
Test (digest of another room): send three messages in `ROOM2`, then `!digest <ROOM2's id>` in `ROOM` as `@alice`. Expect the reply to be exactly `<ROOM2's name>: ok`, with no summary text.
Label: untested.
Test (direct room scope): with the fake runtime, after the link list test, `@alice` leaves `ROOM2`. Run `fake_reset`, register the default reply, and in `DM` send `which links do we have?`. Expect `fake_prompts | tail -n 1` to contain `only-one` and not `only-two`. Have `@bob` invite `@alice` back to `ROOM2`.
Label: untested.

### SHOULD

**S1. Filing into a knowledge store.** When `knowledge_store` has `enabled: true`, after each run that stores or regenerates a summary, scribe files it through a `KnowledgeSink` adapter. Each summary goes to one digest document per month, under `digest_parent`: the document key is `digest-YYYY-MM` of the summary's date, the section heading is `YYYY-MM-DD · <room name>`, and the body is the summary text with its to-dos and links. Each new to-do goes to `todos_target` through `add_todo`. Scribe sets `filed_at` when the adapter returns. Every run first files every summary and to-do whose `filed_at` is null, oldest first. A filing error is logged with a line containing `filing failed`, and the run still ends `ok`. Filing only ever writes one room's content into that room's section.

The adapter interface:

- `create_or_append(doc, section, markdown)`: `doc` is a stable key, `section` a heading, `markdown` the body. The adapter creates the document if it does not exist. If the document has a section with exactly this heading, it replaces that section's body; otherwise it appends the section. It returns a reference to the document (an id or URL) and raises an error when the store does not confirm the write. Calling it twice with the same arguments leaves one section.
- `add_todo(key, text, room, assignee, due, source)`: adds one to-do to `todos_target`. `key` is scribe's to-do id. `assignee`, `due` and `source` (a reference to the digest document) may be null. Returns nothing and raises an error when the store does not confirm the write. If scribe stops after the store accepted a to-do and before `filed_at` was set, it calls `add_todo` again for the same to-do. The adapter SHOULD use `key` to make that call a no-op; an adapter that does not may create a duplicate to-do in the store.

```python
class KnowledgeSink(Protocol):
    def create_or_append(self, doc: str, section: str, markdown: str) -> str: ...
    def add_todo(self, key: str, text: str, room: str, assignee: str | None,
                 due: str | None, source: str | None) -> None: ...
```

Reason: a knowledge store makes digests readable and editable next to other notes. Skipping it leaves digests readable only through the store's database or your build's own view.
Test (best effort): enable filing with `url` pointing at a port nothing listens on, send three messages and run `!digest` in `ROOM` as `@alice`. Expect the reply to start with the summary, `sdb "select status from digest_runs where room_id = '$ROOM' order by id desc limit 1"` to print `ok`, `sdb "select filed_at is null from summaries where room_id = '$ROOM' order by updated_at desc limit 1"` to print `1`, and the log to contain `filing failed`. Point `url` at the real store, restart, send three messages and run `!digest` again. Expect `sdb "select count(*) from summaries where room_id = '$ROOM' and filed_at is null"` to print `0`, and the store to show a document for `digest-<this month>` with a section headed `<today> · <ROOM's name>`.
Label: untested.

**S2. The link index.** When `vector_index` has a `url`, scribe indexes every row in `links` as described under Storage model, through a `VectorIndex` adapter. A link saved by `!link` is indexed right away. Links found by a digest are indexed at the end of the run, at most 10 per room per run (spec choice); the rest wait for the next run or startup. A search embeds the query the same way and always passes the room filter of M13.

The adapter interface:

- `ensure(dimension)`: creates the collection named `collection` for vectors of that size, using cosine distance, if it does not exist. Returns `true` if it created it.
- `count()`: returns the number of points in the collection.
- `upsert(point_id, vector, payload)`: writes one point. The payload always holds `room_id`. Writing an existing `point_id` replaces it. Raises an error when the index does not confirm the write.
- `delete(point_id)`: removes one point. Removing a missing point is not an error. Scribe calls it when it deletes a link row, which happens when the link's source message is redacted (M3).
- `search(vector, limit, room)`: returns up to `limit` hits, best first, each with `point_id`, `score` and `payload`, among the points whose payload `room_id` is `room` (one room id) or in `room` (a list of room ids). The filter is applied by the index, before ranking, so a hit from another room is never returned. An empty list returns no hits.

```python
class VectorIndex(Protocol):
    def ensure(self, dimension: int) -> bool: ...
    def count(self) -> int: ...
    def upsert(self, point_id: str, vector: list[float], payload: dict) -> None: ...
    def delete(self, point_id: str) -> None: ...
    def search(self, vector: list[float], limit: int,
               room: str | list[str]) -> list[Hit]: ...  # Hit: point_id, score, payload
```

Reason: people remember what a link was about more often than its address. Skipping it leaves `!link list` and text search as the only way to find a link.
Test (idempotent ids): `!link HTTPS://Example.COM:443/a/b/?x=1#top first note` as `@alice` in `ROOM`, then `!link https://example.com/a/b?x=1`. Expect `sdb "select count(*), point_id from links where room_id = '$ROOM' and url = 'https://example.com/a/b?x=1'"` to print `1|` followed by the output of `point_id "$ROOM" 'https://example.com/a/b?x=1'`, the second reply (in Element) to start with `updated`, and `sdb "select note from links where room_id = '$ROOM' and url = 'https://example.com/a/b?x=1'"` to print `first note`.
Label: untested.
Test (two rooms, one URL): after the test above, `!link https://example.com/a/b?x=1 second room note` in `ROOM2`. Expect `sdb "select count(*) from links where url = 'https://example.com/a/b?x=1'"` to print `2`, the `ROOM` row's note to still be `first note`, the `ROOM2` row's note to be `second room note`, and the two `point_id` values to differ.
Label: untested.
Test (index down): stop the vector index, run `!link https://example.com/ down test` in `ROOM`. Expect a reply starting `saved` and `sdb "select indexed_at is null from links where room_id = '$ROOM' and url = 'https://example.com/'"` to print `1`. Start the index, restart scribe, wait 60 seconds, and expect the same query to print `0`.
Label: untested.

**S3. Link metadata is opt-in and guarded.** Fetching is controlled by `links.fetch_metadata`, which defaults to `false`. While it is `false`, a link row stores only the URL, room and note (with the sender, source message and time), and scribe makes no request to any URL that came from chat. When it is `true`, scribe fetches a page's title and description for each saved link following every rule under Link fetching rules, and a link is stored even when the fetch is refused or fails. Any build that can fetch link pages has this switch with this default, whatever tier it otherwise meets.
Reason: a fetch sends a request from your host to a third-party site, which learns the host's public address and when the link was saved, including for private share links. That is an outbound path the README's privacy rules list as opt-in, so it stays off until someone turns it on. When it is on, scribe runs next to the model runtime, the homeserver and every other service on the Docker network and the overlay, and a URL typed into chat must never make scribe call one of them.
Test (off by default): with `fetch_metadata: false`, or no `links` section, run `!link https://example.com/ off test` in `ROOM` as `@alice`. Expect `sdb "select title is null from links where room_id = '$ROOM' and url = 'https://example.com/'"` to print `1` and `docker compose logs scribe` to contain no line starting `fetch`.
Label: untested.
The tests below set `links: {fetch_metadata: true}` and restart scribe first, and revert afterward.
Test (private name): start a canary with `docker run -d --rm --name canary --network mesh_mesh mockserver/mockserver`. Run `!link http://canary:1080/probe` and `!link http://127.0.0.1/` in `ROOM` as `@alice`. Expect both links stored with `title` null, `mesh_curl -s -X PUT 'http://canary:1080/mockserver/retrieve?type=REQUESTS&format=JSON' | jq length` to print `0`, and the log to contain `fetch refused: blocked address` twice.
Label: untested.
Test (public page): `!link https://example.com/ public` in `ROOM`. Expect `sdb "select title from links where room_id = '$ROOM' and url = 'https://example.com/'"` to print `Example Domain`.
Label: untested.
Test (rebinding and redirects, in your build's own unit tests): replace the resolver with a stub that returns example.com's current public address on the first lookup of `rebind.test` and `127.0.0.1` on every later lookup, and replace the connection with a recorder that answers `200` with `<title>ok</title>`. Fetch `http://rebind.test/`. Expect one lookup and one connection, to the public address, with the `Host` header `rebind.test`. Then make the recorder answer `302` with `Location: https://rebind.test/next`. Expect a second lookup, no second connection, and the result `fetch refused: blocked address`. Finally make the stub return the public address on every lookup and the recorder answer `301` with `Location: https://rebind.test/` once, then `200`. Expect two connections and the title `ok`.
Label: untested.

**S4. Retention.** At the end of every scheduled run, and once at startup, scribe purges message text by clearing `body`:

1. Normal purge: a `summarized` row whose `ts` is more than `raw_message_days` days old, once the summary for its room and `summary_date` is stored, is not marked `needs_regeneration`, and has `filed_at` set when filing is enabled.
2. Retention cap: any row, in any status and from any room (including rooms that left scope or are on `denylist`), whose `ts` is more than twice `raw_message_days` days old, and at least 1 day old. Scribe logs one line per row purged this way, containing `retention cap` and the event id.

Summaries, to-dos, links and reminders are kept until you delete them. Each purge logs the number of rows cleared by each rule.
Reason: raw chat text is the most sensitive thing scribe holds, and the summary replaces it. Purging only after the summary is stored and filed means an outage costs no data. The cap bounds how long any text can stay, even when a dependency stays down or a room drops out of scope, and the log shows which messages were never summarized. That includes a room that never reaches `min_messages`: its pending rows are purged at the cap, each with a `retention cap` log line, so the loss is bounded and visible.
Test (normal purge): set `raw_message_days: 0` and `schedule: "* * * * *"`, keep filing disabled, and restart. Send three messages and run `!digest` in `ROOM`, then wait 90 seconds. Expect `sdb "select count(*) from messages where room_id = '$ROOM' and status = 'summarized' and body is not null"` to print `0`, and `sdb "select count(*) from summaries where room_id = '$ROOM'"` to print at least `1`. Revert.
Label: untested.
Test (filing holds the purge): as above, with filing enabled and its `url` pointing at a port nothing listens on. Send three messages, run `!digest`, wait 90 seconds. Expect the count of summarized rows with a body to print `3`. Point `url` at the real store, restart, wait 90 seconds, and expect `0`.
Label: untested.
Test (cap, in your build's own unit tests): with `raw_message_days: 1`, store one `pending` and one `summarized` but unfiled row with `ts` 49 hours before an injected clock, and one `pending` row 47 hours before it. Run the purge. Expect the first two bodies cleared, the third kept, and two log lines containing `retention cap`.
Label: untested.

**S5. Answers from memory.** When an admin addresses scribe, scribe answers from its own store and link index, through the model runtime, in the same room, with the room scope of M13. Scribe is addressed when the event's mentions field lists scribe's user id among its `user_ids`, or, for an event without that field, when the text contains scribe's full user id or its current display name, or when the message is sent in a direct room with scribe. A non-admin who addresses scribe gets no answer. The message itself is buffered as usual (M3) when the room is in scope.
Reason: the memory is useful only if people can ask it.
Test: use the fake runtime. In `ROOM2`, send `see https://example.com/purple`, `ok` and `thanks`, and run `!digest` there as `@alice`. In `ROOM`, send three messages without links and run `!digest`. Run `fake_reset` and register the default reply. In `ROOM` as `@alice`, send `@scribe:example.com which links do we have?` and wait 15 seconds. Expect `fake_prompts | tail -n 1` not to contain `example.com/purple`. Send the same question in `DM` and expect the last prompt to contain it. In `ROOM`, send the question as `@bob`, wait 15 seconds, and expect `scribe_posts "$ROOM"` not to change.
Label: untested.

**S6. Late keys.** When scribe receives a room key (from the sender's device, as a forwarded key or from key backup) whose session id matches unresolved rows in `undecryptable`, it fetches those events again, buffers the ones it can now decrypt under M3 as `pending`, and sets `resolved_at`. It retries no row older than the retention cap (S4). The next run covers the recovered messages (M6).
Reason: keys often arrive after the message, for example when the sender's other device comes online. Without a retry those messages stay out of every digest.
Test (needs encryption): repeat M5's setup, then verify scribe's device from `@alice`'s Element session and turn the setting off so Element shares the key. Expect, within 60 seconds, `sdb "select resolved_at is not null from undecryptable order by first_seen desc limit 1"` to print `1` and `sdb "select status from messages where body = 'hidden one'"` to print `pending`.
Label: untested.

### Optional features

**O1. Reminders.** An admin sets a reminder with `!remind` (Commands). Scribe stores it as `pending` in `reminders`. Every 30 seconds (spec choice) it sends each pending reminder whose `due_at` has passed into the room where it was set, mentioning its creator, and then marks it `sent`. The send uses the Matrix transaction id `reminder-<id>`, so if scribe stops between sending and marking, the resend after restart is deduplicated by the homeserver and the room sees one message. A reminder sent more than 60 seconds late says when it was due. If the homeserver refuses the send because scribe is no longer in the room, the reminder becomes `failed`. Any other send error leaves it pending for the next poll.
Reason: a reminder fires once, even across a restart, and one that came due while scribe was down still goes out.
Test: `!remind in 1m stretch` as `@alice` in `ROOM`, then restart scribe 30 seconds later. Expect, within 120 seconds of the command, exactly one new message from scribe in `ROOM` containing `stretch` (in Element), and `sdb "select status from reminders order by id desc limit 1"` to print `sent`.
Label: untested.

**O2. Weekly roll-up.** When `weekly_schedule` is set, at each firing scribe posts one message to each in-scope room that has at least one stored summary dated in the last 7 local dates, ending with the firing's date. The message is a short recap the model writes from that room's summaries only, followed by the room's open to-dos. A room with no summary in that range gets no post. This is the only post scribe makes without being asked.
Reason: a weekly recap in the room is the one reminder that the memory exists. Turning it off leaves scribe completely silent.
Test: with the fake runtime, set `weekly_schedule: "* * * * *"` and restart, with at least one summary for `ROOM` and one for `ROOM2` from today, and none for a third in-scope room `ROOM3` created like `ROOM`. Run `fake_reset` and register the default reply. Expect within 90 seconds one new scribe post in `ROOM` and in `ROOM2` (`scribe_posts`) and none in `ROOM3`, and no single entry of `fake_prompts` to contain text from both rooms' summaries. Revert.
Label: untested.

## Commands

Only admins may run commands (M8). A command is a message whose text starts with the command word, followed by a space or the end of the message. Words are case-sensitive. Scribe replies in the room where the command was sent, never in another room, and every reply follows the room scope of M13. Wrong arguments get a one-line usage reply.

| Command | What it does | Reply |
|---|---|---|
| `!digest` | Runs a digest of this room now (M6), ignoring `min_messages`. | The summary with its to-dos and links, `nothing new to digest`, `this room is not in scope`, or `digest failed: <reason>`. |
| `!digest all` | Runs a digest of every in-scope room now. | `digested N rooms: A ok, B nothing new, C failed`. |
| `!digest <room>` | Runs a digest of one in-scope room, given by room id or alias. | In a direct room, when the admin is joined to that room: as for `!digest`. In a direct room otherwise: `you are not in that room`, and no run. In a group room: only `<room name>: ok`, `nothing new` or `failed`. |
| `!remind <when> <what>` | Sets a reminder (O1). | `reminder #<n> set for <weekday> <day> <month> <HH:MM> (<timezone>)`, or `that time has already passed`. |
| `!remind list` | Lists pending reminders set in this room, soonest first. | One line per reminder with its number and time, or `no pending reminders here`. |
| `!remind cancel <n>` | Cancels pending reminder `n` if it was set in this room. | `canceled #<n>` or `no pending reminder #<n> in this room`. |
| `!link <url> [note]` | Saves the link for this room now: normalizes it, stores it with the note, fetches its title when `links.fetch_metadata` is `true` (S3) and indexes it (S2). A link already saved in this room keeps its row; a new note replaces its note. The same URL in another room is a separate row and is not touched. | `saved: <title or URL>` or `updated: <title or URL>`. |
| `!link list` | Lists the 15 most recent links saved in this room. In a direct room with the admin, the 15 most recent from that room and every room the admin is joined to. | One line per link, or `no links saved yet`. |

`<when>` in `!remind` takes one of these forms, read in `timezone`: `in <n>m`, `in <n>h`, `in <n>d`, `HH:MM` (today, or tomorrow if that time has passed), `tomorrow HH:MM`, `<mon to sun> HH:MM` (the next such day after now), or `YYYY-MM-DD HH:MM`. A local time that does not exist on a daylight-saving change is moved forward by the length of the gap. A time that occurs twice means its first occurrence. A build MAY also accept natural phrasing, such as "remind me to call the vet tomorrow at 9" addressed to scribe, if it shows the resolved time in its reply.

## Link fetching rules

Normalization and point ids apply to every link. The fetch rules from "Which addresses scribe may connect to" onward apply to every request scribe makes to a URL that came from chat, and scribe makes such requests only when `links.fetch_metadata` is `true`. None of these rules apply to the URLs in scribe's config.

**Normalization.** Scribe normalizes a URL before storing, comparing or fetching it:

1. Trim surrounding whitespace. When the URL was found in message text, drop trailing `.`, `,`, `;`, `:`, `!`, `?`, `>`, `"` and `'`. Drop a trailing `)`, `]` or `}` only while the URL holds more closing than opening characters of that kind, so `https://example.com/wiki/Foo_(bar)` keeps its last `)`.
2. The scheme must be `http` or `https`, in any case, and is lowercased. Any other scheme means the text is not a link.
3. Remove any user name and password.
4. Lowercase the host, convert an internationalized name to its ASCII form, and remove a trailing dot.
5. Remove the port when it is the default for the scheme (80 for `http`, 443 for `https`).
6. An empty path becomes `/`. Remove one trailing `/` from any longer path. Keep the path's percent-encoding as given.
7. Keep the query string unchanged, including the order of its parameters.
8. Remove the fragment.

For example, `HTTPS://user:pw@Example.COM:443/a/b/?x=1#top` becomes `https://example.com/a/b?x=1`.

**Point ids.** A link's `point_id` is the version 5 UUID, in the URL namespace (`6ba7b811-9dad-11d1-80b4-00c04fd430c8`), of the room id, one space, and the normalized URL. For the room `!testroom:example.com` and the URL above, the name is `!testroom:example.com https://example.com/a/b?x=1` and the id is `42d1cd7e-980c-59ae-b537-12297e330aa4`. The `point_id` helper computes it.

**Which addresses scribe may connect to.** Scribe resolves the host once per request and gets every IPv4 and IPv6 address for it. If the host is a literal address, that is the only address. The request is refused if any address is one that is not globally reachable, as listed in the IANA IPv4 and IPv6 Special-Purpose Address Registries. Among them:

- IPv4: "this network", private-use (RFC 1918), shared address space (RFC 6598, which overlay networks such as Tailscale use), loopback, link-local, the IETF protocol assignments, the three documentation networks, benchmarking, multicast, reserved, and limited broadcast.
- IPv6: the unspecified and loopback addresses, IPv4-mapped addresses (checked again as the IPv4 address they carry), the NAT64 prefixes, discard-only, the IETF protocol assignments (including Teredo), documentation, 6to4, unique local addresses (which overlay networks also use), link-local, site-local, and multicast.

A builder may use the language's "is global" check only if it refuses every range above. Scribe then connects to one of the checked addresses directly, with the original host name in the `Host` header and for TLS name checking, and does not look the name up again. This closes the gap where a name resolves to a public address for the check and to a private one for the connection.

**Ports, proxies and requests.** Only ports 80 and 443 (spec choice). Scribe ignores proxy settings in its environment, sends no cookies and no credentials, and makes `GET` requests only, with a fixed `User-Agent` your build chooses.

**Redirects.** Scribe follows at most 3 redirects (spec choice), from `http` to `https` and back as well as within a scheme. Each `Location` is resolved against the current URL, normalized, and checked by every rule above, including a new lookup and the address check, before scribe connects. A `Location` with a scheme other than `http` or `https`, a fourth redirect, or a refused hop ends the fetch.

**Limits.** 5 seconds to connect (spec choice) and 10 seconds for the whole fetch, redirects included (spec choice). Scribe reads at most 512 KiB of the body (spec choice), counted after content decoding such as gzip, so a small compressed body cannot expand past the limit, and parses what it has read. It parses only `text/html` and `application/xhtml+xml` responses with status 200. Any other final status ends the fetch, and nothing from that response is stored: the link keeps `title` and `description` null. Any other content type gives no title.

**What is stored.** The normalized URL, the title (the text of the first `<title>` element, whitespace collapsed, cut to 300 characters), the description (the `description` or `og:description` meta tag, cut to 500 characters), the note (from `!link` or the digest), the room, the sender, the source message, and the time. The page body is never stored. A refused or failed fetch keeps the link row with `title` and `description` null and logs a line starting `fetch refused:` or `fetch failed:` with the reason (`blocked address`, `blocked port`, `blocked scheme`, `too many redirects`, `timeout`, `status <code>`, or `too large`).

## Reference implementation notes

These describe the reference deployment's scribe on 2026-10-04. They are not part of the contract.

- **Scheduling.** The reference runs its scheduler on the bot's own async event loop, because its Matrix client library is not thread-safe. Blocking work (embedding, the vector index client) runs in a thread pool. Reminders are polled every 30 seconds by a job on the same loop.
- **Weekday names.** Use weekday names in cron expressions. Some scheduler libraries number weekdays from Monday, so `0` can mean Monday instead of Sunday.
- **Schedule and defaults.** The reference runs the silent daily digest at 07:00 and the weekly roll-up on Mondays at 08:00. It uses a 24-hour window, a minimum of 3 messages, at most 300 messages per room per run and at most 10 indexed links per room per run. Its config keys have different names from this spec's.
- **Store access.** The reference opens SQLite in write-ahead logging mode with a busy timeout of 5 seconds, so that other processes can read the file while scribe writes to it.
- **Model calls.** The reference calls its local runtime's native chat API with a JSON schema for the digest output, at a low temperature, with a 180-second timeout.
- **Embeddings.** A small English sentence-embedding model (384 dimensions) is downloaded at image build time and baked into the image, so nothing is downloaded at runtime. It runs in scribe's process on the CPU. The index uses cosine distance.
- **Retention.** Raw message text is kept for 3 days.
- **Knowledge store.** The reference files into AFFiNE through a third-party MCP server, without the tool gateway. It keeps one rolling digest document per month and appends one dated section per room per day. New to-dos and new links become rows in two tables in the store. The vector index is Qdrant.
- **Link fetching.** 512 KiB body limit, 3 redirects with the host checked on every hop, title and description cut to 300 and 500 characters.
- **Extra commands.** The reference also has `!weekly` (post the roll-up now), and when addressed it understands natural phrasing for reminders and link saving.
