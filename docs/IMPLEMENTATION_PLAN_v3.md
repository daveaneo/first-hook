# Private Trading Hook - Implementation Plan v3

## Major Architecture Change from v2

**v2 Problem:** Used Uniswap's `poolManager.swap()` which requires plaintext direction and amount. This forced async execution (decrypt → wait → execute).

**v3 Solution:** Build our own encrypted AMM. All swap math in FHE. Fully sync execution.

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

### Unified Encrypted Swap Interface

```
┌─────────────────────────────────────────────────────────────────┐
│                    Encrypted AMM Pool                            │
│                                                                  │
│   Source of Truth: encReserve0, encReserve1 (encrypted)          │
│   Display Cache:   reserve0, reserve1 (public, eventually consistent) │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   swap(                                                          │
│     InEbool direction,                                           │
│     InEuint128 amount,                                           │
│     InEuint128 minOutput                                         │
│   )                                                              │
│                                                                  │
│   - ALL swaps go through encrypted path                          │
│   - "Public" swaps just encrypt plaintext inputs first           │
│   - All math uses encrypted reserves (source of truth)           │
│   - Slippage protection via FHE comparison                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Single interface, two entry points:**
- `swap()`: Direct encrypted inputs (full privacy)
- `swapPlaintext()`: Convenience wrapper that encrypts inputs, then calls `swap()`

**All swaps use the same encrypted reserves and same swap logic.**

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

### Unified Swap (Single TX, Sync)

```solidity
function swap(
    InEbool calldata direction,
    InEuint128 calldata amount,
    InEuint128 calldata minOutput
) external {
    ebool encDir = FHE.asEbool(direction);
    euint128 encAmt = FHE.asEuint128(amount);
    euint128 encMinOutput = FHE.asEuint128(minOutput);

    // 1. Direction lock (encrypted - see Direction Lock section)
    _enforceDirectionLockEncrypted(encDir);

    // 2. Execute encrypted swap math against ENCRYPTED reserves
    euint128 actualOutput = _executeSwapMath(encDir, encAmt);

    // 3. Slippage check (encrypted)
    ebool slippageOk = FHE.gte(actualOutput, encMinOutput);
    euint128 finalOutput = FHE.select(slippageOk, actualOutput, FHE.asEuint128(0));

    // 4. Transfer encrypted tokens
    _transferTokensEncrypted(encDir, encAmt, finalOutput);

    // 5. Credit user's encrypted balance
    userBalance[msg.sender] = FHE.add(userBalance[msg.sender], finalOutput);

    // 6. Request async reserve sync (non-blocking)
    _requestReserveSync();

    // 7. Check for triggered limit orders, execute them
    _checkAndExecuteLimitOrders(msg.sender);
}
```

### Plaintext Convenience Wrapper

```solidity
function swapPlaintext(
    bool direction,
    uint256 amount,
    uint256 minOutput
) external {
    // Encrypt inputs and call unified swap
    InEbool memory encDir = _toInEbool(direction);
    InEuint128 memory encAmt = _toInEuint128(amount);
    InEuint128 memory encMinOutput = _toInEuint128(minOutput);

    swap(encDir, encAmt, encMinOutput);
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

## Deposit & Withdrawal

### Deposit

**Normal ERC20:**
```solidity
function deposit(bool isToken0, uint256 amount) external {
    IERC20 token = isToken0 ? token0 : token1;
    token.transferFrom(msg.sender, address(this), amount);

    euint128 encAmount = FHE.asEuint128(amount);

    if (isToken0) {
        userBalanceToken0[msg.sender] = FHE.add(userBalanceToken0[msg.sender], encAmount);
        reserve0 += amount;
    } else {
        userBalanceToken1[msg.sender] = FHE.add(userBalanceToken1[msg.sender], encAmount);
        reserve1 += amount;
    }
}
```
✅ Sync (plaintext → encrypted is sync)

**fheERC20:**
```solidity
function depositEncrypted(bool isToken0, InEuint128 calldata amount) external {
    euint128 encAmount = FHE.asEuint128(amount);
    IFHERC20 token = isToken0 ? fheToken0 : fheToken1;
    token.transferFromEncrypted(msg.sender, address(this), encAmount);

    if (isToken0) {
        userBalanceToken0[msg.sender] = FHE.add(userBalanceToken0[msg.sender], encAmount);
    } else {
        userBalanceToken1[msg.sender] = FHE.add(userBalanceToken1[msg.sender], encAmount);
    }
}
```
✅ Sync

### Withdrawal

**swapPublic users:**
- Contract calculates output from public reserves
- Transfers plaintext tokens immediately
- ✅ Sync

**swapPrivate users:**
- Receive encrypted balance
- Withdraw as encrypted tokens via `transferFromEncrypted`
- Can optionally confirm/decrypt later (async, their choice, separate TX)
- ✅ Sync for our contract

```solidity
function withdrawEncrypted(bool isToken0, InEuint128 calldata amount) external {
    euint128 encAmount = FHE.asEuint128(amount);

    if (isToken0) {
        userBalanceToken0[msg.sender] = FHE.sub(userBalanceToken0[msg.sender], encAmount);
        fheToken0.transferFromEncrypted(address(this), msg.sender, encAmount);
    } else {
        userBalanceToken1[msg.sender] = FHE.sub(userBalanceToken1[msg.sender], encAmount);
        fheToken1.transferFromEncrypted(address(this), msg.sender, encAmount);
    }
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

**Applies to both `swapPublic` and `swapPrivate`.**

### Direction Lock for Encrypted Direction

For `swapPrivate`, we don't know the plaintext direction. Options:

**Option A: Lock both directions on first private swap**
```solidity
// First private swap locks "private mode" - no more swaps this TX
assembly { tstore(DIRECTION_SLOT, 3) }  // 3 = locked for private
```

**Option B: Use encrypted comparison with stored direction**
```solidity
// Store encrypted direction, compare subsequent swaps
ebool sameDirection = FHE.eq(storedDirection, newDirection);
euint128 zero = FHE.asEuint128(0);
amount = FHE.select(sameDirection, amount, zero);  // Zero out if different
```

**Decision:** Option B - Use `FHE.select()` to zero out if direction differs.

```solidity
// On first swap, store direction in transient storage
// On subsequent swaps, compare and zero out if different
ebool sameDirection = FHE.eq(storedDirection, newDirection);
amount = FHE.select(sameDirection, amount, ZERO);  // Zero out if different direction
```

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
- `swapPublic`: Plaintext `minOutput`, checked with `require()`
- `swapPrivate`: Encrypted `minOutput`, checked with `FHE.gte()` + `FHE.select()`
  - If slippage exceeded, output is zeroed (user keeps input via encrypted refund)

### Limit Orders
- Encrypted `minOutput` stored with order
- Checked at execution time
- **If slippage exceeded:** Order stays active, tries again on next price cross

---

## LP Mechanics

### Deposit
- **Regular ERC20:** Transfer plaintext in → encrypt → add to reserves
- **fheERC20:** Transfer encrypted in → add to reserves

### Withdraw
- User tracks balance via events (events emit encrypted handles, user decrypts off-chain)
- User calls `withdraw(amount)` with known amount
- **Regular ERC20:** Async (decrypt required to transfer plaintext out)
- **fheERC20:** Sync (transfer encrypted out directly)

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
**Decision:** Yes, partial fills are supported.

**Rationale:** Large orders would be impossible to fill in one swap. Limit orders act as resting liquidity at a tick - swaps consume what they need, remainder stays.

```solidity
struct LimitOrder {
    address owner;
    int24 tick;              // Specific tick (public)
    ebool direction;         // Encrypted: sell token0 or token1
    euint128 amount;         // Encrypted: total amount
    euint128 filled;         // Encrypted: amount already filled
    euint128 minOutput;      // Encrypted: slippage protection
    bool active;
}
```

**Fill logic:**
```solidity
euint128 remaining = FHE.sub(order.amount, order.filled);
euint128 fillAmount = FHE.select(
    FHE.lte(swapDemand, remaining),
    swapDemand,      // Fill what swap needs
    remaining        // Fill remaining (completes order)
);

order.filled = FHE.add(order.filled, fillAmount);

// Deactivate if fully filled
ebool fullyFilled = FHE.eq(order.filled, order.amount);
```

**Privacy note:** Partial fills don't expose more than full fills - the order only executes when someone else's swap crosses the tick, which already reveals market direction.

---

## All Questions Resolved

All design decisions have been made. Ready for implementation.

---

## File Structure

```
src/
├── EncryptedAMM.sol              # Main contract
├── lib/
│   ├── DirectionLock.sol         # Transient storage direction lock
│   ├── SwapMath.sol              # FHE swap calculations
│   └── ReserveSync.sol           # Eventual consistency logic
├── interface/
│   └── IEncryptedAMM.sol
test/
├── EncryptedAMM.t.sol
├── security/
│   ├── ProbeAttack.t.sol         # Direction lock tests
│   └── PrivacyLeak.t.sol         # Ensure no direction/amount leaks
├── functional/
│   ├── Swap.t.sol                # Unified swap tests
│   ├── ReserveSync.t.sol         # Eventual consistency tests
│   ├── LimitOrders.t.sol
│   └── Deposits.t.sol
```

---

## Changes from v2

| Aspect | v2 | v3 |
|--------|----|----|
| AMM Engine | Uniswap's poolManager | Our own encrypted AMM |
| Swap interface | Two (public/private) | **Unified** (all encrypted) |
| Execution | Async (decrypt required) | Fully sync |
| Reserves (truth) | Public | **Encrypted** (source of truth) |
| Reserves (display) | N/A | **Public cache** (eventually consistent) |
| Reserve sync | N/A | **Lazy on getReserves()** |
| Trade blocking | On stale reserves | **Never** (slippage protects) |
| Limit order execution | Separate TX after trigger | **Same TX as trigger** |
| Executor reward | Sent to tx.origin | **Augments executor's output** |
| Arbitrage | External to Uniswap | **swapPlaintext interface** |
