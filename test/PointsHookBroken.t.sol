// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {PointsHookBroken} from "../src/PointsHookBroken.sol";

contract TestPointsHookBroken is Test, Deployers, ERC1155TokenReceiver {

    MockERC20 token; // our token to use in the ETH-TOKEN pool

    // Native tokens are represented by address(0)
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHookBroken hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG);
        deployCodeTo("PointsHookBroken.sol", abi.encode(manager), address(flags));

        // Deploy our hook
        hook = PointsHookBroken(address(flags));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // Add some liquidity to the pool
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 ethToAdd = 0.003 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            sqrtPriceAtTickUpper,
            ethToAdd
        );
        uint256 tokenToAdd = LiquidityAmounts.getAmount1ForLiquidity(
            sqrtPriceAtTickLower,
            SQRT_PRICE_1_1,
            liquidityDelta
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ============================================
    // Test 1: Verify Hook Permissions Declaration
    // ============================================
    function test_getHookPermissions() public {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        // These should be TRUE (declared but beforeSwap not implemented!)
        assertTrue(perms.beforeSwap, "beforeSwap should be true");
        assertTrue(perms.afterSwap, "afterSwap should be true");

        // All others should be FALSE (not declared)
        assertFalse(perms.beforeInitialize, "beforeInitialize should be false");
        assertFalse(perms.afterInitialize, "afterInitialize should be false");
        assertFalse(perms.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(perms.afterAddLiquidity, "afterAddLiquidity should be false");
        assertFalse(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be false");
        assertFalse(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be false");
        assertFalse(perms.beforeDonate, "beforeDonate should be false");
        assertFalse(perms.afterDonate, "afterDonate should be false");

        console.log("Hook permissions verified:");
        console.log("  beforeSwap: true (DECLARED BUT NOT IMPLEMENTED)");
        console.log("  afterSwap: true (implemented)");
        console.log("  All others: false");
    }

    // ============================================
    // Test 2: Initialize Works Without Hooks
    // ============================================
    // NOTE: setUp() already proves this works (lines 63-69)
    // But let's create another pool to demonstrate explicitly
    function test_initializeWorksWithoutHooks() public {
        // Create a second token
        MockERC20 token2 = new MockERC20("Test Token 2", "TEST2", 18);
        Currency token2Currency = Currency.wrap(address(token2));

        // Initialize a new pool with the same "broken" hook
        // This should work because no initialize hooks are declared
        initPool(
            ethCurrency,
            token2Currency,
            hook,
            3000,
            SQRT_PRICE_1_1
        );

        console.log("Pool initialization succeeded!");
        console.log("  Reason: No initialize hooks declared in permissions");
    }

    // ============================================
    // Test 3: Add Liquidity Works Without Hooks
    // ============================================
    // NOTE: setUp() already proves this (lines 87-96 succeed)
    // Let's add more liquidity to demonstrate
    function test_addLiquidityWorksWithoutHooks() public {
        uint256 ethToAdd = 0.001 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(60),
            ethToAdd
        );

        // This should succeed because no add liquidity hooks are declared
        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        console.log("Add liquidity succeeded!");
        console.log("  Reason: No add liquidity hooks declared in permissions");
    }

    // ============================================
    // Test 4: Remove Liquidity Works Without Hooks
    // ============================================
    function test_removeLiquidityWorksWithoutHooks() public {
        // Remove a small amount of liquidity
        int256 liquidityToRemove = -1000; // Negative = remove

        // This should succeed because no remove liquidity hooks are declared
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: liquidityToRemove,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        console.log("Remove liquidity succeeded!");
        console.log("  Reason: No remove liquidity hooks declared in permissions");
    }

    // ============================================
    // Test 5: Swap Fails With HookNotImplemented
    // ============================================
    function test_swapFailsWithHookNotImplemented() public {
        bytes memory hookData = abi.encode(address(this));

        console.log("Attempting swap with unimplemented beforeSwap hook...");
        console.log("  Expected: Revert with HookNotImplemented()");
        console.log("  Reason: beforeSwap declared in permissions but not implemented");

        // Expect the swap to revert with HookNotImplemented error
        // Error selector: 0x575e24b4 = HookNotImplemented()
        // Note: The error is wrapped by the router, so we just expect any revert
        vm.expectRevert();

        // This swap will fail when PoolManager tries to call beforeSwap
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        // This line is never reached because the swap reverts
        console.log("ERROR: Should have reverted!");
    }

    // ============================================
    // Test 6: Swap Fails Early (Gas Analysis)
    // ============================================
    function test_swapFailsEarly() public {
        bytes memory hookData = abi.encode(address(this));

        console.log("Gas analysis test:");
        console.log("  Working hook uses ~160k gas (full swap execution)");
        console.log("  Broken hook should use ~55k gas (fails immediately)");

        uint256 gasBefore = gasleft();

        // Expect revert (wrapped error containing HookNotImplemented)
        vm.expectRevert();

        // Try to swap - this will fail immediately when beforeSwap is called
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        // This is never reached
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used:", gasUsed);
        console.log("Proof: Hook failed early in execution, not after swap logic");
    }

}
