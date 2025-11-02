# Points Hook (Broken) - Educational Example

An **intentionally broken** version of the Points Hook to demonstrate what happens when hook permissions don't match the actual implementation.

## The Bug

This hook declares `beforeSwap: true` in its permissions but **does not implement** the `_beforeSwap` function.

### Hook Permissions (Declared)
```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        // ...
        beforeSwap: true,   // ❌ DECLARED BUT NOT IMPLEMENTED
        afterSwap: true,    // ✅ Correctly implemented
        // ...
    });
}
```

### Implementation
The contract only implements:
- ✅ `_afterSwap` function (correctly matches permission)
- ❌ No `_beforeSwap` function (missing!)

## What Happens

When you try to swap on a pool with this hook:

1. Pool Manager sees `beforeSwap: true` in permissions
2. Pool Manager tries to call the `beforeSwap` hook
3. The hook doesn't implement `_beforeSwap`
4. **Transaction reverts with `HookNotImplemented` error**

## Educational Value

This example teaches:
1. **Critical importance** of matching permissions to implementation
2. How to debug hook permission errors
3. The difference between declaring a hook and implementing it
4. What error messages to expect when hooks are misconfigured

## Expected Behavior

### Test Results
```
Swaps will fail with:
- Error: HookNotImplemented()
- Reason: beforeSwap permission is true but _beforeSwap is not implemented
```

## How to Fix

To fix this hook, you have two options:

**Option 1**: Remove the permission (recommended for this use case)
```solidity
beforeSwap: false,  // Don't need this for points system
afterSwap: true,
```

**Option 2**: Implement the missing function
```solidity
function _beforeSwap(
    address,
    PoolKey calldata,
    SwapParams calldata,
    bytes calldata
) internal override returns (bytes4, BeforeSwapDelta, uint24) {
    return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}
```

## Testing

Run the tests to see the failure:

```bash
forge test --match-path hooks/points-hook-broken/test/PointsHookBroken.t.sol -vv
```

The tests verify that swaps fail with `HookNotImplemented` error.

## Key Lesson

**Hook permissions must exactly match your implementation!**

If you declare a hook permission as `true`, you **must** implement the corresponding function:
- `beforeInitialize: true` → must implement `_beforeInitialize`
- `beforeSwap: true` → must implement `_beforeSwap`
- `afterSwap: true` → must implement `_afterSwap`
- etc.

## Related Files

- Source: `src/PointsHookBroken.sol`
- Tests: `test/PointsHookBroken.t.sol`

## Comparison

Compare this with:
- **points-hook**: The working version with correct permissions
- See the difference between `beforeSwap: true` (broken) vs `beforeSwap: false` (working)

## Common Mistake

This is a common mistake when:
1. Copying hook code and forgetting to update permissions
2. Planning to implement a hook function "later" but deploying early
3. Not understanding that permissions are a strict contract with the Pool Manager

**Always ensure your `getHookPermissions()` accurately reflects your implemented functions!**
