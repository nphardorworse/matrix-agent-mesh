# Introduction

This repo shows how to run a private chat workspace where people and AI agents share rooms. The goal is the one stated at the top of the [README](../README.md); this chapter adds the vocabulary and the reading order.

## Agents in the loop

An agent is an ordinary room member with its own Matrix account. You mention it in a room, and it answers. It can also call tools, such as searching the web or reading a document, within the permissions you gave that agent. One of the agents is the scribe, which turns each day's conversation into searchable memory.

Agents are described here by role. A bot bridge connects a Matrix account to a model, a tool gateway sits between the bridge and everything the agent can touch, and the scribe reads rooms and writes memory. Where a chapter names a specific product, it is the reference implementation of that role, and the chapter says what any replacement must provide.

## The privacy rules

The workspace keeps four rules. Each one can be checked in a specific chapter.

1. No port on a public address. Services publish ports only on loopback or on the overlay address, and everything is reached over the overlay network, whose client keeps one UDP port open for its own encrypted connections. You check this in [chapter 01](01-private-network.md).
2. Data stays on hardware you control: messages, documents, links and embeddings. The [README](../README.md) lists the metadata that still leaves the machine.
3. Hosted models are opt-in and kept away from local tools. A cloud agent must never be able to call a tool that touches local data. A gateway built to [the spec](../specs/tool-gateway.md) refuses to boot if its config breaks that rule, and at call time it checks each tool call against the agent's own tool list. You trigger the boot refusal in [chapter 04](04-tool-gateway.md).
4. Every agent tool call is logged. You read the log in [chapter 04](04-tool-gateway.md).

Cloud models are possible. They are an exception you configure per agent, and a gateway built to the spec enforces the fence around them.

## The reference deployment

These docs come from a running workspace on one always-on machine. The tool names in the chapters are what that deployment uses. Every build chapter (01 onward) opens with a "What this role must provide" box, so you can swap any tool for another that meets the same description. [ARCHITECTURE.md](../ARCHITECTURE.md) lists every role next to its reference implementation.

## Reading order

1. [00 Introduction](00-intro.md)
2. [00 Prerequisites](00-prerequisites.md)
3. [01 Private network](01-private-network.md)
4. [02 Homeserver](02-homeserver.md)
5. [02b Calls](02b-calls.md) (optional)
6. [03 First persona](03-first-persona.md)
7. [04 Tool gateway](04-tool-gateway.md), with [the gateway spec](../specs/tool-gateway.md)
8. [05 Scribe](05-scribe.md), with [the scribe spec](../specs/scribe.md)
9. [06 Knowledge store](06-knowledge-store.md)

Also useful: [ARCHITECTURE.md](../ARCHITECTURE.md), [LIMITATIONS.md](../LIMITATIONS.md), [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) and [VERSIONS.md](../VERSIONS.md).
