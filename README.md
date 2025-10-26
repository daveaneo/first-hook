# Uniswap v4 Hooks

This repository contains three Uniswap v4 hooks demonstrating different functionality.

## FlashLoanHook

A flash loan provider that allows borrowers to borrow tokens from pool liquidity and repay within the same transaction. Liquidity providers automatically earn compounding yields from flash loan fees without needing to claim or restake.

## PointsHook

A rewards system that mints ERC-1155 point tokens to users when they swap ETH for tokens. Points are awarded equal to 20% of the ETH spent and are tracked per pool.

## PointsHookBroken

A deliberately broken hook that declares `beforeSwap` permission but doesn't implement the function. This demonstrates what happens when hook permissions don't match implementation - swaps fail with `HookNotImplemented` error.
