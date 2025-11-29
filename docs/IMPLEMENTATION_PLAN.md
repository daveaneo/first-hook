# Private Trading Hook - Implementation Plan

## Overview

Build a MEV-protected trading hook for Uniswap v4 using Fhenix FHE that supports:
1. **Immediate Private Swaps** - Trade now with encrypted direction/amount
2. **Private Limit Orders** - All standard limit order types with encrypted parameters

## Current State Analysis

### What iceberg-cofhe Has
- Basic limit orders (trigger at tick)
- Encrypted direction and amount
- Async execution via coprocessor

### What iceberg-cofhe Is Missing
- Immediate swaps
- Probe attack prevention (direction lock)
- Gas side-channel protection (branchless execution)
- Stop-loss orders
- Take-profit orders
- Order cancellation
- Partial fills tracking

---

## Limit Order Types to Support

| Order Type | Description | Trigger Condition |
|------------|-------------|-------------------|
| **Limit Buy** | Buy when price drops to target | price ≤ targetPrice |
| **Limit Sell** | Sell when price rises to target | price ≥ targetPrice |
| **Stop-Loss** | Sell to cut losses when price drops | price ≤ stopPrice |
| **Take-Profit** | Sell to lock gains when price rises | price ≥ targetPrice |
| **Stop-Limit** | Limit order activated by stop price | stopPrice triggers, then limit executes |

All order types share the same encrypted interface - only the trigger logic differs.

---

## Implementation Phases

### Phase 1: Core Infrastructure
**Files to create:**
```
hooks/private-trading-hook/
├── src/
│   ├── PrivateTradingHook.sol      # Main hook contract
│   ├── lib/
│   │   ├── DirectionLock.sol        # Transient storage direction lock
│   │   ├── OrderTypes.sol           # Order type definitions
│   │   └── BranchlessExecution.sol  # FHE branchless helpers
│   └── interface/
│       └── IPrivateTradingHook.sol  # Interface definitions
├── test/
│   ├── PrivateTradingHook.t.sol     # Main test file
│   ├── ImmediateSwap.t.sol          # Immediate swap tests
│   ├── LimitOrders.t.sol            # Limit order tests
│   └── SecurityTests.t.sol          # Import exploit tests
└── foundry.toml
```

### Phase 2: Immediate Swaps
**Function:** `swapNow()`
```solidity
function swapNow(
    PoolKey calldata key,
    einput encryptedDirection,    // Encrypted: buy or sell
    einput encryptedAmount,       // Encrypted: how much
    bytes calldata inputProof
) external;
```

**Features:**
- Single-TX execution
- Encrypted direction and amount
- Direction lock (anti-probe)
- Branchless execution (anti-gas-leak)

### Phase 3: Private Limit Orders
**Function:** `placeOrder()`
```solidity
function placeOrder(
    PoolKey calldata key,
    int24 triggerTick,            // Public: price level
    OrderType orderType,          // Public: limit/stop-loss/take-profit
    einput encryptedDirection,    // Encrypted: buy or sell
    einput encryptedAmount,       // Encrypted: how much
    bytes calldata inputProof
) external returns (uint256 orderId);
```

**Order Types Enum:**
```solidity
enum OrderType {
    LIMIT,          // Standard limit order
    STOP_LOSS,      // Trigger when price falls below
    TAKE_PROFIT,    // Trigger when price rises above
    STOP_LIMIT      // Stop triggers limit order
}
```

### Phase 4: Order Management
**Functions:**
```solidity
function cancelOrder(uint256 orderId) external;
function modifyOrder(uint256 orderId, einput newAmount, bytes calldata proof) external;
function getOrder(uint256 orderId) external view returns (OrderInfo memory);
function getUserOrders(address user) external view returns (uint256[] memory);
```

### Phase 5: Hook Callbacks
**beforeSwap:**
- Enforce direction lock
- Execute ready limit orders
- Apply branchless execution

**afterSwap:**
- Check for triggered orders
- Queue orders for execution
- Update tick tracking

