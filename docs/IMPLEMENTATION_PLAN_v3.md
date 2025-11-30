# Private Trading Hook - Implementation Plan v3

## Core Purpose

**Build a fully encrypted AMM where trade direction and amounts are never revealed on-chain, with all sensitive operations executing synchronously in a single transaction using FHE.**

### Why This Matters

Current DEXs expose every trade to the mempool, enabling:
- **Front-running:** Bots see your trade and jump ahead
- **Sandwich attacks:** Bots surround your trade to extract value
- **Order flow analysis:** Observers track trading patterns and positions

### What We're Building

A private trading system where:
- **All swaps are encrypted** - Direction and amount hidden from observers
- **All limit orders are encrypted** - Only trigger price is public; direction and size remain private
- **Execution is synchronous** - No multi-TX flows that create MEV windows
- **Slippage protection is encrypted** - Even your risk tolerance is private

### Improvements Over Iceberg Hook (v2)

| Problem in v2 | Solution in v3 |
|---------------|----------------|
| Direction exposed after trigger (stored in public `orderInfo` mapping) | Direction never decrypted; all math in FHE |
| Async execution created MEV window between trigger and execute | Single-TX execution via encrypted AMM |
| Probe attacks possible (buy→sell in same TX to detect orders) | Direction lock zeros out opposite-direction swaps |
| Gas side-channel leaked direction (~65k gas difference) | Branchless FHE operations with constant gas |
| Relied on Uniswap's plaintext `poolManager.swap()` | Custom encrypted AMM with FHE swap math |

### Security Hardening

This design protects against:
1. **Probe attacks** - Direction lock prevents buy→sell probing in same TX
2. **Direction inference** - All swap math uses encrypted values; no plaintext direction storage
3. **Timing attacks** - Synchronous execution eliminates multi-TX observation windows

This enables truly private on-chain trading where observers cannot determine what you're buying, selling, or how much.

---

## Major Architecture Change from v2

**v2 Problem:** Used Uniswap's `poolManager.swap()` directly, which requires plaintext direction and amount. This forced async execution (decrypt → wait → execute).

**v3 Solution:** Uniswap v4 hook that **completely overrides swap logic** with our encrypted AMM math. We intercept swaps in `beforeSwap()`, run FHE calculations, and return deltas that bypass Uniswap's native AMM. Fully sync execution.

### Why a Hook (Not Standalone)

| Benefit | Description |
|---------|-------------|
| **Routing** | Aggregators (1inch, Paraswap) route through our pool automatically |
| **Composability** | Works with existing Uniswap v4 infrastructure |
| **Liquidity discovery** | Shows up in Uniswap's pool registry |
| **Hybrid tokens** | Regular ERC20 pairs work - privacy is in the swap logic |
| **Familiar UX** | Users interact via standard Uniswap interface |

---

## FHE Operations Reference

### SYNC (same transaction)
| Operation | Returns | Use |
|-----------|---------|-----|
| `FHE.add(a, b)` | `euint128` | Encrypted arithmetic |
| `FHE.sub(a, b)` | `euint128` | Encrypted arithmetic |
| `FHE.mul(a, b)` | `euint128` | Encrypted arithmetic |
| `FHE.div(a, b)` | `euint128` | Encrypted arithmetic |
| `FHE.select(cond, a, b)` | `euint128` | **Branching on encrypted bool** |
| `FHE.eq(a, b)` | `ebool` | Encrypted comparison |
| `FHE.gte(a, b)` | `ebool` | Encrypted comparison |
| `FHE.asEuint128(plain)` | `euint128` | **Encrypt plaintext (sync!)** |
| `FHE.asEbool(plain)` | `ebool` | **Encrypt plaintext (sync!)** |
| `transferFromEncrypted()` | - | Move encrypted balances |

### ASYNC (requires separate TX)
| Operation | Why |
|-----------|-----|
| `FHE.decrypt()` | Sends to Threshold Decryption Network |
| `requestUnwrap()` | Must poll with `getUnwrapResultSafe()` |

