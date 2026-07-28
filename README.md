# reproduce-practice

Independent audit retrospectives against already-resolved contest scopes.

Each folder is one contest, worked as if live: independent recon, fund-flow
tracing, and a Foundry PoC before ever opening the `-judging` repo. Findings
are cross-checked against the official published results afterward, not before.

## Entries

| Contest | Protocol | Finding | Severity | Status |
|---|---|---|---|---|
| [2025-07-cap](./2025-07-cap) | Cap Labs | Fractional reserve loss not propagated to vault accounting | High | PoC passing, confirmed non-duplicate of published #409 |

Path: smart contract auditor / Web3 security researcher.
