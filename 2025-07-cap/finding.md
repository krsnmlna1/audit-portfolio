# Stale `totalSupplies` Accounting After yVault Loss Leads to Reverted Redemptions

## Severity: High

This issue qualifies as High severity for two reasons:

1. **No extensive limitation on the precondition.** The root cause — a loss in the external yVault strategy — is not an exotic or attacker-engineered state. It is an inherent, expected risk of the fractional reserve design itself (idle capital invested into an external yield strategy). This satisfies the "without (extensive) limitations of external conditions" criterion for High severity in this contest.
2. **The loss is uncapped.** There is no mechanism that bounds or heals the deficit between `totalSupplies` and the actual token balance. New deposits (via `mint()`) increase both figures proportionally but never close the absolute gap, so the deficit persists and can compound over time. Depending on the size of the yVault loss, the affected amount can exceed the 1% TVL / individual collateral threshold required for High.

## Summary

`Vault.redeem()` relies on `FractionalReserveLogic.divest()` (partial variant) to pull funds back from the external yVault, and on `VaultLogic._verifyBalance()` to confirm sufficient funds before transferring assets to the redeemer. Neither function is aware of the other's result: `divest()` performs no loss-detection when the yVault returns less than expected, and `_verifyBalance()` only checks the bookkeeping values `totalSupplies - totalBorrows`, never the contract's actual token balance. As a result, a loss inside the yVault is never reflected in the protocol's own accounting, and redemptions can succeed or fail depending purely on transaction order rather than on principal actually owed.

## Root Cause

In `Vault.redeem()`:

```solidity
divestMany(assets(), totalDivestAmounts);
VaultLogic.redeem(
    getVaultStorage(),
    RedeemParams({ ... })
);
```

`divestMany()` calls `FractionalReserveLogic.divest()` (partial variant) first, to withdraw funds from the yVault. This function performs no loss check at all — if the yVault returns less than requested, the shortfall is silently absorbed.

`VaultLogic.redeem()` then runs `_verifyBalance()`:

```solidity
function _verifyBalance(IVault.VaultStorage storage $, address _asset, uint256 _amount) internal view {
    uint256 balance = availableBalance($, _asset);
    if (balance < _amount) {
        revert InsufficientReserves(_asset, balance, _amount);
    }
}

function availableBalance(IVault.VaultStorage storage $, address _asset) public view returns (uint256 balance) {
    balance = $.totalSupplies[_asset] - $.totalBorrows[_asset];
}
```

`_verifyBalance()` is independent from `divestMany()` — it never inspects the actual result of the divest that just ran. It only compares bookkeeping values (`totalSupplies - totalBorrows`), which are blind to any loss incurred in the yVault.

