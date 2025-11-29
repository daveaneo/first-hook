# FHE-Protected Trading on Uniswap v4

## The Elevator Pitch

> **Trade on Uniswap without anyone knowing what you're trading.**
>
> Using Fully Homomorphic Encryption (FHE), we encrypt your swap direction, amount, and strategy. The blockchain executes your trade *without ever decrypting it*. MEV bots see only encrypted bytes—no information to front-run, no alpha to extract.
>
> Combined with probe attack prevention via transient storage locks and gas side-channel protection through branchless execution, this hook provides comprehensive MEV protection for Uniswap v4.

---

## Two Trading Modes

Our hook supports both **immediate swaps** and **limit orders**, each with full privacy:

| Mode | Use Case | Execution | Privacy |
|------|----------|-----------|---------|
| **Immediate Swap** | "Trade now, privately" | Single TX, instant | Direction + amount encrypted |
| **Limit Order** | "Trade when price hits X" | Place now, execute later | Direction + amount encrypted, trigger price public |

Both modes share the same MEV protections: encrypted calldata, probe attack prevention, and branchless execution.

---

## Document Overview

This document analyzes MEV attack vectors against encrypted trading hooks on Uniswap v4 using Fhenix FHE, and presents practical mitigations.

---

## The Core Problem: Your Trade Intent Is Valuable Alpha

When you submit a trade to a public blockchain, you're broadcasting:

| Information Leaked | What Attackers Learn |
|--------------------|---------------------|
| Direction (buy/sell) | Your market view |
| Size | Magnitude of your conviction |
| Limit price | What you consider fair value |
| Timing | When you need to execute |

This information is **valuable alpha**. Hedge funds pay millions for order flow data. MEV bots exploit it in real-time.

The result:
- **Front-running:** Bots buy before you, driving up your price
- **Back-running:** Bots sell after you, profiting from your price impact
- **Sandwich attacks:** Both, atomically, risk-free for the attacker

**You pay more. Attackers profit. This is the MEV tax on every trade.**

---

## The Solution: Fully Homomorphic Encryption (FHE)

**What if the blockchain couldn't read your trade?**

FHE allows computation on encrypted data without decryption. Using Fhenix's FHE-enabled blockchain:

```
Traditional swap:
  Mempool sees: swap(BUY, 10000 USDC → ETH)
  Attacker: "I'll front-run this"

FHE-encrypted swap:
  Mempool sees: takeAction(0x8f3a2b7c...)
  Attacker: "???"
```

The direction, amount, and strategy remain encrypted throughout execution. The blockchain processes your trade **without ever knowing what it is**.

### How It Works

```solidity
function takeAction(
    einput encryptedDirection,  // Buy or sell? Encrypted.
    einput encryptedAmount,     // How much? Encrypted.
    bytes calldata inputProof
) external {
    // Decode into FHE types - still encrypted
    ebool isBuy = TFHE.asEbool(encryptedDirection, inputProof);
    euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);

    // Execute on encrypted values - no one sees the actual trade
    _executeEncrypted(isBuy, amount);
}
```

### The Result

| Before (Public) | After (FHE) |
|-----------------|-------------|
| Bots see your order | Bots see encrypted bytes |
| Front-running profitable | Front-running impossible (no information) |
| You pay MEV tax | You pay fair price |

---

## But Encryption Alone Isn't Enough

FHE hides your intent, but sophisticated attackers can still probe. This document covers the remaining attack vectors and their solutions:

---

## Attack Vector 1: Traditional Front-Running

### The Problem
Standard swaps expose intent in the mempool:
```
Mempool sees: swap(tokenIn=USDC, tokenOut=ETH, amount=10000)
Attacker knows: "They're buying ETH" → Front-runs
```

### Solution: Encrypted Calldata
```solidity
function takeAction(
    einput encryptedDirection,
    einput encryptedAmount,
    bytes calldata inputProof
) external {
    ebool isBuy = TFHE.asEbool(encryptedDirection, inputProof);
    euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);
    _executeEncrypted(isBuy, amount);
}
```

Mempool sees only: `takeAction(0x8f3a2b...)`

No direction, no amount, no strategy to exploit.

---

## Attack Vector 2: Probe Attacks

### The Problem
Even with encrypted intent, attackers can blindly probe:

```solidity
contract ProbeAttack {
    function attack(pool) external {
        pool.swap(BUY, ...);
        pool.swap(SELL, ...);
        require(profit > 0, "revert if unprofitable");
    }
}
```

The attacker doesn't need to know your order exists. They speculatively sandwich and revert if it doesn't work. Cost of failure = only gas.

