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
4. **Reentrancy attacks** - All state-changing functions use reentrancy guards

This enables truly private on-chain trading where observers cannot determine what you're buying, selling, or how much.

### Reentrancy Protection

All external state-changing functions MUST use reentrancy guards:

```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PrivateTradeHook is BaseHook, ReentrancyGuard {
    // User-facing functions need nonReentrant
    function deposit(...) external nonReentrant { ... }
    function withdraw(...) external nonReentrant { ... }
    function placeOrder(...) external payable nonReentrant { ... }
    function cancelOrder(...) external nonReentrant { ... }

    // Hook callbacks are called by PoolManager (trusted)
    // but still protect for defense in depth
    function beforeSwap(...) external override returns (...) {
        // PoolManager is trusted, but we still protect internal state
        // via checks-effects-interactions pattern
    }
}
```

**Why reentrancy matters here:**
- FHE token transfers (`transferFromEncrypted`) may have callbacks
- Malicious tokens could attempt reentrancy during deposit/withdraw
- Limit order execution iterates through orders - state must be consistent

**Pattern:** Checks-Effects-Interactions
```solidity
function withdraw(uint256 amount) external nonReentrant {
    // 1. CHECKS
    require(userBalance[msg.sender] >= amount, "Insufficient balance");

    // 2. EFFECTS (update state BEFORE external calls)
    userBalance[msg.sender] -= amount;

    // 3. INTERACTIONS (external calls last)
    token.transfer(msg.sender, amount);
}
```

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

### Gas Optimization: Cached FHE Constants

**Problem:** Calling `FHE.asEuint128(0)` repeatedly is expensive - each call encrypts the constant.

**Solution:** Cache commonly-used encrypted constants at deployment:

```solidity
contract PrivateTradeHook {
    // Cached encrypted constants (set once in constructor)
    euint128 internal immutable ENC_ZERO;
    euint128 internal immutable ENC_ONE;
    euint128 internal immutable ENC_HUNDRED;
    euint128 internal immutable ENC_TEN_THOUSAND;

    constructor(...) {
        ENC_ZERO = FHE.asEuint128(0);
        ENC_ONE = FHE.asEuint128(1);
        ENC_HUNDRED = FHE.asEuint128(100);       // For 1% reward calc
        ENC_TEN_THOUSAND = FHE.asEuint128(10000); // For fee basis points
    }

    // Use cached values instead of encrypting each time
    function _executeSwapMath(...) internal {
        // BAD: euint128 zero = FHE.asEuint128(0);
        // GOOD: use ENC_ZERO
        euint128 adjustedAmount = FHE.select(condition, amount, ENC_ZERO);
    }
}
```

**Estimated Savings:** 10-20% reduction in FHE gas costs.

**Note:** `immutable` works because FHE handles are just `uint256` pointers - they're set once and never change.

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

### Custom Accounting (Critical Architecture Decision)

**All swaps use custom accounting. No tokens flow through Uniswap during swaps.**

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Flow                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. DEPOSIT                                                     │
│      User transfers tokens → Hook holds them                     │
│      User receives encrypted internal balance                    │
│                                                                  │
│   2. SWAP                                                        │
│      Hook debits user's internal balance (encrypted)             │
│      Hook credits user's output balance (encrypted)              │
│      BeforeSwapDelta = ZERO (Uniswap transfers nothing)          │
│                                                                  │
│   3. WITHDRAW                                                    │
│      User's internal balance debited                             │
│      Tokens transferred back to user                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Why this is required:**
- We cannot tell Uniswap how many tokens to transfer without revealing the plaintext amount
- Custom accounting lets us keep all amounts encrypted
- `BeforeSwapDelta.ZERO_DELTA` tells Uniswap: "we handled it, do nothing"

**Implication:** Users must deposit before swapping. Direct "swap from wallet" is not supported.

### Balance Model

The hook tracks three distinct balance types:

```solidity
// 1. User Trading Balances - For swaps and limit orders
mapping(address => euint128) public userBalanceToken0;
mapping(address => euint128) public userBalanceToken1;

// 2. Pool Reserves - Source of truth for AMM pricing
euint128 internal encReserve0;
euint128 internal encReserve1;

// 3. LP Shares - Tracks liquidity provider ownership (optional, for v3.1)
// mapping(address => euint128) public lpShares;
```

