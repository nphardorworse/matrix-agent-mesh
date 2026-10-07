# Private network

> **What this role must provide**
>
> - Stable internal names for the host.
> - TLS certificates for those names.
> - Access control between devices.
> - No service ports open to the internet.

## Why an overlay network replaces a perimeter

A conventional setup puts a server behind a firewall and opens the ports people need. Every open port is something to scan and keep patched, and a new vulnerability in any exposed service becomes an urgent job. An overlay network lets the host publish no port on a public address. The overlay client keeps one UDP port open for its own encrypted connections, and it drops packets that do not come from devices on your network.

Clients join the network. A phone or laptop that has joined can talk to the host by name. A device that has not joined cannot connect at all. Access control becomes a list of devices you approved, and you manage that list in one place.

## Reference: Tailscale

The reference deployment uses Tailscale. This is the only chapter that shows `*.ts.net` names, and it always writes them as `mesh-host.tailnet-name.ts.net`.

On Linux, `tailscale` commands that change settings (`up`, `set`, `serve`) need root. Prefix them with `sudo`, or run this once so your own user can run them:

```bash
sudo tailscale set --operator=$USER
```

The `tailscale` commands in this repo are written without `sudo`. On macOS the app's command line needs neither.

1. Install Tailscale on the host and on every client device, phones included. Downloads and install steps are on tailscale.com.
2. Bring the host onto the network.

   ```bash
   tailscale up
   ```

3. In the admin console, disable key expiry for the host. An expired key drops the host off the network, and every client loses the workspace at once. If you tag the host in step 5, you can skip this step: tagging turns key expiry off.
4. Turn on MagicDNS in the admin console, under the DNS settings. Every device then has a stable name, such as `mesh-host.tailnet-name.ts.net`. In the same place, enable HTTPS certificates. Do both before using `tailscale serve`.
5. Tag the host. Add `tag:server` under `tagOwners` in the tailnet policy file:

   ```json
   "tagOwners": {
     "tag:server": ["autogroup:admin"]
   }
   ```

   Then run `tailscale up --advertise-tags=tag:server`, and repeat any flags you passed to `tailscale up` before, because `tailscale up` refuses to drop flags silently. You can also assign the tag to the host in the admin console. Tags let you write access rules about roles ("devices may reach `tag:server`") instead of listing individual machines, which keeps the rules readable. A tagged host has key expiry turned off, so step 3 only matters for an untagged host.

Put the host's MagicDNS name in `.env` as `HS_HOST`. Clients reach the homeserver at that name, and chapter 02 uses it as the delegated host. The name ends up in the public `.well-known` files and in public certificate transparency logs (see below), so pick a neutral machine name. If your overlay network lets you choose its own name, pick one that does not identify you either.

If you use another overlay network, check each item in the box above. The commands differ and the rest of this chapter still applies.

## HTTPS without public ports

Clients need HTTPS to the homeserver, and the overlay network can provide the certificate. `tailscale serve` gets a certificate for the host's name and proxies requests to a loopback port. For the homeserver:

```bash
tailscale serve --bg --https=8448 http://127.0.0.1:8008
```

Clients connect to `https://<HS_HOST>:8448`. The homeserver itself listens only on loopback. Chapter 02b adds two more `tailscale serve` mappings for calls.

## The binding rule

Docker publishes container ports on the host, and the address you bind decides who can reach them. The rule has three cases.

- Bind to `127.0.0.1` when only the host's own proxy needs the port. The homeserver's port 8008 is an example.
- Bind to `${OVERLAY_IP}` when clients must reach the port directly. Call media is the case in this repo.
- Never bind a published port to `0.0.0.0`.

A port bound to the overlay IP can only be published once the overlay interface has that address. After a reboot, Docker may start first and fail to publish it. On Linux, either order Docker after the overlay client with a drop-in (`sudo systemctl edit docker`):

```ini
[Unit]
After=tailscaled.service
Wants=tailscaled.service
```

or let the host bind addresses it does not have yet, with `net.ipv4.ip_nonlocal_bind=1` in a file under `/etc/sysctl.d/`. Chapter 02b is the first chapter that binds to the overlay IP.

A service that only other containers use is not published at all. They reach it over the Docker network by its service name.

A `0.0.0.0` bind inside a container is fine. That address is only visible within the container's own network namespace. The published port on the host is what matters. Docker writes its own firewall rules for published ports, and those rules bypass the host's firewall tools, so a published `0.0.0.0` port can be open to the world even when your firewall says otherwise. Set the bind address in the compose file, and do not rely on the firewall for published ports.

