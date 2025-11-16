// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {InternalSwapPoolHook} from "../src/InternalSwapPoolHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";

contract TestInternalSwapPoolHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    InternalSwapPoolHook hook;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );

        // Deploy our hook
        deployCodeTo("InternalSwapPoolHook.sol", abi.encode(manager), hookAddress);
        hook = InternalSwapPoolHook(hookAddress);

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swapWithoutInternalReserves() public {
        // Swap without any internal reserves - should use Uniswap pool
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 balanceBefore = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceAfter = currency1.balanceOfSelf();
        uint256 outputAmount = balanceAfter - balanceBefore;

        console.log("Output without internal reserves:", outputAmount);
        console.log("Total pool swaps:", hook.totalPoolSwaps());
        console.log("Total hook swaps:", hook.totalHookSwaps());
        console.log("Fees collected:", hook.totalFeesCollected());

        // Should have used Uniswap pool, not hook
        assertEq(hook.totalPoolSwaps(), 1);
        assertEq(hook.totalHookSwaps(), 0);

        // Should have received output
        assertGt(outputAmount, 0);

        // Should have collected fees (1% of output)
        assertGt(hook.totalFeesCollected(), 0);
    }

    function test_internalReservesTrackingConcept() public {
        // Add "reserves" to the hook (conceptual)
        hook.addReserves(currency1, 1 ether);

        console.log("Internal reserves before swap:", hook.internalReserves(currency1));

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 balanceBefore = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceAfter = currency1.balanceOfSelf();
        uint256 outputAmount = balanceAfter - balanceBefore;

        console.log("Output:", outputAmount);
        console.log("Internal reserves after swap:", hook.internalReserves(currency1));
        console.log("Hook's currency0 reserves:", hook.internalReserves(currency0));
        console.log("Total pool swaps:", hook.totalPoolSwaps());
        console.log("Total hook swaps:", hook.totalHookSwaps());

        // Hook tracks that it COULD fulfill this swap
        assertEq(hook.totalHookSwaps(), 1);

        // Should have received output (from Uniswap pool, not hook)
        assertGt(outputAmount, 0);

        // Internal reserves tracking updated (conceptual)
        assertLt(hook.internalReserves(currency1), 1 ether);
        assertGt(hook.internalReserves(currency0), 0);

        // Note: Swap still goes through Uniswap because we don't actually
        // return the BeforeSwapDelta (that would require token settlement)
        // This demonstrates the CONCEPT of beforeSwapReturnDelta
    }

    function test_feeTrackingConcept() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 balanceBefore = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceAfter = currency1.balanceOfSelf();
        uint256 outputAmount = balanceAfter - balanceBefore;

        uint256 feesCollected = hook.totalFeesCollected();

        console.log("Output amount:", outputAmount);
        console.log("Conceptual fees tracked:", feesCollected);

        // Hook tracks what fees WOULD be collected (1% of output)
        assertGt(feesCollected, 0);

        // Note: The user still receives full output because we don't actually
        // take the fee (that would require complex token settlement)
        // This demonstrates the CONCEPT of afterSwapReturnDelta
    }

    function test_partialInternalFulfillment() public {
        // Add small amount of reserves (less than swap amount)
        hook.addReserves(currency1, 0.0005 ether);

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        console.log("Total pool swaps:", hook.totalPoolSwaps());
        console.log("Total hook swaps:", hook.totalHookSwaps());

        // With insufficient reserves, should fall back to pool
        // This simplified implementation does all-or-nothing,
        // so it should use pool swap
        assertEq(hook.totalPoolSwaps(), 1);
    }
}