There should be a check — using `IERC20(asset).balanceOf(address(this))` — that compares the actual balance against the bookkeeping value before proceeding. Because this check does not exist, a yVault loss is never detected until the final `safeTransfer()` call, which reverts entirely (via OpenZeppelin's `ERC20InsufficientBalance`) once the actual balance runs out — by which point the transaction fails atomically, including the `_burn()` of the redeemer's cUSD.

## Attack Path

**Initial state:**
Vault has 1 asset (USDC) with 2 depositors:
- User A deposits 1,000 USDC
- User B deposits 2,000 USDC
- Total `totalSupplies` = 3,000 USDC
- All balance is invested into the external yVault via `investAll()`, so vault balance = 0 and yVault balance = 3,000 USDC

**Step-by-step:**
1. The yVault (external investment strategy) incurs a loss. In this scenario, a 50% loss is assumed, so the actual balance drops to 1,500 USDC (50% of 3,000).
2. User A (first redeemer) redeems 1,000 USDC and successfully receives 1,000 USDC.
3. User B (second redeemer) attempts to redeem 2,000 USDC, but the transaction reverts. This happens because `_verifyBalance` only checks `totalSupplies - totalBorrows`, not the actual balance. At this point, the yVault only holds 500 USDC remaining (after the loss and User A's redemption), while User B is claiming 2,000 USDC — causing the transfer to revert.

**Outcome:**
The revert causes User B's entire transaction to fail — cUSD remains in their hand (never burned), but they cannot redeem it until the vault's actual balance recovers to match `totalSupplies`.

## Impact

This issue is not limited to a simple "first-come-first-served" problem. There are two distinct impact scenarios:

1. **Turn order dependent**: The first redeemer can successfully redeem because the yVault still holds enough balance after the loss. However, subsequent redeemers cannot redeem — their transactions revert due to insufficient actual balance, since the loss has already been absorbed by earlier redemptions and is not reflected in `totalSupplies`.

2. **All-user impact (severity scales with loss size)**: As the yVault's loss increases, the actual balance available decreases proportionally. If the loss is severe enough, even the first redeemer can revert. This means the impact is not strictly limited to "later" redeemers — depending on the size of the loss relative to the amount being claimed, **any depositor** can be affected, including the very first one to attempt redemption.

In both cases, affected users' cUSD remains un-burned (the transaction reverts entirely), and they cannot redeem their principal until the vault's actual balance recovers to match `totalSupplies` — a condition with no guaranteed recovery mechanism in the contract.

## Proof of Concept

The following Foundry test demonstrates the issue: with a 50% yVault loss, the first redeemer (User A, claiming 1,000 USDC) succeeds and receives ~1,000 USDC, while the second redeemer (User B, claiming 2,000 USDC) reverts with `ERC20InsufficientBalance(vault, 500000001, 2000000001)`.

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { Vault } from "../../contracts/vault/Vault.sol";
import { MockAccessControl } from "./mocks/MockAccessControl.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { MockOracle } from "./mocks/MockOracle.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TestVault is Vault {
    function initialize(
        string memory _name,
        string memory _symbol,
        address _accessControl,
        address _feeAuction,
        address _oracle,
        address[] calldata _assets,
        address _insuranceFund
    ) external initializer {
        __Vault_init(_name, _symbol, _accessControl, _feeAuction, _oracle, _assets, _insuranceFund);
    }
}

contract SecondRedeemerBlockedTest is Test {
    TestVault public vault;
    MockAccessControl public accessControl;
    MockOracle public oracle;
    MockERC20 public usdc;
    MockERC4626 public yVault;

    address public userA = makeAddr("userA");
    address public userB = makeAddr("userB");

    function setUp() public {
        accessControl = new MockAccessControl();
        oracle = new MockOracle();
        usdc = new MockERC20("USD Coin", "USDC", 6);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        oracle.setPrice(address(usdc), 1e18);
        vault = new TestVault();
        oracle.setPrice(address(vault), 1e18);
        vault.initialize(
            "Test Vault", "TV",
            address(accessControl),
            address(2),
            address(oracle),
            assets,
            address(4)
        );

        yVault = new MockERC4626(address(usdc), 0, "Mock yVault", "myUSDC");
        vault.setFractionalReserveVault(address(usdc), address(yVault));
        vault.setReserve(address(usdc), 0);
    }

    function test_SecondRedeemerBlockedAfterYVaultLoss() public {
        usdc.mint(userA, 1000e6);
        usdc.mint(userB, 2000e6);

        vm.startPrank(userA);
        usdc.approve(address(vault), 1000e6);
        vault.mint(address(usdc), 1000e6, 0, userA, block.timestamp + 1 hours);
        vm.stopPrank();

        vm.startPrank(userB);
        usdc.approve(address(vault), 2000e6);
        vault.mint(address(usdc), 2000e6, 0, userB, block.timestamp + 1 hours);
        vm.stopPrank();

        vault.investAll(address(usdc));

        console.log("USDC in vault after invest:", usdc.balanceOf(address(vault)));
        console.log("USDC in yVault after invest:", usdc.balanceOf(address(yVault)));

        console.log("totalSupplies after mints:", vault.totalSupplies(address(usdc)));
        console.log("actual USDC in vault:", usdc.balanceOf(address(vault)));

        console.log("yVault USDC balance BEFORE loss:", usdc.balanceOf(address(yVault)));
        deal(address(usdc), address(yVault), 1_500_000_000);
        console.log("yVault USDC balance AFTER loss:", usdc.balanceOf(address(yVault)));

        vm.startPrank(userA);
        uint256[] memory minAmountsOut = new uint256[](1);
        minAmountsOut[0] = 0;
        vault.redeem(1e21, minAmountsOut, userA, block.timestamp + 1 hours);
        console.log("userA USDC balance after redeem:", usdc.balanceOf(userA));
        vm.stopPrank();

        console.log("totalSupplies after userA redeem:", vault.totalSupplies(address(usdc)));
        console.log("actual USDC remaining (vault + yVault):", usdc.balanceOf(address(vault)) + usdc.balanceOf(address(yVault)));

        vm.startPrank(userB);
        uint256[] memory minAmountsOuts = new uint256[](1);
        minAmountsOuts[0] = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                address(vault),
                500000001,
                2000000001
            )
        );
        vault.redeem(2e21, minAmountsOuts, userB, block.timestamp + 1 hours);
        console.log("userB USDC balance after redeem:", usdc.balanceOf(userB));
        vm.stopPrank();
    }
}
```

**Test result:**
```
[PASS] test_SecondRedeemerBlockedAfterYVaultLoss() (gas: 743304)
Logs:
  USDC in vault after invest: 0
  USDC in yVault after invest: 3000000000
  totalSupplies after mints: 3000000000
  actual USDC in vault: 0
  yVault USDC balance BEFORE loss: 3000000000
  yVault USDC balance AFTER loss: 1500000000
  userA USDC balance after redeem: 999999999
  totalSupplies after userA redeem: 2000000001
  actual USDC remaining (vault + yVault): 500000001
  userB USDC balance after redeem: 0
```

## Recommendation

1. **Detect and record losses at `divest()`**: When `divest()` (both the full and partial variants) withdraws less than the expected `loaned` amount from the yVault, this shortfall should be recorded rather than silently discarded. This could be tracked as a separate "realized loss" variable, or used to proportionally reduce `totalSupplies` to reflect the actual deficit. This also has a secondary benefit: it enables calculating the loss percentage for a given asset, which is useful for transparency and monitoring.

2. **Cross-check actual balance in `_verifyBalance()`**: In addition to the existing `totalSupplies - totalBorrows` check, `_verifyBalance()` should also account for the actual token balance held by the contract (`IERC20(asset).balanceOf(address(this))`) before proceeding with a transfer. This ensures the bookkeeping figure cannot approve a redemption that the contract cannot actually fulfill.

Together, these changes ensure that a loss in the yVault is reflected in the protocol's accounting as soon as it is detected, rather than remaining invisible until a redeemer happens to trigger it. This also moves the protocol away from a first-come-first-served distribution of losses toward a more predictable, proportional one.