### Key Insight
- **Plaintext → Encrypted: SYNC** (just wrapping a value)
- **Encrypted → Plaintext: ASYNC** (requires decryption network)

---

## Architecture Overview

### Uniswap v4 Hook with Encrypted AMM Override

```
┌─────────────────────────────────────────────────────────────────┐
│                      Uniswap v4 PoolManager                      │
│                      (standard swap interface)                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   User calls: poolManager.swap(key, params, ...)                 │
│                         │                                        │
│                         ▼                                        │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │              PrivateTradeHook (our contract)             │   │
│   │                                                          │   │
│   │   beforeSwap() ──► Intercept swap                        │   │
│   │                    Encrypt params if plaintext           │   │
│   │                    Run FHE swap math                     │   │
│   │                    Return BeforeSwapDelta                │   │
│   │                    (bypasses Uniswap's AMM)              │   │
│   │                                                          │   │
│   │   afterSwap()  ──► Check limit order triggers            │   │
│   │                    Execute triggered orders              │   │
│   │                                                          │   │
│   │   Source of Truth: encReserve0, encReserve1 (encrypted)  │   │
│   │   Display Cache:   reserve0, reserve1 (eventually sync)  │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│   Uniswap's native swap math: BYPASSED via BeforeSwapDelta      │
│   Our FHE swap math: EXECUTED in beforeSwap()                   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Token Support

| Pool Type | Token0 | Token1 | What's Private |
|-----------|--------|--------|----------------|
| **Regular ERC20 pair** | ERC20 | ERC20 | Swap direction, amounts, limit orders |
| **Hybrid pair** | ERC20 | fheERC20 | Same + one token's balances |
| **Full FHE pair** | fheERC20 | fheERC20 | Everything including deposits |

**Key insight:** Privacy comes from the hook's encrypted swap logic, not the token type. Even regular ERC20 pairs get private swaps.

---

## Data Visibility

| Data | Visibility | Rationale |
|------|------------|-----------|
| encReserve0, encReserve1 | **Encrypted** | Source of truth for all swap math |
| reserve0, reserve1 | **Public (cache)** | Eventually consistent display values for UX |
| currentPrice | **Public (cache)** | Derived from public reserves, may be stale |
| user balances | **Encrypted** | Per-user privacy |
| swap direction | **Encrypted** | Always encrypted, even for "public" swaps |
| swap amount | **Encrypted** | Always encrypted, even for "public" swaps |
| limit order trigger tick | **Public** | Needed for trigger detection |
| limit order direction | **Encrypted** | Hidden until execution |
| limit order amount | **Encrypted** | Hidden until execution |

---

## Swap Flows

### How Swaps Work (Hook Integration)

Users call Uniswap's standard `poolManager.swap()`. Our hook intercepts and handles everything:

```solidity
// User's perspective - standard Uniswap swap call
poolManager.swap(
    poolKey,
    IPoolManager.SwapParams({
        zeroForOne: true,
        amountSpecified: 1000e18,
        sqrtPriceLimitX96: ...
    }),
    hookData  // Can include encrypted params for full privacy
);
```

### beforeSwap Hook (Where the Magic Happens)

```solidity
function beforeSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata hookData
) external override returns (bytes4, BeforeSwapDelta, uint24) {

    // 1. Extract or encrypt swap parameters
    (ebool encDir, euint128 encAmt, euint128 encMinOutput) = _extractOrEncryptParams(params, hookData);

    // 2. Direction lock (encrypted - see Direction Lock section)
    _enforceDirectionLockEncrypted(encDir);

    // 3. Execute encrypted swap math against ENCRYPTED reserves
    euint128 actualOutput = _executeSwapMath(encDir, encAmt);

    // 4. Slippage check (encrypted)
    ebool slippageOk = FHE.gte(actualOutput, encMinOutput);
    euint128 finalOutput = FHE.select(slippageOk, actualOutput, FHE.asEuint128(0));

    // 5. Handle token transfers via PoolManager
    //    Return BeforeSwapDelta to bypass Uniswap's AMM math
    BeforeSwapDelta delta = _calculateDelta(encDir, encAmt, finalOutput);

    // 6. Request async reserve sync (non-blocking)
    _requestReserveSync();

    return (BaseHook.beforeSwap.selector, delta, 0);
}
```

### afterSwap Hook (Limit Order Triggers)

```solidity
function afterSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    BalanceDelta delta,
    bytes calldata hookData
) external override returns (bytes4, int128) {

    // Check for triggered limit orders based on price movement
    _checkAndExecuteLimitOrders(sender, key);

    return (BaseHook.afterSwap.selector, 0);
}
```

### Private Swap (Full Encryption via hookData)

For maximum privacy, users can pass encrypted parameters in `hookData`:

```solidity
// User encrypts params client-side, passes in hookData
bytes memory hookData = abi.encode(
    encryptedDirection,   // InEbool
    encryptedAmount,      // InEuint128
    encryptedMinOutput    // InEuint128
);

