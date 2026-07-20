// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {LiquidationManager} from "../src/LiquidationManager.sol";
import {DutchAuctionManager} from "../src/DutchAuctionManager.sol";
import {ArbitrageManager} from "../src/ArbitrageManager.sol";
import {RepegManager} from "../src/RepegManager.sol";
import {StableGuard} from "../src/StableGuard.sol";
import {Timelock} from "../src/Timelock.sol";
import {Constants} from "../src/Constants.sol";
import {IRepegManager} from "../src/interfaces/IRepegManager.sol";

/// @notice Deploys and wires the full StableGuard protocol.
/// @dev StableGuard and RepegManager reference each other, so the StableGuard
///      address is predicted from the deployer nonce before RepegManager is
///      deployed and asserted afterwards. Set ETH_USD_FEED for non-mainnet runs.
contract Deploy is Script {
    address internal constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function run()
        external
        returns (
            StableGuard stableGuard,
            PriceOracle priceOracle,
            CollateralManager collateralManager,
            LiquidationManager liquidationManager,
            DutchAuctionManager dutchAuctionManager,
            ArbitrageManager arbitrageManager,
            RepegManager repegManager
        )
    {
        address ethUsdFeed = vm.envOr("ETH_USD_FEED", MAINNET_ETH_USD_FEED);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        priceOracle = new PriceOracle();
        collateralManager = new CollateralManager(address(priceOracle));
        liquidationManager = new LiquidationManager(deployer, address(priceOracle), address(collateralManager));
        dutchAuctionManager = new DutchAuctionManager(address(priceOracle), address(collateralManager));

        // Timelock is owned by the deployer/multisig and passed into StableGuard,
        // so governance changes actually pass through its delay.
        Timelock timelock = new Timelock(2 days);

        // ArbitrageManager and RepegManager take the stable token (StableGuard itself)
        // in their constructors: predict its address. After the Timelock, the next
        // three CREATEs are ArbitrageManager, RepegManager, then StableGuard.
        address predictedGuard = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);

        arbitrageManager =
            new ArbitrageManager(Constants.UNISWAP_V2_ROUTER, address(priceOracle), Constants.WETH, predictedGuard);

        repegManager = new RepegManager(
            predictedGuard,
            address(priceOracle),
            predictedGuard,
            address(arbitrageManager),
            IRepegManager.RepegConfig({
                targetPrice: uint128(Constants.PRICE_PRECISION), // $1.00
                deviationThreshold: uint64(Constants.REPEG_DEVIATION_THRESHOLD),
                repegCooldown: uint32(Constants.REPEG_COOLDOWN),
                arbitrageWindow: uint32(Constants.REPEG_ARBITRAGE_WINDOW),
                incentiveRate: uint16(Constants.REPEG_INCENTIVE_RATE),
                maxRepegPerDay: uint8(Constants.MAX_REPEG_PER_DAY),
                enabled: true
            })
        );

        stableGuard = new StableGuard(
            address(priceOracle),
            address(collateralManager),
            address(liquidationManager),
            address(dutchAuctionManager),
            address(repegManager),
            address(timelock)
        );
        require(address(stableGuard) == predictedGuard, "StableGuard address prediction mismatch");

        // Wiring
        collateralManager.setStableGuard(address(stableGuard)); // also authorizes StableGuard for custody
        collateralManager.setAuthorizedManager(address(dutchAuctionManager), true);
        liquidationManager.setStableGuard(address(stableGuard));
        dutchAuctionManager.setStableGuard(address(stableGuard));

        // ETH as initial collateral (further tokens: configureToken per token)
        priceOracle.configureToken(Constants.ETH_TOKEN, ethUsdFeed, 2000e18, 18);

        vm.stopBroadcast();
    }
}
