# Private Trading Hook - Implementation Plan v2

## Revision Summary

This document revises the original implementation plan based on findings from the security review. Key changes:

| Original Plan | Problem | Revised Approach |
|---------------|---------|------------------|
| `OrderType` enum (public) | Leaks direction (stop-loss = long) | Remove enum, use encrypted direction only |
| Single-action lock | Breaks composability | Direction lock (allows same-direction) |
| Store direction in `orderInfo` | Exposed between trigger and execution | Dual-path execution (no plaintext direction) |
| Separate order types in contract | Unnecessary complexity | All orders = tick + direction + amount |

---

## Architecture Overview

### Core Insight

The contract doesn't need to know if an order is a "stop-loss" or "limit buy". It only needs:
- **Trigger tick** (public) - when to execute
- **Direction** (encrypted) - buy or sell
- **Amount** (encrypted) - how much

The UI labels orders based on direction vs current price. The contract just executes when price crosses tick.

### Two Execution Modes

| Mode | User Action | Execution | Direction Revealed |
|------|-------------|-----------|-------------------|
| **Immediate Swap** | `swapNow()` | Same TX | At execution (unavoidable) |
| **Limit Order** | `placeOrder()` | When price crosses tick | At execution (not before) |

---

## Conflicts Identified & Resolutions

### Conflict 1: OrderType Enum

**Original:**
```solidity
enum OrderType { LIMIT, STOP_LOSS, TAKE_PROFIT, STOP_LIMIT }

function placeOrder(
    PoolKey calldata key,
    int24 triggerTick,
    OrderType orderType,  // <-- PUBLIC, LEAKS INFO
    einput encryptedDirection,
    einput encryptedAmount,
    bytes calldata inputProof
) external;
```

**Problem:** `STOP_LOSS` implies user is long. Direction inferrable.

**Resolution:** Remove enum entirely.
```solidity
function placeOrder(
    PoolKey calldata key,
    int24 triggerTick,          // Public: price level
    InEbool calldata direction, // Encrypted: buy or sell
    InEuint128 calldata amount  // Encrypted: how much
) external;
```

**Order type is UI-only:**
| User Intent | Current Price | Trigger | Direction | UI Label |
|-------------|---------------|---------|-----------|----------|
| Buy the dip | 100 | 90 | Buy | "Limit Buy" |
| Stop loss (long) | 100 | 90 | Sell | "Stop Loss" |
| Take profit (long) | 100 | 110 | Sell | "Take Profit" |

---

### Conflict 2: Direction Lock vs Action Lock

**Original:**
```solidity
// lib/DirectionLock.sol
function enforce() internal {
    require(locked == 0, "One action per TX");  // <-- BLOCKS ALL SECOND ACTIONS
    assembly { tstore(DIRECTION_SLOT, 1) }
}
```

**Problem:** Blocks legitimate use cases (multiple orders, swap + order).

**Resolution:** Lock by direction, not by action count.
```solidity
function enforceDirectionLock(bool zeroForOne) internal {
    uint256 locked;
    assembly { locked := tload(DIRECTION_SLOT) }

    uint256 dir = zeroForOne ? 1 : 2;

    // Allow: no lock yet, OR same direction
    // Block: opposite direction
    require(locked == 0 || locked == dir, "No direction reversal");

    assembly { tstore(DIRECTION_SLOT, dir) }
}
```

**Behavior:**
- Multiple buys in same TX: ✅ Allowed
- Multiple sells in same TX: ✅ Allowed
- Buy then sell in same TX: ❌ Blocked
- Multiple orders at different ticks: ✅ Allowed

---

### Conflict 3: Order Trigger & Execution Flow

**Original (iceberg-cofhe style):**
```
afterSwap: price crosses → store DecryptedOrder(zeroForOne, tick, token)
                                              ^^^^^^^^^^^ PLAINTEXT!
beforeSwap: read orderInfo → execute with plaintext direction
```

**Problem:** Direction exposed in public storage between trigger and execution.

**Resolution:** Dual-path execution - never store plaintext direction.

