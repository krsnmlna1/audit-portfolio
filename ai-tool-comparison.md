# AI Audit Tool Comparison — Cap Labs Retrospective (2025-07-cap)

Three independent passes over the same codebase, compared against a confirmed ground-truth finding.

| Pass | Method | Scope | Cost/Time |
|---|---|---|---|
| **Ground truth** | Manual audit (human) | `vault/FractionalReserve.sol`, `vault/Vault.sol` | — |
| **AuditAgent** | Nethermind's AI scanner, Developer Scan tier | 28 files, ~3,101 BLoC (`fractionalReserve/`, `vault/`, `lendingPool/`, `oracle/`) | 5,202 credits (~$52), ±2hr |
| **Claude Code** | Local LLM agent, unscoped (full repo access) | Entire `cap-contracts/` (no manual scoping applied) | ~$12 est. / ~2h1m active |

**Scope verification:** `diff -rq` between `cap-labs-dev/cap-contracts@0a57fbf` (the actual scope repo, per contest README) and the Claude Code working tree returned no differences in `contracts/`. The only deviations from upstream are the local test harness RPC fix (`test/deploy/TestDeployer.sol:97`, dead Blast API endpoint) and the added PoC test files — confirmed, not assumed.

**Note on scope:** Claude Code's pass was not manually scoped the way AuditAgent's was — it had full repo access rather than a curated subset. This is a confound for direct "which tool is better" claims; it's flagged wherever relevant below.

### Cost and time breakdown

| | AuditAgent | Claude Code |
|---|---|---|
| **Time** | ±2hr (single automated job) | ~2h1m active session time, across 2 sessions (Aug 3 audit: 53 min; Aug 4 review/revision: 68 min) |
| **Cost** | $52.02 (5,202 credits, flat quote) | ~$12 estimated (111 API requests, Claude Opus 5 rates: $5/$25 per MTok, cache read at 0.1x) |
| **Token usage** | N/A (opaque, priced by BLoC) | 476,780 fresh input, 14,815,924 cache read, 91,830 output |
| **Tool calls** | N/A (single scan job) | 122 (72 bash, 27 read, 18 edit, 4 write, 1 skill invocation) |

Claude Code came out roughly **4x cheaper** than AuditAgent's Developer Scan tier for this pass. This isn't a clean apples-to-apples comparison, though — the two aren't the same *mode* of work. AuditAgent is a single autonomous job with a flat quote: point it at a scope, get a report back, no further interaction. Claude Code's time and cost reflect an iterative, human-directed session — including the back-and-forth that caught the Symbiotic finding's false-positive PoC and forced the severity downgrade (Findings comparison, below). Some of that extra time is exactly the verification labor this whole exercise is arguing AI tooling doesn't replace — so "cheaper and slower-but-interactive" is a more honest framing than a single cost-per-bug ratio.

---

## Ground truth

