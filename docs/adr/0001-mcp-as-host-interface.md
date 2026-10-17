# 0001: MCP is the host interface

Date: 2026-10-17. Status: accepted.

## Context

Remote-control hosts, first wanctl's `act`, want to use OpenCU on a device
without merging the two projects. Each native engine already speaks a JSON-lines
protocol (`opencu-engine serve`), and the Node MCP server sits on top of it.

The Node layer is not a thin wrapper. It adds the observation returned after
each action, waits for expected text, `run_actions` batching, argument
normalization and the error text agents see. A host that talked to the engine
directly would have to reimplement all of that in its own language and track
every change to it.

## Decision

Hosts integrate through OpenCU's MCP server over stdio, found through a per-user
install manifest. They relay `instructions`, the tool list and tool results
unchanged. The contract is [host-integration.md](../host-integration.md).

## Consequences

- OpenCU can add or change tools without a host release.
- A device needs Node. The Windows package bundles it, so the person installs
  one package.
- The engine JSON-lines protocol stays internal and can change freely.
- Hosts must keep one connection per agent session and must not reconnect to
  clear a person's stop.