---

## Security Features Implementation

### 1. Direction Lock (Anti-Probe)
```solidity
// lib/DirectionLock.sol
library DirectionLock {
    bytes32 constant DIRECTION_SLOT = keccak256("private.trading.direction.lock");

    function enforce() internal {
        uint256 locked;
        assembly { locked := tload(DIRECTION_SLOT) }
        require(locked == 0, "One action per TX");
        assembly { tstore(DIRECTION_SLOT, 1) }
    }

    function isLocked() internal view returns (bool) {
        uint256 locked;
        assembly { locked := tload(DIRECTION_SLOT) }
        return locked != 0;
    }
}
```

### 2. Branchless Execution (Anti-Gas-Leak)
```solidity
// lib/BranchlessExecution.sol
library BranchlessExecution {
    function selectBalance(
        ebool condition,
        euint128 balance,
        euint128 amount
    ) internal returns (euint128) {
        // Compute BOTH paths
        euint128 ifTrue = FHE.sub(balance, amount);
        euint128 ifFalse = FHE.add(balance, amount);
        // Select without branching
        return FHE.select(condition, ifTrue, ifFalse);
    }
}
```

### 3. Encrypted Order Storage
```solidity
struct EncryptedOrder {
    address owner;
    int24 triggerTick;
    OrderType orderType;
    ebool direction;      // Encrypted
    euint128 amount;      // Encrypted
    euint128 filled;      // Encrypted (for partial fills)
    bool active;
}
```

---

## Data Structures

### Order Storage
```solidity
// Order ID => Order details
mapping(uint256 => EncryptedOrder) public orders;

// User => Order IDs
mapping(address => uint256[]) public userOrders;

// Pool => Tick => Order IDs at that tick
mapping(PoolId => mapping(int24 => uint256[])) public tickOrders;

// Order ID counter
uint256 public nextOrderId;
```

### Epoch/Batch System (from iceberg-cofhe)
Keep the epoch system for batching orders at the same tick level, but add:
- Order type tracking
- Individual order status
- Partial fill support

---

## Test Plan

### Existing Tests (from exploit tests)
Copy and adapt the exploit tests to verify our hook passes them:

```solidity
// test/SecurityTests.t.sol
contract SecurityTests is Test {
    // These should PASS for our hook (FAIL for iceberg-cofhe)
    function test_ProbeAttackBlocked() external;
    function test_DirectionReversalBlocked() external;
    function test_ConstantGasConsumption() external;

    // These should PASS for both
    function test_SameDirectionAllowed() external;
    function test_OrderFunctionUsesEncryptedTypes() external;
}
```

### New Tests Needed

#### Immediate Swap Tests
```solidity
// test/ImmediateSwap.t.sol
function test_SwapNowExecutesImmediately() external;
function test_SwapNowWithEncryptedDirection() external;
function test_SwapNowWithEncryptedAmount() external;
function test_SwapNowUpdatesBalances() external;
function test_SwapNowEmitsEvents() external;
```

#### Limit Order Tests
```solidity
// test/LimitOrders.t.sol

// Basic limit orders
function test_PlaceLimitBuyOrder() external;
function test_PlaceLimitSellOrder() external;
function test_LimitOrderTriggersAtTick() external;
function test_LimitOrderExecutesCorrectly() external;

// Stop-loss orders
function test_PlaceStopLossOrder() external;
function test_StopLossTriggersOnPriceDrop() external;
function test_StopLossDoesNotTriggerOnPriceRise() external;

// Take-profit orders
function test_PlaceTakeProfitOrder() external;
function test_TakeProfitTriggersOnPriceRise() external;
function test_TakeProfitDoesNotTriggerOnPriceDrop() external;

// Order management
function test_CancelOrder() external;
function test_CancelOrderRefundsTokens() external;
function test_ModifyOrderAmount() external;
function test_GetUserOrders() external;

// Edge cases
function test_MultipleOrdersAtSameTick() external;
function test_PartialFillTracking() external;
function test_OrderExpirationIfImplemented() external;
```