Original submission (confirmed non-duplicate of published finding #409): `Vault._verifyBalance()` reads bookkeeping values (`totalSupplies - totalBorrows`) instead of the actual token balance via `IERC20.balanceOf()`. When the underlying yVault takes a loss, this bookkeeping figure never reflects it — the first redeemer succeeds and drains real assets, subsequent redeemers hit `ERC20InsufficientBalance` with no guaranteed recovery path. Verified with `test/Redeem.t.sol` (`test_SecondRedeemerBlockedAfterYVaultLoss`), written during the original retrospective audit.

**Neither AuditAgent nor Claude Code independently rediscovered this mechanism from reading the contracts.** `Vault.sol` and `FractionalReserveLogic.sol` were in scope for both passes; neither flagged the bookkeeping-vs-balance mismatch. This is the single most important data point in this comparison: the actual submitted, confirmed vulnerability was missed by both AI passes on a source-reading basis.

**A methodology gap, distinct from the above, surfaced while checking this:** `test/Redeem.t.sol` — containing the PoC for this exact bug — sat in the repository the entire time Claude Code's pass ran, dated three weeks before the session. Claude Code never opened it. Asked directly, its self-diagnosis was specific: it worked from the `contracts/*` scope declared in the contest README and only entered test subfolders it judged relevant (`test/deploy`, `test/mocks`, `test/lendingPool`, `test/vault`) — it never enumerated `test/` at the root level, and its own test-run command (`--match-path "test/{vault,lendingPool}/*.t.sol"`) explicitly excluded root-level files. The reported "63 passed" never included this test. AuditAgent, by contrast, never had `test/` in scope at all — its declared scope is contracts only, by design. So this isn't "AI ignored a known issue" (it never saw it) — it's a recon enumeration blind spot, independent of and in addition to the source-reading miss above.

---

## Findings comparison

### Convergent finding: FractionalReserve divest underflow

Both tools independently found the same bug in `FractionalReserveLogic.divest()`, and — notably — both independently separated it from a *different*, superficially similar rounding-dust issue.

| | AuditAgent (Finding #4) | Claude Code (F-02) |
|---|---|---|
| **Mechanism** | `loaned[_asset]` tracks principal only; full-redeem returns principal + yield; subtraction underflows | Same |
| **Severity** | Medium | Medium |
| **Distinguished from rounding-dust variant?** | Yes (separate Finding #5) | Yes (explicitly noted as "not known-issue #2 — that's a 1-wei shortfall; this reverts because of profit") |
| **Verified with PoC?** | No (AI-generated, unverified per report's own disclaimer) | **Yes** — 5/5 tests passing, including a negative control (`interestRate = 0`) proving yield is the specific cause, not an artifact of test setup |

This is the strongest signal in the comparison: two independent AI systems converged on the same non-obvious mechanism and made the same distinction from a look-alike bug. Claude Code's finding is the only one of the two backed by an isolating control, so it's the one that should be treated as validated.

### Discarded candidate: Symbiotic zero-reward DoS (Claude Code F-01)

Initial claim: zero-amount reward forwarded to Symbiotic's `DefaultStakerRewards` bricks `borrow`/`repay`/`liquidate` for a paused or zero-liquidity reserve.

Verification process (this is the part worth documenting in detail — it's the clearest example of why PoC verification is the actual bottleneck skill, not finding generation):

- **Case 1 (admin pause):** PoC held up for `repay()` with a revert-selector-specific assertion (`InsufficientReward()`), plus a positive control (unpause → repay succeeds). Solid.
- **`liquidate()` claim in case 1:** initial PoC used a bare `vm.expectRevert()` with the agent still healthy — the test passed for the wrong reason (`HealthFactorNotBelowThreshold`, not the claimed bug). Caught on review; not yet re-verified with a corrected setup (unhealthy position + `openLiquidation()` + grace period elapsed).
- **Case 2 (zero-liquidity, no privilege required):** on inspection, this is self-healable — any liquidator can mint dust into the reserve atomically in the same transaction as `liquidate()`, bumping `availableBalance` from 0 to >0 and avoiding the zero-transfer revert entirely, at near-zero cost. A DoS trivially bypassable atomically by any actor doesn't hold up as a real finding.

**Disposition:** withdrawn from the High tier, resubmitted as Medium with an explicit caveat that the `liquidate()` leg is unproven (bare `vm.expectRevert()` caught `HealthFactorNotBelowThreshold`, not the claimed bug — the test passed for the wrong reason). Case 2 doesn't survive scrutiny and is dropped from the narrative entirely.

### Convergent finding #3: VaultAdapter permissionless rate manipulation (F-04)

Both tools flagged the same class of issue — `VaultAdapter.rate()` is permissionless and state-mutating, and repeated calls compound the utilization multiplier faster than a single call over the same interval, letting an unprivileged caller steer borrowing rates by choosing sampling cadence.

| | AuditAgent (Findings #8–#11) | Claude Code (F-04) |
|---|---|---|
| **Submitted as** | Medium (across 4 near-duplicate entries) | **Not submitted** — flagged as unresolved |
| **Reasoning** | — | Magnitude depends on deployed `$.rate`, `maxMultiplier`, `minMultiplier` — no visibility into mainnet config, so materiality against the contest's 0.01% yield-loss bar can't be established without a numeric study |

Third convergent finding between the two tools. The gap here isn't detection — it's confidence calibration. AuditAgent submits without flagging the parameter dependency; Claude Code explicitly declines to submit pending data it doesn't have.

### Contest-context-dependent judgment call: AgentConfiguration bitmap blind spot

AuditAgent submitted a Medium finding (Finding #3): reserve IDs above 127 are never recorded in the agent borrowing bitmap (`bit = 1 << (reserveIndex << 1)` overflows past index 127), so their debt is silently excluded from health and borrow-capacity checks.

Claude Code identified the same mechanism and **declined to submit it**, on a reachability judgment: it requires 128+ listed reserves, and the contest scope restricts assets to standard stablecoins (USDC, USDT, pyUSD) with no plans for that many reserves. AuditAgent's Developer Scan has no access to the contest README's scope constraints — it rates reachability from code structure in isolation. This is less about code-reading ability and more about which pass had contest-specific context to reason with.

### Out of scope / not comparable

- **F-03** (Claude Code, `Delegation.distributeRewards` reward-stranding) — `Delegation.sol` was not in AuditAgent's scanned contract list, so there's no counterpart to compare against.

### AuditAgent findings with no Claude Code counterpart

AuditAgent's report included several oracle- and lending-domain findings that Claude Code's pass didn't surface at all: bootstrap mint bypassing cap-token price (High), zero-oracle-price silently excluded from debt totals (High), reserve-ID bitmap blind spot above index 127 (Medium), liquidation window closing on pre-slash health (Medium), and multiple VaultAdapter utilization-multiplier manipulation findings (Medium). None of these have been independently verified with a PoC as part of this comparison — they're listed here as scope AuditAgent covered that this exercise didn't follow up on, not as confirmed bugs.

**Report quality note:** Findings #8/#9 and #10/#11 in the AuditAgent report describe what appears to be the same underlying VaultAdapter issue from two angles. Effective distinct-finding count is closer to 11 than the reported 13.

### Reviewed and cleared (Claude Code only)

Claude Code's log includes negative results — code paths checked and confirmed *not* buggy: `ScaledToken` mint/burn rounding (verified algebraically, no residual-debt bug), the `BorrowLogic.repay` interest-split mismatch (self-correcting, no leak), `DebtToken._updateIndex` at zero supply (no free-interest window), `StakedCap` donation-attack resistance (rate-limited `notify`, linear vesting), `AccessControl.role()` bit-packing (no collisions), and liquidation math ordering (no reentrancy issue). AuditAgent's report has no equivalent — it lists only what it flagged, not what it checked and ruled out. This is a real asymmetry in what each artifact demonstrates about process, separate from either tool's raw detection count.

---

## Takeaways

1. **The ground-truth bug — the one actually submitted and confirmed — was not independently rediscovered by either AI pass from reading the contracts.** Whatever AI tooling contributes, it isn't a replacement for the manual recon that found the original issue. A separate, unrelated gap (Claude Code never enumerating `test/` at root level) meant it also didn't encounter the existing PoC for that bug — worth noting as a recon methodology lesson, but distinct from the miss itself.
2. **Independent convergence is a meaningful signal, but not a substitute for verification.** Both tools converged on three separate mechanisms (FR divest underflow, VaultAdapter rate manipulation, and — implicitly — the AgentConfiguration bitmap gap) without shared context. But only the PoC with a negative control turns "AI flagged this" into "this is real," and only contest-specific context (which one pass had and the other didn't) turns "reachable in isolation" into "reachable in practice."
3. **The Symbiotic case is the most instructive of the three.** A test can pass while proving nothing (wrong revert reason), and a DoS claim can collapse entirely once an adversarial "how would a rational actor route around this" question is asked. Both failure modes are exactly what a verification step exists to catch — an AI generating the candidate doesn't remove the need for it.
4. **Confidence calibration is not free — and it isn't uniform across tools.** Claude Code explicitly withheld two findings pending information it didn't have (deployed rate parameters; contest asset-count constraints). AuditAgent submitted both without that caveat. Whether that's a tooling gap (no access to contest README) or a disposition difference is worth separating out before drawing conclusions about either tool.
5. **Scope curation matters.** AuditAgent's findings came from a manually scoped, archetype-driven subset of the codebase; Claude Code's pass was unscoped. This makes "which tool found more" an unfair question as posed — the more interesting question is what a scoped Claude Code pass, fed the same contest-context AuditAgent lacks, would find under matched constraints. This exercise didn't test that condition.

---

## Pending

Tare comparison (live contest, closed for judging July 29) will be added once the contest repository is made public.