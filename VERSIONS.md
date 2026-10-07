# Tested versions

Every third-party image tag in `.env.example` is pinned to one of the versions below. Copy the pins from there, not from memory. The throwaway images in the verify steps and spec tests (`curlimages/curl`, `mockserver/mockserver`, `alpine`) are not pinned, because they are not part of the running stack.

| Role | Reference implementation | Pinned version | Tested where | Date |
|---|---|---|---|---|
| Homeserver | Synapse (`matrixdotorg/synapse`) | `v1.152.1` | Reference deployment (running); macOS smoke test of chapter 02 | 2026-10-04 |
| Homeserver database | PostgreSQL (`postgres`) | `16-alpine` | Reference deployment (running); macOS smoke test of chapter 02 | 2026-10-04 |
| Call media server | LiveKit (`livekit/livekit-server`) | `v1.11.0` | Reference deployment (running) | 2026-10-04 |
| Call token service | lk-jwt-service (`ghcr.io/element-hq/lk-jwt-service`) | `0.4.4` | Reference deployment (running) | 2026-10-04 |
| Agent bot | baibot (`ghcr.io/etkecc/baibot`) | `latest@sha256:54280f03184b5016f6d4e9ab8b562a39db721b0cd3fff6564adec906c6a3ab71` | Reference deployment (running) | 2026-10-04 |
| Vector store | Qdrant (`qdrant/qdrant`) | `v1.18.0` | Reference deployment (running) | 2026-10-04 |
| Knowledge store MCP server | affine-mcp-server (`ghcr.io/dawncr0w/affine-mcp-server`) | `2.1.0` | Reference deployment (running) | 2026-10-04 |
| Knowledge store | AFFiNE (`ghcr.io/toeverything/affine`) | `0.27.0` (linked, not templated) | Reference deployment (running) | 2026-10-04 |
| Tool gateway | Your own build of `specs/tool-gateway.md` | none | Not tested here: chapter 04 deploys your image | n/a |
| Scribe | Your own build of `specs/scribe.md` | none | Not tested here: chapter 05 deploys your image | n/a |

## The baibot pin

No version tag of baibot has the digest the reference deployment runs. The `latest` tag has moved on since that image was pulled, and none of the published version tags resolve to the same digest. The pin is therefore `latest@sha256:<digest>`: Docker pulls by digest and ignores the `latest` part, so the image is exactly the one that was tested. The baibot image was run on amd64 only; the arm64 image in the same index was not run. If upstream deletes that digest, the pull fails and you must choose another tag. If you would rather track a release, choose a version tag from the upstream registry and treat it as untested until you have run chapter 03 against it.

## What "tested" means here

"Reference deployment (running)" means the image runs on the reference deployment's host, built from the same roles and configuration this repo describes, and the version was read from the running container. The reference deployment shares this repo's roles but differs in layout, service names and some settings. It is not a clean install from these docs.

"macOS smoke test of chapter 02" means a clean install of chapter 02 on macOS with Docker Desktop, following the docs from the rendered templates through account creation, on 2026-10-04. It covered the homeserver and its database only: render, signing key, startup, client versions endpoint, account creation, password login through the client API and an encrypted room. It did not run Element X. It did not cover the overlay network, the static host for the `.well-known` files, a phone client, or calls.

"Not tested" means no run of that step from these docs on a clean machine. Chapters 04 and 05 deploy images you build yourself, so no version is pinned or tested for them.

## Client facts

Observed on the reference deployment, not on the smoke test:

- Element X on phone and desktop logs in with a password against Synapse 1.152.1 with no separate authentication service.
- The client relies on the homeserver's native sliding sync, so no separate sliding sync proxy is involved.

The macOS smoke test checked password login through the client API only and did not run Element X.

## Upgrading

1. Read the upstream release notes for the role you are changing, including every version between your pin and the new one.
2. Change that one pin in `.env`.
3. Re-run `./render.sh` only if the release notes change configuration. A tag bump alone needs no re-render.
4. Run `docker compose pull`, then `docker compose up -d`.
5. Check the chapter's verify step again.

Change one pin at a time so a failure points at one image. Back up the data directory first.

Synapse does not support downgrades, so keep the backup until the new version has run cleanly. A PostgreSQL major version change needs a dump and restore, not a tag bump.
