# Take Profits Hook

A Uniswap V4 hook that enables users to place take-profit limit orders on liquidity pools.

## Overview

The Take Profits Hook allows users to automatically sell tokens when prices reach specified tick levels. It combines BaseHook and ERC1155 to manage conditional swap orders in an orderbook-like mechanism on-chain.

## Core Features

### Order Management
- **Place Orders**: Users can create pending orders at specific price ticks
- **Cancel Orders**: Users can cancel unexecuted orders and receive token refunds
- **Redeem**: Users can claim output tokens once orders are executed

### Execution Logic
The hook monitors tick movements via the `afterSwap` hook. When market price crosses specified thresholds, orders are automatically executed and output tokens become claimable proportionally to each user's claim token balance.

## How It Works

### Design Approach: Ticks Over Sqrt Prices
The implementation uses ticks at valid spacings rather than sqrt prices for gas efficiency. Using sqrt prices would require too many loop iterations, making ticks the superior choice.

### Three Main Components
1. **Placing Orders**: Users specify a tick price, direction, and input amount
2. **Canceling Orders**: Users can remove orders before execution and get refunds
3. **Redeeming**: Users withdraw output tokens from executed orders

### Storage
- `pendingOrders` - Maps pool/tick/direction to accumulated input amounts
- `claimableOutputTokens` - Tracks available output for each order
- `claimTokensSupply` - Maintains total claim token supply per order
- Claim tokens (ERC1155) represent user positions in pending orders

## Key Assumptions
- Gas costs and execution limits are disregarded
- Slippage requirements are ignored during implementation
- Only ERC20-to-ERC20 pools are supported (no native ETH)

## Implementation Details

The contract handles both increasing and decreasing tick scenarios:
- **Tick Increases** (Token 0 price increases): Executes orders looking to sell Token 0
- **Tick Decreases** (Token 1 price increases): Executes orders looking to sell Token 1

Orders are executed automatically during swaps, and the hook ensures all balances are properly settled with the Pool Manager.

## Source
Based on [haardikk21/take-profits-hook](https://github.com/haardikk21/take-profits-hook)
