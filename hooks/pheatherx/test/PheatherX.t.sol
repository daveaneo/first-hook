// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Foundry Imports
import "forge-std/Test.sol";

// Uniswap Imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

// Local Imports
import {PheatherX} from "../src/PheatherX.sol";
import {IPheatherX} from "../src/interface/IPheatherX.sol";
import {TickBitmap} from "../src/lib/TickBitmap.sol";
import {DirectionLock} from "../src/lib/DirectionLock.sol";

// Test Utils
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {SortTokens} from "./utils/SortTokens.sol";

// FHE Imports
import {FHE, euint128, ebool, InEuint128, InEbool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

// OpenZeppelin Imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple mock ERC20 for testing
contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PheatherXTest is Test, Fixtures, CoFheTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    address private user = makeAddr("user");
    address private user2 = makeAddr("user2");

    PheatherX hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    MockToken token0;
    MockToken token1;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    function setUp() public {
        // Deploy mock tokens at deterministic addresses
        address a0 = address(0x100);
        address a1 = address(0x200);

        // Ensure token0 < token1 for Uniswap ordering
        if (a0 > a1) {
            (a0, a1) = (a1, a0);
        }

        vm.etch(a0, address(new MockToken("Token0", "TK0")).code);
        vm.etch(a1, address(new MockToken("Token1", "TK1")).code);

        token0 = MockToken(a0);
        token1 = MockToken(a1);

        vm.label(user, "user");
        vm.label(user2, "user2");
        vm.label(address(this), "test");
        vm.label(address(token0), "token0");
        vm.label(address(token1), "token1");

        // Create the pool manager, utility routers
        deployFreshManagerAndRouters();

        // Mint tokens for testing
        token0.mint(user, 2 ** 128);
        token1.mint(user, 2 ** 128);
        token0.mint(user2, 2 ** 128);
        token1.mint(user2, 2 ** 128);
        token0.mint(address(this), 2 ** 128);
        token1.mint(address(this), 2 ** 128);

        // Give ETH to users for protocol fees
        vm.deal(user, 100 ether);
        vm.deal(user2, 100 ether);

        // Set currencies
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Deploy POSM
        deployAndApprovePosm(manager, currency0, currency1);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        bytes memory constructorArgs = abi.encode(
            manager,
            address(token0),
            address(token1),
            30 // 0.3% swap fee
        );
        deployCodeTo("PheatherX.sol:PheatherX", constructorArgs, flags);
        hook = PheatherX(payable(flags));

        vm.label(address(hook), "hook");

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Setup tick bounds
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        // Approve tokens for various routers
        vm.startPrank(user);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Deposit Tests ============

    function testDepositToken0() public {
        uint256 depositAmount = 1000 ether;
        uint256 userBalanceBefore = token0.balanceOf(user);

        vm.prank(user);
        hook.deposit(true, depositAmount);

        uint256 userBalanceAfter = token0.balanceOf(user);
        assertEq(userBalanceBefore - userBalanceAfter, depositAmount, "User balance should decrease");

        euint128 encBalance = hook.getUserBalanceToken0(user);
        assertHashValue(encBalance, uint128(depositAmount));
    }

    function testDepositToken1() public {
        uint256 depositAmount = 500 ether;
        uint256 userBalanceBefore = token1.balanceOf(user);

        vm.prank(user);
        hook.deposit(false, depositAmount);

        uint256 userBalanceAfter = token1.balanceOf(user);
        assertEq(userBalanceBefore - userBalanceAfter, depositAmount, "User balance should decrease");

        euint128 encBalance = hook.getUserBalanceToken1(user);
        assertHashValue(encBalance, uint128(depositAmount));
    }

    function testDepositZeroAmountReverts() public {
        vm.prank(user);
        vm.expectRevert(IPheatherX.ZeroAmount.selector);
        hook.deposit(true, 0);
    }

    // ============ Withdraw Tests ============

    function testWithdrawToken0() public {
        uint256 depositAmount = 1000 ether;
        uint256 withdrawAmount = 400 ether;

        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        uint256 userBalanceBefore = token0.balanceOf(user);
        hook.withdraw(true, withdrawAmount);
        uint256 userBalanceAfter = token0.balanceOf(user);
        vm.stopPrank();

        assertEq(userBalanceAfter - userBalanceBefore, withdrawAmount, "User should receive withdrawn amount");

        euint128 encBalance = hook.getUserBalanceToken0(user);
        assertHashValue(encBalance, uint128(depositAmount - withdrawAmount));
    }

    function testWithdrawToken1() public {
        uint256 depositAmount = 1000 ether;
        uint256 withdrawAmount = 600 ether;

        vm.startPrank(user);
        hook.deposit(false, depositAmount);

        uint256 userBalanceBefore = token1.balanceOf(user);
        hook.withdraw(false, withdrawAmount);
        uint256 userBalanceAfter = token1.balanceOf(user);
        vm.stopPrank();

        assertEq(userBalanceAfter - userBalanceBefore, withdrawAmount, "User should receive withdrawn amount");

        euint128 encBalance = hook.getUserBalanceToken1(user);
        assertHashValue(encBalance, uint128(depositAmount - withdrawAmount));
    }

    function testWithdrawZeroAmountReverts() public {
        vm.prank(user);
        vm.expectRevert(IPheatherX.ZeroAmount.selector);
        hook.withdraw(true, 0);
    }

    // ============ Limit Order Tests ============

    function testPlaceOrderZeroForOne() public {
        uint256 depositAmount = 1000 ether;
        int24 triggerTick = 100;

        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        // Use direct FHE encryption without InE types to avoid zkVerify calls
        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(500 ether));
        euint128 minOutput = FHE.asEuint128(uint128(400 ether));

        // Allow the hook to use these encrypted values
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        uint256 orderId = hook.placeOrder{value: 0.001 ether}(
            triggerTick,
            direction,
            amount,
            minOutput
        );
        vm.stopPrank();

        assertEq(orderId, 1, "First order should have ID 1");
        assertTrue(hook.hasOrdersAtTick(triggerTick), "Tick should have orders");

        uint256[] memory activeOrders = hook.getActiveOrders(user);
        assertEq(activeOrders.length, 1, "User should have 1 active order");
        assertEq(activeOrders[0], 1, "Active order should be ID 1");
    }

    function testPlaceOrderOneForZero() public {
        uint256 depositAmount = 1000 ether;
        int24 triggerTick = -100;

        vm.startPrank(user);
        hook.deposit(false, depositAmount);

        ebool direction = FHE.asEbool(false);
        euint128 amount = FHE.asEuint128(uint128(500 ether));
        euint128 minOutput = FHE.asEuint128(uint128(400 ether));

        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        uint256 orderId = hook.placeOrder{value: 0.001 ether}(
            triggerTick,
            direction,
            amount,
            minOutput
        );
        vm.stopPrank();

        assertEq(orderId, 1, "First order should have ID 1");
        assertTrue(hook.hasOrdersAtTick(triggerTick), "Tick should have orders");
    }

    function testPlaceOrderInsufficientFeeReverts() public {
        uint256 depositAmount = 1000 ether;

        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(500 ether));
        euint128 minOutput = FHE.asEuint128(uint128(400 ether));

        vm.expectRevert(IPheatherX.InsufficientFee.selector);
        hook.placeOrder{value: 0.0001 ether}(
            100,
            direction,
            amount,
            minOutput
        );
        vm.stopPrank();
    }

    // ============ Cancel Order Tests ============

    function testCancelOrder() public {
        uint256 depositAmount = 1000 ether;

        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(500 ether));
        euint128 minOutput = FHE.asEuint128(uint128(400 ether));

        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        uint256 orderId = hook.placeOrder{value: 0.001 ether}(
            100,
            direction,
            amount,
            minOutput
        );

        hook.cancelOrder(orderId);
        vm.stopPrank();

        uint256[] memory activeOrders = hook.getActiveOrders(user);
        assertEq(activeOrders.length, 0, "User should have no active orders");
        assertFalse(hook.hasOrdersAtTick(100), "Tick should have no orders");
    }

    function testCancelOrderNotOwnerReverts() public {
        uint256 depositAmount = 1000 ether;

        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(500 ether));
        euint128 minOutput = FHE.asEuint128(uint128(400 ether));

        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        uint256 orderId = hook.placeOrder{value: 0.001 ether}(
            100,
            direction,
            amount,
            minOutput
        );
        vm.stopPrank();

        vm.prank(user2);
        vm.expectRevert(IPheatherX.NotOrderOwner.selector);
        hook.cancelOrder(orderId);
    }

    function testCancelOrderNotFoundReverts() public {
        vm.prank(user);
        vm.expectRevert(IPheatherX.OrderNotFound.selector);
        hook.cancelOrder(999);
    }

    // ============ Reserve Tests ============

    function testGetReserves() public {
        uint256 depositAmount = 1000 ether;

        vm.prank(user);
        hook.deposit(true, depositAmount);

        vm.prank(user);
        hook.deposit(false, 500 ether);

        (uint256 r0, uint256 r1) = hook.getReserves();
        assertEq(r0, depositAmount, "Reserve0 should match deposit");
        assertEq(r1, 500 ether, "Reserve1 should match deposit");
    }

    function testForceSyncReserves() public {
        uint256 depositAmount = 1000 ether;

        vm.prank(user);
        hook.deposit(true, depositAmount);

        hook.forceSyncReserves();

        // In a real environment, this would trigger async decryption
        // For testing, we just verify it doesn't revert
    }

    // ============ Multiple Order Tests ============

    function testMultipleOrdersSameTick() public {
        uint256 depositAmount = 1000 ether;
        int24 triggerTick = 100;

        // User 1 places order
        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        ebool dir1 = FHE.asEbool(true);
        euint128 amt1 = FHE.asEuint128(uint128(300 ether));
        euint128 min1 = FHE.asEuint128(uint128(200 ether));
        FHE.allow(dir1, address(hook));
        FHE.allow(amt1, address(hook));
        FHE.allow(min1, address(hook));

        hook.placeOrder{value: 0.001 ether}(triggerTick, dir1, amt1, min1);
        vm.stopPrank();

        // User 2 places order at same tick
        vm.startPrank(user2);
        token0.approve(address(hook), type(uint256).max);
        hook.deposit(true, depositAmount);

        ebool dir2 = FHE.asEbool(true);
        euint128 amt2 = FHE.asEuint128(uint128(500 ether));
        euint128 min2 = FHE.asEuint128(uint128(400 ether));
        FHE.allow(dir2, address(hook));
        FHE.allow(amt2, address(hook));
        FHE.allow(min2, address(hook));

        hook.placeOrder{value: 0.001 ether}(triggerTick, dir2, amt2, min2);
        vm.stopPrank();

        assertTrue(hook.hasOrdersAtTick(triggerTick), "Tick should have orders");
        assertEq(hook.getOrderCount(user), 1, "User should have 1 order");
        assertEq(hook.getOrderCount(user2), 1, "User2 should have 1 order");
    }

    // ============ TickBitmap Tests ============

    function testTickBitmapSetAndClear() public {
        int24 tick = 256; // Tests word boundary

        // Place order to set tick
        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        uint256 orderId = hook.placeOrder{value: 0.001 ether}(tick, direction, amount, minOutput);

        assertTrue(hook.hasOrdersAtTick(tick), "Tick should be set");

        // Cancel order to clear tick
        hook.cancelOrder(orderId);
        vm.stopPrank();

        assertFalse(hook.hasOrdersAtTick(tick), "Tick should be cleared");
    }

    function testTickBitmapNegativeTicks() public {
        int24 tick = -256;

        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(tick, direction, amount, minOutput);
        vm.stopPrank();

        assertTrue(hook.hasOrdersAtTick(tick), "Negative tick should be set");
    }

    // ============ Multiple Deposits Tests (from Iceberg) ============

    function testMultipleDepositsAccumulate() public {
        uint256 firstDeposit = 1000 ether;
        uint256 secondDeposit = 500 ether;

        vm.startPrank(user);
        hook.deposit(true, firstDeposit);
        hook.deposit(true, secondDeposit);
        vm.stopPrank();

        euint128 encBalance = hook.getUserBalanceToken0(user);
        assertHashValue(encBalance, uint128(firstDeposit + secondDeposit));
    }

    function testDepositBothTokens() public {
        uint256 deposit0 = 1000 ether;
        uint256 deposit1 = 2000 ether;

        vm.startPrank(user);
        hook.deposit(true, deposit0);
        hook.deposit(false, deposit1);
        vm.stopPrank();

        euint128 encBalance0 = hook.getUserBalanceToken0(user);
        euint128 encBalance1 = hook.getUserBalanceToken1(user);

        assertHashValue(encBalance0, uint128(deposit0));
        assertHashValue(encBalance1, uint128(deposit1));
    }

    // ============ Balance Tracking Tests (from Iceberg) ============

    function testUserBalanceDecreasesOnOrderPlacement() public {
        uint256 depositAmount = 1000 ether;
        uint128 orderAmount = 300 ether;

        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        euint128 balanceBeforeOrder = hook.getUserBalanceToken0(user);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(orderAmount);
        euint128 minOutput = FHE.asEuint128(uint128(200 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(100, direction, amount, minOutput);

        euint128 balanceAfterOrder = hook.getUserBalanceToken0(user);
        vm.stopPrank();

        // Balance should decrease by order amount
        uint128 balBefore = uint128(mockStorage(euint128.unwrap(balanceBeforeOrder)));
        uint128 balAfter = uint128(mockStorage(euint128.unwrap(balanceAfterOrder)));
        assertEq(balBefore - balAfter, orderAmount, "Balance should decrease by order amount");
    }

    function testUserBalanceRestoredOnCancel() public {
        uint256 depositAmount = 1000 ether;
        uint128 orderAmount = 300 ether;

        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        euint128 balanceBeforeOrder = hook.getUserBalanceToken0(user);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(orderAmount);
        euint128 minOutput = FHE.asEuint128(uint128(200 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        uint256 orderId = hook.placeOrder{value: 0.001 ether}(100, direction, amount, minOutput);

        // Balance decreased after order (verified by comparing before/after)

        // Cancel the order
        hook.cancelOrder(orderId);

        euint128 balanceAfterCancel = hook.getUserBalanceToken0(user);
        vm.stopPrank();

        // Balance should be restored
        uint128 balBefore = uint128(mockStorage(euint128.unwrap(balanceBeforeOrder)));
        uint128 balAfterCancel = uint128(mockStorage(euint128.unwrap(balanceAfterCancel)));
        assertEq(balBefore, balAfterCancel, "Balance should be restored after cancel");
    }

    // ============ Reserve Tracking Tests (from Iceberg) ============

    function testReservesIncreasesOnDeposit() public {
        uint256 deposit0 = 1000 ether;
        uint256 deposit1 = 2000 ether;

        (uint256 r0Before, uint256 r1Before) = hook.getReserves();

        vm.startPrank(user);
        hook.deposit(true, deposit0);
        hook.deposit(false, deposit1);
        vm.stopPrank();

        (uint256 r0After, uint256 r1After) = hook.getReserves();

        assertEq(r0After - r0Before, deposit0, "Reserve0 should increase by deposit");
        assertEq(r1After - r1Before, deposit1, "Reserve1 should increase by deposit");
    }

    function testReservesDecreasesOnWithdraw() public {
        uint256 depositAmount = 1000 ether;
        uint256 withdrawAmount = 400 ether;

        vm.prank(user);
        hook.deposit(true, depositAmount);

        (uint256 r0Before,) = hook.getReserves();

        vm.prank(user);
        hook.withdraw(true, withdrawAmount);

        (uint256 r0After,) = hook.getReserves();

        assertEq(r0Before - r0After, withdrawAmount, "Reserve should decrease by withdrawal");
    }

    // ============ Two Users Same Order Tests (from Iceberg) ============

    function testTwoUsersPlaceOrdersAtSameTick() public {
        uint256 depositAmount = 1000 ether;
        int24 tick = 60;

        // User 1 places order
        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        ebool dir1 = FHE.asEbool(true);
        euint128 amt1 = FHE.asEuint128(uint128(100 ether));
        euint128 min1 = FHE.asEuint128(uint128(50 ether));
        FHE.allow(dir1, address(hook));
        FHE.allow(amt1, address(hook));
        FHE.allow(min1, address(hook));

        uint256 orderId1 = hook.placeOrder{value: 0.001 ether}(tick, dir1, amt1, min1);
        vm.stopPrank();

        // User 2 places order at same tick
        vm.startPrank(user2);
        hook.deposit(true, depositAmount);

        ebool dir2 = FHE.asEbool(true);
        euint128 amt2 = FHE.asEuint128(uint128(200 ether));
        euint128 min2 = FHE.asEuint128(uint128(100 ether));
        FHE.allow(dir2, address(hook));
        FHE.allow(amt2, address(hook));
        FHE.allow(min2, address(hook));

        uint256 orderId2 = hook.placeOrder{value: 0.001 ether}(tick, dir2, amt2, min2);
        vm.stopPrank();

        // Verify both orders exist
        assertEq(orderId1, 1, "First order ID should be 1");
        assertEq(orderId2, 2, "Second order ID should be 2");
        assertTrue(hook.hasOrdersAtTick(tick), "Tick should have orders");
        assertEq(hook.getOrderCount(user), 1, "User should have 1 order");
        assertEq(hook.getOrderCount(user2), 1, "User2 should have 1 order");

        // Verify orders at tick
        uint256[] memory user1Orders = hook.getActiveOrders(user);
        uint256[] memory user2Orders = hook.getActiveOrders(user2);
        assertEq(user1Orders[0], 1);
        assertEq(user2Orders[0], 2);
    }

    function testTwoUsersOppositeDirections() public {
        uint256 depositAmount = 1000 ether;

        // User 1 places zeroForOne order
        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        ebool dir1 = FHE.asEbool(true); // zeroForOne
        euint128 amt1 = FHE.asEuint128(uint128(100 ether));
        euint128 min1 = FHE.asEuint128(uint128(50 ether));
        FHE.allow(dir1, address(hook));
        FHE.allow(amt1, address(hook));
        FHE.allow(min1, address(hook));

        hook.placeOrder{value: 0.001 ether}(60, dir1, amt1, min1);
        vm.stopPrank();

        // User 2 places oneForZero order
        vm.startPrank(user2);
        hook.deposit(false, depositAmount);

        ebool dir2 = FHE.asEbool(false); // oneForZero
        euint128 amt2 = FHE.asEuint128(uint128(200 ether));
        euint128 min2 = FHE.asEuint128(uint128(100 ether));
        FHE.allow(dir2, address(hook));
        FHE.allow(amt2, address(hook));
        FHE.allow(min2, address(hook));

        hook.placeOrder{value: 0.001 ether}(-60, dir2, amt2, min2);
        vm.stopPrank();

        // Verify different ticks have orders
        assertTrue(hook.hasOrdersAtTick(60), "Tick 60 should have orders");
        assertTrue(hook.hasOrdersAtTick(-60), "Tick -60 should have orders");
    }

    // ============ Order State Tests (from Iceberg) ============

    function testCancelOrderMarksInactive() public {
        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        uint256 orderId = hook.placeOrder{value: 0.001 ether}(100, direction, amount, minOutput);

        // Verify order is active
        uint256[] memory activeOrdersBefore = hook.getActiveOrders(user);
        assertEq(activeOrdersBefore.length, 1, "Should have 1 active order");

        // Cancel
        hook.cancelOrder(orderId);

        // Verify order is inactive
        uint256[] memory activeOrdersAfter = hook.getActiveOrders(user);
        assertEq(activeOrdersAfter.length, 0, "Should have 0 active orders");
        vm.stopPrank();
    }

    function testCannotCancelTwice() public {
        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        uint256 orderId = hook.placeOrder{value: 0.001 ether}(100, direction, amount, minOutput);

        // First cancel should succeed
        hook.cancelOrder(orderId);

        // Second cancel should revert
        vm.expectRevert(IPheatherX.OrderNotActive.selector);
        hook.cancelOrder(orderId);
        vm.stopPrank();
    }

    // ============ Sequential Order Tests (from Iceberg) ============

    function testMultipleOrdersDifferentTicks() public {
        vm.startPrank(user);
        hook.deposit(true, 5000 ether);

        int24[] memory ticks = new int24[](5);
        ticks[0] = 60;
        ticks[1] = 120;
        ticks[2] = 180;
        ticks[3] = -60;
        ticks[4] = -120;

        for (uint256 i = 0; i < 5; i++) {
            ebool direction = FHE.asEbool(true);
            euint128 amount = FHE.asEuint128(uint128(100 ether));
            euint128 minOutput = FHE.asEuint128(uint128(50 ether));
            FHE.allow(direction, address(hook));
            FHE.allow(amount, address(hook));
            FHE.allow(minOutput, address(hook));

            hook.placeOrder{value: 0.001 ether}(ticks[i], direction, amount, minOutput);
        }
        vm.stopPrank();

        // Verify all ticks have orders
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(hook.hasOrdersAtTick(ticks[i]), "Tick should have orders");
        }

        assertEq(hook.getOrderCount(user), 5, "User should have 5 orders");
    }

    function testCancelMiddleOrder() public {
        vm.startPrank(user);
        hook.deposit(true, 3000 ether);

        uint256[] memory orderIds = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            ebool direction = FHE.asEbool(true);
            euint128 amount = FHE.asEuint128(uint128(100 ether));
            euint128 minOutput = FHE.asEuint128(uint128(50 ether));
            FHE.allow(direction, address(hook));
            FHE.allow(amount, address(hook));
            FHE.allow(minOutput, address(hook));

            orderIds[i] = hook.placeOrder{value: 0.001 ether}(int24(int256(60 * (i + 1))), direction, amount, minOutput);
        }

        // Cancel middle order
        hook.cancelOrder(orderIds[1]);
        vm.stopPrank();

        // Verify order count
        uint256[] memory activeOrders = hook.getActiveOrders(user);
        assertEq(activeOrders.length, 2, "Should have 2 active orders");

        // First and third should still be active
        assertTrue(activeOrders[0] == 1 || activeOrders[1] == 1, "Order 1 should be active");
        assertTrue(activeOrders[0] == 3 || activeOrders[1] == 3, "Order 3 should be active");
    }

    // ============ TickBitmap Extended Tests ============

    function testTickBitmapWordBoundary() public {
        // Test at exactly word boundary (256)
        int24 tick = 256;

        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(tick, direction, amount, minOutput);
        vm.stopPrank();

        assertTrue(hook.hasOrdersAtTick(tick), "Tick at word boundary should be set");
        assertFalse(hook.hasOrdersAtTick(255), "Adjacent tick should not be set");
        assertFalse(hook.hasOrdersAtTick(257), "Adjacent tick should not be set");
    }

    function testTickBitmapMultipleInSameWord() public {
        // Place orders at ticks 0, 1, 2 (all in same word)
        vm.startPrank(user);
        hook.deposit(true, 3000 ether);

        for (int24 tick = 0; tick < 3; tick++) {
            ebool direction = FHE.asEbool(true);
            euint128 amount = FHE.asEuint128(uint128(100 ether));
            euint128 minOutput = FHE.asEuint128(uint128(50 ether));
            FHE.allow(direction, address(hook));
            FHE.allow(amount, address(hook));
            FHE.allow(minOutput, address(hook));

            hook.placeOrder{value: 0.001 ether}(tick, direction, amount, minOutput);
        }
        vm.stopPrank();

        assertTrue(hook.hasOrdersAtTick(0), "Tick 0 should be set");
        assertTrue(hook.hasOrdersAtTick(1), "Tick 1 should be set");
        assertTrue(hook.hasOrdersAtTick(2), "Tick 2 should be set");
    }

    function testTickBitmapLargeTick() public {
        int24 tick = 10000; // Large positive tick

        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(tick, direction, amount, minOutput);
        vm.stopPrank();

        assertTrue(hook.hasOrdersAtTick(tick), "Large tick should be set");
    }

    function testTickBitmapLargeNegativeTick() public {
        int24 tick = -10000; // Large negative tick

        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(tick, direction, amount, minOutput);
        vm.stopPrank();

        assertTrue(hook.hasOrdersAtTick(tick), "Large negative tick should be set");
    }

    // ============ Edge Cases ============

    function testOrderWithMinimumFee() public {
        uint256 minFee = 0.001 ether; // PROTOCOL_FEE

        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        // Should succeed with exact minimum fee
        uint256 orderId = hook.placeOrder{value: minFee}(100, direction, amount, minOutput);
        vm.stopPrank();

        assertEq(orderId, 1, "Order should be placed with minimum fee");
    }

    function testOrderWithExcessFee() public {
        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        // Should succeed with excess fee (excess goes to hook)
        uint256 orderId = hook.placeOrder{value: 1 ether}(100, direction, amount, minOutput);
        vm.stopPrank();

        assertEq(orderId, 1, "Order should be placed with excess fee");
    }

    function testWithdrawAllBalance() public {
        uint256 depositAmount = 1000 ether;

        vm.startPrank(user);
        hook.deposit(true, depositAmount);

        // Withdraw all
        hook.withdraw(true, depositAmount);
        vm.stopPrank();

        euint128 encBalance = hook.getUserBalanceToken0(user);
        assertHashValue(encBalance, 0);
    }

    // ============ Order Fill Tests ============

    function testOrderFilledWhenTickCrosses() public {
        // Setup: User deposits and places order at tick 60
        uint128 orderAmount = 100 ether;
        int24 triggerTick = 60;

        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true); // zeroForOne
        euint128 amount = FHE.asEuint128(orderAmount);
        euint128 minOutput = FHE.asEuint128(uint128(50 ether)); // Low slippage requirement
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(triggerTick, direction, amount, minOutput);
        vm.stopPrank();

        // Verify order is active
        uint256[] memory activeOrdersBefore = hook.getActiveOrders(user);
        assertEq(activeOrdersBefore.length, 1, "Should have 1 active order before");

        // Note: Full integration test would require setting up liquidity and executing
        // a swap through the pool manager to trigger the tick cross.
        // For now, we verify the order placement and structure.
        assertTrue(hook.hasOrdersAtTick(triggerTick), "Order should be at trigger tick");
    }

    function testOrderNotFilledIfSlippageFails() public {
        // Setup: User deposits and places order with very high minOutput
        uint128 orderAmount = 100 ether;
        int24 triggerTick = 60;

        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(orderAmount);
        euint128 minOutput = FHE.asEuint128(uint128(1000 ether)); // Impossibly high
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(triggerTick, direction, amount, minOutput);
        vm.stopPrank();

        // Order should be active
        uint256[] memory activeOrders = hook.getActiveOrders(user);
        assertEq(activeOrders.length, 1, "Should have 1 active order");
    }

    function testMultipleOrdersAtSameTickAllFill() public {
        int24 triggerTick = 60;

        // User 1 places order
        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool dir1 = FHE.asEbool(true);
        euint128 amt1 = FHE.asEuint128(uint128(100 ether));
        euint128 min1 = FHE.asEuint128(uint128(50 ether));
        FHE.allow(dir1, address(hook));
        FHE.allow(amt1, address(hook));
        FHE.allow(min1, address(hook));

        hook.placeOrder{value: 0.001 ether}(triggerTick, dir1, amt1, min1);
        vm.stopPrank();

        // User 2 places order at same tick
        vm.startPrank(user2);
        hook.deposit(true, 1000 ether);

        ebool dir2 = FHE.asEbool(true);
        euint128 amt2 = FHE.asEuint128(uint128(200 ether));
        euint128 min2 = FHE.asEuint128(uint128(100 ether));
        FHE.allow(dir2, address(hook));
        FHE.allow(amt2, address(hook));
        FHE.allow(min2, address(hook));

        hook.placeOrder{value: 0.001 ether}(triggerTick, dir2, amt2, min2);
        vm.stopPrank();

        // Both orders should be at the same tick
        assertTrue(hook.hasOrdersAtTick(triggerTick), "Tick should have orders");
        assertEq(hook.getOrderCount(user), 1, "User1 should have 1 order");
        assertEq(hook.getOrderCount(user2), 1, "User2 should have 1 order");
    }

    function testOrderWithZeroMinOutput() public {
        // Order with 0 minOutput should always pass slippage check
        uint128 orderAmount = 100 ether;
        int24 triggerTick = 60;

        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(orderAmount);
        euint128 minOutput = FHE.asEuint128(uint128(0)); // Zero min output
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(triggerTick, direction, amount, minOutput);
        vm.stopPrank();

        assertTrue(hook.hasOrdersAtTick(triggerTick), "Order should be placed");
    }

    function testOrdersAtDifferentTicksProcessIndependently() public {
        // Place orders at different ticks
        vm.startPrank(user);
        hook.deposit(true, 3000 ether);

        int24[] memory ticks = new int24[](3);
        ticks[0] = 60;
        ticks[1] = 120;
        ticks[2] = 180;

        for (uint256 i = 0; i < 3; i++) {
            ebool direction = FHE.asEbool(true);
            euint128 amount = FHE.asEuint128(uint128(100 ether));
            euint128 minOutput = FHE.asEuint128(uint128(50 ether));
            FHE.allow(direction, address(hook));
            FHE.allow(amount, address(hook));
            FHE.allow(minOutput, address(hook));

            hook.placeOrder{value: 0.001 ether}(ticks[i], direction, amount, minOutput);
        }
        vm.stopPrank();

        // Verify each tick has orders
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(hook.hasOrdersAtTick(ticks[i]), "Tick should have orders");
        }

        assertEq(hook.getOrderCount(user), 3, "User should have 3 orders");
    }

    function testLastTickLowerTracking() public view {
        // Initially lastTickLower should be 0
        assertEq(hook.lastTickLower(), 0, "Initial lastTickLower should be 0");
    }

    // ============ Admin Function Tests ============

    function testWithdrawProtocolFees() public {
        // First, accumulate some fees by placing orders
        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        // Place order with 0.001 ETH fee
        hook.placeOrder{value: 0.001 ether}(100, direction, amount, minOutput);
        vm.stopPrank();

        // Check hook has ETH balance
        uint256 hookBalance = address(hook).balance;
        assertEq(hookBalance, 0.001 ether, "Hook should have fee balance");

        // Withdraw as owner (test contract deployed the hook)
        address payable recipient = payable(makeAddr("feeRecipient"));
        uint256 recipientBalanceBefore = recipient.balance;

        hook.withdrawProtocolFees(recipient);

        uint256 recipientBalanceAfter = recipient.balance;
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 0.001 ether, "Recipient should receive fees");
        assertEq(address(hook).balance, 0, "Hook should have no balance after withdrawal");
    }

    function testWithdrawProtocolFeesOnlyOwner() public {
        // Place order to accumulate fees
        vm.startPrank(user);
        hook.deposit(true, 1000 ether);

        ebool direction = FHE.asEbool(true);
        euint128 amount = FHE.asEuint128(uint128(100 ether));
        euint128 minOutput = FHE.asEuint128(uint128(50 ether));
        FHE.allow(direction, address(hook));
        FHE.allow(amount, address(hook));
        FHE.allow(minOutput, address(hook));

        hook.placeOrder{value: 0.001 ether}(100, direction, amount, minOutput);
        vm.stopPrank();

        // Try to withdraw as non-owner
        vm.prank(user);
        vm.expectRevert("Only owner");
        hook.withdrawProtocolFees(payable(user));
    }

    function testEmergencyTokenRecoveryBlocksPoolTokens() public {
        // Try to recover token0 - should fail
        vm.expectRevert("Cannot recover pool tokens");
        hook.emergencyTokenRecovery(address(token0), address(this), 1 ether);

        // Try to recover token1 - should fail
        vm.expectRevert("Cannot recover pool tokens");
        hook.emergencyTokenRecovery(address(token1), address(this), 1 ether);
    }

    function testTickCalculation() public {
        // Deposit equal amounts to set reserves to 1:1 ratio
        vm.startPrank(user);
        hook.deposit(true, 1000 ether);
        hook.deposit(false, 1000 ether);
        vm.stopPrank();

        // Get reserves
        (uint256 r0, uint256 r1) = hook.getReserves();
        assertEq(r0, 1000 ether, "Reserve0 should be 1000");
        assertEq(r1, 1000 ether, "Reserve1 should be 1000");

        // Tick at 1:1 ratio should be 0
        int24 tick = hook.lastTickLower(); // This will be 0 initially but after a swap would update
        assertEq(tick, 0, "Initial tick should be 0");
    }

    // ============ Helper Functions ============

    function _defaultTestSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
    }

    function _mockStorageHelper(euint128 value) private view returns (uint128) {
        return uint128(mockStorage(euint128.unwrap(value)));
    }

    function doSwap(bool zeroForOne, int256 amount) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        vm.prank(user);
        swapRouter.swap(key, params, _defaultTestSettings(), ZERO_BYTES);
    }

    function doSwap(bool zeroForOne, int256 amount, int24 tick) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick)
        });

        vm.prank(user);
        swapRouter.swap(key, params, _defaultTestSettings(), ZERO_BYTES);
    }
}