```
afterSwap: price crosses → compute both amounts using FHE.select()
                         → request unwrap for BOTH (one is zero)
                         → store OrderPair(handle0, handle1, tick)
                                          ^^^^^^^^^^^^^^^^ NO DIRECTION!

beforeSwap: poll both handles → execute whichever is non-zero
```

**Implementation:**
```solidity
struct PendingOrderPair {
    euint128 handle0;      // Unwrap handle for zeroForOne path
    euint128 handle1;      // Unwrap handle for oneForZero path
    int24 tickLower;
    // NO direction field!
}

function _triggerOrder(ebool encDirection, euint128 encAmount) internal {
    euint128 ZERO = FHE.asEuint128(0);

    // Compute amounts for BOTH paths
    euint128 amount0 = FHE.select(encDirection, encAmount, ZERO);
    euint128 amount1 = FHE.select(encDirection, ZERO, encAmount);

    // Request unwrap for BOTH
    euint128 handle0 = token0.requestUnwrap(address(this), amount0);
    euint128 handle1 = token1.requestUnwrap(address(this), amount1);

    // Store pair - observer can't tell which is real
    pendingOrders.push(PendingOrderPair(handle0, handle1, tickLower));
}

function _executePendingOrders() internal {
    for each pair {
        (uint128 amt0, bool ready0) = getUnwrapResultSafe(pair.handle0);
        (uint128 amt1, bool ready1) = getUnwrapResultSafe(pair.handle1);

        if (!ready0 || !ready1) continue;

        // Execute whichever is non-zero (one will be zero)
        if (amt0 > 0) _swapPoolManager(key, true, -int256(uint256(amt0)));
        if (amt1 > 0) _swapPoolManager(key, false, -int256(uint256(amt1)));
    }
}
```

---

### Conflict 4: Internal vs External Swaps

**Problem:** Direction lock would block our own order execution (dual-path tries both directions).

**Resolution:** Internal execution flag exempts hook's own swaps.

```solidity
bytes32 constant DIRECTION_SLOT = keccak256("direction.lock");
bytes32 constant INTERNAL_SLOT = keccak256("internal.execution");

function _beforeSwap(...) internal override {
    uint256 isInternal;
    assembly { isInternal := tload(INTERNAL_SLOT) }

    if (isInternal == 0) {
        // External swap - enforce direction lock
        enforceDirectionLock(params.zeroForOne);
    }
    // Internal execution - skip lock

    _executePendingOrders(key);
}

function _executePendingOrders(...) internal {
    // Mark as internal
    assembly { tstore(INTERNAL_SLOT, 1) }

    // Execute orders (recursive beforeSwap calls skip direction lock)
    ...

    // Clear flag
    assembly { tstore(INTERNAL_SLOT, 0) }
}
```

---

## Revised Data Structures

### Order Storage

```solidity
// Pending orders waiting for price trigger
struct EncryptedOrder {
    address owner;
    int24 triggerTick;
    ebool direction;       // Encrypted
    euint128 amount;       // Encrypted
    euint128 maxSlippage;  // Encrypted - max acceptable slippage
    euint256 expiration;   // Encrypted - 0 = never expires
    bool active;
}

// Orders triggered, waiting for decryption
struct PendingOrderPair {
    euint128 handle0;      // zeroForOne amount handle
    euint128 handle1;      // oneForZero amount handle
    int24 tickLower;
    address owner;         // For executor reward
    euint128 maxSlippage;  // Carry forward for execution check
    // NO direction field - that's the point!
}

// Storage
mapping(bytes32 poolKey => mapping(int24 tick => EncryptedOrder[])) public ordersByTick;
PendingOrderPair[] public pendingExecutions;

// Fee configuration
uint256 public constant PROTOCOL_FEE = 0.0005 ether;  // ~$1 at $2000 ETH
uint256 public constant EXECUTOR_REWARD_BPS = 100;    // 1% of output = ~$1 on $100 order
```

### What We DON'T Need

- ~~`OrderType` enum~~ - UI concern, not contract
- ~~`orderInfo` with plaintext direction~~ - security hole
- ~~Separate stop-loss/take-profit logic~~ - all orders same: tick + direction + amount
- ~~Partial fill tracking~~ - use slippage protection instead

