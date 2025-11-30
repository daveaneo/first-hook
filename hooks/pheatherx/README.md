# PheatherX

**PheatherX** is a private execution layer built on FHE and engineered within the Fhenix ecosystem. Its custom Uniswap v4 hook replaces public swap paths with encrypted balance accounting, ensuring that trade direction, size, and intent remain hidden from all observers.

*Named after the phoenix feather — a symbol of silent, precise movement — PheatherX delivers institutional-grade privacy without sacrificing atomicity, performance, or trustlessness.*

## Overview

PheatherX enables users to:
- **Deposit tokens** into encrypted balances stored in the hook
- **Place encrypted limit orders** with hidden direction, amount, and slippage
- **Execute private swaps** where trade details are never revealed on-chain
- **Cancel orders** and receive funds back to encrypted balance

All sensitive operations use Fully Homomorphic Encryption (FHE), meaning trade direction and amounts remain encrypted throughout the entire lifecycle.

## Features

### Core Functionality
- **Encrypted User Balances**: Token balances stored as FHE ciphertexts (`euint128`)
- **Encrypted Limit Orders**: Order direction (`ebool`), amount (`euint128`), and minOutput (`euint128`) all encrypted
- **Custom Accounting**: Returns `ZERO_DELTA` from `beforeSwap` to bypass Uniswap's AMM - all accounting done internally
- **Automatic Order Fills**: Orders execute when price crosses trigger tick

### Security Features
- **Direction Lock**: Transient storage (EIP-1153) prevents probe attacks by ensuring only one swap direction per transaction
- **Slippage Protection**: Encrypted comparison ensures minimum output requirements
- **Constant-Time Execution**: Uses `FHE.select()` for branchless operations to prevent timing attacks
- **Reentrancy Protection**: All user-facing functions protected with `nonReentrant`

### Efficiency
- **TickBitmap**: Uniswap v3's bitmap pattern for O(1) tick lookup within 256-tick words
- **Cached FHE Constants**: `ENC_ZERO`, `ENC_ONE`, etc. stored as immutables for gas efficiency
- **Rate-Limited Reserve Sync**: 5-block cooldown prevents excessive decryption requests

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        PheatherX                            │
├─────────────────────────────────────────────────────────────┤
│  Encrypted State                                            │
│  ├── userBalanceToken0[user] → euint128                    │
│  ├── userBalanceToken1[user] → euint128                    │
│  ├── encReserve0, encReserve1 → euint128                   │
│  └── orders[id].direction, amount, minOutput → encrypted   │
├─────────────────────────────────────────────────────────────┤
│  Public State (Display Cache)                               │
│  ├── reserve0, reserve1 → uint256 (eventually consistent)  │
│  └── orderBitmap → tick lookup                             │
├─────────────────────────────────────────────────────────────┤
│  Hook Callbacks                                             │
│  ├── beforeSwap → Execute encrypted swap, return ZERO_DELTA│
│  ├── afterSwap → Process triggered limit orders            │
│  ├── beforeAddLiquidity → Update encrypted reserves        │
│  └── beforeRemoveLiquidity → Update encrypted reserves     │
└─────────────────────────────────────────────────────────────┘
```

## Installation

```bash
# Clone the repository
git clone <repo-url>
cd pheatherx

# Install dependencies
forge install
npm install

# Build
forge build

# Run tests
forge test
```

## Usage

### Depositing Tokens

```solidity
// Approve hook first
token0.approve(address(hook), amount);

// Deposit token0
hook.deposit(true, amount);  // true = token0

// Deposit token1
hook.deposit(false, amount); // false = token1
```

### Placing a Limit Order

```solidity
// Create encrypted parameters
ebool direction = FHE.asEbool(true);        // true = zeroForOne
euint128 amount = FHE.asEuint128(100 ether);
euint128 minOutput = FHE.asEuint128(95 ether);

// Allow hook to use encrypted values
FHE.allow(direction, address(hook));
FHE.allow(amount, address(hook));
FHE.allow(minOutput, address(hook));

// Place order with protocol fee
uint256 orderId = hook.placeOrder{value: 0.001 ether}(
    triggerTick,  // int24: tick at which order triggers
    direction,
    amount,
    minOutput
);
```

### Cancelling an Order

```solidity
hook.cancelOrder(orderId);
// Funds returned to encrypted balance
```

### Withdrawing Tokens

```solidity
hook.withdraw(true, amount);  // Withdraw token0
hook.withdraw(false, amount); // Withdraw token1
```

## Deployment

### Local Testing (Anvil)

```bash
# Start Anvil
anvil

# Deploy
forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Testnet Deployment

1. Update `script/DeployPheatherX.s.sol` with:
   - `POOL_MANAGER` address for target network
   - `TOKEN0` and `TOKEN1` addresses

2. Set environment variables:
   ```bash
   export PRIVATE_KEY=<your-private-key>
   export RPC_URL=<network-rpc-url>
   ```

3. Deploy:
   ```bash
   forge script script/DeployPheatherX.s.sol --rpc-url $RPC_URL --broadcast
   ```

> **Note**: For production deployments, use `HookMiner` to find a CREATE2 salt that produces a hook address with correct flag bits.

## Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| `PROTOCOL_FEE` | 0.001 ETH | Fee for placing limit orders |
| `SYNC_COOLDOWN_BLOCKS` | 5 | Minimum blocks between reserve syncs |
| `EXECUTOR_REWARD_BPS` | 100 (1%) | Reward for executing orders |
| `swapFeeBps` | Configurable | Swap fee in basis points |

## Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vv

# Run specific test
forge test --match-test testDepositToken0

# Run with gas report
forge test --gas-report
```

### Test Coverage

| Category | Tests |
|----------|-------|
| Deposits | 4 |
| Withdrawals | 4 |
| Limit Orders | 5 |
| Cancel Orders | 4 |
| Balance Tracking | 2 |
| Reserve Tracking | 2 |
| Multi-User | 4 |
| Order State | 2 |
| TickBitmap | 6 |
| Order Fill Logic | 6 |
| Admin Functions | 4 |
| Edge Cases | 3 |
| **Total** | **46** |

## Admin Functions

### Withdraw Protocol Fees

```solidity
// Only owner
hook.withdrawProtocolFees(payable(recipient));
```

### Emergency Token Recovery

```solidity
// Only owner, cannot recover pool tokens (token0/token1)
hook.emergencyTokenRecovery(tokenAddress, recipient, amount);
```

## Security Considerations

1. **FHE Trust Model**: Security relies on Fhenix's CoFHE network for encrypted computation
2. **Reserve Sync Delay**: Public reserves are eventually consistent, not real-time
3. **Order Visibility**: Trigger ticks are public; only amounts/directions are encrypted
4. **Gas Costs**: FHE operations are computationally expensive

## License

MIT

## Acknowledgments

- [Uniswap v4](https://github.com/Uniswap/v4-core) - Hook architecture
- [Fhenix](https://fhenix.io) - FHE implementation
- [OpenZeppelin](https://openzeppelin.com) - Security utilities