poolManager.swap(poolKey, params, hookData);
```

### Standard Swap (Plaintext - Still Private Execution)

Even with plaintext params, the hook encrypts them before processing:

```solidity
function _extractOrEncryptParams(
    IPoolManager.SwapParams calldata params,
    bytes calldata hookData
) internal returns (ebool, euint128, euint128) {
    if (hookData.length > 0) {
        // Fully encrypted params from hookData
        return abi.decode(hookData, (InEbool, InEuint128, InEuint128));
    } else {
        // Encrypt plaintext params
        return (
            FHE.asEbool(params.zeroForOne),
            FHE.asEuint128(uint128(params.amountSpecified)),
            FHE.asEuint128(0)  // No slippage protection for plaintext
        );
    }
}
```

### Core Swap Math (Encrypted)

```solidity
function _executeSwapMath(ebool direction, euint128 amountIn) internal returns (euint128 amountOut) {
    // x * y = k formula, all encrypted
    // Uses ENCRYPTED reserves as source of truth

    // Select reserves based on direction
    euint128 reserveIn = FHE.select(direction, encReserve0, encReserve1);
    euint128 reserveOut = FHE.select(direction, encReserve1, encReserve0);

    // amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
    euint128 numerator = FHE.mul(amountIn, reserveOut);
    euint128 denominator = FHE.add(reserveIn, amountIn);
    amountOut = FHE.div(numerator, denominator);

    // Update ENCRYPTED reserves (source of truth)
    euint128 newReserveIn = FHE.add(reserveIn, amountIn);
    euint128 newReserveOut = FHE.sub(reserveOut, amountOut);

    // Apply based on direction (branchless)
    encReserve0 = FHE.select(direction, newReserveIn, newReserveOut);
    encReserve1 = FHE.select(direction, newReserveOut, newReserveIn);
}
```

---

## Reserve Consistency Model

### The Problem

After any swap, the encrypted reserves (`encReserve0`, `encReserve1`) are updated immediately. But public reserves (`reserve0`, `reserve1`) cannot be updated sync because we'd need to decrypt the new values.

### Solution: Eventual Consistency

**Public reserves are a display cache, not the source of truth.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    Reserve Architecture                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   encReserve0, encReserve1    ←── Source of truth (encrypted)    │
│         │                                                        │
│         │ async decrypt                                          │
│         ▼                                                        │
│   reserve0, reserve1          ←── Display cache (public, stale)  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Behavior

1. **All swap math uses encrypted reserves** - always accurate
2. **Public reserves may lag** - updated when async decrypt completes
3. **No trades blocked** - swaps always attempt, slippage protects users
4. **Stale prices = slippage failures** - not silent wrong execution

### Implementation

```solidity
// Encrypted reserves (source of truth)
euint128 internal encReserve0;
euint128 internal encReserve1;