---

## Revised Implementation Phases

### Phase 1: Core Infrastructure
```
src/
├── PrivateTradingHook.sol    # Main hook
├── lib/
│   ├── DirectionLock.sol     # Direction-based lock (not action-based)
│   └── DualPathExecution.sol # FHE.select helpers for both paths
```

**Key change:** DirectionLock allows same-direction, blocks reversal.

### Phase 2: Immediate Swaps (`swapNow`)

```solidity
function swapNow(
    PoolKey calldata key,
    InEbool calldata direction,
    InEuint128 calldata amount
) external {
    // Direction lock enforced in beforeSwap (external swap)

    // Decode encrypted inputs
    ebool dir = FHE.asEbool(direction);
    euint128 amt = FHE.asEuint128(amount);

    // Branchless execution
    _executeBranchless(key, dir, amt);
}
```

**Execution:** Single TX, direction revealed only at swap moment.

### Phase 3: Limit Orders (`placeOrder`)

```solidity
function placeOrder(
    PoolKey calldata key,
    int24 triggerTick,
    InEbool calldata direction,
    InEuint128 calldata amount,
    InEuint128 calldata maxSlippage,  // Encrypted slippage tolerance
    InEuint256 calldata expiration    // Encrypted, 0 = never expires
) external payable {
    // Collect protocol fee
    require(msg.value >= PROTOCOL_FEE, "Insufficient fee");

    ebool dir = FHE.asEbool(direction);
    euint128 amt = FHE.asEuint128(amount);
    euint128 slip = FHE.asEuint128(maxSlippage);
    euint256 exp = FHE.asEuint256(expiration);

    // Store encrypted order
    ordersByTick[key][triggerTick].push(EncryptedOrder({
        owner: msg.sender,
        triggerTick: triggerTick,
        direction: dir,
        amount: amt,
        maxSlippage: slip,
        expiration: exp,
        active: true
    }));

    // Transfer tokens (branchless - both paths computed)
    _transferTokensIn(key, dir, amt);
}
```

**No OrderType parameter.** Contract doesn't need to know intent.

**Fee:** Protocol collects ETH fee on placement. Executor gets output token reward on execution.

### Phase 4: Order Triggering (`afterSwap`)

```solidity
function _afterSwap(...) internal override {
    (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(...);

    for (int24 tick = lower; tick <= upper; tick += tickSpacing) {
        EncryptedOrder[] storage orders = ordersByTick[key][tick];

        for each order {
            if (!order.active) continue;

            // Check expiration (encrypted comparison)
            euint256 encTimestamp = FHE.asEuint256(block.timestamp);
            ebool notExpired = FHE.or(
                FHE.eq(order.expiration, FHE.asEuint256(0)),  // 0 = never expires
                FHE.lte(encTimestamp, order.expiration)
            );

            // Only trigger if not expired (we'll check result in execution)
            // Dual-path: compute both amounts, request unwrap for both
            _triggerOrderDualPath(order, notExpired);
        }
    }
}

function _triggerOrderDualPath(EncryptedOrder storage order, ebool notExpired) internal {
    euint128 ZERO = FHE.asEuint128(0);

    // If expired, amount becomes zero (order won't execute)
    euint128 effectiveAmount = FHE.select(notExpired, order.amount, ZERO);

    // Compute amounts for BOTH paths
    euint128 amount0 = FHE.select(order.direction, effectiveAmount, ZERO);
    euint128 amount1 = FHE.select(order.direction, ZERO, effectiveAmount);

    // Request unwrap for BOTH
    euint128 handle0 = token0.requestUnwrap(address(this), amount0);
    euint128 handle1 = token1.requestUnwrap(address(this), amount1);

    // Store pair with slippage for execution check
    pendingExecutions.push(PendingOrderPair({
        handle0: handle0,
        handle1: handle1,
        tickLower: order.triggerTick,
        owner: order.owner,
        maxSlippage: order.maxSlippage
    }));

    order.active = false;
}
```

### Phase 5: Order Execution (`beforeSwap`)

