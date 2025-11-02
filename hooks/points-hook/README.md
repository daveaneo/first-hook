# Points Hook

A Uniswap v4 hook that implements a rewards system by minting ERC-1155 point tokens to users who swap ETH for tokens.

## Overview

This hook demonstrates how to:
- Implement the `afterSwap` hook to reward users after they complete swaps
- Use ERC-1155 tokens to track points per pool
- Decode `hookData` to determine which user should receive rewards
- Work with ETH-TOKEN pools specifically

## How It Works

1. **Swap Detection**: The hook activates only on ETH-TOKEN pools (where currency0 is ETH)
2. **Direction Check**: Points are only minted when users buy TOKEN with ETH (`zeroForOne` swaps)
3. **Points Calculation**: Users receive points equal to 20% of the ETH they spend
4. **Point Minting**: Points are minted as ERC-1155 tokens, with the pool ID as the token ID

## Key Features

- **ERC-1155 Integration**: Each pool has its own token ID (derived from pool ID)
- **Flexible Rewards**: Points can be used for governance, airdrops, or other incentive mechanisms
- **Hook Data Usage**: Demonstrates how to pass user address through `hookData` parameter
- **Selective Activation**: Only works on ETH pools and only for specific swap directions

## Code Highlights

### Hook Permissions
```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        // ... all false except:
        afterSwap: true,
        // ...
    });
}
```

Only `afterSwap` is enabled, making this a simple, focused hook.

### Points Assignment Logic
```solidity
uint256 ethSpendAmount = uint256(int256(-delta.amount0()));
uint256 pointsForSwap = ethSpendAmount / 5;  // 20% of ETH spent
_assignPoints(key.toId(), hookData, pointsForSwap);
```

Points are calculated as 20% of the ETH amount spent (1/5 = 20%).

## Testing

Run the tests for this hook:

```bash
forge test --match-path hooks/points-hook/test/PointsHook.t.sol -vv
```

## Learning Objectives

This hook teaches:
1. How to implement the `afterSwap` hook function
2. How to work with `BalanceDelta` to calculate swap amounts
3. How to use `hookData` to pass additional information to hooks
4. How to combine hook functionality with ERC-1155 tokens
5. How to restrict hook behavior to specific pool types (ETH pools)
6. How to handle swap direction (`zeroForOne` vs `oneForZero`)

## Related Files

- Source: `src/PointsHook.sol`
- Tests: `test/PointsHook.t.sol`

## Next Steps

After understanding this hook, check out:
- **points-hook-broken**: Learn what happens when hook permissions don't match implementation
- **flash-loan-hook**: A more complex hook with multiple lifecycle hooks enabled
