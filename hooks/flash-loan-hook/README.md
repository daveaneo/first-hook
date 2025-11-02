# Flash Loan Hook

A Uniswap v4 hook that provides flash loan functionality with auto-compounding yields for liquidity providers. This is a comprehensive example demonstrating advanced hook concepts and the Uniswap v4 unlock callback pattern.

## Overview

This hook transforms any Uniswap v4 pool into a flash loan provider where:
- **Liquidity providers** earn auto-compounding yields from flash loan fees
- **Borrowers** can flash loan tokens from the pool's liquidity
- **Fees** automatically compound without requiring any action from LPs

## How It Works

### 1. Liquidity Tracking (ERC-4626 Vault Pattern)

When users add/remove liquidity:
1. Hook tracks deposits in `afterAddLiquidity`
2. Mints shares proportional to the deposit (like ERC-4626 vault)
3. When users withdraw, burns shares and returns tokens + accumulated fees

**Example:**
```
Alice deposits 100 tokens → gets 100 shares (1:1 ratio, first depositor)
Bob deposits 100 tokens → gets 100 shares (total: 200 tokens, 200 shares)
```

### 2. Flash Loan Execution

Borrowers can flash loan any currency from the pool:
```solidity
flashLoan(poolId, currency, amount, recipient, data)
```

The flow:
1. Hook validates loan is possible
2. Hook calls `poolManager.unlock()` → triggers `unlockCallback()`
3. Inside callback:
   - `take()` sends tokens to borrower (creates debt)
   - Borrower's `onFlashLoan()` callback executes (must repay + fee)
   - `settle()` clears the debt
   - `clear()` locks the fee in the pool
4. Fee increases `lendingPoolAssets` without minting shares = **auto-compounding!**

### 3. Auto-Compounding Mechanism

**This is the magic:**
```
Before flash loan:
- Total assets: 200 tokens
- Total shares: 200 shares
- Each share worth: 200/200 = 1.0 tokens

Flash loan charges 2 token fee:
- Total assets: 202 tokens (fee added!)
- Total shares: 200 shares (unchanged!)
- Each share worth: 202/200 = 1.01 tokens

Alice withdraws 100 shares → gets 101 tokens (1% gain!)
Bob withdraws 100 shares → gets 101 tokens (1% gain!)
```

No new shares are minted when fees come in, so existing shares become more valuable!

## Key Features

### Multiple Hook Permissions
```solidity
afterAddLiquidity: true     // Track deposits and mint shares
afterRemoveLiquidity: true  // Track withdrawals and burn shares
```

Only these two hooks are enabled, keeping the contract focused on liquidity tracking.

### Uniswap v4 Unlock Pattern

This hook demonstrates the unlock callback pattern:
- **Transient storage** (EIP-1153) tracks debts within a transaction
- `take()` creates negative delta (debt)
- `settle()` pays off debt
- `clear()` handles positive balance
- All deltas must be zero when `unlock()` ends

**Why?** Gas efficiency! Only net balance changes are settled, not individual movements.

### IFlashLoanReceiver Interface

Borrowers must implement:
```solidity
function onFlashLoan(
    address initiator,
    Currency currency,
    uint256 amount,
    uint256 fee,
    bytes calldata data
) external returns (bytes4);
```

This ensures borrowers can use the funds and repay in one transaction.

## Code Highlights

### Share Calculation (First vs Later Deposits)
```solidity
// First depositor: 1:1 ratio
if (totalShares == 0) return assets;

// Later depositors: proportional
return (assets * totalShares) / totalAssets;
```

### Flash Loan Settlement (ERC20)
```solidity
poolManager.sync(currency);              // 1. Checkpoint balance
currency.transfer(poolManager, repay);   // 2. Send repayment
poolManager.settle();                    // 3. Clear debt
poolManager.clear(currency, fee);        // 4. Lock fee in pool
```

### Auto-Compounding
```solidity
// Key line: Add fee to assets WITHOUT minting shares
lendingPoolAssets[poolId][currency] += fee;
```

## Testing

Run the comprehensive test suite:

```bash
forge test --match-path hooks/flash-loan-hook/test/FlashLoanHook.t.sol -vv
```

