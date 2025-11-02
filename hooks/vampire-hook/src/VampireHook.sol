// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

contract VampireHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    // The default base fees we will charge
    uint24 public constant BASE_FEE = 5000; // 0.5%

    // Track the current fee for each pool
    mapping(PoolId => uint24) public currentFee;

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
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
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `LPFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        _alignFee(key);

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _alignFee(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        uint24 newFee = getFee();

        // Only update if the fee has changed
        if (currentFee[poolId] != newFee) {
            poolManager.updateDynamicLPFee(key, newFee);
            currentFee[poolId] = newFee;
        }
    }

    function getFee() internal view returns (uint24) {
        // Get current hour (0-23) from timestamp
        uint256 hour = (block.timestamp / 1 hours) % 24;

        // Night time: 18:00 - 5:59 (hours 18-23 and 0-5)
        // Vampires are active at night, so fees are LOWER
        if (hour >= 18 || hour < 6) {
            return BASE_FEE / 2; // Night: half fees
        }

        // Day time: 6:00 - 17:59 (hours 6-17)
        // Vampires sleep during the day, so fees are HIGHER
        return BASE_FEE * 2; // Day: double fees
    }
}
