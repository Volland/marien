---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Out-of-tree extension with its own repository

## Context and Problem Statement

LadybugDB has no stable extension ABI and builds with CMake without a Lean toolchain.

## Considered Options

* Own repository, pinned LadybugDB version, own extension server
* Contribute to `ladybugdb/extensions`
* Own repository now, upstream proposal once stable

## Decision Outcome

Chosen option: "Own repository now, upstream proposal once stable", because both.

Rejected: Own repository, pinned LadybugDB version, own extension server (`INSTALL marien FROM <url>`); Contribute to `ladybugdb/extensions` (upstream must adopt Lean in CI).

### Consequences

* Good, because releases do not wait for upstream.
* Bad, because a CI matrix of LadybugDB version, OS and CPU is needed, and Lean, GMP and libuv must stay hidden inside the library. The spike measured 2.7 MB uncompressed and 0.8 MB gzipped on macOS arm64 ([ADR 0022](0022-runtime-only-lean-initialization.md)).

## More Information

Recorded in the knowledge graph as [[decisions#Out-of-tree extension with its own repository]].
