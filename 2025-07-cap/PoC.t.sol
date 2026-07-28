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