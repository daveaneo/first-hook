# Gas Price Fees Hook

A Uniswap v4 dynamic fee hook that adjusts swap fees based on real-time gas prices to incentivize trading during low-congestion periods.

## Overview

This hook demonstrates:
- **Dynamic fee adjustment** based on gas price conditions
- **Moving average tracking** for gas prices
- **Fee override mechanism** using `beforeSwap` hook
- Working with `DYNAMIC_FEE_FLAG` pools
- Real-time fee calculation per swap

## How It Works

### Fee Adjustment Strategy

The hook maintains a moving average of gas prices and adjusts fees dynamically:

1. **High Gas Price** (>10% above average): Charge **half fees** (0.25%)
   - Incentivizes trading when network is congested
   - Lower fees compensate for high gas costs

2. **Normal Gas Price** (±10% of average): Charge **base fees** (0.5%)
   - Standard fee rate for typical conditions

3. **Low Gas Price** (<10% below average): Charge **double fees** (1.0%)
   - Capture more value during low-congestion periods
   - Users still save on overall transaction costs

### Moving Average Calculation

```
New Average = ((Old Average × Count) + Current Gas Price) / (Count + 1)
```

The moving average is updated:
- In the constructor (initial value)
- After each swap in `afterSwap`

**Example:**
```
Constructor: gasPrice = 10 gwei → avg = 10 gwei (count = 1)
After swap 1: gasPrice = 10 gwei → avg = 10 gwei (count = 2)
After swap 2: gasPrice = 4 gwei → avg = 8 gwei (count = 3)
After swap 3: gasPrice = 12 gwei → avg = 9 gwei (count = 4)
```

## Key Features

### Dynamic Fee Pool

The pool must be initialized with `DYNAMIC_FEE_FLAG` instead of a fixed fee:

```solidity
initPool(
    currency0,
    currency1,
    hook,
    LPFeeLibrary.DYNAMIC_FEE_FLAG,  // Special flag = 0x800000
    SQRT_PRICE_1_1
);
```

### Fee Override in beforeSwap

Instead of calling `poolManager.updateDynamicLPFee()`, we use the fee override mechanism:

```solidity
function _beforeSwap(...) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
    uint24 fee = getFee();
    uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
}
```

The `OVERRIDE_FEE_FLAG` (23rd bit = 1) tells the PoolManager to use this fee for the current swap.

### Two Ways to Update Fees

**Method 1: Per-Swap Override** (used in this hook)
- Update fee for each individual swap
- Return override fee from `beforeSwap`
- Best for frequently changing fees

**Method 2: Pool-Wide Update** (commented out)
```solidity
poolManager.updateDynamicLPFee(key, fee);
```
- Update fee once, applies to all subsequent swaps
- Best for infrequent updates (once per block or less)

## Code Highlights