### Solution: Transient Storage Direction Lock
```solidity
bytes32 constant DIRECTION_SLOT = keccak256("direction.lock");

function beforeSwap(...) external {
    uint256 locked = tload(DIRECTION_SLOT);
    uint256 dir = params.zeroForOne ? 1 : 2;

    require(locked == 0 || locked == dir, "No direction reversal");

    tstore(DIRECTION_SLOT, dir);
}
```

**Why this works:**
- Transient storage persists for the entire transaction
- Scoped to the hook contract (attackers can't manipulate it)
- Resets automatically after TX
- No account management needed - global lock is sufficient

**Result:** If anyone buys, nobody can sell in the same TX. Atomic probe attacks become impossible.

---

## Attack Vector 3: Gas Side-Channel

### The Problem
FHE operations cost gas. If different code paths have different costs, gas usage could reveal intent:

```solidity
// DANGEROUS - leaks information
if (TFHE.decrypt(isBuy)) {
    doBuyStuff();      // 50k gas
} else {
    doSellStuff();     // 80k gas
}
```

### Solution: Branchless Execution
```solidity
// SAFE - constant gas regardless of direction
euint64 buyResult = computeBuy(amount);
euint64 sellResult = computeSell(amount);
euint64 finalResult = TFHE.select(isBuy, buyResult, sellResult);
```

**Key principles:**
1. Never decrypt mid-execution to branch
2. Always compute both paths
3. Use `TFHE.select` to choose the result
4. Keep operations symmetric

**Note:** FHE operations are constant-cost for encrypted values. `TFHE.add(x, 1)` costs the same as `TFHE.add(x, 999999)`.

---

## Attack Vector 4: Multi-TX Coordination

### The Problem
Direction lock only works within a single TX. Attacker with builder relationships could coordinate across TXs in the same block:

```
Block N, TX 1: Attacker buys (lock resets after TX)
Block N, TX 2: Attacker sells (fresh TX, fresh lock)
```

### Mitigation
This is **partially mitigated** because:
- Attack is no longer atomic
- Attacker cannot use revert-if-unprofitable across TXs
- Attacker must commit real capital with real risk
- Price may move between TXs

**Residual risk:** Attackers with block builder collusion can still coordinate, but at actual financial risk.

---

## Attack Vector 5: Cross-Pool Arbitrage

### The Problem
Attacker routes around your protection:

```solidity
function attack() external {
    protectedPool.swap(BUY, ...);   // Buy on your pool
    vanillaPool.swap(SELL, ...);    // Sell on unprotected pool
}
```

### Mitigation
This is a **general MEV problem**, not specific to your hook. If liquidity exists elsewhere, arbitrage is possible.

**Partial solutions:**
- Deep liquidity in your pool reduces external arbitrage profitability
- Encrypted execution makes it harder to know when arbitrage is available

---

## Comparison: Our Approach vs iceberg-cofhe

[iceberg-cofhe](https://github.com/marronjo/iceberg-cofhe) is an existing FHE limit order implementation on Uniswap v4. Here's how our approach differs:

### Architecture Comparison

| Aspect | iceberg-cofhe | Our Hook |
|--------|---------------|----------|
| **Trading modes** | Limit orders only | Immediate swaps + limit orders |
| **FHE execution** | Coprocessor (async, callbacks) | On-chain native (sync, single TX) |
| **User transactions** | 1 TX to place, execution triggered by others | 1 TX for immediate, 1 TX to place limits |
| **Probe attack prevention** | Not implemented | Transient storage direction lock |
| **Gas side-channel protection** | Not visible | Branchless execution |

### Execution Model Difference

**iceberg-cofhe (Coprocessor Pattern):**
```
TX1: User places encrypted limit order → stored, waiting

[Price moves via other swaps]

TX2: afterSwap() detects price crossed → requests decryption from coprocessor

[Off-chain: coprocessor decrypts]

TX3: beforeSwap() checks decryption ready → executes order
```
User does 1 TX. Execution requires 2+ subsequent TXs from other users, plus off-chain coprocessor.

**Our Hook (On-Chain Native FHE):**
```
Immediate swap:
TX1: swapNow(encrypted) → executes immediately → done

Limit order:
TX1: placeOrder(encrypted) → stored, waiting
TX2+: Price crosses → executes in same TX (no coprocessor callback)
```

### Why This Architecture Matters

With Fhenix CoFHE, **encrypted operations** (`FHE.add()`, `FHE.select()`, etc.) execute synchronously. Only **decryption** (`FHE.decrypt()`) requires async callbacks.

This enables:
1. **Immediate private swaps** - execute entirely in encrypted domain, single TX
2. **Branchless execution** - `FHE.select()` is sync, no callback needed
3. **Minimal decryption** - only decrypt when revealing to user (withdrawal)

iceberg-cofhe decrypts to check order fill conditions. We stay encrypted longer.

### What We Add

| Feature | iceberg-cofhe | Our Hook |
|---------|:-------------:|:--------:|
| Encrypted limit orders | ✅ | ✅ |
| Immediate private swaps | ❌ | ✅ |
| Probe attack prevention | ❌ | ✅ |
| Gas side-channel protection | ❌ | ✅ |
| Single-TX execution | ❌ | ✅ |

---

## Complete Hook Pattern

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TFHE, einput, ebool, euint64} from "@fhenix/fhevm/lib/TFHE.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";

contract PrivateTradingHook is BaseHook {
    bytes32 constant DIRECTION_SLOT = keccak256("direction.lock");

    // ==================== ENCRYPTED STATE ====================

    euint64 private encryptedBalanceA;
    euint64 private encryptedBalanceB;

    // Limit order storage: user => tick => encrypted order
    mapping(address => mapping(int24 => EncryptedOrder)) private limitOrders;

    struct EncryptedOrder {
        ebool direction;    // Encrypted: buy or sell
        euint64 amount;     // Encrypted: how much
        bool exists;
    }

    // ==================== IMMEDIATE SWAPS ====================

    /// @notice Execute a private swap immediately
    /// @dev Direction and amount are encrypted - MEV bots see nothing
    function swapNow(
        einput encryptedDirection,
        einput encryptedAmount,
        bytes calldata inputProof
    ) external {
        // 1. Anti-probe: only one action per TX
        _enforceActionLock();

        // 2. Decode encrypted inputs (still encrypted after decode)
        ebool isBuy = TFHE.asEbool(encryptedDirection, inputProof);
        euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);

        // 3. Branchless execution (constant gas, no side-channel)
        _executeEncrypted(msg.sender, isBuy, amount);
    }

    // ==================== LIMIT ORDERS ====================

    /// @notice Place a private limit order
    /// @param triggerTick Public: the price level to trigger at
    /// @param encryptedDirection Private: buy or sell
    /// @param encryptedAmount Private: how much
    function placeOrder(
        int24 triggerTick,
        einput encryptedDirection,
        einput encryptedAmount,
        bytes calldata inputProof
    ) external {
        ebool direction = TFHE.asEbool(encryptedDirection, inputProof);
        euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);

        limitOrders[msg.sender][triggerTick] = EncryptedOrder({
            direction: direction,
            amount: amount,
            exists: true
        });
    }

    /// @notice Cancel a limit order
    function cancelOrder(int24 triggerTick) external {
        delete limitOrders[msg.sender][triggerTick];
    }

    // ==================== HOOK CALLBACKS ====================

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override {
        // Check if price crossed any limit order triggers
        // Execute triggered orders with same protections
        int24 currentTick = _getCurrentTick(key);
        _processTriggeredOrders(currentTick);
    }

    // ==================== CORE LOGIC ====================

    function _enforceActionLock() internal {
        uint256 locked;
        bytes32 slot = DIRECTION_SLOT;
        assembly { locked := tload(slot) }

        require(locked == 0, "One action per TX");

        assembly { tstore(slot, 1) }
    }

    function _executeEncrypted(
        address user,
        ebool isBuy,
        euint64 amount
    ) internal {
        // Compute BOTH paths (constant gas - no side-channel leak)
        euint64 newBalA_buy = TFHE.sub(encryptedBalanceA, amount);
        euint64 newBalA_sell = TFHE.add(encryptedBalanceA, amount);

        euint64 newBalB_buy = TFHE.add(encryptedBalanceB, amount);
        euint64 newBalB_sell = TFHE.sub(encryptedBalanceB, amount);

        // Select based on encrypted condition - direction never revealed
        encryptedBalanceA = TFHE.select(isBuy, newBalA_buy, newBalA_sell);
        encryptedBalanceB = TFHE.select(isBuy, newBalB_buy, newBalB_sell);

        // Update user balances (also encrypted)
        _updateUserBalance(user, isBuy, amount);
    }

    function _processTriggeredOrders(int24 currentTick) internal {
        // For each triggered order at currentTick:
        // - Apply same direction lock (anti-probe)
        // - Execute with branchless logic (anti-gas-leak)
        // - Clear the order
    }

    function _updateUserBalance(
        address user,
        ebool isBuy,
        euint64 amount
    ) internal {
        // Branchless balance update for user
        // Implementation depends on token accounting model
    }

    function _getCurrentTick(PoolKey calldata key) internal view returns (int24) {
        // Get current tick from pool
    }
}
```

---

## Remaining Open Issues

| Issue | Severity | Notes |
|-------|----------|-------|
| Block builder collusion | Medium | Multi-TX attacks possible but not atomic |
| Cross-pool arbitrage | Low | General MEV problem, not hook-specific |
| Fhenix mainnet readiness | TBD | Testnet available, production timing unclear |
| Direction lock + encrypted direction | Design | Need to reconcile - see note below |

### Design Note: Direction Lock with Encrypted Direction

There's a tension: if direction is encrypted, how do we enforce direction lock?

**Options:**

#### Option 1: Single-Action Lock (Simplest)
One `takeAction` per TX regardless of direction:
```solidity
uint256 locked = _tload(DIRECTION_SLOT);
require(locked == 0, "One action per TX");
_tstore(DIRECTION_SLOT, 1);
```
**Pros:** Trivial to implement, no FHE overhead for the check.
**Cons:** Blocks even same-direction multi-swaps (rarely needed in practice).

#### Option 2: FHE Direction Comparison (Recommended)
Store last direction as encrypted state, compare using FHE, decrypt only the boolean result:

```solidity
bytes32 constant LAST_DIR_SLOT = keccak256("last.direction");
bytes32 constant HAS_TRADED_SLOT = keccak256("has.traded");