```solidity
function _beforeSwap(...) internal override {
    // Direction lock for external swaps
    if (!isInternalExecution()) {
        enforceDirectionLock(params.zeroForOne);
    }

    // Execute ready orders
    _executePendingOrders(key);
}

function _executePendingOrders(PoolKey memory key) internal {
    // Mark as internal execution (exempt from direction lock)
    assembly { tstore(INTERNAL_SLOT, 1) }

    for (uint i = 0; i < pendingExecutions.length; i++) {
        PendingOrderPair storage pair = pendingExecutions[i];

        // Poll unwrap results
        (uint128 amt0, bool ready0) = getUnwrapResultSafe(pair.handle0);
        (uint128 amt1, bool ready1) = getUnwrapResultSafe(pair.handle1);

        if (!ready0 || !ready1) continue;

        // Skip if both zero (expired order)
        if (amt0 == 0 && amt1 == 0) {
            _removeOrder(i);
            continue;
        }

        // Execute whichever path has non-zero amount
        uint256 outputAmount;
        if (amt0 > 0) {
            outputAmount = _swapPoolManager(key, true, -int256(uint256(amt0)));
        } else {
            outputAmount = _swapPoolManager(key, false, -int256(uint256(amt1)));
        }

        // Slippage check (would need to unwrap maxSlippage too)
        // For v1: simplified - just execute, slippage checked pre-swap

        // Pay executor reward (1% of output)
        uint256 executorReward = (outputAmount * EXECUTOR_REWARD_BPS) / 10000;
        _transferReward(pair.owner, tx.origin, executorReward);  // tx.origin = executor

        _removeOrder(i);
    }

    // Clear internal flag
    assembly { tstore(INTERNAL_SLOT, 0) }
}
```

### Phase 6: Order Management

```solidity
function cancelOrder(PoolKey calldata key, int24 tick, uint256 index) external {
    EncryptedOrder storage order = ordersByTick[key][tick][index];
    require(order.owner == msg.sender);
    require(order.active);

    order.active = false;

    // Refund tokens (branchless)
    _transferTokensOut(key, order.direction, order.amount, msg.sender);
}
```

---

## Revised File Structure

```
src/
├── PrivateTradingHook.sol
├── lib/
│   ├── DirectionLock.sol        # Direction-based transient lock
│   ├── DualPathExecution.sol    # Dual-path helpers
│   └── EpochLibrary.sol         # Keep from iceberg-cofhe
├── interface/
│   └── IPrivateTradingHook.sol
test/
├── PrivateTradingHook.t.sol
├── security/
│   ├── ProbeAttack.t.sol        # Must PASS (blocks probe)
│   ├── DirectionExposure.t.sol  # Must PASS (no plaintext direction)
│   ├── GasSideChannel.t.sol     # Must PASS (constant gas)
│   └── Composability.t.sol      # Must PASS (same-direction allowed)
├── functional/
│   ├── ImmediateSwap.t.sol
│   ├── LimitOrders.t.sol
│   └── OrderManagement.t.sol
```

---

## Security Test Requirements

Tests that must **PASS** on our implementation:

| Test | Requirement |
|------|-------------|
| `test_ProbeAttackBlocked` | Buy→sell in same TX reverts |
| `test_DirectionNotExposedAfterTrigger` | No plaintext direction in storage |
| `test_ConstantGasConsumption` | Gas diff < threshold |
| `test_SameDirectionSwapsAllowed` | Multiple same-direction works |
| `test_CannotProbeAttackInSameTx` | Atomic buy→sell reverts |

---

## Accepted Limitations

| Limitation | Severity | Rationale |
|------------|----------|-----------|
| Multi-TX attacks by builders | High | Fundamental EVM limitation |
| Epoch correlation | Low | Tick already public |
| Withdrawal reveals tick | Low | Post-execution, minor info |
| Gas tests in mock environment | Medium | Real validation needs testnet |

---

## Design Decisions (Resolved)

### 1. Partial Fills
**Decision:** No partial fills. Use encrypted slippage protection instead.

