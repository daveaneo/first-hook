// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FlashLoanHook, IFlashLoanReceiver} from "../src/FlashLoanHook.sol";
import "forge-std/console.sol";

/// @notice Mock flash loan receiver that properly repays the loan
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function onFlashLoan(
        address initiator,
        Currency currency,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes4) {
        // Verify tokens were received from poolManager.take()
        require(currency.balanceOfSelf() >= amount, "Did not receive flash loan");

        console.log("MockReceiver: Received", amount, "tokens");
        console.log("MockReceiver: Fee required", fee);

        // In a real use case, borrower would:
        // 1. Use the tokens (trade, arbitrage, etc.)
        // 2. Make profit to cover the fee
        // For testing, we assume this contract was pre-funded with fee

        // Calculate total repayment
        uint256 repayAmount = amount + fee;

        // Verify we have enough to repay
        require(currency.balanceOfSelf() >= repayAmount, "Insufficient balance to repay");

        // Transfer amount + fee back to the HOOK (msg.sender)
        // The hook will then settle the debt with PoolManager
        currency.transfer(msg.sender, repayAmount);

        console.log("MockReceiver: Repaid", repayAmount, "tokens to Hook");

        return IFlashLoanReceiver.onFlashLoan.selector;
    }

    // Helper to fund this contract with tokens for fee payment
    function fundWithTokens(Currency currency, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
    }

    // Allow receiving ETH
    receive() external payable {}
}

/// @notice Malicious receiver that doesn't repay
contract MaliciousFlashLoanReceiver is IFlashLoanReceiver {
    function onFlashLoan(
        address initiator,
        Currency currency,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes4) {
        // Don't repay - just return success
        return IFlashLoanReceiver.onFlashLoan.selector;
    }
}