**Balance Types Explained:**

| Balance | Purpose | Who Uses It |
|---------|---------|-------------|
| `userBalanceToken0/1` | Trading balance for swaps & limit orders | All users |
| `encReserve0/1` | Pool liquidity, source of truth for pricing | AMM math |
| `lpShares` | LP ownership for withdraw proportions | Liquidity providers |

**Flow Example:**

```
1. User deposits 1000 USDC
   → userBalanceToken0[user] += 1000 (encrypted)
   → encReserve0 += 1000 (encrypted)

2. User swaps 100 USDC for ETH
   → userBalanceToken0[user] -= 100 (encrypted)
   → userBalanceToken1[user] += 0.05 ETH (encrypted)
   → encReserve0 += 100, encReserve1 -= 0.05 ETH

3. User places limit order (100 USDC → ETH at tick X)
   → userBalanceToken0[user] -= 100 (reserved for order)
   → order.amount = 100

4. Limit order fills
   → userBalanceToken1[user] += ETH output
   → encReserve0 += 100, encReserve1 -= output

5. User withdraws
   → userBalanceToken1[user] debited
   → tokens transferred to wallet
```

**Note on LP Shares:** For v3, we use a simplified model where `lpShares` are equivalent to the tokens deposited. Future versions may implement proper LP share calculation (proportional to total liquidity).

---

## Data Visibility

| Data | Visibility | Rationale |
|------|------------|-----------|
| encReserve0, encReserve1 | **Encrypted** | Source of truth for all swap math |
| reserve0, reserve1 | **Public (cache)** | Eventually consistent display values for UX |
| currentPrice | **Public (cache)** | Derived from public reserves, may be stale |
| user balances | **Encrypted** | Per-user privacy |
| swap direction | **Encrypted** | Always encrypted during execution |
| swap amount | **Encrypted** | Always encrypted during execution |
| limit order trigger tick | **Public** | Needed for trigger detection |
| limit order direction | **Encrypted** | Hidden until execution |
| limit order amount | **Encrypted** | Hidden until execution |

### Privacy Levels: hookData vs Plaintext Swaps

**Important:** There are two privacy levels depending on how users submit swaps:

| Swap Method | Calldata Privacy | Execution Privacy | MEV Protection |
|-------------|------------------|-------------------|----------------|
| **hookData (encrypted params)** | ✅ Direction/amount encrypted in calldata | ✅ Full | ✅ Full |
| **Plaintext params** | ❌ Direction/amount visible in calldata | ✅ Full | ⚠️ Partial |

**hookData swaps (maximum privacy):**
```solidity
// User encrypts params CLIENT-SIDE before submitting
bytes memory hookData = abi.encode(
    encryptedDirection,   // Encrypted - not visible in mempool
    encryptedAmount,      // Encrypted - not visible in mempool
    encryptedMinOutput    // Encrypted - not visible in mempool
);
poolManager.swap(poolKey, params, hookData);
```
- Mempool observers see only encrypted blobs
- No front-running possible - can't determine trade direction
- Full MEV protection

**Plaintext swaps (execution privacy only):**
```solidity
// Standard Uniswap call - params visible in calldata
poolManager.swap(
    poolKey,
    IPoolManager.SwapParams({
        zeroForOne: true,      // VISIBLE in mempool!
        amountSpecified: 1000e18,  // VISIBLE in mempool!
        sqrtPriceLimitX96: ...
    }),
    ""  // Empty hookData
);
```
- Direction and amount visible in mempool/calldata
- Hook still encrypts internally for execution
- **Still protected against:** Probe attacks (direction lock), order sniping
- **NOT protected against:** Front-running based on visible intent

**Why support plaintext swaps?**
1. Aggregator compatibility - 1inch, Paraswap don't know how to encrypt
2. Simpler integration for protocols that don't need mempool privacy
3. Gradual adoption path - users can start plaintext, upgrade to hookData

