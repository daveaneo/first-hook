# Internal Swap Pool Hook - Return Delta Demonstration

## Overview

This hook demonstrates the concepts of **beforeSwapReturnDelta** and **afterSwapReturnDelta** - two powerful features in Uniswap V4 that allow hooks to:

1. **beforeSwapReturnDelta**: Partially or fully fulfill swaps from internal reserves (bypassing the pool)
2. **afterSwapReturnDelta**: Take fees or add bonuses to swap outputs

⚠️ **IMPORTANT**: This is a **conceptual demonstration** that tracks the logic without actually moving tokens. In production, return delta hooks require complex token settlement with the PoolManager.

## Does This Hook Actually Skip Uniswap's Swap?

### Current Implementation (Demonstration Mode)
**NO** - The Uniswap swap mechanism is **NOT skipped** in this version.

**Why?**
- We return `BeforeSwapDeltaLibrary.ZERO_DELTA` (no delta)
- This means we're not actually consuming the user's input or providing output
- The swap proceeds through Uniswap's pool normally
- We just **track** what WOULD happen if we returned a non-zero delta

**What gets tracked:**
- `totalHookSwaps`: Counts swaps that COULD be fulfilled by hook reserves
- `totalPoolSwaps`: All swaps (since we're not actually bypassing anything)
- `internalReserves`: Conceptual reserves that get updated as if we filled the swap
- `totalFeesCollected`: What fees WOULD be if we took them from outputs

### Production Implementation (What WOULD Happen)

**YES** - The Uniswap swap mechanism **WOULD be skipped** (partially or fully).

**How it works:**

1. **User initiates swap**: "Sell 1 ETH for TOKEN"
   - `params.amountSpecified = -1 ETH` (negative = exact input)
   - `params.zeroForOne = true`

2. **Hook's beforeSwap executes**:
   - Hook has 100 TOKEN in reserves
   - Hook returns `BeforeSwapDelta(+1 ETH, -100 TOKEN)`
   - This means: "I'll take the 1 ETH and give 100 TOKEN"

3. **PoolManager processes the delta**:
   - Calculates: `amountToSwap = -1 ETH + 1 ETH = 0`
   - Since `amountToSwap = 0`, the core swap logic is **completely skipped** (NoOp)
   - The pool's liquidity and price remain unchanged!

4. **Token settlement** (critical!):
   ```solidity
   inputCurrency.settle(poolManager, user, 1 ETH, false);  // Take user's ETH
   outputCurrency.take(poolManager, user, 100 TOKEN, false); // Give user TOKEN
   ```

5. **User receives**: 100 TOKEN without affecting Uniswap's pool

**The Power**: The hook acts as an internal order book or liquidity source that can fill orders at custom prices WITHOUT impacting the Uniswap pool's state or charging pool fees!

## Why Demonstrate This Way?

Token settlement with PoolManager requires:
- Understanding the unlock/lock mechanism
- Proper accounting of deltas
- Handling claims vs direct settlement
- Complex error handling for `CurrencyNotSettled`

By demonstrating the LOGIC without actual settlement, you can learn:
- When to use positive vs negative deltas
- How to calculate specified vs unspecified amounts
- What the impact on `amountToSwap` would be
- How partial vs full fulfillment works

Once you understand these concepts, implementing actual token settlement is the final step!

## Key Concepts

### BeforeSwapDelta

- Format: `(amountSpecified, amountUnspecified)`
- **Positive delta**: Hook takes/is owed currency from user
- **Negative delta**: Hook gives/owes currency to user
- By returning a positive specified delta and negative unspecified delta, the hook "consumes" the swap input and "provides" the output
- This reduces `amountToSwap`, potentially to zero (NoOp - bypassing pool entirely!)

### AfterSwapReturnDelta

- Format: `int128 hookDeltaUnspecified`
- **Positive value**: Hook takes from output (reduces user's received amount - fee)
- **Negative value**: Hook adds to output (increases user's received amount - bonus)

## What This Hook Does

1. **Tracks Internal Reserves**: Simulates having token reserves that could fulfill swaps
2. **Monitors Swap Routing**: Counts how many swaps would be fulfilled by hook vs Uniswap pool
3. **Calculates Fees**: Tracks what a 1% fee on outputs would be

## Running Tests

```bash
forge test --match-contract TestInternalSwapPoolHook -vv
```

### Test Cases

- `test_swapWithoutInternalReserves`: Swap when hook has no reserves - uses Uniswap pool
- `test_internalReservesTrackingConcept`: Demonstrates beforeSwapReturnDelta logic
- `test_feeTrackingConcept`: Demonstrates afterSwapReturnDelta logic
- `test_partialInternalFulfillment`: Shows fallback to pool with insufficient reserves

## For Production Use

To actually implement return delta hooks, you need to:

### beforeSwapReturnDelta
```solidity
// After returning BeforeSwapDelta, settle tokens:
inputCurrency.settle(poolManager, user, inputAmount, false);
outputCurrency.take(poolManager, user, outputAmount, false);
```

### afterSwapReturnDelta
```solidity
// After returning hookDeltaUnspecified, take/settle the delta:
unspecifiedCurrency.take(poolManager, address(this), feeAmount, false);
```

Token settlement must happen within the PoolManager's lock context, typically using the unlock callback pattern.

## Learn More

- Check `InternalSwapPoolHookEditing` for a template with TODO comments
- See the extensive code comments explaining each concept
- Modify and experiment to understand how return deltas work!