function takeAction(
    einput encryptedDirection,
    einput encryptedAmount,
    bytes calldata inputProof
) external {
    ebool isBuy = TFHE.asEbool(encryptedDirection, inputProof);

    // Load transient encrypted state
    ebool lastDir = _tloadEbool(LAST_DIR_SLOT);
    ebool traded = _tloadEbool(HAS_TRADED_SLOT);

    // FHE comparison - all encrypted
    ebool sameDir = TFHE.eq(isBuy, lastDir);
    ebool allowed = TFHE.or(TFHE.not(traded), sameDir);

    // Decrypt ONLY the "allowed" boolean
    // This reveals: "was the check passed?" - NOT the direction itself
    require(TFHE.decrypt(allowed), "No direction reversal");

    // Store encrypted state for next call in this TX
    _tstoreEbool(LAST_DIR_SLOT, isBuy);
    _tstoreEbool(HAS_TRADED_SLOT, TFHE.asEbool(true));

    _executeEncrypted(isBuy, TFHE.asEuint64(encryptedAmount, inputProof));
}
```

**What's revealed:** Only that the check passed or failed (which the attacker already knows from the revert).
**What stays hidden:** The actual direction of both trades.

**Pros:**
- Direction remains fully encrypted
- Allows multiple same-direction swaps if needed
- Minimal information leakage

**Cons:**
- Additional FHE operations (minor gas overhead)
- Requires transient storage for encrypted types

#### Option 3: Decrypt Direction Only
Decrypt the direction bit but keep amount encrypted. Partial privacy leak.

**Not recommended** - if you're going to leak direction, Option 1 is simpler.

### Recommendation

For most use cases, **Option 1 (single-action lock)** is sufficient. Normal trades don't need multiple swaps per TX, and the simplicity is valuable.

If you specifically need to allow multiple same-direction swaps while blocking reversals, **Option 2 (FHE comparison)** provides full privacy with minimal leakage.

---

## Summary: Defense in Depth

| Layer | Technique | Attack Blocked |
|-------|-----------|----------------|
| 1 | FHE-encrypted calldata | Mempool front-running |
| 2 | Transient storage direction lock | Atomic probe attacks |
| 3 | Branchless FHE execution | Gas side-channel leaks |
| 4 | Non-atomic execution risk | Multi-TX coordination (partial) |

---

## Why This Matters

**For traders:** Execute without paying the MEV tax. Your strategy stays private.

**For DAOs:** Rebalance treasuries without signaling intent to the market.

**For protocols:** Run liquidation auctions without telegraphing desperation.

**For the ecosystem:** Reduce the ~$1B+ extracted annually by MEV bots.

---

## Technical Stack

- **Uniswap v4 Hooks:** Native integration with the largest DEX
- **Fhenix CoFHE:** FHE coprocessor for encrypted computation
- **EIP-1153 Transient Storage:** Per-TX state for probe prevention
- **Branchless Solidity:** Constant-gas execution patterns

---

## Technical Note: FHE Execution Models

After researching Fhenix's architecture, here's an important clarification on FHE execution:

### Fhenix CoFHE (Coprocessor Model)

Fhenix uses an **FHE Coprocessor (CoFHE)** - an off-chain computation layer that processes encrypted data:

```
Host Chain → Invoke coprocessor → Off-chain FHE computation → Result returned → Host chain continues
```

**Characteristics:**
- Heavy FHE operations offloaded to coprocessor
- Secured via EigenLayer restaking (cryptoeconomic guarantees)
- Avoids 7-day fraud proof window via operator attestations
- Currently live on Arbitrum

### What This Means for Our Design

Both iceberg-cofhe and our hook would use the same underlying Fhenix infrastructure. The difference is in **what we do with it**:

| Aspect | iceberg-cofhe | Our Hook |
|--------|---------------|----------|
| **Decryption timing** | Decrypt to check order fill | Minimize decryption, stay encrypted |
| **Execution flow** | Multi-step with explicit decrypt requests | Single logical operation where possible |
| **Probe protection** | None | Transient storage lock |
| **Gas side-channel** | Not addressed | Branchless execution |

### Our Innovation Is Not "On-Chain vs Off-Chain"

Our innovation is:
1. **Probe attack prevention** - transient storage direction lock
2. **Gas side-channel protection** - branchless execution
3. **Immediate swaps** - not just limit orders
4. **Unified design** - both modes with consistent protections

These are **application-level** innovations that work regardless of whether FHE runs on-chain or via coprocessor.

### Synchronous vs Asynchronous Operations (Confirmed)

From [Fhenix CoFHE documentation](https://cofhe-docs.fhenix.zone/docs/devdocs/overview) and [cofhe-foundry-mocks](https://github.com/FhenixProtocol/cofhe-foundry-mocks):

**Synchronous (single TX):**
- `FHE.add()`, `FHE.sub()`, `FHE.mul()`
- `FHE.eq()`, `FHE.lt()`, `FHE.gt()`
- `FHE.select()` - encrypted conditional selection
- `FHE.and()`, `FHE.or()`, `FHE.not()`
- All encrypted arithmetic and comparison operations

**Asynchronous (requires callback via `IAsyncFHEReceiver`):**
- `FHE.decrypt()` - reveals plaintext, needs threshold decryption network
- `FHE.sealoutput()` - prepares encrypted value for client-side unsealing

### What This Means for Our Design

**Good news:** `FHE.select()` is synchronous! This is the key operation for branchless execution.

```solidity
// This ALL happens in a single transaction:
euint64 buyResult = FHE.sub(balance, amount);
euint64 sellResult = FHE.add(balance, amount);
euint64 newBalance = FHE.select(isBuy, buyResult, sellResult);  // ✅ Sync!
```

**The constraint:** If we need to **decrypt** a value (reveal plaintext on-chain), that requires a callback. But our design minimizes decryption:

| Operation | Needs Decrypt? | Single TX? |
|-----------|----------------|------------|
| Immediate swap execution | No - stays encrypted | ✅ Yes |
| Direction lock check (Option 1) | No - just block action | ✅ Yes |
| Direction lock check (Option 2) | Yes - decrypt boolean | ❌ No |
| Limit order trigger detection | Depends on design | Maybe |
| User balance withdrawal | Yes - must reveal amount | ❌ No |

### Revised Immediate Swap Design

For truly single-TX immediate swaps, use **Option 1 (single-action lock)**:

```solidity
function swapNow(einput encDirection, einput encAmount, bytes calldata proof) external {
    // 1. Simple action lock - no decryption needed
    require(_tload(ACTION_SLOT) == 0, "One action per TX");
    _tstore(ACTION_SLOT, 1);

    // 2. Decode (still encrypted)
    ebool isBuy = FHE.asEbool(encDirection, proof);
    euint64 amount = FHE.asEuint64(encAmount, proof);

    // 3. Branchless execution - all sync operations
    euint64 newBalA_buy = FHE.sub(encryptedBalanceA, amount);
    euint64 newBalA_sell = FHE.add(encryptedBalanceA, amount);
    encryptedBalanceA = FHE.select(isBuy, newBalA_buy, newBalA_sell);  // ✅ Sync

    // ... same for balanceB and user balances
}
```

**Result:** True single-TX private swaps with probe protection. No callbacks needed.

---

## References

- [Fhenix Official](https://www.fhenix.io/)
- [FHE Coprocessors: Fhenix & EigenLayer](https://www.fhenix.io/fhe-coprocessors-fhenix-eigenlayer-join-forces-for-next-gen-onchain-confidentiality/)
- [Fhenix on Arbitrum](https://blog.arbitrum.io/fhenix-private-computation/)
- [iceberg-cofhe](https://github.com/marronjo/iceberg-cofhe)

---

**Built for the Atrium Hookathon.**
