# audit-portfolio

Public findings and proof-of-concepts from smart contract audit work — contest
submissions once judging closes, plus independent retrospectives against
already-resolved scopes.

Retrospectives are worked as if live: independent recon, fund-flow tracing, and a
Foundry PoC before ever opening the `-judging` repo. Findings are cross-checked
against the official published results afterward, not before.

Each folder is one contest. The target codebases are not vendored here — every
entry records the upstream repo and commit so the work can be reconstructed.

## Entries

| Contest | Protocol | Finding | Severity | Status |
|---|---|---|---|---|
| [2025-07-cap](./2025-07-cap) | Cap Labs | Fractional reserve loss not propagated to vault accounting | High | PoC passing, confirmed non-duplicate of published #409 |

## Also here

- [`ai-tool-comparison.md`](./ai-tool-comparison.md) — Nethermind AuditAgent vs. a
  Claude Code pass over the same Cap Labs scope, both benchmarked against the
  ground-truth finding above.

Path: smart contract auditor / Web3 security researcher.