// Public reserves (display cache, eventually consistent)
uint256 public reserve0;
uint256 public reserve1;

// Pending decrypt handles
euint128 internal pendingReserve0;
euint128 internal pendingReserve1;

function _requestReserveSync() internal {
    // Request async decryption of current encrypted reserves
    pendingReserve0 = encReserve0;
    pendingReserve1 = encReserve1;
    FHE.decrypt(pendingReserve0);
    FHE.decrypt(pendingReserve1);
}

function getReserves() public returns (uint256 r0, uint256 r1) {
    // Try to sync before returning (lazy update)
    _trySyncReserves();
    return (reserve0, reserve1);
}

function _trySyncReserves() internal {
    // Check if pending decrypts are ready
    (uint256 val0, bool ready0) = FHE.getDecryptResultSafe(pendingReserve0);
    (uint256 val1, bool ready1) = FHE.getDecryptResultSafe(pendingReserve1);

    if (ready0 && ready1) {
        reserve0 = val0;
        reserve1 = val1;
    }
    // If not ready, public reserves stay stale - that's fine
}
```

### User Experience

| Scenario | What Happens |
|----------|--------------|
| User queries price | Gets `reserve0/reserve1` (may be slightly stale) |
| User submits swap with tight slippage | May fail if real price moved significantly |
| User submits swap with reasonable slippage | Succeeds, gets accurate output from encrypted math |
| Reserves sync after decrypt | Next `getReserves()` returns fresh values |

### Why This Works

- **Accurate execution:** All swaps use encrypted reserves (truth)
- **Slippage protection:** Users set tolerance, FHE checks it
- **No blocking:** Trades never rejected due to sync state
- **Self-correcting:** Prices eventually catch up
- **Familiar UX:** Feels like normal DEX slippage (someone traded before you)

### Trade-offs Accepted

- Routers/aggregators see stale prices temporarily
- Users may experience more slippage failures during high activity
- No griefing vector - stale prices hurt no one, just cause failed TXs

---

## Limit Orders

### Placement (TX 1)

```solidity
function placeOrder(
    int24 triggerTick,
    InEbool calldata direction,
    InEuint128 calldata amount,
    InEuint128 calldata minOutput
) external payable {
    require(msg.value >= PROTOCOL_FEE, "Insufficient fee");

    ebool encDir = FHE.asEbool(direction);
    euint128 encAmt = FHE.asEuint128(amount);
    euint128 encMinOutput = FHE.asEuint128(minOutput);

    // Store order
    orders[nextOrderId] = Order({
        owner: msg.sender,
        triggerTick: triggerTick,
        direction: encDir,
        amount: encAmt,
        minOutput: encMinOutput,
        active: true
    });

    ordersByTick[triggerTick].push(nextOrderId);
    nextOrderId++;

    // Transfer encrypted tokens in (branchless)
    _transferTokensIn(encDir, encAmt);
}
```

### Trigger + Execute (TX 2 - Same Transaction as Swap)

When any swap crosses a limit order's trigger tick:

```solidity
function _checkAndExecuteLimitOrders(address executor) internal {
    // Get price movement from this swap
    int24 tickBefore = _tickFromPrice(priceBefore);
    int24 tickAfter = _tickFromPrice(priceAfter);

    // Find all orders with triggers between tickBefore and tickAfter
    int24 lower = tickBefore < tickAfter ? tickBefore : tickAfter;
    int24 upper = tickBefore < tickAfter ? tickAfter : tickBefore;

    euint128 totalExecutorReward = FHE.asEuint128(0);

    for (int24 tick = lower; tick <= upper; tick++) {
        uint256[] storage orderIds = ordersByTick[tick];

        for (uint i = 0; i < orderIds.length; i++) {
            Order storage order = orders[orderIds[i]];
            if (!order.active) continue;

            // Execute order (encrypted math)
            euint128 orderOutput = _executeSwapMath(order.direction, order.amount);

            // Slippage check
            ebool slippageOk = FHE.gte(orderOutput, order.minOutput);
            euint128 finalOutput = FHE.select(slippageOk, orderOutput, FHE.asEuint128(0));

            // Calculate executor reward (1% of output)
            euint128 reward = FHE.div(finalOutput, FHE.asEuint128(100));
            euint128 ownerReceives = FHE.sub(finalOutput, reward);

            // Credit balances
            userBalance[order.owner] = FHE.add(userBalance[order.owner], ownerReceives);
            totalExecutorReward = FHE.add(totalExecutorReward, reward);

            order.active = false;
        }
    }

    // Credit executor's balance with total rewards
    userBalance[executor] = FHE.add(userBalance[executor], totalExecutorReward);
}
```

**Key Points:**
- No separate "execute" call
- Trigger = Execute in same TX
- Executor (whoever swapped) gets reward added to their output

---

## Deposit & Withdrawal (Liquidity Management)

Liquidity is managed through Uniswap v4's `modifyLiquidity` with our hook handling the encrypted accounting.

### Adding Liquidity

```solidity
function beforeAddLiquidity(
    address sender,
    PoolKey calldata key,
    IPoolManager.ModifyLiquidityParams calldata params,
    bytes calldata hookData
) external override returns (bytes4) {
    // Get amounts being added
    uint256 amount0 = uint256(params.liquidityDelta);  // Simplified
    uint256 amount1 = uint256(params.liquidityDelta);

    // Update encrypted reserves (source of truth)
    encReserve0 = FHE.add(encReserve0, FHE.asEuint128(amount0));
    encReserve1 = FHE.add(encReserve1, FHE.asEuint128(amount1));

    // Update display cache (known plaintext amounts)
    reserve0 += amount0;
    reserve1 += amount1;

    // Track LP position (encrypted)
    lpBalance[sender] = FHE.add(lpBalance[sender], FHE.asEuint128(params.liquidityDelta));

    return BaseHook.beforeAddLiquidity.selector;
}
```

### Removing Liquidity

```solidity
function beforeRemoveLiquidity(
    address sender,
    PoolKey calldata key,
    IPoolManager.ModifyLiquidityParams calldata params,
    bytes calldata hookData
) external override returns (bytes4) {
    uint256 amount0 = uint256(-params.liquidityDelta);  // Simplified
    uint256 amount1 = uint256(-params.liquidityDelta);

    // Update encrypted reserves
    encReserve0 = FHE.sub(encReserve0, FHE.asEuint128(amount0));
    encReserve1 = FHE.sub(encReserve1, FHE.asEuint128(amount1));

    // Update display cache
    reserve0 -= amount0;
    reserve1 -= amount1;

    // Update LP position
    lpBalance[sender] = FHE.sub(lpBalance[sender], FHE.asEuint128(-params.liquidityDelta));

    // Request async sync (removal amount known, but sync for consistency)
    _requestReserveSync();

    return BaseHook.beforeRemoveLiquidity.selector;
}
```

### Direct Deposit/Withdraw (For fheERC20 Tokens)

If tokens are fheERC20, users can also deposit/withdraw with full encryption:

```solidity
function depositEncrypted(bool isToken0, InEuint128 calldata amount) external {
    euint128 encAmount = FHE.asEuint128(amount);

    if (isToken0) {
        fheToken0.transferFromEncrypted(msg.sender, address(this), encAmount);
        encReserve0 = FHE.add(encReserve0, encAmount);
    } else {
        fheToken1.transferFromEncrypted(msg.sender, address(this), encAmount);
        encReserve1 = FHE.add(encReserve1, encAmount);
    }

    lpBalance[msg.sender] = FHE.add(lpBalance[msg.sender], encAmount);
    _requestReserveSync();  // Async update display cache
}

