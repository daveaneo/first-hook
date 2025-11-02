// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import "forge-std/console.sol";

/// @title IFlashLoanReceiver
/// @notice Interface that flash loan borrowers must implement
/// @dev This callback pattern ensures borrowers can use the funds and repay in one transaction
interface IFlashLoanReceiver {
    /// @notice Called by the hook after tokens are sent to the borrower
    /// @dev MUST return the function selector to prove the callback succeeded
    /// @dev Borrower MUST transfer `amount + fee` back to the hook before returning
    /// @param initiator The address that called flashLoan() (msg.sender in flashLoan)
    /// @param currency The currency that was borrowed
    /// @param amount The amount borrowed (not including fee)
    /// @param fee The fee that must be paid (in addition to amount)
    /// @param data Arbitrary data passed by the initiator
    /// @return Must return IFlashLoanReceiver.onFlashLoan.selector (0x23e30c8b)
    function onFlashLoan(
        address initiator,
        Currency currency,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes4);
}

/// @title FlashLoanHook
/// @notice A Uniswap v4 hook that provides flash loan functionality with auto-compounding yields
/// @dev All liquidity providers receive shares in the lending pool and earn flash loan fees proportionally
///
/// HOW IT WORKS:
/// 1. Liquidity providers add liquidity to the Uniswap pool
/// 2. The hook tracks their deposits and mints shares (like ERC-4626)
/// 3. Borrowers can take flash loans from the pool's liquidity
/// 4. Flash loan fees are added to the pool WITHOUT minting new shares
/// 5. This increases the value of each share = auto-compounding yield!
///
/// EXAMPLE:
/// - Alice deposits 100 tokens, gets 100 shares (1:1 ratio)
/// - Bob deposits 100 tokens, gets 100 shares (total: 200 tokens, 200 shares)
/// - Flash loan charges 1 token fee → total assets becomes 201 tokens
/// - Each share is now worth 201/200 = 1.005 tokens (auto-compounding!)
/// - Alice can withdraw 100 * 201/200 = 100.5 tokens
/// - Bob can withdraw 100 * 201/200 = 100.5 tokens
contract FlashLoanHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when a provider deposits liquidity into the lending pool
    /// @param poolId The pool identifier
    /// @param currency The currency deposited
    /// @param provider The address of the liquidity provider
    /// @param amount The amount of tokens deposited
    /// @param shares The number of shares minted to the provider
    event LendingPoolDeposit(PoolId indexed poolId, Currency indexed currency, address indexed provider, uint256 amount, uint256 shares);

    /// @notice Emitted when a provider withdraws liquidity from the lending pool
    /// @param poolId The pool identifier
    /// @param currency The currency withdrawn
    /// @param provider The address of the liquidity provider
    /// @param amount The amount of tokens withdrawn
    /// @param shares The number of shares burned from the provider
    event LendingPoolWithdraw(PoolId indexed poolId, Currency indexed currency, address indexed provider, uint256 amount, uint256 shares);

    /// @notice Emitted when a flash loan is executed
    /// @param poolId The pool identifier
    /// @param currency The currency borrowed
    /// @param borrower The address that initiated the flash loan
    /// @param amount The amount borrowed (not including fee)
    /// @param fee The fee charged for the flash loan
    event FlashLoan(PoolId indexed poolId, Currency indexed currency, address indexed borrower, uint256 amount, uint256 fee);

    /// @notice Emitted when the owner changes the flash loan fee rate
    /// @param oldRate The previous fee rate in basis points
    /// @param newRate The new fee rate in basis points
    event FeeRateChanged(uint256 oldRate, uint256 newRate);

    // ============================================
    // Errors
    // ============================================

    /// @notice Thrown when a non-owner tries to call an owner-only function
    error Unauthorized();

    /// @notice Thrown when attempting to borrow more than available in the lending pool
    error InsufficientLendingPoolBalance();

    /// @notice Thrown when flash loan borrower doesn't return the correct selector
    error FlashLoanNotRepaid();

    /// @notice Thrown when trying to borrow zero amount
    error InvalidAmount();

    /// @notice Thrown when trying to withdraw but user has no shares
    error NoSharesOwned();

    // ============================================
    // State Variables
    // ============================================

    /// @notice Total assets (tokens) in the lending pool for each pool and currency
    /// @dev This increases when:
    ///      - Providers deposit liquidity
    ///      - Flash loan fees are collected (auto-compounding!)
    ///      Decreases when:
    ///      - Providers withdraw liquidity
    /// @dev Mapping: poolId => currency => total assets
    mapping(PoolId => mapping(Currency => uint256)) public lendingPoolAssets;

    /// @notice Individual user shares in the lending pool (ERC-4626 vault style)
    /// @dev Shares represent proportional ownership of the lending pool
    ///      Formula to get user's asset value: (userShares * totalAssets) / totalShares
    /// @dev Mapping: poolId => currency => user address => shares owned
    mapping(PoolId => mapping(Currency => mapping(address => uint256))) public userShares;

    /// @notice Total shares issued for each pool and currency
    /// @dev Used to calculate share value: each share worth (totalAssets / totalShares)
    ///      When flash loan fees are added to totalAssets WITHOUT increasing totalShares,
    ///      each existing share becomes more valuable = auto-compounding!
    /// @dev Mapping: poolId => currency => total shares
    mapping(PoolId => mapping(Currency => uint256)) public totalShares;

    /// @notice Fee charged for flash loans, in basis points
    /// @dev 1 basis point = 0.01%
    ///      Examples: 10 = 0.1%, 50 = 0.5%, 100 = 1%
    ///      Fee calculation: fee = (borrowAmount * flashLoanFeeRate) / 10000
    uint256 public flashLoanFeeRate;

    /// @notice Address that owns this contract and can adjust the fee rate
    address public owner;

    // ============================================
    // Modifiers
    // ============================================

    /// @notice Restricts function access to only the contract owner
    /// @dev Reverts with Unauthorized() if caller is not the owner
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ============================================
    // Constructor
    // ============================================

    /// @notice Initializes the FlashLoanHook
    /// @param _manager The Uniswap v4 PoolManager contract
    /// @param _initialFeeRate The initial flash loan fee rate in basis points
    /// @param _owner The address that will own this contract
    constructor(
        IPoolManager _manager,
        uint256 _initialFeeRate,
        address _owner
    ) BaseHook(_manager) {
        flashLoanFeeRate = _initialFeeRate;
        owner = _owner;
    }

    // ============================================
    // Hook Permissions
    // ============================================

    /// @notice Declares which hook callbacks this contract wants to receive
    /// @dev This function is called by Uniswap v4 to determine which hooks to enable
    ///      Only hooks marked as `true` will be called by the PoolManager
    /// @return Hooks.Permissions struct with flags for each possible hook
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,           // Don't need - pool setup is standard
                afterInitialize: false,            // Don't need - no initialization logic required
                beforeAddLiquidity: false,         // Don't need - we track AFTER liquidity is added
                beforeRemoveLiquidity: false,      // Don't need - we track AFTER liquidity is removed
                afterAddLiquidity: true,           // ✓ ENABLED - track deposits and mint shares
                afterRemoveLiquidity: true,        // ✓ ENABLED - track withdrawals and burn shares
                beforeSwap: false,                 // Don't need - liquidity stays in pool during swaps
                afterSwap: false,                  // Don't need - no swap-related logic
                beforeDonate: false,               // Don't need - donations not relevant
                afterDonate: false,                // Don't need - donations not relevant
                beforeSwapReturnDelta: false,      // Don't need - not modifying swap deltas
                afterSwapReturnDelta: false,       // Don't need - not modifying swap deltas
                afterAddLiquidityReturnDelta: false,    // Don't need - not modifying liquidity deltas
                afterRemoveLiquidityReturnDelta: false  // Don't need - not modifying liquidity deltas
            });
    }

    // ============================================
    // Hook Functions
    // ============================================

    /// @notice Hook called by PoolManager AFTER liquidity has been added to the pool
    /// @dev This is where we track deposits and mint lending pool shares to providers
    /// @param sender The address that called modifyLiquidity (usually a router contract)
    /// @param key The pool key identifying which pool was modified
    /// @param params The liquidity modification parameters (tick range, liquidity delta)
    /// @param delta The balance changes that occurred (negative = tokens taken from user)
    /// @param hookData Arbitrary data passed from the caller (we use it to identify the actual user)
    /// @return selector The function selector to confirm the hook executed successfully
    /// @return delta We return the original delta unchanged
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Extract the REAL user address from hookData
        // Why? Because `sender` is the router contract, not the actual user
        // The router should pass the user's address via hookData
        address user = sender;
        if (hookData.length > 0) {
            user = abi.decode(hookData, (address));
        }

        // BalanceDelta represents token changes from the USER's perspective
        // In afterAddLiquidity, amounts will ALWAYS be:
        //   - Negative: User deposited this currency (tokens taken FROM user)
        //   - Zero: User didn't deposit this currency (single-sided liquidity)
        //   - NEVER positive (that would mean user received tokens, which doesn't happen when adding liquidity)
        int128 amount0 = delta.amount0();  // Currency0 change (negative = deposited, zero = not deposited)
        int128 amount1 = delta.amount1();  // Currency1 change (negative = deposited, zero = not deposited)

        console.log("After add liquidity - Lending pool addition");
        console.logInt(amount0);
        console.logInt(amount1);

        // Check if user deposited currency0
        // amount0 < 0 means "user deposited some currency0"
        // amount0 == 0 means "single-sided liquidity - user only deposited currency1"
        if (amount0 < 0) {
            // Convert negative delta to positive deposit amount
            // Example: amount0 = -1000 → depositAmount = 1000
            uint256 depositAmount = uint256(int256(-amount0));
            console.log("Depositing to currency0:", depositAmount);
            // Mint shares to the user proportional to their deposit
            _depositToLendingPool(poolId, key.currency0, user, depositAmount);
        }

        // Check if user deposited currency1
        // amount1 < 0 means "user deposited some currency1"
        // amount1 == 0 means "single-sided liquidity - user only deposited currency0"
        if (amount1 < 0) {
            // Convert negative delta to positive deposit amount
            // Example: amount1 = -500 → depositAmount = 500
            uint256 depositAmount = uint256(int256(-amount1));
            console.log("Depositing to currency1:", depositAmount);
            // Mint shares to the user proportional to their deposit
            _depositToLendingPool(poolId, key.currency1, user, depositAmount);
        }

        // Return the function selector (required by hook interface)
        // and pass through the original delta unchanged
        return (this.afterAddLiquidity.selector, delta);
    }

    /// @notice Hook called by PoolManager AFTER liquidity has been removed from the pool
    /// @dev This is where we track withdrawals and burn lending pool shares from providers
    /// @param sender The address that called modifyLiquidity (usually a router contract)
    /// @param key The pool key identifying which pool was modified
    /// @param params The liquidity modification parameters (tick range, liquidity delta)
    /// @param delta The balance changes that occurred (positive = tokens given to user)
    /// @param hookData Arbitrary data passed from the caller (we use it to identify the actual user)
    /// @return selector The function selector to confirm the hook executed successfully
    /// @return delta We return the original delta unchanged
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Extract the REAL user address from hookData
        // Same logic as afterAddLiquidity - sender is the router, not the actual user
        address user = sender;
        if (hookData.length > 0) {
            user = abi.decode(hookData, (address));
        }

        // BalanceDelta represents token changes from the USER's perspective
        // In afterRemoveLiquidity, amounts will ALWAYS be:
        //   - Positive: User withdrew this currency (tokens given TO user)
        //   - Zero: User didn't withdraw this currency (single-sided withdrawal)
        //   - NEVER negative (that would mean user deposited tokens, which doesn't happen when removing liquidity)
        int128 amount0 = delta.amount0();  // Currency0 change (positive = withdrew, zero = didn't withdraw)
        int128 amount1 = delta.amount1();  // Currency1 change (positive = withdrew, zero = didn't withdraw)

        // Check if user withdrew currency0
        // amount0 > 0 means "user withdrew some currency0"
        // amount0 == 0 means "single-sided withdrawal - user only withdrew currency1"
        if (amount0 > 0) {
            uint256 withdrawAmount = uint256(int256(amount0));
            // Only process withdrawal if user actually has shares to burn
            // This check handles edge cases where someone removes liquidity but didn't
            // have lending pool shares (they never passed hookData when depositing)
            if (userShares[poolId][key.currency0][user] > 0) {
                // Burn shares proportional to the withdrawal amount
                _withdrawFromLendingPool(poolId, key.currency0, user, withdrawAmount);
            }
        }

        // Check if user withdrew currency1
        // amount1 > 0 means "user withdrew some currency1"
        // amount1 == 0 means "single-sided withdrawal - user only withdrew currency0"
        if (amount1 > 0) {
            uint256 withdrawAmount = uint256(int256(amount1));
            // Only process withdrawal if user actually has shares to burn
            if (userShares[poolId][key.currency1][user] > 0) {
                // Burn shares proportional to the withdrawal amount
                _withdrawFromLendingPool(poolId, key.currency1, user, withdrawAmount);
            }
        }

        // Return the function selector (required by hook interface)
        // and pass through the original delta unchanged
        return (this.afterRemoveLiquidity.selector, delta);
    }

    // ============================================
    // Flash Loan Functions
    // ============================================

    /// @notice Execute a flash loan - borrow tokens, use them, and repay in one transaction
    /// @dev This is the entry point for flash loans. It validates the request and initiates
    ///      the unlock callback pattern required by Uniswap v4
    /// @param poolId The pool ID to borrow from
    /// @param currency The currency to borrow (either currency0 or currency1)
    /// @param amount The amount to borrow (not including fee)
    /// @param recipient The contract that will receive the loaned tokens (must implement IFlashLoanReceiver)
    /// @param data Arbitrary data to pass to the recipient's callback
    ///
    /// EXAMPLE FLOW:
    /// 1. Arbitrage bot calls flashLoan(poolId, USDC, 10000 USDC, botAddress, "")
    /// 2. Hook validates 10000 USDC is available
    /// 3. Hook calls poolManager.unlock() which triggers unlockCallback()
    /// 4. unlockCallback() sends 10000 USDC to bot via take()
    /// 5. unlockCallback() calls bot.onFlashLoan() - bot does arbitrage
    /// 6. Bot must return 10000 + fee USDC to hook
    /// 7. Hook settles debt with PoolManager
    /// 8. Fee is added to lendingPoolAssets (auto-compounds for all providers!)
    function flashLoan(
        PoolId poolId,
        Currency currency,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external {
        // Validate the flash loan request
        if (amount == 0) revert InvalidAmount();
        if (lendingPoolAssets[poolId][currency] < amount) revert InsufficientLendingPoolBalance();

        // Pack all parameters into bytes for the unlock callback
        // We need to preserve msg.sender (initiator) because inside unlockCallback,
        // msg.sender will be the PoolManager
        bytes memory unlockData = abi.encode(poolId, currency, amount, recipient, msg.sender, data);

        // Call unlock - this is required by Uniswap v4's flash accounting system
        // PoolManager will immediately call back to our unlockCallback() function
        // All token operations (take/settle/clear) MUST happen inside the callback
        poolManager.unlock(unlockData);
    }

    /// @notice Callback from PoolManager.unlock() - this is where the actual flash loan happens
    /// @dev Only callable by PoolManager during the unlock context
    ///      This function MUST:
    ///      1. Send tokens to borrower (take)
    ///      2. Call borrower's callback
    ///      3. Receive repayment from borrower
    ///      4. Settle debt with PoolManager (settle + clear)
    ///      5. Update accounting
    /// @param data The encoded flash loan parameters from flashLoan()
    /// @return Empty bytes (required by unlock callback interface)
    ///
    /// UNISWAP V4 UNLOCK PATTERN:
    /// Uniswap v4 uses "transient storage" (EIP-1153) to track debts within a transaction.
    /// - take() creates a negative delta (debt) in transient storage
    /// - settle() pays off the debt
    /// - clear() handles any positive balance remaining
    /// - unlock() reverts if any deltas are not zero at the end
    ///
    /// WHY THIS PATTERN?
    /// It allows flash operations without actually moving all tokens in/out of the pool!
    /// Only the net balance change is settled at the end = gas savings.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Security: Only PoolManager can call this function
        // This prevents anyone from calling our flash loan logic directly
        require(msg.sender == address(poolManager), "Only PoolManager");

        // Unpack the flash loan parameters that were encoded in flashLoan()
        (
            PoolId poolId,
            Currency currency,
            uint256 amount,
            address recipient,
            address initiator,
            bytes memory borrowerData
        ) = abi.decode(data, (PoolId, Currency, uint256, address, address, bytes));

        // Calculate the fee to charge
        // Example: amount = 10000, flashLoanFeeRate = 10 (0.1%)
        //          fee = (10000 * 10) / 10000 = 10 tokens
        uint256 fee = (amount * flashLoanFeeRate) / 10000;

        console.log("Flash loan executing:", amount, "Fee:", fee);

        // ========================================
        // STEP 1: TAKE - Send tokens to borrower
        // ========================================
        // poolManager.take() does two things:
        // 1. Transfers `amount` tokens from PoolManager to `recipient`
        // 2. Creates a DEBT in transient storage that must be repaid before unlock() ends
        //
        // At this point:
        // - Borrower has the tokens
        // - PoolManager has a debt recorded (in transient storage, not state)
        // - We MUST settle this debt before unlockCallback returns
        poolManager.take(currency, recipient, amount);

        // ========================================
        // STEP 2: Borrower callback
        // ========================================
        // Now call the borrower's callback so they can use the tokens
        // The borrower MUST:
        // 1. Do something with the tokens (arbitrage, refinance, whatever)
        // 2. Transfer `amount + fee` back to THIS contract (the hook)
        // 3. Return the correct function selector to prove success
        bytes4 result = IFlashLoanReceiver(recipient).onFlashLoan(
            initiator,      // Who initiated the flash loan
            currency,       // What token was borrowed
            amount,         // How much was borrowed
            fee,            // How much fee must be paid
            borrowerData    // Any extra data from the initiator
        );

        // Verify the callback succeeded
        // If the borrower doesn't return the correct selector, they probably failed
        if (result != IFlashLoanReceiver.onFlashLoan.selector) {
            revert FlashLoanNotRepaid();
        }

        // ========================================
        // STEP 3: SETTLE - Verify repayment
        // ========================================
        // At this point, the borrower should have transferred `amount + fee` to us (the hook)
        // Now we need to:
        // 1. Transfer these tokens to PoolManager
        // 2. Call settle() to clear the debt (amount)
        // 3. Call clear() to handle the extra fee

        uint256 repayAmount = amount + fee;

        // For ERC20 tokens (not native ETH)
        if (!currency.isAddressZero()) {
            // Step 3a: Sync - checkpoint the PoolManager's current balance
            // This is REQUIRED before sending ERC20 tokens to PoolManager
            // It tells PoolManager "remember your current balance, compare to it after tokens arrive"
            poolManager.sync(currency);

            // Step 3b: Transfer the full repayment (amount + fee) to PoolManager
            // Now PoolManager has more tokens than it expects
            currency.transfer(address(poolManager), repayAmount);

            // Step 3c: Settle - clear the debt
            // PoolManager compares current balance to the synced balance
            // Difference should be at least `amount` (the debt from take())
            // settle() uses that difference to clear the debt delta in transient storage
            //
            // Before settle(): PoolManager delta = -amount (debt)
            // After settle(): PoolManager delta = +fee (we sent amount + fee, debt was amount)
            poolManager.settle();

            // Step 3d: Clear the fee - zero out the positive balance
            // We still have a positive delta of `fee` in transient storage
            // clear() zeroes this out, keeping the fee locked in the pool PERMANENTLY
            // This is what makes the fees stay in the pool and auto-compound!
            //
            // Before clear(): PoolManager delta = +fee
            // After clear(): PoolManager delta = 0 ✓
            poolManager.clear(currency, fee);
        } else {
            // For native ETH (special case)
            // The value was sent along with the transaction
            poolManager.settle();
            poolManager.clear(currency, fee);
        }

        // ========================================
        // STEP 4: Update lending pool accounting
        // ========================================
        // Increase lendingPoolAssets by the fee amount
        // This is KEY to auto-compounding:
        // - totalAssets increases by `fee`
        // - totalShares stays the same
        // - Therefore, each share is now worth more!
        //
        // Example:
        // Before: 1000 assets, 1000 shares, 1 share = 1 asset
        // After:  1010 assets, 1000 shares, 1 share = 1.01 assets (1% gain!)
        lendingPoolAssets[poolId][currency] += fee;

        emit FlashLoan(poolId, currency, initiator, amount, fee);

        // Return empty bytes (required by the unlock callback interface)
        return "";
    }

    // ============================================
    // Admin Functions
    // ============================================

    /// @notice Update the flash loan fee rate (only callable by owner)
    /// @dev This affects all future flash loans, not existing ones
    /// @param newFeeRate New fee rate in basis points (e.g., 10 = 0.1%, 100 = 1%)
    ///
    /// EXAMPLE:
    /// If fee is currently 10 basis points (0.1%) and you want 50 basis points (0.5%):
    /// setFeeRate(50)
    function setFeeRate(uint256 newFeeRate) external onlyOwner {
        uint256 oldRate = flashLoanFeeRate;
        flashLoanFeeRate = newFeeRate;
        emit FeeRateChanged(oldRate, newFeeRate);
    }

    // ============================================
    // View Functions
    // ============================================

    /// @notice Preview how many shares would be minted for a deposit (ERC-4626 style)
    /// @dev This implements the share calculation formula:
    ///      - First depositor: 1:1 ratio (100 tokens = 100 shares)
    ///      - Later depositors: proportional (shares = assets * totalShares / totalAssets)
    /// @param poolId The pool identifier
    /// @param currency The currency being deposited
    /// @param assets The amount of tokens to deposit
    /// @return shares The number of shares that would be minted
    ///
    /// EXAMPLE:
    /// Pool state: 1000 assets, 1000 shares
    /// Someone deposits 100 assets
    /// shares = (100 * 1000) / 1000 = 100 shares
    ///
    /// After flash loan fee: 1000 assets → 1010 assets (still 1000 shares)
    /// Someone deposits 100 assets
    /// shares = (100 * 1000) / 1010 = 99 shares (each share worth more now!)
    function previewDeposit(PoolId poolId, Currency currency, uint256 assets) public view returns (uint256 shares) {
        uint256 totalAssets = lendingPoolAssets[poolId][currency];
        uint256 _totalShares = totalShares[poolId][currency];

        // First deposit gets 1:1 ratio
        if (_totalShares == 0) {
            return assets;
        }

        // Subsequent deposits get proportional shares
        // Formula: shares = (assets * totalShares) / totalAssets
        return (assets * _totalShares) / totalAssets;
    }

    /// @notice Preview how many assets would be returned for burning shares (ERC-4626 style)
    /// @dev This implements the withdrawal calculation formula:
    ///      assets = (shares * totalAssets) / totalShares
    /// @param poolId The pool identifier
    /// @param currency The currency being withdrawn
    /// @param shares The number of shares to burn
    /// @return assets The amount of tokens that would be returned
    ///
    /// EXAMPLE:
    /// Pool state: 1010 assets, 1000 shares (grew from flash loan fees!)
    /// User has 100 shares
    /// assets = (100 * 1010) / 1000 = 101 tokens
    /// User deposited 100, getting back 101 = 1% auto-compounded gain!
    function previewWithdraw(PoolId poolId, Currency currency, uint256 shares) public view returns (uint256 assets) {
        uint256 totalAssets = lendingPoolAssets[poolId][currency];
        uint256 _totalShares = totalShares[poolId][currency];

        // No shares = no assets
        if (_totalShares == 0) return 0;

        // Calculate asset value of shares
        // Formula: assets = (shares * totalAssets) / totalShares
        return (shares * totalAssets) / _totalShares;
    }

    /// @notice Get user's balance in the lending pool (in tokens, not shares)
    /// @dev Convenience function that converts user's shares to asset value
    /// @param poolId The pool identifier
    /// @param currency The currency to check
    /// @param user The user address to check
    /// @return The amount of tokens the user can withdraw
    ///
    /// EXAMPLE:
    /// User has 100 shares
    /// Pool has 1010 total assets and 1000 total shares
    /// User balance = (100 * 1010) / 1000 = 101 tokens
    function getUserBalance(PoolId poolId, Currency currency, address user) external view returns (uint256) {
        uint256 shares = userShares[poolId][currency][user];
        return previewWithdraw(poolId, currency, shares);
    }

    // ============================================
    // Internal Functions
    // ============================================

    /// @notice Internal function to handle lending pool deposits and mint shares
    /// @dev Called by _afterAddLiquidity when a user adds liquidity to the pool
    ///      This implements the ERC-4626 vault deposit pattern
    /// @param poolId The pool identifier
    /// @param currency The currency being deposited
    /// @param provider The address providing the liquidity
    /// @param amount The amount of tokens being deposited
    ///
    /// HOW SHARE MINTING WORKS:
    /// - First depositor: Gets 1:1 shares (100 tokens = 100 shares)
    /// - Later depositors: Get proportional shares based on current pool state
    ///
    /// EXAMPLE:
    /// Initial state: 0 assets, 0 shares
    /// Alice deposits 100 tokens → gets 100 shares
    /// State: 100 assets, 100 shares
    ///
    /// Flash loan adds 10 token fee → 110 assets, still 100 shares
    /// Bob deposits 110 tokens → gets (110 * 100) / 110 = 100 shares
    /// State: 220 assets, 200 shares
    ///
    /// Both Alice and Bob own 100 shares, each worth 220/200 = 1.1 tokens
    function _depositToLendingPool(
        PoolId poolId,
        Currency currency,
        address provider,
        uint256 amount
    ) internal {
        // Calculate how many shares to mint for this deposit
        // Uses previewDeposit() which implements the proportional share formula
        uint256 shares = previewDeposit(poolId, currency, amount);

        // Update state - ORDER MATTERS!
        // We update these in this specific order to maintain consistency
        lendingPoolAssets[poolId][currency] += amount;        // Increase total assets
        userShares[poolId][currency][provider] += shares;     // Give shares to provider
        totalShares[poolId][currency] += shares;              // Increase total shares

        console.log("Lending pool deposit:", amount, "Shares:", shares);
        emit LendingPoolDeposit(poolId, currency, provider, amount, shares);
    }

    /// @notice Internal function to handle lending pool withdrawals and burn shares
    /// @dev Called by _afterRemoveLiquidity when a user removes liquidity from the pool
    ///      This implements the ERC-4626 vault withdrawal pattern
    /// @param poolId The pool identifier
    /// @param currency The currency being withdrawn
    /// @param provider The address withdrawing liquidity
    /// @param amount The amount of tokens being withdrawn (for proportional share burning)
    ///
    /// HOW SHARE BURNING WORKS:
    /// - User's shares are converted to asset value
    /// - We burn shares proportionally
    /// - User gets back MORE tokens if flash loan fees accumulated (auto-compounding!)
    ///
    /// EXAMPLE:
    /// User has 100 shares
    /// Pool: 1100 total assets, 1000 total shares (10% gain from fees)
    /// User share value: (100 * 1100) / 1000 = 110 tokens
    /// User deposited 100, withdrawing 110 = 10% auto-compounded gain!
    function _withdrawFromLendingPool(
        PoolId poolId,
        Currency currency,
        address provider,
        uint256 amount
    ) internal {
        // Get user's current share balance
        uint256 shares = userShares[poolId][currency][provider];
        if (shares == 0) revert NoSharesOwned();

        // Calculate how many assets these shares are worth
        // This includes any flash loan fees that have accumulated!
        uint256 assetsToReturn = previewWithdraw(poolId, currency, shares);

        // Safety check: Can't withdraw more than pool has
        // This should never happen in normal operation, but protects against edge cases
        if (assetsToReturn > lendingPoolAssets[poolId][currency]) {
            assetsToReturn = lendingPoolAssets[poolId][currency];
        }

        // Calculate how many shares to burn
        // Normally we burn all shares, but in edge cases we burn proportionally
        uint256 sharesToBurn = shares;
        if (assetsToReturn < previewWithdraw(poolId, currency, shares)) {
            // Edge case: Not enough assets available, burn shares proportionally
            sharesToBurn = (amount * totalShares[poolId][currency]) / lendingPoolAssets[poolId][currency];
        }

        // Update state - ORDER MATTERS!
        // We update these in this specific order to maintain consistency
        lendingPoolAssets[poolId][currency] -= assetsToReturn;   // Decrease total assets
        userShares[poolId][currency][provider] -= sharesToBurn;  // Burn user's shares
        totalShares[poolId][currency] -= sharesToBurn;           // Decrease total shares

        console.log("Lending pool withdrawal:", assetsToReturn, "Shares burned:", sharesToBurn);
        emit LendingPoolWithdraw(poolId, currency, provider, assetsToReturn, sharesToBurn);
    }
}