**Rationale:** Once execution starts, direction is revealed. We want full execution in that moment, not a remainder left exposed. Slippage protection prevents executing into thin liquidity at a bad price.

### 2. Order Expiration
**Decision:** Yes, optional and encrypted.

**Rationale:** Time-sensitive trades are real (earnings, token unlocks). Encrypting expiration prevents leaking "user expects something Friday" information.

### 3. Order Fees
**Decision:** $2 placement fee split:
- $1 ETH → Protocol treasury (clean single-asset accounting)
- $1 output token → Executor reward (compensates gas for processing limit orders)

**Rationale:** Executor incentive ensures people don't avoid pools with pending orders. ETH for protocol keeps treasury simple.

### 4. Withdrawal Batching
**Decision:** Skip for v1.

**Rationale:** Post-execution information leak. Order already filled, direction already revealed. Low value to attackers.

---

## Implementation Order (Revised)

1. **DirectionLock library** - Direction-based, not action-based
2. **Basic hook structure** - beforeSwap/afterSwap with direction lock
3. **Immediate swaps** - `swapNow()` with branchless execution
4. **Order placement** - `placeOrder()` with encrypted storage
5. **Order triggering** - Dual-path in `afterSwap`
6. **Order execution** - Internal flag + execution in `beforeSwap`
7. **Order management** - Cancel, withdraw
8. **Security tests** - All must pass
9. **Functional tests** - Full coverage

---

## Success Criteria (Revised)

### Security (Must Pass)
- [ ] `test_ProbeAttackBlocked`
- [ ] `test_DirectionNotExposedAfterTrigger`
- [ ] `test_CannotProbeAttackInSameTx`
- [ ] `test_SameDirectionSwapsAllowed`

### Functional (Must Pass)
- [ ] Immediate swaps execute
- [ ] Limit orders trigger at correct tick
- [ ] Order cancellation works
- [ ] Withdrawal returns correct tokens

### Composability (Must Pass)
- [ ] Multiple same-direction swaps work
- [ ] Swap + order in same TX works (same direction)
- [ ] Multiple orders at different ticks work

---

## Summary of Changes from v1

| Aspect | v1 (Original) | v2 (Revised) |
|--------|---------------|--------------|
| Order types | Enum in contract | UI-only, not in contract |
| Direction lock | Action-based (blocks all) | Direction-based (allows same) |
| Order storage | Plaintext direction after trigger | Dual-path, no plaintext |
| Internal swaps | Not addressed | Internal execution flag |
| Security tests | Basic | Comprehensive, must PASS |

---

## Critical Review (Post-Update)

### Issues Found

#### Issue 1: Slippage Check Timing Problem (High)

**Problem:** The plan stores `maxSlippage` as `euint128` in `PendingOrderPair`, but slippage check happens AFTER execution (line 421-422 says "For v1: simplified"). This is backwards - slippage should prevent bad execution, not detect it after.

**Current flow:**
```
1. Execute swap → direction revealed
2. Check slippage → too late, already executed
```

**Fix Required:** Slippage must be checked BEFORE execution using FHE comparison, or we need to request unwrap for slippage alongside the amounts.

```solidity
// In _executePendingOrders:
(uint128 maxSlip, bool slipReady) = getUnwrapResultSafe(pair.maxSlippageHandle);
if (!slipReady) continue;

// Check BEFORE executing
uint256 expectedOutput = _quoteSwap(key, amt0 > 0, amt0 > 0 ? amt0 : amt1);
if (expectedOutput < (inputAmount - maxSlip)) {
    // Don't execute, refund user
    _refundOrder(pair);
    continue;
}
// Then execute
```

**Severity:** High - without this fix, users have no slippage protection.

---

#### Issue 2: Token Transfer in `_transferTokensIn` Not Specified (Medium)

**Problem:** `placeOrder` calls `_transferTokensIn(key, dir, amt)` but this function isn't implemented. The branchless transfer needs to handle both paths.

