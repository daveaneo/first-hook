# Implementation Plan v3 - Audit Report

## Executive Summary

This audit reviews IMPLEMENTATION_PLAN_v3.md for alignment with the stated vision, architectural consistency, security considerations, and gas optimization opportunities.

**Overall Assessment:** The plan is well-structured and addresses the core v2 vulnerabilities. However, there are several issues ranging from minor inconsistencies to potential security gaps that should be addressed before implementation.

---

## Part 1: Vision Alignment

### Stated Vision (Core Purpose)

> "Build a fully encrypted AMM where trade direction and amounts are never revealed on-chain, with all sensitive operations executing synchronously in a single transaction using FHE."

### Alignment Check

| Vision Element | Addressed? | Notes |
|----------------|------------|-------|
| Trade direction never revealed | ⚠️ **Partial** | Direction is encrypted, but see Issue #1 |
| Trade amounts never revealed | ⚠️ **Partial** | Amounts are encrypted, but see Issue #2 |
| Synchronous execution | ✅ **Yes** | All swaps execute in single TX |
| FHE operations | ✅ **Yes** | All math uses FHE primitives |
| MEV protection | ⚠️ **Partial** | Direction lock exists, but see Issue #3 |

### Vision Alignment Issues

#### Issue #1: Plaintext Swaps Still Reveal Direction (MEDIUM) - ✅ RESOLVED

**Location:** Swap Flows → Standard Swap (Plaintext)

**Problem:** When users call `poolManager.swap()` without `hookData`, the plaintext `params.zeroForOne` is visible in the transaction calldata before encryption occurs in the hook.

**Impact:** The "privacy comes from the hook" claim is only true for `hookData` swaps. Plaintext swaps have their direction/amount exposed in calldata.

**Resolution:** Added "Privacy Levels: hookData vs Plaintext Swaps" section clearly documenting:
- Two privacy levels with comparison table
- hookData swaps = full MEV protection
- Plaintext swaps = execution privacy only (vulnerable to front-running)
- Why plaintext is still supported (aggregator compatibility)
- Clear recommendation: "Users seeking full privacy MUST use hookData with client-side encryption"

See "Data Visibility → Privacy Levels: hookData vs Plaintext Swaps" in IMPLEMENTATION_PLAN_v3.md.

---

#### Issue #2: Deposit Amounts Are Public for ERC20 (LOW)

**Location:** Deposit & Withdrawal → Adding Liquidity

**Problem:** For regular ERC20 deposits, the amount is visible in the ERC20 `transferFrom` call.

**Impact:** Liquidity positions can be tracked for non-fheERC20 tokens.

**Recommendation:** Already documented in Token Support table. No action needed, but ensure users understand.

---

#### Issue #3: Direction Lock Has a Gap (HIGH) - ✅ RESOLVED

**Location:** Direction Lock → Direction Lock for Encrypted Swaps

**Problem:** The direction lock implementation stores `firstSwapDirection` and `hasSwappedThisTx` in **regular storage**, not transient storage.

**Impact:**
1. These values persist across transactions (not reset automatically)
2. The note says "must reset between transactions" but no mechanism is provided
3. An attacker could exploit stale state

**Resolution:** Updated to use transient storage (EIP-1153) with proper ebool handle unwrapping.

Key implementation details:
- `HAS_SWAPPED_SLOT` and `FIRST_DIRECTION_SLOT` use `tload`/`tstore`
- ebool handles are unwrapped to uint256 for transient storage
- Function returns adjusted amount (zeroed if direction differs)
- Transient storage auto-resets each TX

See "Direction Lock → Implementation (Using Transient Storage)" in IMPLEMENTATION_PLAN_v3.md.

---

## Part 2: Architectural Consistency

### Issue #4: BeforeSwapDelta Calculation Not Defined (HIGH)

**Location:** beforeSwap Hook

**Problem:** The code references `_calculateDelta(encDir, encAmt, finalOutput)` but this function is never defined. This is critical because:

