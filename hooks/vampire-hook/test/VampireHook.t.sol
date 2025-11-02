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
import {VampireHook} from "../src/VampireHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";

contract TestVampireHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    VampireHook hook;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG
            )
        );

        // Deploy our hook
        deployCodeTo("VampireHook.sol", abi.encode(manager), hookAddress);
        hook = VampireHook(hookAddress);

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
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

    function test_feeUpdatesWithTimeOfDay() public {
        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Test 1: Night time (2 AM = hour 2) - should have LOWER fees (BASE_FEE / 2)
        vm.warp(2 hours);
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromNightSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);
        console.log("Night (2 AM) Output", outputFromNightSwap);

        // Verify the fee was set correctly in the hook's storage
        uint24 storedFee = hook.currentFee(key.toId());
        assertEq(storedFee, 2500); // BASE_FEE / 2 = 5000 / 2 = 2500

        // Test 2: Day time (12 PM = hour 12) - should have HIGHER fees (BASE_FEE * 2)
        vm.warp(12 hours);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromDaySwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);
        console.log("Day (12 PM) Output", outputFromDaySwap);

        // Verify the fee was updated correctly
        storedFee = hook.currentFee(key.toId());
        assertEq(storedFee, 10000); // BASE_FEE * 2 = 5000 * 2 = 10000

        // Test 3: Late night (10 PM = hour 22) - should have LOWER fees (BASE_FEE / 2)
        vm.warp(22 hours);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromLateNightSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);
        console.log("Late Night (10 PM) Output", outputFromLateNightSwap);

        // Verify the fee was updated back to night rate
        storedFee = hook.currentFee(key.toId());
        assertEq(storedFee, 2500); // BASE_FEE / 2 = 5000 / 2 = 2500

        // Verify: Night swaps should have MORE output (lower fees) than day swaps
        assertGt(outputFromNightSwap, outputFromDaySwap);
        assertGt(outputFromLateNightSwap, outputFromDaySwap);

        // Night outputs should be approximately equal
        assertApproxEqRel(outputFromNightSwap, outputFromLateNightSwap, 0.001e18); // within 0.1%
    }
}
