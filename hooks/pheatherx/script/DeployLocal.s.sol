// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PheatherX} from "../src/PheatherX.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple mock token for local testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title DeployLocal
/// @notice Deploy everything needed for local testing (tokens, pool manager, hook)
/// @dev Run with: forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast
contract DeployLocal is Script {
    // Configuration
    uint256 constant SWAP_FEE_BPS = 30; // 0.3%
    int24 constant TICK_SPACING = 60;
    uint24 constant POOL_FEE = 3000;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Initial token mint amount
    uint256 constant INITIAL_MINT = 1_000_000 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)); // Default Anvil key
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Local Deployment ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock tokens
        MockERC20 tokenA = new MockERC20("Token A", "TKNA");
        MockERC20 tokenB = new MockERC20("Token B", "TKNB");

        // Sort tokens (required by Uniswap)
        (address token0, address token1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        console.log("Token0:", token0);
        console.log("Token1:", token1);

        // 2. Deploy PoolManager
        PoolManager poolManager = new PoolManager(deployer);
        console.log("PoolManager:", address(poolManager));

        // 3. Deploy hook
        // Note: Hook address must have correct flag bits set
        // Required flags: BEFORE_ADD_LIQUIDITY, BEFORE_REMOVE_LIQUIDITY,
        //                 BEFORE_SWAP, AFTER_SWAP, BEFORE_SWAP_RETURNS_DELTA
        // Note: For local testing, we deploy then etch the bytecode to correct address
        // In production, use CREATE2 mining
        PheatherX hookImpl = new PheatherX(
            IPoolManager(address(poolManager)),
            token0,
            token1,
            SWAP_FEE_BPS
        );

        console.log("Hook deployed at:", address(hookImpl));

        // 5. Mint tokens to deployer
        MockERC20(token0).mint(deployer, INITIAL_MINT);
        MockERC20(token1).mint(deployer, INITIAL_MINT);
        console.log("Minted", INITIAL_MINT / 1e18, "of each token to deployer");

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("PoolManager:", address(poolManager));
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Hook:", address(hookImpl));
        console.log("Hook Owner:", hookImpl.owner());
        console.log("\n=== Configuration ===");
        console.log("Swap Fee (BPS):", SWAP_FEE_BPS);
        console.log("Pool Fee:", POOL_FEE);
        console.log("Tick Spacing:", TICK_SPACING);
    }
}
