// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/**
 * @title InternalSwapPoolHookEditing
 * @notice Template for experimenting with beforeSwapReturnDelta and afterSwapReturnDelta
 */
contract InternalSwapPoolHookEditing is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // Simulated internal reserves
    mapping(Currency => uint256) public internalReserves;

    // Track stats
    uint256 public totalHookSwaps;
    uint256 public totalPoolSwaps;
    uint256 public totalFeesCollected;

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

    function addReserves(Currency currency, uint256 amount) external {
        internalReserves[currency] += amount;
    }

    /**
     * @notice TODO: Implement beforeSwap with Return Delta
     *
     * Key Concepts:
     * - BeforeSwapDelta = (amountSpecified, amountUnspecified)
     * - Positive delta: Hook takes/is owed currency
     * - Negative delta: Hook gives/owes currency
     * - By returning a positive specified delta, you "consume" user's input
     * - By returning a negative unspecified delta, you "provide" output to user
     * - This reduces amountToSwap, potentially to zero (bypassing pool swap entirely!)
     *
     * Example: User swaps 1 ETH for TOKEN (exact input)
     * - params.amountSpecified = -1 ETH (negative = exact input)
     * - params.zeroForOne = true (ETH is currency0)
     * - To fulfill: return toBeforeSwapDelta(+1 ETH, -X TOKEN)
     * - This consumes the 1 ETH and provides X TOKEN
     * - amountToSwap becomes 0, pool swap is skipped!
     */
    function _beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // TODO: Add logic to fulfill swaps from internal reserves
        // Hint: Check if internalReserves has enough of the output currency
        // If yes, consume input and provide output via BeforeSwapDelta

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /**
     * @notice TODO: Implement afterSwap with Return Delta
     *
     * Key Concepts:
     * - hookDeltaUnspecified modifies the output amount
     * - Positive value: Hook takes from output (reduces user's received amount)
     * - Negative value: Hook adds to output (increases user's received amount)
     * - Use this to take fees, add bonuses, or manipulate swap results
     *
     * Example: Swap outputs 100 TOKEN to user
     * - delta.amount1() = +100 TOKEN (positive = user receives)
     * - To take 1% fee: return hookDeltaUnspecified = +1 TOKEN
     * - User receives 99 TOKEN, hook "keeps" 1 TOKEN
     * - Note: In production, you must actually take/settle the tokens!
     */
    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // TODO: Add logic to take fees from swap outputs
        // Hint: Calculate fee based on delta amount
        // Return positive hookDeltaUnspecified to reduce user's output

        return (this.afterSwap.selector, 0);
    }
}
