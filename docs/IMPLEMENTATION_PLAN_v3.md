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

### One Pool, Two Interfaces

```
┌─────────────────────────────────────────────────────────────────┐
│                    Encrypted AMM Pool                            │
│              (public reserves: reserve0, reserve1)               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   swapPrivate(                   swapPublic(                     │
│     InEbool direction,             bool direction,               │
│     InEuint128 amount,             uint256 amount,               │
│     InEuint128 minOutput           uint256 minOutput             │
│   )                              )                               │
│                                                                  │
│   - Encrypted inputs             - Plaintext inputs              │
│   - Full privacy                 - Visible in mempool            │
│   - Same pool liquidity          - Same pool liquidity           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Why two interfaces?**
- `swapPublic`: Arbitrageurs keep our pool price aligned with market
- `swapPrivate`: Privacy-seeking traders get full encryption

**Both use the same reserves and same swap logic internally.**

---

## Data Visibility

| Data | Visibility | Rationale |
|------|------------|-----------|
| reserve0, reserve1 | **Public** | Users need to calculate expected prices |
| currentPrice | **Public** | Derived from reserves |
| user balances | **Encrypted** | Per-user privacy |
| swap direction | **Encrypted** (private) / Public (public) | Core privacy feature |
| swap amount | **Encrypted** (private) / Public (public) | Core privacy feature |
| limit order trigger tick | **Public** | Needed for trigger detection |
| limit order direction | **Encrypted** | Hidden until execution |
| limit order amount | **Encrypted** | Hidden until execution |

---

## Swap Flows

### swapPublic (Sync, Single TX)

```solidity
function swapPublic(
    bool direction,
    uint256 amount,
    uint256 minOutput
) external {
    // 1. Direction lock
    _enforceDirectionLock(direction);

    // 2. Calculate expected output from PUBLIC reserves
    uint256 expectedOutput = _calculateOutput(direction, amount);
    require(expectedOutput >= minOutput, "Slippage exceeded");

    // 3. Execute encrypted swap math (for internal consistency)
    ebool encDir = FHE.asEbool(direction);
    euint128 encAmt = FHE.asEuint128(amount);
    euint128 actualOutput = _executeSwapMath(encDir, encAmt);

    // 4. Verify encrypted matches expected
    euint128 encExpected = FHE.asEuint128(expectedOutput);
    ebool isValid = FHE.eq(actualOutput, encExpected);
    euint128 finalOutput = FHE.select(isValid, actualOutput, FHE.asEuint128(0));

    // 5. Update public reserves
    _updateReserves(direction, amount, expectedOutput);

    // 6. Transfer plaintext tokens
    _transferTokensPublic(direction, amount, expectedOutput);

    // 7. Check for triggered limit orders, execute them
    _checkAndExecuteLimitOrders(msg.sender);
}
```

### swapPrivate (Sync, Single TX)

```solidity
function swapPrivate(
    InEbool calldata direction,
    InEuint128 calldata amount,
    InEuint128 calldata minOutput
) external {
    ebool encDir = FHE.asEbool(direction);
    euint128 encAmt = FHE.asEuint128(amount);
    euint128 encMinOutput = FHE.asEuint128(minOutput);

    // 1. Direction lock (need to handle encrypted direction)
    //    See "Direction Lock for Encrypted Direction" section

    // 2. Execute encrypted swap math
    euint128 actualOutput = _executeSwapMath(encDir, encAmt);

    // 3. Slippage check (encrypted)
    ebool slippageOk = FHE.gte(actualOutput, encMinOutput);
    euint128 finalOutput = FHE.select(slippageOk, actualOutput, FHE.asEuint128(0));

    // 4. Transfer encrypted tokens
    _transferTokensPrivate(encDir, encAmt, finalOutput);

    // 5. Credit user's encrypted balance
    userBalance[msg.sender] = FHE.add(userBalance[msg.sender], finalOutput);

    // 6. Check for triggered limit orders, execute them
    _checkAndExecuteLimitOrders(msg.sender);
}
```

### Core Swap Math (Encrypted)

```solidity
function _executeSwapMath(ebool direction, euint128 amountIn) internal returns (euint128 amountOut) {
    // x * y = k formula, all encrypted

    euint128 encReserve0 = FHE.asEuint128(reserve0);
    euint128 encReserve1 = FHE.asEuint128(reserve1);

    // Select reserves based on direction
    euint128 reserveIn = FHE.select(direction, encReserve0, encReserve1);
    euint128 reserveOut = FHE.select(direction, encReserve1, encReserve0);

    // amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
    euint128 numerator = FHE.mul(amountIn, reserveOut);
    euint128 denominator = FHE.add(reserveIn, amountIn);
    amountOut = FHE.div(numerator, denominator);

    // Update encrypted reserves (will sync with public reserves for public swaps)
    euint128 newReserveIn = FHE.add(reserveIn, amountIn);
    euint128 newReserveOut = FHE.sub(reserveOut, amountOut);

    // Apply based on direction
    encReserve0 = FHE.select(direction, newReserveIn, newReserveOut);
    encReserve1 = FHE.select(direction, newReserveOut, newReserveIn);
}
```

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

| Action | TX Count | Sync? |
|--------|----------|-------|
| swapPublic | 1 | ✅ |
| swapPrivate | 1 | ✅ |
| placeOrder | 1 | ✅ |
| Order trigger + execute | 0 (piggybacks on swap) | ✅ |
| Deposit (ERC20) | 1 | ✅ |
| Deposit (fheERC20) | 1 | ✅ |
| Withdraw (encrypted) | 1 | ✅ |
| Withdraw (plaintext) | 2 (request + claim) | ❌ Async |
| Confirm balance (optional) | 1 | ❌ Async (user's choice) |

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
│   └── SwapMath.sol              # FHE swap calculations
├── interface/
│   └── IEncryptedAMM.sol
test/
├── EncryptedAMM.t.sol
├── security/
│   ├── ProbeAttack.t.sol         # Direction lock tests
│   └── PrivacyLeak.t.sol         # Ensure no direction/amount leaks
├── functional/
│   ├── SwapPublic.t.sol
│   ├── SwapPrivate.t.sol
│   ├── LimitOrders.t.sol
│   └── Deposits.t.sol
```

---

## Changes from v2

| Aspect | v2 | v3 |
|--------|----|----|
| AMM Engine | Uniswap's poolManager | Our own encrypted AMM |
| Execution | Async (decrypt required) | Fully sync |
| Reserves | Encrypted | **Public** (users need prices) |
| Limit order execution | Separate TX after trigger | **Same TX as trigger** |
| Executor reward | Sent to tx.origin | **Augments executor's output** |
| Arbitrage | External to Uniswap | **swapPublic interface** |
