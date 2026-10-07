# Calls (optional)

This chapter is optional. Skip to chapter 03 if you only want text.

> **What this role must provide**
>
> - A media server for group calls, reachable on the overlay network.
> - An auth service that turns a Matrix identity into a media-server token.

## Reference: LiveKit and lk-jwt-service

The reference deployment uses LiveKit as the media server and lk-jwt-service as the auth service. The templates in `templates/02b-calls/` run both. The compose services are `call-sfu` and `call-auth`. Any pair of services that meets the two requirements in the box works, as long as your Matrix client supports it.

## How call auth works

A client that wants to join a call asks the auth service for a token. The auth service checks who the user is by asking the homeserver's OpenID endpoint, which the `federation` listener resource serves. So that resource stays in `homeserver.yaml` even while federation is closed. If you remove it, calls fail at the token step.

The tested homeserver version needed no experimental flags for this. Older versions may need some.

The auth service also calls the homeserver itself. It follows the server's `.well-known` file to `https://<HS_HOST>:8448`, so the `call-auth` container must be able to resolve and reach that address. Overlay DNS names sometimes do not resolve inside containers.

## Configure and start

Open `.env` and fill in the chapter 02b values.

- Set `LIVEKIT_TAG` and `LK_JWT_TAG` to the versions listed in `VERSIONS.md`.
- Set `LIVEKIT_KEY` to any short identifier.
- Generate `LIVEKIT_SECRET` with `openssl rand -hex 32`.

Render the templates.

```bash
./render.sh
```

Open `compose.yaml`, uncomment the two include lines for chapter 02b, and start the new services.

```bash
docker compose up -d
```

## Publish

Signaling and token requests go through the HTTPS proxy from chapter 01. Both container ports stay on loopback. On Linux, add `sudo` unless you set yourself as the operator in chapter 01. With another overlay network, use its own HTTPS proxy with the same port mappings.

```bash
tailscale serve --bg --https=7443 http://127.0.0.1:7880
tailscale serve --bg --https=8449 http://127.0.0.1:8089
```

Media ports 7881/tcp and 7882/udp are bound to the overlay IP directly, so clients send audio and video to the machine without a proxy in between.

> **Note:** Docker can publish these ports only once the overlay interface has its address. On Linux, order Docker after the overlay client or allow non-local binds, as described under the binding rule in [chapter 01](01-private-network.md). Otherwise the call services fail to start after a reboot.

## Advertise calls to clients

Clients learn about the call service from the client delegation file. Replace the chapter 02 client file on the static host with `rendered/02b-calls/static-host/.well-known/matrix/client`. It has the same homeserver address plus the auth service address. The header file from chapter 02 (JSON content type and CORS) still applies to the replaced file, so keep it on the static host.

## Verify

On the machine that runs the services, check the published ports.

```bash
tailscale serve status
```

The output lists 8448, 7443 and 8449. Then fetch the delegation file from anywhere.

```bash
curl -s https://<WELLKNOWN_HOST>/.well-known/matrix/client | jq '."org.matrix.msc4143.rtc_foci"'
```

The output shows the auth service URL on port 8449. Next, check that a container on the compose network can reach the homeserver by its overlay name. The auth service image may not include a download tool, so use a throwaway curl container. The network name is the compose project name plus `_mesh`, and the project name is `mesh` (set in `compose.yaml`).

```bash
docker run --rm --network mesh_mesh curlimages/curl -s https://<HS_HOST>:8448/_matrix/client/versions
```

The output is JSON with a list of Matrix versions. If the name does not resolve, fix DNS for containers before testing calls. Finally, place a call between two devices on the overlay network. Both should hear and see each other.