## Reaching the model runtime from containers

The model runtime runs on the host, so containers need a name for the host. Every service that calls the runtime gets this in its compose definition:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

The service then calls the runtime at the address in `MODEL_RUNTIME_URL` in `.env`, which is `http://host.docker.internal:11434/v1` for the reference runtime. How to make the runtime reachable depends on the operating system.

**macOS.** Docker Desktop provides `host.docker.internal` itself. The runtime's default loopback listen address works with no change.

**Linux.** A container reaches the host through the Docker bridge, so the runtime must listen on an address that the bridge can reach. Loopback is not enough. Bind the runtime to the Docker bridge address. Find it with:

```bash
ip -4 addr show docker0
```

The address is usually `172.17.0.1`. For Ollama, set `OLLAMA_HOST=172.17.0.1:11434` (or the address `ip` showed) in the runtime's service environment, then restart it. That keeps the runtime off every other interface, and containers reach it through `host.docker.internal`. From now on, host-side checks of the runtime use this address instead of `127.0.0.1`.

The bridge address exists only once Docker has started, so order the runtime after Docker. For a systemd service, add a drop-in (`systemctl edit ollama`) containing:

```ini
[Unit]
After=docker.service
Requires=docker.service

[Service]
Environment="OLLAMA_HOST=172.17.0.1:11434"
```

If the host runs a firewall such as ufw or firewalld, allow port 11434 from the Docker networks. Compose services sit on their own bridge networks, not on `docker0`, and the firewall drops their traffic otherwise. Print the subnet of each network:

```bash
docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

Then allow each subnet, putting it in place of `<SUBNET>`. Port 11434 is the reference runtime's default, so use your runtime's port if it differs. With ufw:

```bash
sudo ufw allow from <SUBNET> to any port 11434 proto tcp
```

With firewalld, add a rich rule, or put the Docker bridge interfaces in the trusted zone instead. The trusted zone accepts traffic from those interfaces to every port on the host, so prefer the rich rule unless you want that:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<SUBNET>" port port="11434" protocol="tcp" accept' && sudo firewall-cmd --reload
sudo firewall-cmd --permanent --zone=trusted --add-interface=docker0 && sudo firewall-cmd --reload
```

Once chapter 02 has started, run the `inspect` command again with `mesh_mesh` in place of `bridge` and allow that subnet too (with firewalld's trusted zone, add the network's `br-` interface from `ip link`).

As an alternative, set `OLLAMA_HOST=0.0.0.0:11434`. This listens on every interface, including the overlay one, so it needs a host firewall rule that restricts port 11434 to the Docker bridge. Host firewalls are outside this repo's scope, so the bridge address is the default here.

## What the overlay does not protect

Every device on the network can reach every overlay-bound port. A compromised laptop is inside, and it can reach whatever the host binds to the overlay address. Access rules between devices narrow this, and they are worth writing, but the network is a single trust boundary. See [LIMITATIONS.md](../LIMITATIONS.md).

Certificate transparency logs are public, and every HTTPS certificate issued for the host appears in them. The certificate names the machine and the overlay network, for example `mesh-host.tailnet-name.ts.net`, so anyone can learn those names by searching the logs. Knowing the names does not let anyone connect. This is the second reason for a neutral machine name.

The overlay network's coordination service also sees device metadata, such as device names, addresses and when each device is online. It does not see the traffic between devices.

If you don't want a company to hold that metadata, run the coordination service yourself. Headscale is an open-source coordination server that works with the Tailscale clients.

## Verify

Check the proxy mapping:

```bash
tailscale serve status
```

The output lists your `HS_HOST` name on port 8448 proxying to `http://127.0.0.1:8008`.

Check what is listening. On Linux:

```bash
sudo ss -tulnp
```

On macOS:

```bash
lsof -iTCP -sTCP:LISTEN -n -P
```

Nothing should listen on `0.0.0.0` or `*` except what you expect. The `-u` flag includes UDP, which call media uses. Loopback and overlay addresses are fine.

Check that a container reaches the model runtime:

```bash
docker run --rm --add-host=host.docker.internal:host-gateway curlimages/curl -s http://host.docker.internal:11434/v1/models
```

The output is JSON listing your models.

Once chapter 02 is running, open this address from a phone on the network, with your `HS_HOST` value in place of the placeholder:

```text
https://<HS_HOST>:8448/_matrix/client/versions
```

The page shows a JSON list of supported Matrix versions. The same address from a device that has not joined the network does not load.
