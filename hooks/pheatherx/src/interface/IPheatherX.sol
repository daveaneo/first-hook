// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint128, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title IPheatherX
/// @notice Interface for PheatherX - a private execution layer built on FHE
interface IPheatherX {
    // ============ Events ============

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event DepositEncrypted(address indexed user, address indexed token, euint128 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event WithdrawEncrypted(address indexed user, address indexed token, euint128 amount);

    event OrderPlaced(uint256 indexed orderId, address indexed owner, int24 triggerTick);
    event OrderCancelled(uint256 indexed orderId, address indexed owner);
    event OrderFilled(uint256 indexed orderId, address indexed owner, address indexed executor);

    event ReserveSyncRequested(uint256 blockNumber);
    event ReservesSynced(uint256 reserve0, uint256 reserve1);

    // ============ Errors ============

    error InsufficientBalance();
    error InsufficientFee();
    error OrderNotFound();
    error OrderNotActive();
    error NotOrderOwner();
    error InvalidTick();
    error ZeroAmount();

    // ============ Structs ============

    struct Order {
        address owner;
        int24 triggerTick;
        ebool direction;      // true = zeroForOne
        euint128 amount;
        euint128 minOutput;
        bool active;
    }

    // ============ View Functions ============

    /// @notice Get the public (cached) reserves
    function getReserves() external returns (uint256 reserve0, uint256 reserve1);

    /// @notice Get a user's encrypted balance for token0
    function getUserBalanceToken0(address user) external view returns (euint128);

    /// @notice Get a user's encrypted balance for token1
    function getUserBalanceToken1(address user) external view returns (euint128);

    /// @notice Get all active order IDs for a user
    function getActiveOrders(address user) external view returns (uint256[] memory);

    /// @notice Get the count of active orders for a user
    function getOrderCount(address user) external view returns (uint256);

    /// @notice Check if a tick has orders
    function hasOrdersAtTick(int24 tick) external view returns (bool);

    // ============ User Functions ============

    /// @notice Deposit tokens into the hook
    /// @param isToken0 True to deposit token0, false for token1
    /// @param amount Amount to deposit
    function deposit(bool isToken0, uint256 amount) external;

    /// @notice Withdraw tokens from the hook
    /// @param isToken0 True to withdraw token0, false for token1
    /// @param amount Amount to withdraw
    function withdraw(bool isToken0, uint256 amount) external;

    /// @notice Place a limit order
    /// @param triggerTick The tick at which the order triggers
    /// @param direction Encrypted direction (true = sell token0 for token1)
    /// @param amount Encrypted amount to sell
    /// @param minOutput Encrypted minimum output for slippage protection
    function placeOrder(
        int24 triggerTick,
        ebool direction,
        euint128 amount,
        euint128 minOutput
    ) external payable returns (uint256 orderId);

    /// @notice Cancel an active order
    /// @param orderId The ID of the order to cancel
    function cancelOrder(uint256 orderId) external;

    /// @notice Force a reserve sync (anyone can call, pays gas)
    function forceSyncReserves() external;
}