Tests include:
- Deposit and withdrawal with share accounting
- Flash loan execution and repayment
- Auto-compounding yield verification
- Error cases (insufficient balance, non-repayment, etc.)

## Learning Objectives

This hook teaches:

### Core Concepts
1. **ERC-4626 vault pattern** for share-based accounting
2. **Flash loans** and their implementation in Uniswap v4
3. **Unlock callback pattern** with take/settle/clear
4. **Transient storage** (EIP-1153) and flash accounting
5. **Auto-compounding yields** without active management

### Advanced Hook Techniques
6. **Multiple lifecycle hooks** (`afterAddLiquidity`, `afterRemoveLiquidity`)
7. **BalanceDelta interpretation** (negative = user deposited, positive = user withdrew)
8. **HookData usage** to identify the real user (vs router address)
9. **Access control** with owner-only functions
10. **Event emissions** for off-chain tracking

### Uniswap v4 Specific
11. **PoolManager.unlock()** flow and why it's required
12. **sync() before settle()** for ERC20 tokens
13. **Currency handling** (both ERC20 and native ETH)
14. **Delta management** and why deltas must sum to zero

## Architecture

### State Variables
- `lendingPoolAssets` - Total tokens in lending pool per (poolId, currency)
- `userShares` - User's share ownership per (poolId, currency, user)
- `totalShares` - Total shares issued per (poolId, currency)
- `flashLoanFeeRate` - Fee in basis points (e.g., 10 = 0.1%)

### Key Functions

**User-facing:**
- `flashLoan()` - Borrow tokens with a fee

**Hook callbacks:**
- `_afterAddLiquidity()` - Track deposits, mint shares
- `_afterRemoveLiquidity()` - Track withdrawals, burn shares
- `unlockCallback()` - Execute flash loan (called by PoolManager)

**View functions:**
- `previewDeposit()` - Calculate shares for a deposit
- `previewWithdraw()` - Calculate tokens for shares
- `getUserBalance()` - Get user's token value

**Admin:**
- `setFeeRate()` - Adjust flash loan fee (owner only)

## Real-World Applications

This pattern could be used for:
1. **Flash loan aggregators** - Compete with Aave, dYdX for best rates
2. **Yield optimization** - LPs earn swap fees + flash loan fees
3. **Capital efficiency** - Same liquidity serves swaps AND loans
4. **Arbitrage infrastructure** - MEV searchers can borrow from any pool
5. **Liquidation bots** - Borrow to liquidate undercollateralized positions

## Security Considerations

- Flash loan borrowers must implement callback correctly
- Repayment verification via callback return value
- Owner can adjust fees (consider timelock in production)
- Share math must prevent rounding exploits
- First depositor advantage (consider minimum deposit)

## Gas Optimization

- Uses transient storage (EIP-1153) for flash accounting
- Minimal state updates (only shares + assets tracked)
- No ERC20 token minting (shares stored in mapping)
- settle/clear pattern avoids unnecessary token movements

## Related Files

- Source: `src/FlashLoanHook.sol` (729 lines)
- Tests: `test/FlashLoanHook.t.sol` (580 lines)
- Mock Helper: `test/MockFlashLoanReceiver.sol` (74 lines)

## Comparison to Other Hooks

- **points-hook**: Simple, single hook (`afterSwap`)
- **points-hook-broken**: Demonstrates permission errors
- **flash-loan-hook**: Complex, multiple hooks, advanced patterns ⭐

## Next Steps

After mastering this hook:
1. Study the test file to see all edge cases
2. Try modifying the fee structure (dynamic fees?)
3. Add access control for who can borrow
4. Implement flash loan aggregation across multiple pools
5. Build an arbitrage bot that uses these flash loans

## Resources

- [EIP-1153: Transient Storage](https://eips.ethereum.org/EIPS/eip-1153)
- [ERC-4626: Tokenized Vaults](https://eips.ethereum.org/EIPS/eip-4626)
- [Uniswap v4 Hooks Documentation](https://docs.uniswap.org/contracts/v4/overview)
- Flash loan concepts: Aave, dYdX implementations