**Recommendation:** Users seeking full privacy MUST use hookData with client-side encryption.

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

    // 1. Extract encrypted swap parameters from hookData
    (ebool encDir, euint128 encAmt, euint128 encMinOutput) = abi.decode(
        hookData, (InEbool, InEuint128, InEuint128)
    );

    // 2. Direction lock (encrypted - see Direction Lock section)
    _enforceDirectionLockEncrypted(encDir);

    // 3. Debit user's input balance (branchless)
    _debitUserBalance(sender, encDir, encAmt);

    // 4. Execute encrypted swap math against ENCRYPTED reserves
    euint128 actualOutput = _executeSwapMath(encDir, encAmt);

    // 5. Slippage check (encrypted)
    ebool slippageOk = FHE.gte(actualOutput, encMinOutput);
    euint128 finalOutput = FHE.select(slippageOk, actualOutput, ENC_ZERO);

    // 6. Credit user's output balance (branchless)
    _creditUserBalance(sender, encDir, finalOutput);

    // 7. If slippage failed, refund input (finalOutput is zero, so this is safe)
    euint128 refund = FHE.select(slippageOk, ENC_ZERO, encAmt);
    _creditUserBalance(sender, FHE.not(encDir), refund);  // Credit back to input token

    // 8. Request async reserve sync (non-blocking)
    _requestReserveSync();

    // 9. Return ZERO_DELTA - we handled everything via custom accounting
    return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}

function _debitUserBalance(address user, ebool direction, euint128 amount) internal {
    // Debit token0 if direction=true, else debit token1 (branchless)
    userBalanceToken0[user] = FHE.sub(
        userBalanceToken0[user],
        FHE.select(direction, amount, ENC_ZERO)
    );
    userBalanceToken1[user] = FHE.sub(
        userBalanceToken1[user],
        FHE.select(direction, ENC_ZERO, amount)
    );
}