function withdrawEncrypted(bool isToken0, InEuint128 calldata amount) external {
    euint128 encAmount = FHE.asEuint128(amount);

    if (isToken0) {
        encReserve0 = FHE.sub(encReserve0, encAmount);
        fheToken0.transferFromEncrypted(address(this), msg.sender, encAmount);
    } else {
        encReserve1 = FHE.sub(encReserve1, encAmount);
        fheToken1.transferFromEncrypted(address(this), msg.sender, encAmount);
    }

    lpBalance[msg.sender] = FHE.sub(lpBalance[msg.sender], encAmount);
    _requestReserveSync();
}
```

---

## Direction Lock

Prevents probe attacks (buy→sell in same TX to detect hidden orders).

```solidity
bytes32 constant DIRECTION_SLOT = keccak256("direction.lock");

function _enforceDirectionLock(bool zeroForOne) internal {
    uint256 locked;
    assembly { locked := tload(DIRECTION_SLOT) }

    uint256 dir = zeroForOne ? 1 : 2;
    require(locked == 0 || locked == dir, "No direction reversal");

    assembly { tstore(DIRECTION_SLOT, dir) }
}
```

**Behavior:**
- Multiple same-direction swaps: ✅ Allowed
- Opposite direction in same TX: ❌ Blocked

### Direction Lock for Encrypted Swaps

Since all swaps use encrypted direction, we can't read the plaintext to enforce the lock directly. Options:

**Option A: Lock on first swap - no more swaps this TX**
```solidity
// First swap locks the pool for this TX - no subsequent swaps allowed
assembly { tstore(DIRECTION_SLOT, 1) }  // 1 = locked
```
Simple but restrictive - prevents legitimate same-direction swaps.

**Option B: Store encrypted direction, compare subsequent swaps**
```solidity
// First swap: store encrypted direction
// Subsequent swaps: compare and zero out if different direction
ebool sameDirection = FHE.eq(storedEncDirection, newDirection);
amount = FHE.select(sameDirection, amount, FHE.asEuint128(0));
```
Allows same-direction swaps, blocks opposite direction via zeroed output.

**Decision:** Option B - Use `FHE.select()` to zero out if direction differs.

```solidity
// Storage for first swap's direction (persists within TX via transient-like pattern)
ebool internal firstSwapDirection;
bool internal hasSwappedThisTx;