### Hook Permissions

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: true,  // Validate pool has DYNAMIC_FEE_FLAG
        beforeSwap: true,        // Calculate and override fee per swap
        afterSwap: true,         // Update moving average after swap
        // ... all others false
    });
}
```

### Fee Calculation Logic

```solidity
function getFee() internal view returns (uint24) {
    uint128 gasPrice = uint128(tx.gasprice);

    // High gas (>110% avg) → lower fees (50% of base)
    if (gasPrice > (movingAverageGasPrice * 11) / 10) {
        return BASE_FEE / 2;  // 2500 = 0.25%
    }

    // Low gas (<90% avg) → higher fees (200% of base)
    if (gasPrice < (movingAverageGasPrice * 9) / 10) {
        return BASE_FEE * 2;  // 10000 = 1.0%
    }

    return BASE_FEE;  // 5000 = 0.5%
}
```

### Validation in beforeInitialize

```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160)
    internal pure override returns (bytes4)
{
    if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
    return this.beforeInitialize.selector;
}
```

Ensures the pool was created with dynamic fee support.

## Testing

Run the tests for this hook:

```bash
forge test --match-path hooks/gas-price-fees-hook/test/GasPriceFeesHook.t.sol -vv
```

### Test Flow

The test verifies:

1. **Initial State**: Moving average = 10 gwei (from constructor)
2. **Swap at 10 gwei**: Uses base fee, average stays at 10 gwei
3. **Swap at 4 gwei**: Uses doubled fee, average updates to 8 gwei
4. **Swap at 12 gwei**: Uses halved fee, average updates to 9 gwei
5. **Output Verification**: Decreased fee swap > Base fee swap > Increased fee swap

## Economic Mechanism

### User Perspective

**Scenario 1: High Network Congestion**
- Gas price: 20 gwei (average: 10 gwei)
- Swap fee: 0.25% instead of 0.5%
- Total cost: High gas + Low swap fee
- Incentive: Still expensive, but swap fee discount helps

**Scenario 2: Low Network Congestion**
- Gas price: 5 gwei (average: 10 gwei)
- Swap fee: 1.0% instead of 0.5%
- Total cost: Low gas + Higher swap fee
- Net result: Still cheaper overall transaction

**Scenario 3: Normal Conditions**
- Gas price: 10 gwei (average: 10 gwei)
- Swap fee: 0.5% (standard)
- Predictable costs

### LP Perspective

- Earn higher fees during low-congestion periods
- Lower fees during high-congestion (but potentially more volume)
- Fee revenue varies with network conditions
- Average fee income should remain competitive

## Production Considerations

### Improvements Needed

1. **Financial Modeling**
   - Ensure users can't game the system by setting higher gas prices
   - Total cost (gas + fees) should always be higher for manipulation attempts

2. **More Frequent Updates**
   - Enable all hook functions to track gas prices more accurately
   - Current implementation only updates on swaps

3. **Configurable Parameters**
   - Make BASE_FEE adjustable
   - Make threshold multipliers (0.9x, 1.1x) configurable
   - Add owner controls for parameter updates

4. **Advanced Fee Curves**
   - Polynomial curves instead of step functions
   - Gradual fee transitions
   - Consider time-weighted averages

5. **MEV Protection**
   - Prevent sandwich attacks exploiting fee changes
   - Consider batch updates or delayed effects

## Learning Objectives

This hook teaches:

### Core Concepts
1. **Dynamic fee pools** and `DYNAMIC_FEE_FLAG`
2. **Fee override mechanism** with `OVERRIDE_FEE_FLAG`
3. **Moving average calculations** onchain
4. **Gas price access** via `tx.gasprice`
5. **Pool initialization validation** in `beforeInitialize`

### Advanced Techniques
6. **Per-swap fee adjustment** vs pool-wide updates
7. **State management** for tracking metrics
8. **Economic mechanism design** for incentive alignment
9. **Helper function patterns** for cleaner code
10. **Real-world considerations** for production systems

## Gas Optimization Notes

- Moving average calculation is gas-efficient (simple arithmetic)
- Fee calculation happens in a view function (no state changes)
- State updates only in `afterSwap` (once per swap)
- Could be optimized further by batching updates

## Limitations

1. **Manipulation Risk**: Users could set artificial gas prices (depends on tx.gasprice behavior)
2. **Limited Tracking**: Only updates on swaps, misses other network activity
3. **Simple Model**: Step function for fees, not smooth curve
4. **No Time Decay**: Old data has equal weight in moving average
5. **Single Pool**: Each pool tracks independently, no cross-pool optimization

## Extensions and Ideas

- **Time-weighted moving average** with decay
- **Exponential moving average** for faster adaptation
- **Cross-pool gas price oracle** for better data
- **Volatility-based adjustments** in addition to gas price
- **Integration with Chainlink oracles** for more reliable gas price data

## Related Files

- Source: `src/GasPriceFeesHook.sol`
- Tests: `test/GasPriceFeesHook.t.sol`

## Comparison to Other Hooks

- **points-hook**: Simple `afterSwap`, no fee modification
- **flash-loan-hook**: Multiple hooks, no dynamic fees
- **gas-price-fees-hook**: Dynamic fees, moving average tracking ⭐

## Resources

- [Uniswap v4 Dynamic Fees](https://docs.uniswap.org/contracts/v4/concepts/dynamic-fees)
- [LPFeeLibrary Documentation](https://github.com/Uniswap/v4-core/blob/main/src/libraries/LPFeeLibrary.sol)
- Moving Average Algorithms
- Gas Price Optimization Strategies