**Required Implementation:**
```solidity
function _transferTokensIn(PoolKey memory key, ebool direction, euint128 amount) internal {
    euint128 ZERO = FHE.asEuint128(0);

    // Compute both paths
    euint128 amount0 = FHE.select(direction, amount, ZERO);
    euint128 amount1 = FHE.select(direction, ZERO, amount);

    // Transfer from both (one will be zero)
    token0.encTransferFrom(msg.sender, address(this), amount0);
    token1.encTransferFrom(msg.sender, address(this), amount1);
}
```

**Severity:** Medium - must be implemented for placement to work.

---

#### Issue 3: Expired Order Refund Not Handled (Medium)

**Problem:** When an expired order has both amounts = 0, we call `_removeOrder(i)` but don't refund the user's tokens.

**Current code (line 408-411):**
```solidity
if (amt0 == 0 && amt1 == 0) {
    _removeOrder(i);
    continue;  // No refund!
}
```

**Fix Required:**
```solidity
if (amt0 == 0 && amt1 == 0) {
    // Expired - refund user
    _refundExpiredOrder(pair);
    _removeOrder(i);
    continue;
}
```

**Severity:** Medium - users lose funds on expired orders.

---

#### Issue 4: `swapNow` Flow Unclear (Low-Medium)

**Problem:** `swapNow()` calls `_executeBranchless()` but the flow between this and the pool manager swap isn't clear. Does it go through `beforeSwap`? If so, how does the direction get passed?

**Questions:**
1. Does `swapNow` trigger a normal pool manager swap?
2. If so, how is direction communicated if it's encrypted?
3. If not, how does it interact with the AMM?

**Likely Solution:** `swapNow` must:
1. Decrypt direction (request unwrap)
2. Wait for decryption (async)
3. Execute once ready

This means `swapNow` is NOT actually immediate - it's also async. Need to clarify this.

**Severity:** Low-Medium - design needs clarification.

---

#### Issue 5: Array Removal Pattern Bug (Low)

**Problem:** In `_executePendingOrders`, we loop through `pendingExecutions` and call `_removeOrder(i)`. Removing elements while iterating causes index shifts.

**Current pattern:**
```solidity
for (uint i = 0; i < pendingExecutions.length; i++) {
    ...
    _removeOrder(i);  // Shifts all subsequent indices!
}
```

**Fix Required:** Iterate backwards or mark-and-sweep:
```solidity
// Option 1: Iterate backwards
for (uint i = pendingExecutions.length; i > 0; i--) {
    uint idx = i - 1;
    ...
    _removeOrder(idx);
}

// Option 2: Mark-and-sweep
for (uint i = 0; i < pendingExecutions.length; i++) {
    ...
    pair.executed = true;  // Mark
}
_cleanupExecutedOrders();  // Sweep
```

**Severity:** Low - common bug, easy fix.

---

#### Issue 6: `tx.origin` for Executor Reward (Low)

**Problem:** Using `tx.origin` for executor reward (line 426) is generally discouraged and may not correctly identify the executor in all cases (e.g., meta-transactions, account abstraction).

**Better approach:**
```solidity
// Executor is whoever triggered the beforeSwap
// If internal execution, no reward (we triggered ourselves)
if (!isInternalExecution()) {
    _transferReward(pair.owner, msg.sender, executorReward);
}
```

**Severity:** Low - works for most cases, edge cases can be addressed later.

---

### Summary of Review

| Issue | Severity | Action |
|-------|----------|--------|
| Slippage check timing | High | Must fix before implementation |
| `_transferTokensIn` missing | Medium | Must implement |
| Expired order refund | Medium | Must add refund logic |
| `swapNow` async unclear | Low-Medium | Clarify in design |
| Array removal bug | Low | Use backwards iteration |
| `tx.origin` usage | Low | Consider alternative |

### Recommendations

1. **Priority 1:** Fix slippage to check BEFORE execution
2. **Priority 2:** Add expired order refund logic
3. **Priority 3:** Clarify `swapNow` async behavior (maybe rename to `swapAsync`?)
4. **During implementation:** Use backwards iteration for array removal

### Plan Verdict

**Overall:** The plan is solid architecturally. The security model (dual-path, direction lock, internal flag) is sound. The issues found are implementation details, not architectural flaws. Ready for implementation with the above fixes noted.