function _enforceDirectionLockEncrypted(ebool direction) internal {
    if (!hasSwappedThisTx) {
        // First swap - store direction
        firstSwapDirection = direction;
        hasSwappedThisTx = true;
    }
    // Subsequent swaps - will zero out amount if direction differs
    // (handled in swap() via FHE.select)
}
```

**Note:** `hasSwappedThisTx` must reset between transactions. Use transient storage (EIP-1153) or rely on external reset mechanism.

---

## Executor Reward Mechanism

Executor reward is **added to executor's output**, not sent separately:

```solidity
// In _checkAndExecuteLimitOrders:
euint128 reward = FHE.div(orderOutput, FHE.asEuint128(100));  // 1%
euint128 ownerReceives = FHE.sub(orderOutput, reward);

// Order owner gets output minus reward
userBalance[order.owner] = FHE.add(userBalance[order.owner], ownerReceives);

// Executor gets reward added to their swap output
userBalance[executor] = FHE.add(userBalance[executor], reward);
```

This avoids relying on `msg.sender` or `tx.origin` for reward recipient.

---

## Slippage Protection

### Regular Swaps
All swaps use encrypted `minOutput`, checked with `FHE.gte()` + `FHE.select()`:
- If slippage OK: User receives `actualOutput`
- If slippage exceeded: Output zeroed, user keeps input (encrypted refund)

The `swapPlaintext()` wrapper encrypts the user's plaintext `minOutput` before calling `swap()`.

### Limit Orders
- Encrypted `minOutput` stored with order
- Checked at execution time
- **If slippage exceeded:** Order stays active, tries again on next price cross

---

## LP Mechanics

### Deposit
- **Regular ERC20:** Transfer plaintext in → encrypt → add to both `encReserve` and `reserve` (cache)
- **fheERC20:** Transfer encrypted in → add to `encReserve` → request async sync for cache

### Withdraw
- User tracks balance via events (events emit encrypted handles, user decrypts off-chain)
- User calls `withdraw(amount)` with known amount
- **fheERC20:** Sync - transfer encrypted out, update `encReserve`, request async sync
- **Regular ERC20:** Async - requires decryption (2 TX: request + claim)

### Events for Balance Tracking
```solidity
event Deposit(address indexed user, euint128 amount);
event Swap(address indexed user, euint128 amountIn, euint128 amountOut);
event LimitOrderFilled(address indexed user, euint128 filledAmount);
event Withdraw(address indexed user, euint128 amount);
```

User reads events off-chain, decrypts to know their balance. No async on-chain call needed.

---

## Summary: Call Patterns

| Action | TX Count | Sync? | Notes |
|--------|----------|-------|-------|
| swap (encrypted) | 1 | ✅ | All swaps use this path |
| swapPlaintext | 1 | ✅ | Convenience wrapper |
| placeOrder | 1 | ✅ | |
| Order trigger + execute | 0 (piggybacks on swap) | ✅ | |
| Deposit (ERC20) | 1 | ✅ | |
| Deposit (fheERC20) | 1 | ✅ | |
| Withdraw (encrypted) | 1 | ✅ | |
| Withdraw (plaintext) | 2 (request + claim) | ❌ Async | |
| getReserves | 1 | ✅ | Lazy syncs if decrypt ready |
| Reserve sync | Background | ❌ Async | Non-blocking, eventual |

---

## Resolved Design Decisions

### Slippage Failure Behavior
**Decision:** Order stays active, tries again next time.

**Rationale:** Don't punish users for temporary bad liquidity. Order remains until filled or cancelled.

### Partial Fills
**Decision:** No partial fills in v3.

Orders execute completely or not at all. This simplifies the implementation:
- No `filled` tracking needed
- No complex slippage-per-fill logic
- Clean order state transitions (active → inactive)

```solidity
struct LimitOrder {
    address owner;
    int24 tick;              // Specific tick (public)
    ebool direction;         // Encrypted: sell token0 or token1
    euint128 amount;         // Encrypted: order size
    euint128 minOutput;      // Encrypted: slippage protection
    bool active;
}
```

**For large orders:** Users should split into multiple smaller orders at adjacent ticks.

---

## All Questions Resolved

All design decisions have been made. Ready for implementation.

---

## File Structure

```
src/
├── PrivateTradeHook.sol          # Main hook contract (extends BaseHook)
├── lib/
│   ├── DirectionLock.sol         # Transient storage direction lock
│   ├── SwapMath.sol              # FHE swap calculations
│   └── ReserveSync.sol           # Eventual consistency logic
├── interface/
│   └── IPrivateTradeHook.sol
test/
├── PrivateTradeHook.t.sol        # Main hook tests
├── security/
│   ├── ProbeAttack.t.sol         # Direction lock tests
│   └── PrivacyLeak.t.sol         # Ensure no direction/amount leaks
├── functional/
│   ├── Swap.t.sol                # Hook swap tests (via PoolManager)
│   ├── ReserveSync.t.sol         # Eventual consistency tests
│   ├── LimitOrders.t.sol
│   └── Liquidity.t.sol           # Add/remove liquidity tests
```

---

## Changes from v2

| Aspect | v2 | v3 |
|--------|----|----|
| Architecture | Hook that delegates to poolManager.swap() | **Hook that overrides swap logic entirely** |
| AMM Engine | Uniswap's native AMM | **Our FHE AMM via BeforeSwapDelta** |
| Token support | fheERC20 only | **Any ERC20 pair** (privacy from hook logic) |
| Swap interface | Custom functions | **Standard Uniswap swap()** (with optional hookData) |
| Execution | Async (decrypt required) | Fully sync |
| Reserves (truth) | Public | **Encrypted** (source of truth) |
| Reserves (display) | N/A | **Public cache** (eventually consistent) |
| Reserve sync | N/A | **Lazy on getReserves()** |
| Trade blocking | On stale reserves | **Never** (slippage protects) |
| Limit order execution | Separate TX after trigger | **Same TX as trigger (afterSwap)** |
| Executor reward | Sent to tx.origin | **Augments executor's output** |
| Routing/aggregators | Custom integration needed | **Automatic** (standard Uniswap interface) |

---

## Resolved Questions

### 1. Order Cancellation
**Decision:** Users can cancel limit orders via `cancelOrder(orderId)`.

```solidity
function cancelOrder(uint256 orderId) external {
    Order storage order = orders[orderId];
    require(order.owner == msg.sender, "Not owner");
    require(order.active, "Already inactive");

    order.active = false;

    // Return encrypted tokens to user balance (branchless)
    userBalanceToken0[msg.sender] = FHE.add(
        userBalanceToken0[msg.sender],
        FHE.select(order.direction, order.amount, FHE.asEuint128(0))
    );
    userBalanceToken1[msg.sender] = FHE.add(
        userBalanceToken1[msg.sender],
        FHE.select(order.direction, FHE.asEuint128(0), order.amount)
    );

    emit OrderCancelled(orderId, msg.sender);
}

