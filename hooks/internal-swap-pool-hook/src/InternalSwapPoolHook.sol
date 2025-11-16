// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/**
 * @title InternalSwapPoolHook
 * @notice Demonstrates beforeSwapReturnDelta and afterSwapReturnDelta
 *
 * Key Concepts:
 * 1. beforeSwapReturnDelta: Hook can partially/fully fulfill swaps
 * 2. afterSwapReturnDelta: Hook can take a fee from the swap output
 *
 * This simplified version demonstrates the concepts without complex token management
 */
contract InternalSwapPoolHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // Track total swaps fulfilled by hook vs Uniswap pool
    uint256 public totalHookSwaps;
    uint256 public totalPoolSwaps;

    // Track fees collected
    uint256 public totalFeesCollected;

    // Simulated internal "reserves" - just tracks amounts conceptually
    mapping(Currency => uint256) public internalReserves;

    error MustUseDynamicFee();

    event HookFulfilledSwap(uint256 inputAmount, uint256 outputAmount);
    event FeeCollected(uint256 amount);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Add simulated reserves (for demonstration)
     */
    function addReserves(Currency currency, uint256 amount) external {
        internalReserves[currency] += amount;
    }

    /**
     * @notice beforeSwap with Return Delta - DEMONSTRATION
     *
     * NOTE: This is a CONCEPTUAL demonstration only!
     * Actually returning a non-zero BeforeSwapDelta requires proper token settlement.
     * This version just tracks swap routing without actual token movements.
     *
     * The key concept: By returning BeforeSwapDelta with positive specified and
     * negative unspecified amounts, the hook "consumes" the swap input and "provides"
     * the output, reducing or eliminating the amount sent to the Uniswap pool.
     *
     * In production, you would need to actually settle these tokens via:
     * - inputCurrency.settle(poolManager, user, inputAmount, claims);
     * - outputCurrency.take(poolManager, user, outputAmount, claims);
     */
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Determine currencies
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        // Check if we have "reserves" to fulfill this swap
        // This is simplified - in reality you'd need proper pricing
        if (params.amountSpecified < 0 && internalReserves[outputCurrency] > 0) {
            uint256 inputAmount = uint256(-params.amountSpecified);
            uint256 outputAmount = inputAmount; // 1:1 for simplicity

            // Check if we can fulfill it
            if (outputAmount <= internalReserves[outputCurrency]) {
                // Update our tracking (conceptual - not actual tokens)
                internalReserves[inputCurrency] += inputAmount;
                internalReserves[outputCurrency] -= outputAmount;
                totalHookSwaps++;

                emit HookFulfilledSwap(inputAmount, outputAmount);

                // NOTE: In production, you would return the delta and settle tokens.
                // For this demo, we just track the logic without actual settlement.
                // Uncomment below to see the delta concept (will fail without settlement):
                /*
                return (
                    this.beforeSwap.selector,
                    toBeforeSwapDelta(
                        int128(int256(inputAmount)),    // We took the input (specified)
                        -int128(int256(outputAmount))    // We gave the output (unspecified)
                    ),
                    0
                );
                */
                // Still increment pool swaps since we're not actually bypassing it
                totalPoolSwaps++;
                return (
                    this.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    0
                );
            }
        }

        // Track that this swap will use the Uniswap pool
        totalPoolSwaps++;
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /**
     * @notice afterSwap with Return Delta - DEMONSTRATION
     *
     * NOTE: This is a CONCEPTUAL demonstration only!
     * Actually returning a non-zero hookDeltaUnspecified requires proper token settlement
     * which is complex. This version just tracks what WOULD happen.
     *
     * In production, you would return a positive hookDeltaUnspecified and call:
     * unspecifiedCurrency.take(poolManager, address(this), feeAmount, false);
     */
    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Determine which currency is unspecified (the output)
        // For exact input (amountSpecified < 0):
        //   - if zeroForOne = true: specified is currency0 (input), unspecified is currency1 (output)
        //   - if zeroForOne = false: specified is currency1 (input), unspecified is currency0 (output)
        bool currency0IsUnspecified = params.amountSpecified < 0 == params.zeroForOne;
        int128 unspecifiedAmount = currency0IsUnspecified ? delta.amount0() : delta.amount1();

        // Take fee on output (positive delta means user receives)
        // But delta can be negative (user owes), so check absolute value
        int128 absAmount = unspecifiedAmount > 0 ? unspecifiedAmount : -unspecifiedAmount;

        if (absAmount > 0) {
            // Calculate what the 1% fee WOULD be
            uint256 feeAmount = uint128(absAmount) / 100;

            totalFeesCollected += feeAmount;
            emit FeeCollected(feeAmount);

            // NOTE: In production, you would return int128(int256(feeAmount))
            // and actually take the tokens. For this demo, we return 0 to avoid
            // settlement complexity while still demonstrating the concept.
        }

        return (this.afterSwap.selector, 0);
    }
}
