# Cap Labs — Fractional Reserve Vault Accounting (Retrospective)

**Contest:** Sherlock `2025-07-cap` (resolved — practiced retrospectively, not a live submission)
**Severity:** High
**Status:** PoC passing, independently confirmed not a duplicate of published finding #409

## Root Cause
Cap's fractional reserve vault invests idle capital into an external ERC4626
yield vault (yVault). When a partial `divest()` realizes a loss, it's never
detected: `VaultLogic._verifyBalance()` checks bookkeeping (`totalSupplies -
totalBorrows`) instead of actual balance (`IERC20.balanceOf`). Both run
independently inside `Vault.redeem()`, so yVault losses never propagate.

## Attack Path / Impact
- First redeemer after a loss succeeds in full.
- Every subsequent redeemer's `safeTransfer` reverts.
- New deposits compound the gap instead of healing it.
- Loss is uncapped, hits user principal, precondition is normal market behavior.

## PoC
`SecondRedeemerBlockedTest` (Foundry) — deposits User A (~1,000 USDC) and User B
(~2,000 USDC), simulates 50% yVault loss via `deal()`. User A redeems fully;
User B reverts with `ERC20InsufficientBalance(vault, 500000001, 2000000001)`.
Result: `[PASS]`.

## Recommendation
Detect and record losses inside `divest()` (both full and partial variants)
instead of silently discarding a shortfall, and have `_verifyBalance()`
cross-check the actual token balance (`IERC20.balanceOf`) alongside the
existing `totalSupplies - totalBorrows` check before approving a transfer.

## Independent verification
Cross-checked against the resolved contest's judging repo after this finding
and PoC were complete — confirmed distinct from #409 (active-borrowing DoS via
`totalBorrows` drain; this bug persists even at `totalBorrows = 0`, since it's
about unrealized yVault loss, not funds currently on loan).

## Note
PoC references types from the original cap-contracts repo (not included here);
intended as documentation, not standalone-runnable.