function getActiveOrders(address user) external view returns (uint256[] memory);
```

### 2. Swap Fees
**Decision:** Standard swap fee (e.g., 0.3%) set at pool initialization.

```solidity
uint256 public immutable swapFeeBps;  // e.g., 30 = 0.3%

constructor(address _token0, address _token1, uint256 _swapFeeBps) {
    // ...
    swapFeeBps = _swapFeeBps;
}

function _executeSwapMath(...) internal {
    // Apply fee to amountIn before swap calculation
    euint128 feeAmount = FHE.div(FHE.mul(amountIn, FHE.asEuint128(swapFeeBps)), FHE.asEuint128(10000));
    euint128 amountInAfterFee = FHE.sub(amountIn, feeAmount);
    // ... rest of swap math using amountInAfterFee
}
```

### 3. Pool Initialization
**Decision:** Standard LP initialization - first depositor sets initial reserves.

Any user can add liquidity at any time. First deposit establishes the initial price ratio.

```solidity
function deposit(bool isToken0, uint256 amount) external {
    // First deposit initializes reserves
    // Subsequent deposits add to existing liquidity
    // ...
}
```

### 4. Tick Calculation for Limit Orders
**Decision:** Use public reserve cache for tick calculation.

The public reserves (`reserve0`, `reserve1`) provide the tick values for limit order triggering. Since these are eventually consistent, orders may trigger with slight delay after large encrypted swaps - this is acceptable as slippage protection handles any price difference.

```solidity
function _checkAndExecuteLimitOrders(address executor) internal {
    // Use public reserves for tick calculation
    int24 tickBefore = _tickFromReserves(reserve0Before, reserve1Before);
    int24 tickAfter = _tickFromReserves(reserve0, reserve1);
    // ... check orders between these ticks
}
```

**Rationale:** The slight delay in triggering is acceptable because:
- Orders have slippage protection
- This maintains sync execution
- Alternative (async decrypt) would defeat the core purpose

---

## Open Questions

### 5. Gas Limits on Tick Loops
If price moves many ticks in one swap, the loop could be expensive.

**Options to consider:**
- Add tick spacing (only check every N ticks)?
- Limit max ticks checked per swap?
- Accept gas cost as-is for now?

### 6. Partial Fills
**Decision:** Partial fills are NOT supported in v3.

Orders fill completely or not at all. This simplifies:
- No tracking of `filled` amount
- No complex slippage-per-fill logic
- Cleaner order state (active → inactive)

Large orders should be split into multiple smaller orders at adjacent ticks if needed.
