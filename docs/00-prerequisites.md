# Prerequisites

> **What this role must provide**
>
> - An always-on machine that can run the model you choose.
> - Docker with Compose v2.20 or later.
> - A local model runtime with an OpenAI-compatible endpoint, running natively on the host.
> - A domain you control, and a static host for two files.
> - Client devices (phones and laptops) that can join the overlay network.

## The machine

There is no hardware requirement beyond the first line of the box: the machine stays on, and it can run the model you pick. A model that fits in memory is what matters. These figures are approximate, for a model quantized to 4 bits.

| Model size | Memory needed (approximate) |
|---|---|
| 7–8B parameters | about 6 GB |
| 12–14B parameters | about 10 GB |
| 26–32B parameters | about 20 GB |

Add room for context. Longer conversations and more parallel requests need more memory on top of these numbers.

If your machine has an accelerator with its own memory, a small model that fits entirely in that memory beats a larger one that spills over to the CPU. The larger model will answer, but slowly enough that people stop mentioning the agent.

## Docker and Compose

The repo's `compose.yaml` uses the `include:` key to pull in one file per chapter. That key needs Compose v2.20 or later. Check your version:

```bash
docker compose version
```

## Local model runtime

The runtime serves models over an OpenAI-compatible HTTP endpoint. Run it natively on the host, not in a container. On macOS, containers cannot use the host GPU. On Linux, a native runtime avoids setting up GPU passthrough for containers. Containers reach the runtime over the network; chapter 01 shows how.

The reference implementation is Ollama. Pull one model that supports tool calling, because chapter 03 and later rely on it. With the reference runtime, that is `ollama pull <model>`, where `<model>` is the name of a tool-capable model from its library. Then check that the endpoint lists it:

```bash
curl -s http://127.0.0.1:11434/v1/models
```

The output is JSON with at least one model in its `data` list. If another runtime is on a different port, use that port instead. On Linux, after chapter 01 moves the runtime to the Docker bridge address, run this check against that address instead of `127.0.0.1`.

## Domain and static host

You need a domain you control. It becomes the Matrix server name, the part after `:` in every user ID, such as `@alice:example.com`. It cannot change later without starting a new server, so choose it now.

You also need somewhere to serve two small JSON files at `https://example.com/.well-known/matrix/`. Any static host works if it can set a response header, because the files need a JSON content type and a CORS header. Chapter 02 gives the exact files.

## Verify

Run these three checks on the host.

```bash
docker compose version
curl -s http://127.0.0.1:11434/v1/models
nslookup example.com
```

Replace `example.com` with your domain in the third command. The first prints a version of v2.20 or later. The second prints JSON listing at least one model (on Linux, use the bridge address once chapter 01 has changed it). The third prints an address, which shows the domain resolves.