function _creditUserBalance(address user, ebool direction, euint128 amount) internal {
    // Credit token1 if direction=true (sold token0, got token1), else credit token0
    userBalanceToken0[user] = FHE.add(
        userBalanceToken0[user],
        FHE.select(direction, ENC_ZERO, amount)
    );
    userBalanceToken1[user] = FHE.add(
        userBalanceToken1[user],
        FHE.select(direction, amount, ENC_ZERO)
    );
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

### Standardized Reserve Update Pattern

| Operation | Amount Known? | Update encReserve | Update reserve (cache) | Request Sync |
|-----------|---------------|-------------------|------------------------|--------------|
| Swap | ❌ No (encrypted) | ✅ Yes | ❌ No | ✅ Yes |
| Add Liquidity (ERC20) | ✅ Yes (plaintext) | ✅ Yes | ✅ Yes (direct) | ❌ No |
| Remove Liquidity (ERC20) | ✅ Yes (plaintext) | ✅ Yes | ✅ Yes (direct) | ❌ No |
| Deposit (fheERC20) | ❌ No (encrypted) | ✅ Yes | ❌ No | ✅ Yes |
| Withdraw (fheERC20) | ❌ No (encrypted) | ✅ Yes | ❌ No | ✅ Yes |

**Rule:** If the amount is known plaintext, update both reserves directly. If encrypted, only update encReserve and request async sync.

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

// Rate limiting for sync requests
uint256 public lastSyncBlock;
uint256 constant SYNC_COOLDOWN_BLOCKS = 5;  // Min blocks between syncs

function _requestReserveSync() internal {
    // Rate limit: don't request sync if one was recently requested
    if (block.number < lastSyncBlock + SYNC_COOLDOWN_BLOCKS) {
        return;  // Skip - too soon
    }

    // Request async decryption of current encrypted reserves
    pendingReserve0 = encReserve0;
    pendingReserve1 = encReserve1;
    FHE.decrypt(pendingReserve0);
    FHE.decrypt(pendingReserve1);

    lastSyncBlock = block.number;
}

function forceSyncReserves() external {
    // Allow anyone to force a sync (pays gas)
    // Useful if price display is very stale
    pendingReserve0 = encReserve0;
    pendingReserve1 = encReserve1;
    FHE.decrypt(pendingReserve0);
    FHE.decrypt(pendingReserve1);
    lastSyncBlock = block.number;
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

**Token Flow:** Users must have deposited tokens first. Placing an order debits their internal balance (no wallet transfer).

```solidity
function placeOrder(
    int24 triggerTick,
    InEbool calldata direction,
    InEuint128 calldata amount,
    InEuint128 calldata minOutput
) external payable nonReentrant {
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

    // Update tick bitmap
    if (ordersByTick[triggerTick].length == 0) {
        _flipTick(triggerTick);  // Mark tick as having orders
    }
    ordersByTick[triggerTick].push(nextOrderId);

    // Track user's orders for enumeration
    userOrders[msg.sender].push(nextOrderId);

    nextOrderId++;

    // Debit user's internal balance (branchless)
    // Tokens stay in hook, just reserved for this order
    _debitUserBalance(msg.sender, encDir, encAmt);

    emit OrderPlaced(nextOrderId - 1, msg.sender, triggerTick);
}

// Debit user balance based on direction (branchless)
function _debitUserBalance(address user, ebool direction, euint128 amount) internal {
    // If direction=true (zeroForOne), debit token0. Otherwise debit token1.
    userBalanceToken0[user] = FHE.sub(
        userBalanceToken0[user],
        FHE.select(direction, amount, ENC_ZERO)
    );
    userBalanceToken1[user] = FHE.sub(
        userBalanceToken1[user],
        FHE.select(direction, ENC_ZERO, amount)
    );
}
```

**Important:** Limit orders use the same internal balance system as swaps. Users deposit once, then can either swap or place limit orders against that balance.

### Trigger + Execute (TX 2 - Same Transaction as Swap)

When any swap crosses a limit order's trigger tick:

```solidity
uint8 constant MAX_FAILED_ATTEMPTS = 3;

struct Order {
    address owner;
    int24 triggerTick;
    ebool direction;
    euint128 amount;
    euint128 minOutput;
    bool active;
    uint8 failedAttempts;  // Track slippage failures
}

function _checkAndExecuteLimitOrders(address executor) internal {
    // Get price movement from this swap
    int24 tickBefore = _tickFromPrice(priceBefore);
    int24 tickAfter = _tickFromPrice(priceAfter);

    // Use TickBitmap to efficiently find ticks with orders
    _processOrdersInRange(tickBefore, tickAfter, executor);
}

function _processOrdersInRange(int24 tickStart, int24 tickEnd, address executor) internal {
    int24 lower = tickStart < tickEnd ? tickStart : tickEnd;
    int24 upper = tickStart < tickEnd ? tickEnd : tickStart;

    euint128 totalExecutorReward = ENC_ZERO;

    int24 tick = lower;
    while (tick <= upper) {
        // Use TickBitmap to find next tick with orders
        (int24 nextTick, bool found) = _nextTickWithOrders(tick, upper, true);
        if (!found) break;

        // Process all orders at this tick
        uint256[] storage orderIds = ordersByTick[nextTick];

        for (uint i = 0; i < orderIds.length; i++) {
            Order storage order = orders[orderIds[i]];
            if (!order.active) continue;

            // Execute order (encrypted math)
            euint128 orderOutput = _executeSwapMath(order.direction, order.amount);

            // Slippage check
            ebool slippageOk = FHE.gte(orderOutput, order.minOutput);

            // Branch on slippage result (we need to know if it passed)
            // This requires async decrypt - but we can use a different approach:
            // Always mark as filled, but zero out amounts if slippage failed
            euint128 finalOutput = FHE.select(slippageOk, orderOutput, ENC_ZERO);

            // If slippage failed, finalOutput is zero - no reward, no credit
            // But we still want to track the failed attempt

            // Calculate executor reward (1% of output, zero if slippage failed)
            euint128 reward = FHE.div(finalOutput, ENC_HUNDRED);
            euint128 ownerReceives = FHE.sub(finalOutput, reward);

            // Credit balances (zero if slippage failed)
            _creditUserBalance(order.owner, order.direction, ownerReceives);
            totalExecutorReward = FHE.add(totalExecutorReward, reward);

            // Mark order as filled
            // Note: If slippage failed, user got zero output but order is still consumed
            // This prevents gaming - order only triggers once per tick crossing
            order.active = false;

            // Clean up: remove from tick array
            _removeOrderFromTick(nextTick, i);
            i--;  // Adjust index after removal
        }

        // If no more orders at this tick, clear bitmap
        if (ordersByTick[nextTick].length == 0) {
            _flipTick(nextTick);
        }

        tick = nextTick + 1;
    }

    // Credit executor's balance with total rewards
    _creditUserBalance(executor, FHE.asEbool(true), totalExecutorReward);  // Credit as token1
}

function _removeOrderFromTick(int24 tick, uint256 index) internal {
    uint256[] storage orderIds = ordersByTick[tick];
    orderIds[index] = orderIds[orderIds.length - 1];
    orderIds.pop();
}
```

### Slippage Failure Handling

**Design Decision:** Orders are consumed on trigger, regardless of slippage outcome.

**Why?**
- Prevents gaming: Attacker can't repeatedly trigger orders to waste executor gas
- Each tick crossing triggers the order exactly once
- If slippage fails, user gets zero output but tokens are returned

**Alternative considered (rejected):**
```solidity
// DON'T DO THIS - allows gaming
order.failedAttempts++;
if (order.failedAttempts >= MAX_FAILED_ATTEMPTS) {
    order.active = false;
    // Return tokens
}
```
This approach was rejected because:
1. Attackers can still trigger MAX_FAILED_ATTEMPTS times
2. Each failed attempt wastes executor gas
3. Complex state management

**Current approach:** Single trigger, fill-or-return semantics.

If slippage fails:
- `finalOutput` = 0 (user gets nothing from the swap)
- Order is marked inactive
- User's original tokens (order.amount) need to be returned

```solidity
// Return tokens if slippage failed (branchless)
euint128 refundAmount = FHE.select(slippageOk, ENC_ZERO, order.amount);
_creditUserBalance(order.owner, order.direction, refundAmount);
```

**Key Points:**
- No separate "execute" call
- Trigger = Execute in same TX
- Order triggers once per tick crossing (no repeat attempts)
- Slippage failure returns tokens to user
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

    // Update display cache (amounts are plaintext, no sync needed)
    reserve0 -= amount0;
    reserve1 -= amount1;

    // Update LP position
    lpBalance[sender] = FHE.sub(lpBalance[sender], FHE.asEuint128(-params.liquidityDelta));

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

### Implementation (Using Transient Storage)

**Critical:** All direction lock state MUST use transient storage (EIP-1153) to auto-reset between transactions.

```solidity
// Transient storage slots (auto-reset each TX)
bytes32 constant HAS_SWAPPED_SLOT = keccak256("private.trade.has.swapped");
bytes32 constant FIRST_DIRECTION_SLOT = keccak256("private.trade.first.direction");

function _enforceDirectionLockEncrypted(ebool direction, euint128 amount)
    internal
    returns (euint128 adjustedAmount)
{
    bool hasSwapped;
    assembly { hasSwapped := tload(HAS_SWAPPED_SLOT) }

    if (!hasSwapped) {
        // First swap this TX - store encrypted direction handle
        // ebool is a uint256 handle under the hood
        uint256 dirHandle = ebool.unwrap(direction);
        assembly {
            tstore(HAS_SWAPPED_SLOT, 1)
            tstore(FIRST_DIRECTION_SLOT, dirHandle)
        }
        return amount;  // First swap always proceeds
    }

    // Subsequent swap - compare directions
    uint256 storedHandle;
    assembly { storedHandle := tload(FIRST_DIRECTION_SLOT) }
    ebool storedDirection = ebool.wrap(storedHandle);

    // If direction matches first swap, proceed. If different, zero out amount.
    ebool sameDirection = FHE.eq(storedDirection, direction);
    return FHE.select(sameDirection, amount, ENC_ZERO);
}
```

**How it works:**
1. First swap: Store direction handle in transient storage, return full amount
2. Subsequent swaps: Load stored direction, compare with new direction
3. If same direction: Return full amount (swap proceeds)
4. If different direction: Return zero amount (swap silently fails - no tokens moved)

**Why transient storage:**
- Automatically resets to zero at end of each transaction
- No manual cleanup needed
- Prevents cross-TX state exploitation
- Gas efficient (no SSTORE costs)

**Note on ebool handles:** FHE types like `ebool` are wrappers around `uint256` handles pointing to encrypted data. We store the raw handle in transient storage and reconstruct the `ebool` when needed.

---

## Executor Reward Mechanism

Executor reward is **added to executor's output**, not sent separately:

```solidity
// In _checkAndExecuteLimitOrders:
euint128 reward = FHE.div(orderOutput, ENC_HUNDRED);  // 1%
euint128 ownerReceives = FHE.sub(orderOutput, reward);

// Order owner gets output minus reward
_creditUserBalance(order.owner, order.direction, ownerReceives);

// Executor gets reward added to their swap output
totalExecutorReward = FHE.add(totalExecutorReward, reward);
```

This avoids relying on `msg.sender` or `tx.origin` for reward recipient.

### Incentive Considerations

**Current model:** 1% of order output goes to executor.

**Tradeoffs:**
| Aspect | Implication |
|--------|-------------|
| Large orders | More profitable to execute → prioritized |
| Small orders | Less profitable → may wait longer |
| Self-dealing | Placing and executing own order has no benefit (net zero) |
| Gas costs | Executor pays gas, reward must exceed gas cost to be profitable |

**Why this is acceptable for v3:**
1. All orders at triggered ticks execute in the same TX - no selective execution
2. Executors can't skip small orders to get to large ones (processed sequentially)
3. Natural equilibrium: high activity = more executors = faster fills

**Future improvements (v3.1):**
- Flat fee per order instead of percentage
- Minimum reward floor to ensure small orders are profitable
- Protocol-operated keeper for guaranteed execution

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
│   ├── ReserveSync.sol           # Eventual consistency logic
│   └── TickBitmap.sol            # Efficient tick lookup (256 ticks per word)
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

// Tracking array populated during placeOrder
mapping(address => uint256[]) public userOrders;

function getActiveOrders(address user) external view returns (uint256[] memory) {
    uint256[] storage allOrders = userOrders[user];

    // Count active orders first
    uint256 activeCount = 0;
    for (uint256 i = 0; i < allOrders.length; i++) {
        if (orders[allOrders[i]].active) {
            activeCount++;
        }
    }

    // Build result array
    uint256[] memory result = new uint256[](activeCount);
    uint256 j = 0;
    for (uint256 i = 0; i < allOrders.length; i++) {
        if (orders[allOrders[i]].active) {
            result[j++] = allOrders[i];
        }
    }

    return result;
}

function getOrderCount(address user) external view returns (uint256) {
    uint256 count = 0;
    uint256[] storage allOrders = userOrders[user];
    for (uint256 i = 0; i < allOrders.length; i++) {
        if (orders[allOrders[i]].active) {
            count++;
        }
    }
    return count;
}
```

**Note:** `userOrders` is populated during `placeOrder()` (see Limit Orders → Placement section).

### 2. Swap Fees
**Decision:** Standard swap fee (e.g., 0.3%) set at pool initialization.

```solidity
uint256 public immutable swapFeeBps;  // e.g., 30 = 0.3%
euint128 internal immutable ENC_SWAP_FEE_BPS;      // Cached encrypted fee
euint128 internal immutable ENC_FEE_DENOMINATOR;  // Cached 10000

constructor(address _token0, address _token1, uint256 _swapFeeBps) {
    // ...
    swapFeeBps = _swapFeeBps;
    ENC_SWAP_FEE_BPS = FHE.asEuint128(swapFeeBps);
    ENC_FEE_DENOMINATOR = FHE.asEuint128(10000);
}

function _executeSwapMath(...) internal {
    // Apply fee to amountIn before swap calculation
    // Formula: feeAmount = (amountIn * feeBps) / 10000
    //
    // Precision note: FHE.div truncates. For small amounts this could round to 0.
    // Example: 100 tokens * 30 bps / 10000 = 0.3 → truncates to 0
    //
    // This is acceptable because:
    // 1. Very small swaps paying no fee is negligible value loss
    // 2. Fee goes to LPs, not extracted - minor rounding benefits traders
    // 3. Alternative (higher precision) would cost more gas
    euint128 feeAmount = FHE.div(
        FHE.mul(amountIn, ENC_SWAP_FEE_BPS),
        ENC_FEE_DENOMINATOR
    );
    euint128 amountInAfterFee = FHE.sub(amountIn, feeAmount);
    // ... rest of swap math using amountInAfterFee
}
```

**Precision tradeoff:** FHE division truncates, so very small swaps may pay zero fees. This is acceptable because the lost fee value is negligible and benefits traders slightly. Higher precision alternatives would increase gas costs significantly.

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

## Resolved Questions (Continued)

### 5. Gas Limits on Tick Loops
**Decision:** Use TickBitmap (inspired by Uniswap v3) for efficient tick lookup.

**Problem:** When price moves from tick 100 to tick 1000, naively iterating through all 900 ticks to find orders is expensive (900 storage reads).

**Solution:** Pack 256 ticks into a single `uint256` bitmap. Each bit represents whether a tick has orders.

```solidity
// Each int16 word covers 256 ticks
// Word 0: ticks 0-255, Word 1: ticks 256-511, Word -1: ticks -256 to -1
mapping(int16 => uint256) public orderBitmap;

function _position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
    wordPos = int16(tick >> 8);      // tick / 256
    bitPos = uint8(uint24(tick) % 256);
}

function _flipTick(int24 tick) internal {
    (int16 wordPos, uint8 bitPos) = _position(tick);
    orderBitmap[wordPos] ^= (1 << bitPos);  // XOR toggles the bit
}

function _hasOrdersAtTick(int24 tick) internal view returns (bool) {
    (int16 wordPos, uint8 bitPos) = _position(tick);
    return (orderBitmap[wordPos] & (1 << bitPos)) != 0;
}
```

**Finding next tick with orders:**

```solidity
function _nextTickWithOrders(
    int24 tick,
    int24 maxTick,
    bool searchingUp
) internal view returns (int24 next, bool found) {
    (int16 wordPos, uint8 bitPos) = _position(tick);

    if (searchingUp) {
        // Mask: all bits ABOVE current position
        uint256 mask = ~((1 << bitPos) - 1) << 1;
        uint256 masked = orderBitmap[wordPos] & mask;

        if (masked != 0) {
            // Found in same word - get lowest set bit
            uint8 nextBit = _leastSignificantBit(masked);
            next = int24(int16(wordPos) * 256 + int24(uint24(nextBit)));
            return (next, next <= maxTick);
        }

        // Search subsequent words
        wordPos++;
        while (wordPos <= int16(maxTick >> 8)) {
            if (orderBitmap[wordPos] != 0) {
                uint8 nextBit = _leastSignificantBit(orderBitmap[wordPos]);
                next = int24(int16(wordPos) * 256 + int24(uint24(nextBit)));
                return (next, next <= maxTick);
            }
            wordPos++;
        }
    }
    // Similar logic for searching down
    return (0, false);
}
```

**Processing orders in range:**

```solidity
function _processOrdersInRange(int24 tickLower, int24 tickUpper, bool zeroForOne) internal {
    int24 tick = tickLower;
    while (tick <= tickUpper) {
        (int24 next, bool hasOrders) = _nextTickWithOrders(tick, tickUpper, true);
        if (!hasOrders) break;

        _executeOrdersAtTick(next, zeroForOne);
        tick = next + 1;
    }
}
```

**Why this is efficient:**
- **Single SLOAD covers 256 ticks** - One storage read tells you about 256 ticks
- **Bit manipulation is cheap** - AND, OR, XOR are single opcodes (~3 gas each)
- **Skip empty ranges** - If a 256-tick word is 0, skip it entirely
- **Proven pattern** - Battle-tested in Uniswap v3

**Example:** Price moves from tick 100 to tick 1000 (900 ticks)
- Naive: 900 storage reads = 900 × 2100 gas = 1,890,000 gas
- TickBitmap: ~4 storage reads (4 words) = 4 × 2100 gas = 8,400 gas

**Order placement/cancellation updates:**

```solidity
function placeOrder(int24 triggerTick, ...) external {
    // ... store order ...

    // If first order at this tick, set bit
    if (ordersByTick[triggerTick].length == 1) {
        _flipTick(triggerTick);
    }
}

function cancelOrder(uint256 orderId) external {
    // ... cancel logic ...

    // If last order at this tick, clear bit
    if (ordersByTick[order.triggerTick].length == 0) {
        _flipTick(order.triggerTick);
    }
}
```

### 6. Partial Fills
**Decision:** Partial fills are NOT supported in v3.

Orders fill completely or not at all. This simplifies:
- No tracking of `filled` amount
- No complex slippage-per-fill logic
- Cleaner order state (active → inactive)

Large orders should be split into multiple smaller orders at adjacent ticks if needed.

---

## All Questions Resolved

All design decisions have been made. Ready for implementation.