1. `BeforeSwapDelta` must be calculated from **plaintext** values to tell Uniswap how many tokens to transfer
2. But `encDir`, `encAmt`, `finalOutput` are all **encrypted**

**Impact:** Cannot implement as written. This is a fundamental architectural gap.

**Analysis:** To return a `BeforeSwapDelta`, we need plaintext amounts. But our swap math produces encrypted outputs. Options:

1. **Use custom accounting:** Don't return a delta, handle all transfers ourselves via `beforeSwap` return flags
2. **Decrypt inline:** Would require async (breaks sync goal)
3. **Use expected values:** Calculate expected output from public reserves, return that as delta, verify encrypted matches

**Recommendation:** Add section explaining how `BeforeSwapDelta` is calculated. Likely need to use public reserves for the delta calculation (similar to resolved question #4 for tick calculation), then verify encrypted math matches.

```solidity
// Proposed solution:
function beforeSwap(...) {
    // Calculate expected output from PUBLIC reserves (for delta)
    uint256 expectedOutput = _calculateFromPublicReserves(params);

    // Run encrypted math (source of truth)
    euint128 actualOutput = _executeSwapMath(encDir, encAmt);

    // Verify encrypted matches expected (within tolerance)
    // If mismatch, slippage protection kicks in

    // Return delta based on expected (plaintext)
    BeforeSwapDelta delta = toBeforeSwapDelta(expectedOutput, params.amountSpecified);

    return (selector, delta, 0);
}
```

---

### Issue #5: Conflicting Reserve Update Logic (MEDIUM) - ✅ RESOLVED

**Location:** Multiple sections

**Problem:** The document has conflicting descriptions of when/how reserves are updated.

**Resolution:** Added "Standardized Reserve Update Pattern" table and fixed inconsistent code:
- Clear rule: If amount is plaintext → update both reserves directly, no sync needed
- If amount is encrypted → update encReserve only, request async sync
- Fixed `beforeRemoveLiquidity` to NOT call `_requestReserveSync()` (amounts are plaintext)
- Table shows exactly which operations update what

See "Reserve Consistency Model → Standardized Reserve Update Pattern" in IMPLEMENTATION_PLAN_v3.md.

---

### Issue #6: Limit Order Token Handling Unclear (MEDIUM) - ✅ RESOLVED

**Location:** Limit Orders → Placement

**Problem:** `_transferTokensIn(encDir, encAmt)` is called but function not defined.

**Resolution:** Replaced with `_debitUserBalance()` and added clear documentation:
- "Token Flow" section explains users must deposit first
- `_debitUserBalance()` function defined inline (branchless)
- Clarified tokens stay in hook, just reserved for order
- Added `userOrders` tracking for enumeration
- Integrated TickBitmap (`_flipTick`) for new ticks
- Added `nonReentrant` modifier

See "Limit Orders → Placement" in IMPLEMENTATION_PLAN_v3.md.

---

### Issue #7: User Balance vs LP Balance Confusion (LOW) - ✅ RESOLVED

**Location:** Throughout document

**Problem:** The document uses multiple balance concepts inconsistently.

**Resolution:** Added "Balance Model" section with clear definitions:
- Three balance types: `userBalanceToken0/1` (trading), `encReserve0/1` (pool), `lpShares` (LP ownership)
- Table explaining purpose of each
- Flow example showing how balances change through deposit → swap → limit order → withdraw
- Note that v3 uses simplified LP model (to be enhanced in v3.1)

See "Custom Accounting → Balance Model" in IMPLEMENTATION_PLAN_v3.md.

---

## Part 3: Security Analysis

### Issue #8: Limit Order Slippage Can Be Gamed (MEDIUM) - ✅ RESOLVED

**Location:** Limit Orders → Trigger + Execute

**Problem:** If slippage fails, order stays active. An attacker could repeatedly trigger orders to waste executor gas.

**Resolution:** Changed to "single trigger, fill-or-return" semantics:
- Orders are consumed on trigger, regardless of slippage outcome
- If slippage fails: user gets original tokens back (refund), order deactivated
- If slippage passes: user gets output, order deactivated
- No repeat attempts possible - each tick crossing triggers once

This prevents gaming because:
- Attacker cannot repeatedly trigger the same order
- Executor gas is bounded (one attempt per order)
- User is protected (tokens returned on slippage failure)

Also integrated TickBitmap for efficient tick iteration and added `_removeOrderFromTick()` cleanup.

See "Limit Orders → Slippage Failure Handling" in IMPLEMENTATION_PLAN_v3.md.

---

### Issue #9: Executor Reward Creates Incentive Misalignment (LOW) - ✅ DOCUMENTED

**Location:** Executor Reward Mechanism

**Problem:** Executor gets 1% of filled order output. This could incentivize prioritizing large orders.

**Resolution:** Documented as acceptable tradeoff with explanation:
- All orders at triggered ticks execute in same TX (no selective execution)
- Executors can't skip small orders (processed sequentially)
- Self-dealing has no benefit (net zero)
- Future improvements noted (flat fee, minimum floor, protocol keeper)

See "Executor Reward Mechanism → Incentive Considerations" in IMPLEMENTATION_PLAN_v3.md.

---

### Issue #10: No Reentrancy Protection Mentioned (MEDIUM) - ✅ RESOLVED

**Location:** All external functions

**Problem:** No `nonReentrant` modifiers or reentrancy guards mentioned.

**Impact:** FHE operations may have unexpected callbacks. Hook callbacks from PoolManager could re-enter.

**Resolution:** Added "Reentrancy Protection" section in Security Hardening. Key points:
- Contract inherits `ReentrancyGuard` from OpenZeppelin
- All user-facing functions (`deposit`, `withdraw`, `placeOrder`, `cancelOrder`) use `nonReentrant`
- Checks-Effects-Interactions pattern documented
- Defense in depth for hook callbacks

See "Security Hardening → Reentrancy Protection" in IMPLEMENTATION_PLAN_v3.md.

---

## Part 4: Logic & Implementation Issues

### Issue #11: Fee Calculation Has Precision Loss (LOW) - ✅ DOCUMENTED

**Location:** Resolved Questions → Swap Fees

**Problem:** FHE division truncates. For small amounts, fee could round to zero.

**Resolution:** Documented as acceptable tradeoff:
- Very small swaps paying zero fees is negligible value loss
- Fee goes to LPs, not extracted - minor rounding benefits traders
- Higher precision (1e18 scaling) would significantly increase gas costs
- Added cached encrypted constants for fee calculation

See "Resolved Questions → 2. Swap Fees" in IMPLEMENTATION_PLAN_v3.md.

---

### Issue #12: getActiveOrders Function Signature Incomplete (LOW) - ✅ RESOLVED

**Location:** Resolved Questions → Order Cancellation

**Problem:** `getActiveOrders(address user)` is declared but not implemented.

**Resolution:** Added full implementation:
- `userOrders` mapping tracks all orders per user (populated in `placeOrder()`)
- `getActiveOrders()` filters for active orders only
- `getOrderCount()` helper for gas-efficient counting

See "Resolved Questions → 1. Order Cancellation" in IMPLEMENTATION_PLAN_v3.md.

---

### Issue #13: Tick Loop Could Exceed Block Gas Limit (HIGH) - ✅ RESOLVED

**Location:** Limit Orders → Trigger + Execute, Open Questions #5

**Problem:**
```solidity
for (int24 tick = lower; tick <= upper; tick++) {
    // ... process orders
}
```

If price moves 1000 ticks, this loops 1000 times, each with FHE operations.

**Impact:** Transaction reverts, orders never execute, swap fails.

**Resolution:** Use TickBitmap pattern (inspired by Uniswap v3) for efficient tick lookup.

TickBitmap packs 256 ticks into a single `uint256` word. Each bit represents whether a tick has orders:
- Single SLOAD covers 256 ticks (vs 256 separate storage reads)
- Bit manipulation (AND, OR, XOR) is ~3 gas each
- Skip empty 256-tick ranges entirely

**Example:** Price moves 900 ticks (tick 100 to 1000)
- Naive: 900 storage reads = 900 × 2100 gas = 1,890,000 gas
- TickBitmap: ~4 storage reads = 4 × 2100 gas = 8,400 gas

See "Resolved Questions → 5. Gas Limits on Tick Loops" in IMPLEMENTATION_PLAN_v3.md for full implementation.

---

## Part 5: Gas Optimization Opportunities

### Gas Issue #1: Repeated FHE.asEuint128(0) Calls (HIGH IMPACT) - ✅ RESOLVED

**Location:** Multiple places

**Problem:** `FHE.asEuint128(0)` is called repeatedly. Each call encrypts a constant, which is expensive.

**Resolution:** Added "Gas Optimization: Cached FHE Constants" section. Key points:
- Cache `ENC_ZERO`, `ENC_ONE`, `ENC_HUNDRED`, `ENC_TEN_THOUSAND` as immutables
- Set once in constructor
- Use cached values throughout contract
- Estimated 10-20% reduction in FHE gas costs

See "FHE Operations Reference → Gas Optimization: Cached FHE Constants" in IMPLEMENTATION_PLAN_v3.md.

---

### Gas Issue #2: Unnecessary Reserve Sync on Every Swap (MEDIUM IMPACT) - ✅ RESOLVED

**Location:** beforeSwap → line 199

**Problem:** `_requestReserveSync()` is called on every swap, which calls `FHE.decrypt()` twice.

**Resolution:** Added rate limiting with `SYNC_COOLDOWN_BLOCKS = 5`:
- Skip sync if one was requested within last 5 blocks
- Added `forceSyncReserves()` for manual sync when needed
- Estimated 80%+ reduction in decrypt calls during high activity

See "Reserve Consistency Model → Implementation" in IMPLEMENTATION_PLAN_v3.md.

---

### Gas Issue #3: Double Storage Write for Reserves (MEDIUM IMPACT)

**Location:** _executeSwapMath

**Problem:**
```solidity
encReserve0 = FHE.select(direction, newReserveIn, newReserveOut);
encReserve1 = FHE.select(direction, newReserveOut, newReserveIn);
```

Two SSTORE operations for reserves every swap.

**Recommendation:** Consider packing or batch updates. For FHE values this may not be possible, but worth investigating if Fhenix supports packed encrypted values.

---

### Gas Issue #4: Inefficient Order Lookup (HIGH IMPACT)

**Location:** _checkAndExecuteLimitOrders

**Problem:**
```solidity
for (int24 tick = lower; tick <= upper; tick++) {
    uint256[] storage orderIds = ordersByTick[tick];
    for (uint i = 0; i < orderIds.length; i++) {
        Order storage order = orders[orderIds[i]];
        if (!order.active) continue;  // Still loads inactive orders
```

Inactive orders are still loaded from storage before being skipped.

**Recommendation:** Remove inactive order IDs from the array:
```solidity
// When deactivating order:
order.active = false;
_removeFromTickArray(order.triggerTick, orderId);

function _removeFromTickArray(int24 tick, uint256 orderId) internal {
    uint256[] storage orderIds = ordersByTick[tick];
    for (uint i = 0; i < orderIds.length; i++) {
        if (orderIds[i] == orderId) {
            orderIds[i] = orderIds[orderIds.length - 1];
            orderIds.pop();
            break;
        }
    }
}
```

---

### Gas Issue #5: Executor Reward Calculation Inefficient (LOW IMPACT)

**Location:** _checkAndExecuteLimitOrders

**Problem:**
```solidity
euint128 reward = FHE.div(finalOutput, FHE.asEuint128(100));  // 1%
euint128 ownerReceives = FHE.sub(finalOutput, reward);
```

Division then subtraction. Could use single multiply.

**Recommendation:**
```solidity
// 1% = divide by 100, or multiply by 99/100 for owner
euint128 ownerReceives = FHE.div(FHE.mul(finalOutput, ENC_NINETY_NINE), ENC_HUNDRED);
euint128 reward = FHE.sub(finalOutput, ownerReceives);
```

Minimal savings but cleaner.

---

## Summary of Findings

### Critical (Must Fix Before Implementation)
| # | Issue | Section | Status |
|---|-------|---------|--------|
| 4 | BeforeSwapDelta calculation not defined | Architecture | ✅ RESOLVED - Custom accounting with ZERO_DELTA |
| 13 | Tick loop could exceed gas limit | Logic | ✅ RESOLVED - TickBitmap pattern |

### High Priority (Should Fix)
| # | Issue | Section | Status |
|---|-------|---------|--------|
| 3 | Direction lock uses regular storage, not transient | Vision | ✅ RESOLVED |
| 10 | No reentrancy protection | Security | ✅ RESOLVED |
| G1 | Repeated FHE constant encryption | Gas | ✅ RESOLVED |

### Medium Priority (Recommended)
| # | Issue | Section | Status |
|---|-------|---------|--------|
| 1 | Plaintext swaps reveal direction in calldata | Vision | ✅ RESOLVED |
| 5 | Conflicting reserve update logic | Architecture | ✅ RESOLVED |
| 6 | Limit order token handling unclear | Architecture | ✅ RESOLVED |
| 8 | Limit order slippage can be gamed | Security | ✅ RESOLVED |
| G2 | Unnecessary reserve sync every swap | Gas | ✅ RESOLVED |
| G4 | Inefficient order lookup | Gas | ✅ RESOLVED (TickBitmap) |

### Low Priority (Nice to Have)
| # | Issue | Section | Status |
|---|-------|---------|--------|
| 2 | Deposit amounts public for ERC20 | Vision | Documented |
| 7 | User balance vs LP balance confusion | Architecture | ✅ RESOLVED |
| 9 | Executor reward incentive misalignment | Security | ✅ DOCUMENTED |
| 11 | Fee calculation precision loss | Logic | ✅ DOCUMENTED |
| 12 | getActiveOrders incomplete | Logic | ✅ RESOLVED |
| G3 | Double storage write for reserves | Gas | Acceptable |
| G5 | Executor reward calculation inefficient | Gas | Minor |

---

## Recommendations

All critical and high-priority issues have been resolved. The document is ready for implementation.

### Completed Improvements
1. ✅ **Custom accounting with ZERO_DELTA** - Solved BeforeSwapDelta problem
2. ✅ **TickBitmap** - Efficient tick lookup (256 ticks per storage read)
3. ✅ **Transient storage** - Direction lock uses EIP-1153
4. ✅ **Reentrancy guards** - Added to all external functions
5. ✅ **Cached FHE constants** - Major gas savings
6. ✅ **Balance model clarified** - Three distinct balance types documented
7. ✅ **Privacy levels documented** - hookData vs plaintext tradeoffs clear
8. ✅ **Reserve update pattern** - Standardized table
9. ✅ **Rate-limited sync** - 5 block cooldown for reserve syncs
10. ✅ **Slippage gaming prevented** - Single trigger, fill-or-return semantics

### Remaining Minor Items (Acceptable)
- **G3 (Double storage write):** Inherent to FHE design, no practical optimization
- **G5 (Reward calculation):** Minor optimization, low impact
- **Issue #2 (ERC20 deposit visibility):** Documented as known limitation

---

*Audit completed: November 2024*
*Document version: v3*
*Auditor: Claude*
*Status: All critical/high/medium issues RESOLVED*
