// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PheatherX} from "../src/PheatherX.sol";

/// @title DeployPheatherX
/// @notice Deployment script for PheatherX - a private execution layer built on FHE
/// @dev Run with: forge script script/DeployPheatherX.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployPheatherX is Script {
    // Uniswap v4 PoolManager address (update for target network)
    // Mainnet: TBD
    // Sepolia: 0x...
    // Fhenix Testnet: TBD
    address constant POOL_MANAGER = address(0); // UPDATE THIS

    // Token addresses (update for target network)
    address constant TOKEN0 = address(0); // UPDATE THIS (must be < TOKEN1)
    address constant TOKEN1 = address(0); // UPDATE THIS

    // Hook configuration
    uint256 constant SWAP_FEE_BPS = 30; // 0.3% swap fee
    int24 constant TICK_SPACING = 60;
    uint24 constant POOL_FEE = 3000; // 0.3%

    // Initial sqrt price (1:1 ratio)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        // Validate configuration
        require(POOL_MANAGER != address(0), "Set POOL_MANAGER address");
        require(TOKEN0 != address(0), "Set TOKEN0 address");
        require(TOKEN1 != address(0), "Set TOKEN1 address");
        require(TOKEN0 < TOKEN1, "TOKEN0 must be less than TOKEN1");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Pool Manager:", POOL_MANAGER);
        console.log("Token0:", TOKEN0);
        console.log("Token1:", TOKEN1);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy hook
        // Note: Hook address must have correct flag bits:
        // BEFORE_ADD_LIQUIDITY, BEFORE_REMOVE_LIQUIDITY,
        // BEFORE_SWAP, AFTER_SWAP, BEFORE_SWAP_RETURNS_DELTA
        //
        // For production, use HookMiner to find a CREATE2 salt that produces
        // an address with the correct flag bits
        PheatherX hook = new PheatherX(
            IPoolManager(POOL_MANAGER),
            TOKEN0,
            TOKEN1,
            SWAP_FEE_BPS
        );

        console.log("Hook deployed at:", address(hook));
        console.log("Hook owner:", hook.owner());

        // Initialize the pool with the hook
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        IPoolManager(POOL_MANAGER).initialize(poolKey, SQRT_PRICE_1_1);
        console.log("Pool initialized");

        vm.stopBroadcast();

        // Log deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("Hook Address:", address(hook));
        console.log("Pool Fee:", POOL_FEE);
        console.log("Tick Spacing:", TICK_SPACING);
        console.log("Swap Fee (BPS):", SWAP_FEE_BPS);
    }
}

/// @title DeployPheatherXWithMining
/// @notice Deployment script that mines for correct hook address
/// @dev Use this for production deployments where hook address must have correct flags
contract DeployPheatherXWithMining is Script {
    using CurrencyLibrary for Currency;

    function run() external pure {
        // This script would use HookMiner to find a CREATE2 salt
        // that produces an address with the correct flag bits.
        //
        // The process:
        // 1. Define the desired hook flags
        // 2. Use HookMiner.find() to brute-force a salt
        // 3. Deploy using CREATE2 with that salt
        //
        // Example:
        // (address hookAddress, bytes32 salt) = HookMiner.find(
        //     CREATE2_DEPLOYER,
        //     flags,
        //     creationCode,
        //     constructorArgs
        // );

        revert("Use HookMiner for production deployments - see Uniswap v4 examples");
    }
}
