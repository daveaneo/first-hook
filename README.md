# Learning Hooks - Uniswap v4 Hook Examples

A collection of educational Uniswap v4 hooks demonstrating various concepts from basic to advanced. Each hook is self-contained with its own documentation and tests.

## Repository Structure

```
learning-hooks/
├── hooks/                          # All hook implementations
│   ├── points-hook/               # Basic: Rewards system with ERC-1155
│   ├── points-hook-broken/        # Educational: Intentionally broken hook
│   ├── flash-loan-hook/           # Advanced: Flash loans with auto-compounding
│   └── gas-price-fees-hook/       # Intermediate: Dynamic fees based on gas prices
├── ideas/                         # Unimplemented hook concepts
├── lib/                           # Shared dependencies (Uniswap v4, Forge)
└── README.md                      # This file
```

## Available Hooks

| Hook | Difficulty | Concepts | Description |
|------|-----------|----------|-------------|
| [points-hook](hooks/points-hook/) | ⭐ Basic | `afterSwap`, ERC-1155, hookData | Rewards system that mints point tokens to swappers |
| [points-hook-broken](hooks/points-hook-broken/) | ⭐ Basic | Permission errors, debugging | Intentionally broken to teach permission matching |
| [gas-price-fees-hook](hooks/gas-price-fees-hook/) | ⭐⭐ Intermediate | Dynamic fees, moving average, gas price oracle | Adjusts swap fees based on network gas prices |
| [flash-loan-hook](hooks/flash-loan-hook/) | ⭐⭐⭐ Advanced | Multiple hooks, flash loans, ERC-4626, unlock pattern | Flash loan provider with auto-compounding yields |

## Quick Start

### Build All Hooks
```bash
forge build
```

### Test All Hooks
```bash
forge test -vv
```

### Test a Specific Hook
```bash
forge test --match-path hooks/points-hook/test/PointsHook.t.sol -vv
```

## Hook Summaries

### 1. Points Hook
**Level:** Beginner
**File:** `hooks/points-hook/`

A simple rewards system that demonstrates:
- Basic `afterSwap` hook implementation
- ERC-1155 token integration
- Using `hookData` to pass user information
- Working with `BalanceDelta` to calculate swap amounts

Users receive point tokens equal to 20% of the ETH they spend when swapping. Perfect for learning the basics of hooks.

[Read more →](hooks/points-hook/README.md)

---

### 2. Points Hook (Broken)
**Level:** Beginner
**File:** `hooks/points-hook-broken/`

An educational example that shows what happens when you get hook permissions wrong:
- Declares `beforeSwap: true` but doesn't implement `_beforeSwap`
- Demonstrates `HookNotImplemented` error
- Teaches the importance of matching permissions to implementation

A common mistake turned into a learning opportunity!

[Read more →](hooks/points-hook-broken/README.md)

---

### 3. Gas Price Fees Hook
**Level:** Intermediate
**File:** `hooks/gas-price-fees-hook/`

A dynamic fee hook that adjusts swap fees based on network congestion:
- Dynamic fee pools with `DYNAMIC_FEE_FLAG`
- Moving average gas price tracking
- Fee override mechanism in `beforeSwap`
- Gas price-based fee adjustment (lower fees during high gas, higher fees during low gas)
- Real-time state updates in `afterSwap`

Demonstrates how to create responsive fee structures that adapt to network conditions. Users are incentivized to trade during low-congestion periods.

[Read more →](hooks/gas-price-fees-hook/README.md)

---

### 4. Flash Loan Hook
**Level:** Advanced
**File:** `hooks/flash-loan-hook/`

A comprehensive flash loan provider demonstrating:
- Multiple hook lifecycle events (`afterAddLiquidity`, `afterRemoveLiquidity`)
- ERC-4626 vault pattern for share accounting
- Uniswap v4 unlock callback pattern with take/settle/clear
- Auto-compounding yields (fees increase share value automatically)
- Transient storage (EIP-1153) for flash accounting

Liquidity providers earn automatically compounding yields from flash loan fees. This hook showcases advanced Uniswap v4 concepts.

[Read more →](hooks/flash-loan-hook/README.md)

## Learning Path

**Recommended order:**

1. **Start with points-hook**
   Learn basic hook structure, permissions, and the `afterSwap` lifecycle event.

2. **Study points-hook-broken**
   Understand common mistakes and error handling.

3. **Explore gas-price-fees-hook**
   Learn about dynamic fees, moving averages, and fee override mechanisms.

4. **Tackle flash-loan-hook**
   Dive into advanced concepts like flash loans, share accounting, and the unlock pattern.

## Hook Concepts Covered

### Basic Concepts
- ✅ Hook permissions and `getHookPermissions()`
- ✅ Lifecycle hooks (`afterSwap`, `afterAddLiquidity`, `afterRemoveLiquidity`)
- ✅ `BalanceDelta` and interpreting token flows
- ✅ `hookData` for passing parameters
- ✅ Pool keys and pool IDs

### Intermediate Concepts
- ✅ Token integration (ERC-1155)
- ✅ Swap direction (`zeroForOne` vs `oneForZero`)
- ✅ ETH vs ERC20 handling
- ✅ Error handling and debugging
- ✅ Dynamic fee pools and `DYNAMIC_FEE_FLAG`
- ✅ Fee override mechanism with `OVERRIDE_FEE_FLAG`
- ✅ Moving average calculations onchain
- ✅ Gas price tracking (`tx.gasprice`)
- ✅ State management for metrics

### Advanced Concepts
- ✅ Flash loans in Uniswap v4
- ✅ Unlock callback pattern
- ✅ Take/settle/clear operations
- ✅ Transient storage (EIP-1153)
- ✅ ERC-4626 vault pattern
- ✅ Auto-compounding yields
- ✅ Share-based accounting

## Future Hook Ideas

See [`ideas/`](ideas/) for concepts not yet implemented:
- Dynamic fees and opportunistic rebalancing

## Development

### Dependencies
- [Foundry](https://book.getfoundry.sh/)
- [Uniswap v4 Core](https://github.com/Uniswap/v4-core)
- [Uniswap v4 Periphery](https://github.com/Uniswap/v4-periphery)

### Project Configuration
- Solidity: 0.8.26
- EVM: Cancun
- Optimizer: 800 runs
- Test framework: Forge

### Adding a New Hook

1. Create directory: `hooks/your-hook-name/`
2. Add subdirectories: `src/` and `test/`
3. Implement your hook in `src/YourHook.sol`
4. Write tests in `test/YourHook.t.sol`
5. Create `README.md` documenting your hook
6. Run `forge build` and `forge test` to verify

The monorepo structure will automatically detect your new hook!

## Resources

- [Uniswap v4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [Uniswap v4 Core Repository](https://github.com/Uniswap/v4-core)
- [Foundry Book](https://book.getfoundry.sh/)
- [EIP-1153: Transient Storage](https://eips.ethereum.org/EIPS/eip-1153)
- [ERC-4626: Tokenized Vaults](https://eips.ethereum.org/EIPS/eip-4626)

## Contributing

Feel free to:
- Add new educational hooks
- Improve documentation
- Add more test cases
- Propose new hook ideas in `ideas/`

## License

MIT
