// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Uniswap Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// Fhenix Imports
import {
    FHE,
    InEuint128,
    euint128,
    InEbool,
    ebool
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

// OpenZeppelin Imports
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Local Imports
import {TickBitmap} from "./lib/TickBitmap.sol";
import {DirectionLock} from "./lib/DirectionLock.sol";
import {IPheatherX} from "./interface/IPheatherX.sol";

/// @title PheatherX
/// @notice A private execution layer built on FHE within the Fhenix ecosystem
/// @dev PheatherX replaces public swap paths with encrypted balance accounting,
///      ensuring that trade direction, size, and intent remain hidden from all observers.
///      Named after the phoenix feather — a symbol of silent, precise movement.
contract PheatherX is BaseHook, ReentrancyGuard, IPheatherX {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using TickBitmap for mapping(int16 => uint256);

    // ============ Constants ============

    uint256 public constant PROTOCOL_FEE = 0.001 ether; // Fee for placing limit orders
    uint256 public constant SYNC_COOLDOWN_BLOCKS = 5;   // Min blocks between reserve syncs
    uint256 public constant EXECUTOR_REWARD_BPS = 100;  // 1% executor reward

    // ============ Immutables ============

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint256 public immutable swapFeeBps;
    address public immutable owner;

    // Cached encrypted constants (set in constructor for gas efficiency)
    euint128 public immutable ENC_ZERO;
    euint128 public immutable ENC_ONE;
    euint128 public immutable ENC_HUNDRED;
    euint128 public immutable ENC_TEN_THOUSAND;
    euint128 public immutable ENC_SWAP_FEE_BPS;

    // ============ State Variables ============

    // Encrypted reserves (source of truth)
    euint128 internal encReserve0;
    euint128 internal encReserve1;

    // Public reserves (display cache, eventually consistent)
    uint256 public reserve0;
    uint256 public reserve1;

    // Reserve sync state
    uint256 public lastSyncBlock;
    euint128 internal pendingReserve0;
    euint128 internal pendingReserve1;

    // Tick tracking for order fills
    int24 public lastTickLower;

    // User balances (encrypted)
    mapping(address => euint128) public userBalanceToken0;
    mapping(address => euint128) public userBalanceToken1;

    // Limit orders
    mapping(uint256 => Order) public orders;
    mapping(int24 => uint256[]) public ordersByTick;
    mapping(address => uint256[]) public userOrders;
    uint256 public nextOrderId = 1;

    // Tick bitmap for efficient order lookup
    mapping(int16 => uint256) public orderBitmap;

    // Track initialized users (for FHE balance initialization)
    mapping(address => bool) private userInitialized;

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _token0,
        address _token1,
        uint256 _swapFeeBps
    ) BaseHook(_poolManager) {
        require(_token0 < _token1, "Tokens must be sorted");

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        swapFeeBps = _swapFeeBps;
        owner = msg.sender;

        // Cache encrypted constants
        ENC_ZERO = FHE.asEuint128(0);
        ENC_ONE = FHE.asEuint128(1);
        ENC_HUNDRED = FHE.asEuint128(100);
        ENC_TEN_THOUSAND = FHE.asEuint128(10000);
        ENC_SWAP_FEE_BPS = FHE.asEuint128(_swapFeeBps);

        // Initialize encrypted reserves
        encReserve0 = ENC_ZERO;
        encReserve1 = ENC_ZERO;

        // Allow FHE operations on cached values
        FHE.allowThis(ENC_ZERO);
        FHE.allowThis(ENC_ONE);
        FHE.allowThis(ENC_HUNDRED);
        FHE.allowThis(ENC_TEN_THOUSAND);
        FHE.allowThis(ENC_SWAP_FEE_BPS);
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,  // We return custom deltas
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Hook Callbacks ============

    function _beforeSwap(
        address sender,
        PoolKey calldata /* key */,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // 1. Extract or encrypt swap parameters
        (ebool encDir, euint128 encAmt, euint128 encMinOutput) = _extractOrEncryptParams(params, hookData);

        // 2. Direction lock (encrypted)
        euint128 adjustedAmount = DirectionLock.enforceDirectionLock(encDir, encAmt, ENC_ZERO);

        // 3. Debit user's input balance
        _debitUserBalance(sender, encDir, adjustedAmount);

        // 4. Execute encrypted swap math
        euint128 actualOutput = _executeSwapMath(encDir, adjustedAmount);

        // 5. Slippage check (encrypted)
        ebool slippageOk = FHE.gte(actualOutput, encMinOutput);
        euint128 finalOutput = FHE.select(slippageOk, actualOutput, ENC_ZERO);

        // 6. Credit user's output balance
        _creditUserBalance(sender, encDir, finalOutput);

        // 7. Refund input if slippage failed
        euint128 refund = FHE.select(slippageOk, ENC_ZERO, adjustedAmount);
        _creditUserBalanceReverse(sender, encDir, refund);

        // 8. Request async reserve sync (rate limited)
        _requestReserveSync();

        // 9. Return ZERO_DELTA - we handled everything via custom accounting
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata /* key */,
        SwapParams calldata /* params */,
        BalanceDelta /* delta */,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, int128) {
        // Get current tick after swap
        int24 currentTick = _getCurrentTick();
        int24 prevTick = lastTickLower;

        // Update tick tracker for next swap
        lastTickLower = currentTick;

        // Process triggered limit orders based on price movement
        // Only process if tick has actually moved
        if (currentTick != prevTick) {
            _processOrdersInRange(prevTick, currentTick, sender);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Process all orders triggered by tick movement
    /// @param startTick The tick before the swap
    /// @param endTick The tick after the swap
    /// @param executor The address executing the swap (receives reward)
    function _processOrdersInRange(int24 startTick, int24 endTick, address executor) internal {
        bool movingUp = endTick > startTick;

        // Determine tick range to check
        int24 minTick = movingUp ? startTick : endTick;
        int24 maxTick = movingUp ? endTick : startTick;

        // Use bitmap to efficiently find ticks with orders
        int24 tick = minTick;
        while (tick <= maxTick) {
            // Check if this tick has orders
            if (orderBitmap.hasOrdersAtTick(tick)) {
                _processOrdersAtTick(tick, movingUp, executor);
            }

            // Move to next tick (could optimize with bitmap.nextTickWithOrders)
            tick++;
        }
    }

    /// @notice Process all orders at a specific tick
    /// @param tick The tick to process orders at
    /// @param movingUp True if price is moving up (oneForZero swaps)
    /// @param executor The address executing (receives reward)
    function _processOrdersAtTick(int24 tick, bool movingUp, address executor) internal {
        uint256[] storage orderIds = ordersByTick[tick];

        // Convert movingUp to encrypted bool for comparison
        // zeroForOne orders (direction=true) trigger when price moves DOWN (movingUp=false)
        // oneForZero orders (direction=false) trigger when price moves UP (movingUp=true)
        // So we need: direction != movingUp for an order to trigger
        ebool encMovingUp = FHE.asEbool(movingUp);

        // Process each order at this tick
        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            Order storage order = orders[orderId];

            if (!order.active) continue;

            // Check if order should trigger based on direction
            // Order triggers when direction is opposite to price movement:
            // - zeroForOne (true) triggers on price DOWN (movingUp=false)
            // - oneForZero (false) triggers on price UP (movingUp=true)
            ebool shouldTrigger = FHE.ne(order.direction, encMovingUp);

            // Try to fill the order (will be zeroed if shouldn't trigger)
            _tryFillOrderConditional(orderId, order, executor, shouldTrigger);
        }
    }

    /// @notice Try to fill a single order conditionally
    /// @param orderId The order ID
    /// @param order The order storage reference
    /// @param executor The executor address
    /// @param shouldTrigger Encrypted bool indicating if order should execute
    function _tryFillOrderConditional(
        uint256 orderId,
        Order storage order,
        address executor,
        ebool shouldTrigger
    ) internal {
        // Calculate swap output (always computed for constant-time execution)
        euint128 amountOut = _executeSwapMathConditional(order.direction, order.amount, shouldTrigger);

        // Slippage check (encrypted comparison)
        ebool slippageOk = FHE.gte(amountOut, order.minOutput);

        // Combined condition: should trigger AND slippage OK
        ebool shouldFill = FHE.and(shouldTrigger, slippageOk);

        // Compute fill amount (0 if shouldn't fill)
        euint128 fillAmount = FHE.select(shouldFill, amountOut, ENC_ZERO);

        // If slippage failed but should have triggered, return input
        ebool slippageFailed = FHE.and(shouldTrigger, FHE.not(slippageOk));
        euint128 reversedInput = FHE.select(slippageFailed, order.amount, ENC_ZERO);

        // Credit output to user (will be 0 if not filled)
        _creditUserBalance(order.owner, order.direction, fillAmount);

        // If slippage failed, return input to user
        _creditUserBalanceReverse(order.owner, order.direction, reversedInput);

        // Calculate executor reward (1% of fill amount)
        euint128 executorReward = FHE.div(fillAmount, ENC_HUNDRED);

        // Credit executor reward (in output token)
        _ensureUserBalancesInitialized(executor);
        _creditUserBalance(executor, order.direction, executorReward);

        // Mark order as filled (we mark inactive regardless - order is processed)
        // In encrypted world, even non-triggering orders get "processed" for privacy
        order.active = false;

        // Clean up tick array and bitmap
        _removeOrderFromTick(order.triggerTick, orderId);
        if (ordersByTick[order.triggerTick].length == 0) {
            orderBitmap.clearTick(order.triggerTick);
        }

        emit OrderFilled(orderId, order.owner, executor);
    }

    /// @notice Execute swap math conditionally (for constant-time execution)
    /// @param direction The swap direction
    /// @param amountIn The input amount
    /// @param shouldExecute Whether to actually modify reserves
    /// @return amountOut The output amount (0 if not executed)
    function _executeSwapMathConditional(
        ebool direction,
        euint128 amountIn,
        ebool shouldExecute
    ) internal returns (euint128 amountOut) {
        // Conditionally zero the input if not executing
        euint128 effectiveInput = FHE.select(shouldExecute, amountIn, ENC_ZERO);

        // Apply fee
        euint128 feeAmount = FHE.div(FHE.mul(effectiveInput, ENC_SWAP_FEE_BPS), ENC_TEN_THOUSAND);
        euint128 amountInAfterFee = FHE.sub(effectiveInput, feeAmount);

        // x * y = k formula, all encrypted
        euint128 reserveIn = FHE.select(direction, encReserve0, encReserve1);
        euint128 reserveOut = FHE.select(direction, encReserve1, encReserve0);

        // amountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee)
        euint128 numerator = FHE.mul(amountInAfterFee, reserveOut);
        euint128 denominator = FHE.add(reserveIn, amountInAfterFee);

        // Protect against division by zero
        euint128 safeDenominator = FHE.select(FHE.gt(denominator, ENC_ZERO), denominator, ENC_ONE);
        amountOut = FHE.div(numerator, safeDenominator);

        // Update encrypted reserves (will be 0 change if not executing)
        euint128 newReserveIn = FHE.add(reserveIn, effectiveInput);
        euint128 newReserveOut = FHE.sub(reserveOut, amountOut);

        encReserve0 = FHE.select(direction, newReserveIn, newReserveOut);
        encReserve1 = FHE.select(direction, newReserveOut, newReserveIn);

        return amountOut;
    }

    function _beforeAddLiquidity(
        address /* sender */,
        PoolKey calldata /* key */,
        ModifyLiquidityParams calldata params,
        bytes calldata /* hookData */
    ) internal override returns (bytes4) {
        // Update encrypted reserves
        uint256 amount0 = uint256(int256(params.liquidityDelta));
        uint256 amount1 = uint256(int256(params.liquidityDelta));

        encReserve0 = FHE.add(encReserve0, FHE.asEuint128(uint128(amount0)));
        encReserve1 = FHE.add(encReserve1, FHE.asEuint128(uint128(amount1)));

        // Update display cache (amounts are plaintext)
        reserve0 += amount0;
        reserve1 += amount1;

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address /* sender */,
        PoolKey calldata /* key */,
        ModifyLiquidityParams calldata params,
        bytes calldata /* hookData */
    ) internal override returns (bytes4) {
        uint256 amount0 = uint256(int256(-params.liquidityDelta));
        uint256 amount1 = uint256(int256(-params.liquidityDelta));

        encReserve0 = FHE.sub(encReserve0, FHE.asEuint128(uint128(amount0)));
        encReserve1 = FHE.sub(encReserve1, FHE.asEuint128(uint128(amount1)));

        reserve0 -= amount0;
        reserve1 -= amount1;

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // ============ User Functions ============

    function deposit(bool isToken0, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20 token = isToken0 ? token0 : token1;
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Initialize user balances if this is their first interaction
        _ensureUserBalancesInitialized(msg.sender);

        euint128 encAmount = FHE.asEuint128(uint128(amount));

        if (isToken0) {
            userBalanceToken0[msg.sender] = FHE.add(userBalanceToken0[msg.sender], encAmount);
            encReserve0 = FHE.add(encReserve0, encAmount);
            reserve0 += amount; // Known plaintext
        } else {
            userBalanceToken1[msg.sender] = FHE.add(userBalanceToken1[msg.sender], encAmount);
            encReserve1 = FHE.add(encReserve1, encAmount);
            reserve1 += amount; // Known plaintext
        }

        emit Deposit(msg.sender, address(token), amount);
    }

    function withdraw(bool isToken0, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        euint128 encAmount = FHE.asEuint128(uint128(amount));

        // Debit user's balance (this will underflow if insufficient - handled by FHE)
        if (isToken0) {
            userBalanceToken0[msg.sender] = FHE.sub(userBalanceToken0[msg.sender], encAmount);
            encReserve0 = FHE.sub(encReserve0, encAmount);
            reserve0 -= amount;
            token0.safeTransfer(msg.sender, amount);
        } else {
            userBalanceToken1[msg.sender] = FHE.sub(userBalanceToken1[msg.sender], encAmount);
            encReserve1 = FHE.sub(encReserve1, encAmount);
            reserve1 -= amount;
            token1.safeTransfer(msg.sender, amount);
        }

        emit Withdraw(msg.sender, isToken0 ? address(token0) : address(token1), amount);
    }

    function placeOrder(
        int24 triggerTick,
        ebool direction,
        euint128 amount,
        euint128 minOutput
    ) external payable nonReentrant returns (uint256 orderId) {
        if (msg.value < PROTOCOL_FEE) revert InsufficientFee();

        orderId = nextOrderId++;

        orders[orderId] = Order({
            owner: msg.sender,
            triggerTick: triggerTick,
            direction: direction,
            amount: amount,
            minOutput: minOutput,
            active: true
        });

        // Update tick bitmap if first order at this tick
        if (ordersByTick[triggerTick].length == 0) {
            orderBitmap.setTick(triggerTick);
        }
        ordersByTick[triggerTick].push(orderId);
        userOrders[msg.sender].push(orderId);

        // Debit user's balance for the order
        _debitUserBalance(msg.sender, direction, amount);

        emit OrderPlaced(orderId, msg.sender, triggerTick);
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];

        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (!order.active) revert OrderNotActive();

        order.active = false;

        // Return input tokens to user (branchless - reverse of debit)
        _creditUserBalanceReverse(order.owner, order.direction, order.amount);

        // Clean up tick array
        _removeOrderFromTick(order.triggerTick, orderId);

        // Clear bitmap if no more orders at this tick
        if (ordersByTick[order.triggerTick].length == 0) {
            orderBitmap.clearTick(order.triggerTick);
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    // ============ Admin Functions ============

    /// @notice Withdraw accumulated protocol fees (ETH)
    /// @param to Address to send fees to
    function withdrawProtocolFees(address payable to) external {
        require(msg.sender == owner, "Only owner");
        require(to != address(0), "Invalid recipient");

        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");

        (bool success, ) = to.call{value: balance}("");
        require(success, "Transfer failed");
    }

    /// @notice Emergency function to recover stuck tokens (not user balances)
    /// @param tokenAddress The token to recover
    /// @param to Address to send tokens to
    /// @param amount Amount to recover
    function emergencyTokenRecovery(address tokenAddress, address to, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        require(to != address(0), "Invalid recipient");
        // Cannot recover pool tokens - those belong to users
        require(tokenAddress != address(token0) && tokenAddress != address(token1), "Cannot recover pool tokens");

        IERC20(tokenAddress).safeTransfer(to, amount);
    }

    // ============ View Functions ============

    function getReserves() external returns (uint256, uint256) {
        _trySyncReserves();
        return (reserve0, reserve1);
    }

    function getUserBalanceToken0(address user) external view returns (euint128) {
        return userBalanceToken0[user];
    }

    function getUserBalanceToken1(address user) external view returns (euint128) {
        return userBalanceToken1[user];
    }

    function getActiveOrders(address user) external view returns (uint256[] memory) {
        uint256[] storage allOrders = userOrders[user];

        uint256 activeCount = 0;
        for (uint256 i = 0; i < allOrders.length; i++) {
            if (orders[allOrders[i]].active) {
                activeCount++;
            }
        }

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

    function hasOrdersAtTick(int24 tick) external view returns (bool) {
        return orderBitmap.hasOrdersAtTick(tick);
    }

    function forceSyncReserves() external {
        pendingReserve0 = encReserve0;
        pendingReserve1 = encReserve1;
        FHE.decrypt(pendingReserve0);
        FHE.decrypt(pendingReserve1);
        lastSyncBlock = block.number;

        emit ReserveSyncRequested(block.number);
    }

    // ============ Internal Functions ============

    function _extractOrEncryptParams(
        SwapParams calldata params,
        bytes calldata hookData
    ) internal returns (ebool, euint128, euint128) {
        if (hookData.length > 0) {
            // Fully encrypted params from hookData
            (InEbool memory inDir, InEuint128 memory inAmt, InEuint128 memory inMinOut) =
                abi.decode(hookData, (InEbool, InEuint128, InEuint128));
            return (
                FHE.asEbool(inDir),
                FHE.asEuint128(inAmt),
                FHE.asEuint128(inMinOut)
            );
        } else {
            // Encrypt plaintext params
            return (
                FHE.asEbool(params.zeroForOne),
                FHE.asEuint128(uint128(params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified))),
                ENC_ZERO // No slippage protection for plaintext swaps
            );
        }
    }

    function _executeSwapMath(ebool direction, euint128 amountIn) internal returns (euint128 amountOut) {
        // Apply fee
        euint128 feeAmount = FHE.div(FHE.mul(amountIn, ENC_SWAP_FEE_BPS), ENC_TEN_THOUSAND);
        euint128 amountInAfterFee = FHE.sub(amountIn, feeAmount);

        // x * y = k formula, all encrypted
        euint128 reserveIn = FHE.select(direction, encReserve0, encReserve1);
        euint128 reserveOut = FHE.select(direction, encReserve1, encReserve0);

        // amountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee)
        euint128 numerator = FHE.mul(amountInAfterFee, reserveOut);
        euint128 denominator = FHE.add(reserveIn, amountInAfterFee);
        amountOut = FHE.div(numerator, denominator);

        // Update encrypted reserves
        euint128 newReserveIn = FHE.add(reserveIn, amountIn); // Full amount (includes fee)
        euint128 newReserveOut = FHE.sub(reserveOut, amountOut);

        encReserve0 = FHE.select(direction, newReserveIn, newReserveOut);
        encReserve1 = FHE.select(direction, newReserveOut, newReserveIn);
    }

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

    function _creditUserBalance(address user, ebool direction, euint128 amount) internal {
        // If direction=true (zeroForOne), credit token1. Otherwise credit token0.
        userBalanceToken0[user] = FHE.add(
            userBalanceToken0[user],
            FHE.select(direction, ENC_ZERO, amount)
        );
        userBalanceToken1[user] = FHE.add(
            userBalanceToken1[user],
            FHE.select(direction, amount, ENC_ZERO)
        );
    }

    function _creditUserBalanceReverse(address user, ebool direction, euint128 amount) internal {
        // Credit back to input token (opposite of _creditUserBalance)
        userBalanceToken0[user] = FHE.add(
            userBalanceToken0[user],
            FHE.select(direction, amount, ENC_ZERO)
        );
        userBalanceToken1[user] = FHE.add(
            userBalanceToken1[user],
            FHE.select(direction, ENC_ZERO, amount)
        );
    }

    function _requestReserveSync() internal {
        if (block.number < lastSyncBlock + SYNC_COOLDOWN_BLOCKS) {
            return; // Too soon
        }

        pendingReserve0 = encReserve0;
        pendingReserve1 = encReserve1;
        FHE.decrypt(pendingReserve0);
        FHE.decrypt(pendingReserve1);

        lastSyncBlock = block.number;
        emit ReserveSyncRequested(block.number);
    }

    function _trySyncReserves() internal {
        (uint256 val0, bool ready0) = FHE.getDecryptResultSafe(pendingReserve0);
        (uint256 val1, bool ready1) = FHE.getDecryptResultSafe(pendingReserve1);

        if (ready0 && ready1) {
            reserve0 = val0;
            reserve1 = val1;
            emit ReservesSynced(val0, val1);
        }
    }

    function _getCurrentTick() internal view returns (int24) {
        // Calculate tick from public reserves using price ratio
        if (reserve0 == 0 || reserve1 == 0) return 0;

        // Price = reserve1 / reserve0
        // sqrtPriceX96 = sqrt(price) * 2^96
        // For AMM: sqrtPrice = sqrt(reserve1/reserve0) * 2^96

        // Calculate sqrt(reserve1/reserve0) scaled by 2^96
        // Using: sqrtPriceX96 = sqrt(reserve1 * 2^192 / reserve0)
        uint256 ratioX192 = (reserve1 << 192) / reserve0;
        uint160 sqrtPriceX96 = uint160(_sqrt(ratioX192));

        // Clamp to valid range
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE) {
            sqrtPriceX96 = TickMath.MIN_SQRT_PRICE;
        } else if (sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            sqrtPriceX96 = TickMath.MAX_SQRT_PRICE;
        }

        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice Calculate square root using Babylonian method
    /// @param x The number to calculate square root of
    /// @return y The square root
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _removeOrderFromTick(int24 tick, uint256 orderId) internal {
        uint256[] storage orderIds = ordersByTick[tick];
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == orderId) {
                orderIds[i] = orderIds[orderIds.length - 1];
                orderIds.pop();
                break;
            }
        }
    }

    function _ensureUserBalancesInitialized(address user) internal {
        if (!userInitialized[user]) {
            userBalanceToken0[user] = ENC_ZERO;
            userBalanceToken1[user] = ENC_ZERO;
            FHE.allowThis(userBalanceToken0[user]);
            FHE.allowThis(userBalanceToken1[user]);
            FHE.allow(userBalanceToken0[user], user);
            FHE.allow(userBalanceToken1[user], user);
            userInitialized[user] = true;
        }
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