#### Integration Tests
```solidity
// test/Integration.t.sol
function test_ImmediateSwapThenLimitOrder() external;
function test_LimitOrderThenImmediateSwap() external;
function test_MultipleUsersMultipleOrders() external;
function test_HighVolumeOrderProcessing() external;
```

---

## Migration from iceberg-cofhe

### Code to Reuse
1. `EpochLibrary.sol` - Epoch management
2. `Queue.sol` - Decryption queue
3. `HybridFHERC20.sol` - FHE token interface
4. Test utilities (`Fixtures.sol`, `EasyPosm.sol`, etc.)

### Code to Modify
1. `Iceberg.sol` → `PrivateTradingHook.sol`
   - Add direction lock
   - Add branchless execution
   - Add immediate swaps
   - Add order types
   - Add order management

### Code to Add
1. `DirectionLock.sol` - New
2. `BranchlessExecution.sol` - New
3. `OrderTypes.sol` - New
4. All new test files

---

## Implementation Order

1. **Setup project structure**
   - Create directory structure
   - Copy dependencies from iceberg-cofhe
   - Setup foundry.toml and remappings

2. **Implement DirectionLock library**
   - Transient storage helpers
   - Unit tests

3. **Implement basic PrivateTradingHook**
   - Constructor and hook permissions
   - Direction lock in beforeSwap

4. **Implement swapNow()**
   - Encrypted inputs
   - Branchless execution
   - Tests

5. **Implement placeOrder()**
   - All order types
   - Order storage
   - Tests

6. **Implement order execution**
   - afterSwap trigger detection
   - beforeSwap execution
   - Tests

7. **Implement order management**
   - cancelOrder
   - modifyOrder
   - getUserOrders
   - Tests

8. **Security validation**
   - Run all exploit tests (should pass)
   - Gas consumption analysis
   - Edge case testing

9. **Documentation**
   - Update FHE_MEV_Protection_Analysis.md
   - Add usage examples
   - API documentation

---

## Success Criteria

### Security Tests (Must Pass)
- [ ] `test_ProbeAttackBlocked` - Direction reversal blocked
- [ ] `test_DirectionReversalBlocked` - Buy→sell in same TX reverts
- [ ] `test_ConstantGasConsumption` - Gas difference < 1000

### Functional Tests (Must Pass)
- [ ] Immediate swaps execute correctly
- [ ] Limit buy orders trigger at correct price
- [ ] Limit sell orders trigger at correct price
- [ ] Stop-loss orders trigger on price drop
- [ ] Take-profit orders trigger on price rise
- [ ] Order cancellation works
- [ ] Withdrawal returns correct amounts

### Performance
- [ ] Gas usage reasonable for all operations
- [ ] No excessive storage costs
- [ ] Batch execution efficient

---

## Timeline Estimate

| Phase | Tasks | Complexity |
|-------|-------|------------|
| 1 | Project setup, copy dependencies | Low |
| 2 | Direction lock library | Low |
| 3 | Basic hook structure | Medium |
| 4 | Immediate swaps | Medium |
| 5 | Limit orders | High |
| 6 | Order execution | High |
| 7 | Order management | Medium |
| 8 | Security validation | Medium |
| 9 | Documentation | Low |

---

## Open Questions

1. **Partial Fills**: Should we support partial fills for limit orders?
   - Adds complexity but more realistic for large orders
   - iceberg-cofhe does batch fills at epoch level

2. **Order Expiration**: Should orders have expiration timestamps?
   - Prevents stale orders
   - Adds gas cost for expiry checks

3. **Fee Structure**: Should placing/canceling orders have fees?
   - Prevents spam
   - May discourage legitimate use

4. **Oracle Integration**: Should stop-loss use external price oracles?
   - More accurate triggers
   - Adds external dependency

---

## Next Steps

1. Review this plan and get feedback
2. Decide on open questions
3. Begin Phase 1 implementation
