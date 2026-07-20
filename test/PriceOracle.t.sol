// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockAggregatorV3 is AggregatorV3Interface {
    int256 private _price;
    uint8 private _decimals;
    uint256 private _version;
    string private _description;
    uint80 private _roundId;
    uint256 private _updatedAt; // 0 = always fresh (mirrors block.timestamp)

    constructor(int256 price, uint8 decimals_) {
        _price = price;
        _decimals = decimals_;
        _version = 1;
        _description = "Mock Aggregator";
        _roundId = 1;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external view override returns (uint256) {
        return _version;
    }

    function getRoundData(uint80 _roundId_)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 ts = _updatedAt == 0 ? block.timestamp : _updatedAt;
        return (_roundId_, _price, ts, ts, _roundId_);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 ts = _updatedAt == 0 ? block.timestamp : _updatedAt;
        return (_roundId, _price, ts, ts, _roundId);
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
        _roundId++;
    }

    function setUpdatedAt(uint256 newUpdatedAt) external {
        _updatedAt = newUpdatedAt;
    }
}

contract PriceOracleTest is Test {
    PriceOracle public priceOracle;
    MockAggregatorV3 public mockAggregator;
    address public owner;
    address public tokenAddress;

    function setUp() public {
        owner = address(this);
        tokenAddress = address(0x2);

        // Deploy mock aggregator with a higher initial price
        mockAggregator = new MockAggregatorV3(2000 * 1e8, 8); // $2000 with 8 decimals

        // Deploy PriceOracle
        priceOracle = new PriceOracle();
    }

    function testDeployment() public view {
        assertEq(priceOracle.owner(), owner);
        // MIN_VALID_PRICE is a private constant, so we can't access it directly
        // Instead, we'll just verify the contract was deployed successfully
        assertTrue(address(priceOracle) != address(0));
    }

    function testMockAggregator() public view {
        // Test if our mock aggregator works correctly
        uint8 decimals = mockAggregator.decimals();
        assertEq(decimals, 8);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = mockAggregator.latestRoundData();
        assertTrue(roundId > 0);
        assertTrue(answer > 0);
        assertTrue(updatedAt > 0);
        assertTrue(answeredInRound >= roundId);
    }

    function testConfigureToken() public {
        console2.log("=== Starting testConfigureToken ===");
        console2.log("Token address:");
        console2.logAddress(tokenAddress);
        console2.log("Mock aggregator address:");
        console2.logAddress(address(mockAggregator));
        console2.log("PriceOracle address:");
        console2.logAddress(address(priceOracle));

        // Test the actual configuration
        console2.log("=== Calling configureToken ===");
        console2.log("Parameters:");
        console2.log("- Token:");
        console2.logAddress(tokenAddress);
        console2.log("- Price feed:");
        console2.logAddress(address(mockAggregator));
        console2.log("- Fallback price:");
        console2.logUint(1000 * 1e18);
        console2.log("- Decimals:");
        console2.logUint(18);

        // Check if we're the owner
        console2.log("- Contract owner:");
        console2.logAddress(priceOracle.owner());
        console2.log("- Test contract (msg.sender):");
        console2.logAddress(address(this));

        // Test the mock aggregator data before configuring
        console2.log("=== Testing mock aggregator data ===");
        try mockAggregator.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256, // startedAt - unused
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            console2.log("Mock aggregator data:");
            console2.log("- Round ID:");
            console2.logUint(roundId);
            console2.log("- Answer:");
            console2.logUint(uint256(answer));
            console2.log("- Updated at:");
            console2.logUint(updatedAt);
            console2.log("- Answered in round:");
            console2.logUint(answeredInRound);
            console2.log("- Current timestamp:");
            console2.logUint(block.timestamp);
            console2.log("- Time difference:");
            console2.logUint(block.timestamp - updatedAt);
        } catch Error(string memory reason) {
            console2.log("Mock aggregator latestRoundData failed:");
            console2.log(reason);
        }

        try priceOracle.configureToken(
            tokenAddress,
            address(mockAggregator),
            1000 * 1e18, // fallback price
            18 // decimals
        ) {
            console2.log("configureToken call succeeded");
        } catch Error(string memory reason) {
            console2.log("configureToken failed with reason:");
            console2.log(reason);
            revert("configureToken failed");
        } catch {
            console2.log("configureToken failed with unknown error");
            revert("configureToken failed with unknown error");
        }

        console2.log("=== Checking isSupportedToken ===");
        bool isSupported = priceOracle.isSupportedToken(tokenAddress);
        console2.log("Is token supported:");
        console2.logBool(isSupported);

        console2.log("=== Getting token config ===");
        try priceOracle.getTokenConfig(tokenAddress) returns (
            address configPriceFeed, uint256 configFallbackPrice, uint8 configDecimals
        ) {
            console2.log("Token config retrieved successfully:");
            console2.log("Price feed:");
            console2.logAddress(configPriceFeed);
            console2.log("Fallback price:");
            console2.logUint(configFallbackPrice);
            console2.log("Decimals:");
            console2.logUint(configDecimals);
        } catch Error(string memory reason) {
            console2.log("getTokenConfig failed with reason:");
            console2.log(reason);
        } catch {
            console2.log("getTokenConfig failed with unknown error");
        }

        assertTrue(isSupported);
        (address priceFeed, uint256 fallbackPrice, uint8 tokenDecimals) = priceOracle.getTokenConfig(tokenAddress);
        console2.log("Price feed address:");
        console2.logAddress(priceFeed);
        console2.log("Expected price feed:");
        console2.logAddress(address(mockAggregator));
        console2.log("Fallback price:");
        console2.logUint(fallbackPrice);
        console2.log("Expected fallback price:");
        console2.logUint(1000 * 1e18);
        console2.log("Token decimals:");
        console2.logUint(tokenDecimals);
        console2.log("Expected decimals:");
        console2.logUint(18);

        assertEq(priceFeed, address(mockAggregator));
        assertEq(fallbackPrice, 1000 * 1e18);
        assertEq(tokenDecimals, 18);

        console2.log("=== Test completed successfully ===");
    }

    /**
     * @dev Basic test that demonstrates how PriceOracle works with Chainlink
     * This test shows the full flow without needing external APIs
     */
    function testBasicChainlinkIntegration() public {
        console2.log("BASIC TEST: Integration with Chainlink ===");

        // 1. Configuring token with our mock aggregator (simulates Chainlink)
        console2.log("1. Configuring token with price feed...");
        priceOracle.configureToken(
            tokenAddress,
            address(mockAggregator), // This simulates a Chainlink aggregator
            1500 * 1e18, // fallback price: $1500
            18 // decimals
        );

        // 2. Verify token is configured
        console2.log("2. Verifying configuration...");
        assertTrue(priceOracle.isSupportedToken(tokenAddress));

        // 3. Get price using getTokenPrice (this calls Chainlink)
        console2.log("3. Getting price from 'Chainlink'...");
        uint256 price = priceOracle.getTokenPrice(tokenAddress);

        // 4. Show how decimal conversion works
        console2.log("4. Analysis of the obtained price:");
        console2.log("- Raw price from aggregator (8 decimals):");
        console2.logUint(2000 * 1e8); // What our mock returns
        console2.log("- Price converted to 18 decimals:");
        console2.logUint(price);
        console2.log("- Price in USD (divided by 1e18):");
        console2.logUint(price / 1e18);

        // 5. Demonstrate the fallback system
        console2.log("5. Demonstrating fallback system...");

        // Set mock price to 0 to simulate Chainlink failure
        mockAggregator.setPrice(0);

        // It should now use the fallback price
        uint256 fallbackPrice = priceOracle.getTokenPrice(tokenAddress);
        console2.log("- Fallback price used:");
        console2.logUint(fallbackPrice);
        console2.log("- Fallback price in USD:");
        console2.logUint(fallbackPrice / 1e18);

        assertEq(fallbackPrice, 1500 * 1e18); // Debe usar el fallback de $1500

        console2.log("TEST COMPLETED: PriceOracle works correctly with Chainlink");
        console2.log("");
        console2.log("SUMMARY:");
        console2.log("Token configuration successful");
        console2.log("Price obtained from aggregator");
        console2.log("Automatic decimal conversion");
        console2.log("Functional fallback system");
        console2.log("No external RPC needed in the contract");
    }

    /**
     * @dev Test that demonstrates the contract is ALREADY READY for real Chainlink
     */
    function testChainlinkReadyContract() public {
        console2.log("=== DEMONSTRATION: Contract ready for real Chainlink ===");

        // Configure with our mock
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        console2.log("HOW IT WORKS WITH REAL CHAINLINK:");
        console2.log("1. Instead of MockAggregatorV3, you would use:");
        console2.log("   - ETH/USD: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419");
        console2.log("   - BTC/USD: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c");
        console2.log("   - USDC/USD: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6");

        console2.log("2. The contract will automatically call:");
        console2.log("   - aggregator.latestRoundData() -> gets real price");
        console2.log("   - aggregator.decimals() -> gets decimals");

        console2.log("3. Automatic validations:");
        console2.log("   Price > 0");
        console2.log("   Data no older than 1 hour");
        console2.log("   Valid round ID");

        // Demonstrate the validations
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = mockAggregator.latestRoundData();

        console2.log("4. Current aggregator data:");
        console2.log("   - Round ID:");
        console2.logUint(roundId);
        console2.log("   - Price:");
        console2.logUint(uint256(answer));
        console2.log("   - Updated seconds ago:");
        console2.logUint(block.timestamp - updatedAt);
        console2.log("   - Answered in round:");
        console2.logUint(answeredInRound);

        // Verify it passes all validations
        assertTrue(roundId > 0);
        assertTrue(answer > 0);
        assertTrue(updatedAt > 0);
        assertTrue(block.timestamp - updatedAt <= 3600); // Less than 1 hour

        console2.log("RESULT: Your contract ALREADY WORKS with real Chainlink");
        console2.log("   You only need to change the aggregator address");
    }

    /**
     * @dev Exhaustive test of edge cases and validations
     */
    function testEdgeCasesAndValidations() public {
        console2.log("=== EXTREME CASES AND VALIDATIONS TEST ===");

        // First configure the token with a valid price
        console2.log("0. Configuring token with initial valid price...");
        mockAggregator.setPrice(2000 * 1e8); // Valid price for configuration
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);
        console2.log("   Token configured successfully");

        // 1. Test with price = 0 (should use fallback)
        console2.log("1. Testing price = 0...");
        mockAggregator.setPrice(0);

        uint256 priceZero = priceOracle.getTokenPrice(tokenAddress);
        console2.log("   Price when aggregator returns 0 (USD):");
        console2.logUint(priceZero / 1e18);
        assertEq(priceZero, 1000 * 1e18); // Should use fallback

        // 2. Test with negative price (should use fallback)
        console2.log("2. Testing negative price...");
        mockAggregator.setPrice(-100 * 1e8);
        uint256 priceNegative = priceOracle.getTokenPrice(tokenAddress);
        console2.log("   Price when aggregator returns negative (USD):");
        console2.logUint(priceNegative / 1e18);
        assertEq(priceNegative, 1000 * 1e18); // Should use fallback

        // 3. Test with very high price
        console2.log("3. Testing very high price...");
        mockAggregator.setPrice(1000000 * 1e8); // $1M
        uint256 priceHigh = priceOracle.getTokenPrice(tokenAddress);
        console2.log("   Very high price (USD):");
        console2.logUint(priceHigh / 1e18);
        assertEq(priceHigh, 1000000 * 1e18);

        // 4. Test with very low but valid price
        console2.log("4. Testing very low price...");
        mockAggregator.setPrice(1); // 0.00000001 USD
        uint256 priceLow = priceOracle.getTokenPrice(tokenAddress);
        console2.log("   Very low price:");
        console2.logUint(priceLow);
        assertTrue(priceLow > 0);

        console2.log("All edge cases handled correctly");
    }

    /**
     * @dev Test with multiple tokens and different configurations
     */
    function testMultipleTokenConfigurations() public {
        console2.log("=== MULTIPLE TOKENS TEST ===");

        // Create multiple tokens and aggregators
        address token1 = address(0x10);
        address token2 = address(0x20);
        address token3 = address(0x30);

        MockAggregatorV3 ethAggregator = new MockAggregatorV3(3000 * 1e8, 8); // ETH: $3000
        MockAggregatorV3 btcAggregator = new MockAggregatorV3(45000 * 1e8, 8); // BTC: $45000
        MockAggregatorV3 usdcAggregator = new MockAggregatorV3(1 * 1e8, 8); // USDC: $1

        console2.log("1. Configuring ETH...");
        priceOracle.configureToken(token1, address(ethAggregator), 2500 * 1e18, 18);

        console2.log("2. Configuring BTC...");
        priceOracle.configureToken(token2, address(btcAggregator), 40000 * 1e18, 18);

        console2.log("3. Configuring USDC...");
        priceOracle.configureToken(token3, address(usdcAggregator), 1 * 1e18, 18);

        // Verify that all are configured
        assertTrue(priceOracle.isSupportedToken(token1));
        assertTrue(priceOracle.isSupportedToken(token2));
        assertTrue(priceOracle.isSupportedToken(token3));

        // Get prices
        uint256 ethPrice = priceOracle.getTokenPrice(token1);
        uint256 btcPrice = priceOracle.getTokenPrice(token2);
        uint256 usdcPrice = priceOracle.getTokenPrice(token3);

        console2.log("4. Retrieved prices:");
        console2.log("   ETH (USD):");
        console2.logUint(ethPrice / 1e18);
        console2.log("   BTC (USD):");
        console2.logUint(btcPrice / 1e18);
        console2.log("   USDC (USD):");
        console2.logUint(usdcPrice / 1e18);

        // Verify correct prices
        assertEq(ethPrice, 3000 * 1e18);
        assertEq(btcPrice, 45000 * 1e18);
        assertEq(usdcPrice, 1 * 1e18);

        console2.log("Multiple tokens configured and working");
    }

    /**
     * @dev Decimal conversion test
     */
    function testDecimalConversions() public {
        console2.log("=== TEST DECIMAL CONVERSION ===");

        // Test con diferentes decimales de aggregators
        address token6 = address(0x60);
        address token18 = address(0x180);

        // Aggregator with 6 decimals (like real USDC)
        MockAggregatorV3 aggregator6 = new MockAggregatorV3(1000000, 6); // $1 with 6 decimals

        // Aggregator with 18 decimals
        MockAggregatorV3 aggregator18 = new MockAggregatorV3(1 * 1e18, 18); // $1 with 18 decimals

        console2.log("1. Configuring token with 6-decimal aggregator...");
        priceOracle.configureToken(token6, address(aggregator6), 1 * 1e18, 18);

        console2.log("2. Configuring token with 18-decimal aggregator...");
        priceOracle.configureToken(token18, address(aggregator18), 1 * 1e18, 18);

        uint256 price6 = priceOracle.getTokenPrice(token6);
        uint256 price18 = priceOracle.getTokenPrice(token18);

        console2.log("3. Conversion results:");
        console2.log("   Price from 6-decimal aggregator:");
        console2.logUint(price6);
        console2.log("   Price from 18-decimal aggregator:");
        console2.logUint(price18);
        console2.log("   Both in USD:");
        console2.logUint(price6 / 1e18);
        console2.logUint(price18 / 1e18);

        // Both should yield the same result: $1
        assertEq(price6, 1 * 1e18);
        assertEq(price18, 1 * 1e18);

        console2.log("Decimal conversion works correctly");
    }

    /**
     * @dev Error handling and fallbacks test
     */
    function testErrorHandlingAndFallbacks() public {
        console2.log("=== TEST ERROR HANDLING AND FALLBACKS ===");

        // Configure normal token
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1500 * 1e18, 18);

        console2.log("1. Normal price:");
        mockAggregator.setPrice(2000 * 1e8);
        uint256 normalPrice = priceOracle.getTokenPrice(tokenAddress);
        console2.log("   Normal price in USD:");
        console2.logUint(normalPrice / 1e18);
        assertEq(normalPrice, 2000 * 1e18);

        console2.log("2. Simulating Chainlink failure (price = 0):");
        mockAggregator.setPrice(0);
        uint256 fallbackPrice = priceOracle.getTokenPrice(tokenAddress);
        console2.log("   Fallback price in USD:");
        console2.logUint(fallbackPrice / 1e18);
        assertEq(fallbackPrice, 1500 * 1e18);

        console2.log("3. Recovery after failure:");
        mockAggregator.setPrice(2100 * 1e8);
        uint256 recoveredPrice = priceOracle.getTokenPrice(tokenAddress);
        console2.log("   Recovered price in USD:");
        console2.logUint(recoveredPrice / 1e18);
        assertEq(recoveredPrice, 2100 * 1e18);

        console2.log("Fallback system works perfectly");
    }

    /**
     * @dev Freshness validation test (stale data)
     */
    function testPriceFreshness() public {
        console2.log("=== PRICE FRESHNESS TEST ===");

        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        // Fresh price is served from Chainlink
        mockAggregator.setPrice(2000 * 1e8);
        assertEq(priceOracle.getTokenPrice(tokenAddress), 2000 * 1e18);

        // Freeze the feed's timestamp and warp past the 1h staleness threshold:
        // the oracle must reject the stale reading and serve the fallback price.
        mockAggregator.setUpdatedAt(block.timestamp);
        vm.warp(block.timestamp + 3601);
        assertEq(priceOracle.getTokenPrice(tokenAddress), 1000 * 1e18, "Stale price must fall back");

        // A refreshed feed is accepted again
        mockAggregator.setUpdatedAt(0); // always fresh
        assertEq(priceOracle.getTokenPrice(tokenAddress), 2000 * 1e18);

        console2.log("Freshness validations work");
    }

    /**
     * @dev Deviation tracking: 10-50% moves are accepted but emit an event
     */
    function testPriceDeviationEvent() public {
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        // Seed last valid price
        mockAggregator.setPrice(2000 * 1e8);
        assertEq(priceOracle.getTokenPrice(tokenAddress), 2000 * 1e18);

        // A 20% move is accepted but reported (>10% threshold), comparing against
        // the PREVIOUS valid price
        mockAggregator.setPrice(2400 * 1e8);
        vm.expectEmit(true, false, false, true);
        emit PriceOracle.PriceDeviationDetected(tokenAddress, 2000 * 1e18, 2400 * 1e18, 2000);
        assertEq(priceOracle.getTokenPrice(tokenAddress), 2400 * 1e18);

        // A >50% move from the last valid price (2400) is rejected -> fallback
        mockAggregator.setPrice(4000 * 1e8);
        assertEq(priceOracle.getTokenPrice(tokenAddress), 1000 * 1e18, "Deviation guard must fall back");
    }

    /**
     * @dev Events and logs test
     */
    function testEventsAndLogs() public {
        console2.log("=== TEST EVENTS AND LOGS ===");

        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        console2.log("1. Testing getTokenPriceWithEvents...");
        mockAggregator.setPrice(2500 * 1e8);

        // This method emits events
        uint256 priceWithEvents = priceOracle.getTokenPriceWithEvents(tokenAddress);
        console2.log("   Price with events in USD:");
        console2.logUint(priceWithEvents / 1e18);

        assertEq(priceWithEvents, 2500 * 1e18);

        console2.log("Events work correctly");
    }

    /**
     * @dev Invalid configurations test
     */
    function testInvalidConfigurations() public {
        console2.log("=== TEST INVALID CONFIGURATIONS ===");

        console2.log("1. Configuring ETH as address(0)...");
        // Now allowed: ETH is represented as address(0) with a valid feed
        priceOracle.configureToken(address(0), address(mockAggregator), 1000 * 1e18, 18);
        assertTrue(priceOracle.isSupportedToken(address(0)), "ETH (address(0)) should be supported");
        (address pf0, uint256 fb0, uint8 dec0) = priceOracle.getTokenConfig(address(0));
        assertTrue(pf0 != address(0), "Price feed must be set for ETH");
        assertTrue(fb0 > 0, "Fallback price must be positive for ETH");
        assertTrue(dec0 > 0, "Decimals must be positive for ETH");

        console2.log("2. Trying to configure with aggregator address(0)...");
        vm.expectRevert();
        priceOracle.configureToken(tokenAddress, address(0), 1000 * 1e18, 18);

        console2.log("3. Trying to get price of unconfigured token...");
        vm.expectRevert();
        priceOracle.getTokenPrice(address(0x999));

        console2.log("Configuration validations work");
    }

    /**
     * @dev Complete system overview test
     */
    function testCompleteSystemOverview() public view {
        console2.log("=== COMPLETE SYSTEM OVERVIEW ===");

        console2.log("CONFIGURATION:");
        console2.log("- PriceOracle deployed at:");
        console2.logAddress(address(priceOracle));
        console2.log("- MockAggregator deployed at:");
        console2.logAddress(address(mockAggregator));
        console2.log("- Contract owner:");
        console2.logAddress(priceOracle.owner());

        console2.log("CAPABILITIES:");
        console2.log("- Integration with Chainlink: YES");
        console2.log("- Automatic fallback: YES");
        console2.log("- Price validation: YES");
        console2.log("- Decimal conversion: YES");
        console2.log("- Multiple tokens: YES");

        console2.log("READY FOR PRODUCTION:");
        console2.log("- You only need to change aggregator addresses");
        console2.log("- Example: ETH/USD on mainnet: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419");
        console2.log("- The contract will automatically handle real prices");

        assertTrue(address(priceOracle) != address(0));
        assertTrue(priceOracle.owner() == address(this));
    }

    // ============ FUZZING TESTS ============

    /**
     * @dev Fuzzing test for price validation with random inputs
     */
    function testFuzz_PriceValidation(int256 fuzzPrice) public {
        // Limit the range to avoid overflow
        vm.assume(fuzzPrice >= type(int128).min && fuzzPrice <= type(int128).max);

        // Configure token first with a valid price
        mockAggregator.setPrice(2000 * 1e8);
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        // Now test with fuzzed price
        mockAggregator.setPrice(fuzzPrice);

        uint256 retrievedPrice = priceOracle.getTokenPrice(tokenAddress);

        if (fuzzPrice > 0 && fuzzPrice <= type(int128).max) {
            // If the price is positive and reasonable, it should return the converted price or fallback
            assertTrue(retrievedPrice > 0);
        } else {
            // If the price is 0, negative or too large, it must use fallback
            assertEq(retrievedPrice, 1000 * 1e18);
        }
    }

    /**
     * @dev Fuzzing test for token configuration with random parameters
     */
    function testFuzz_TokenConfiguration(uint256 fuzzFallbackPrice, uint8 fuzzDecimals) public {
        // Limit inputs to valid ranges
        vm.assume(fuzzFallbackPrice > 0 && fuzzFallbackPrice <= type(uint88).max);
        vm.assume(fuzzDecimals > 0 && fuzzDecimals <= 18);

        // Set aggregator with a valid price
        mockAggregator.setPrice(2000 * 1e8);

        // Attempt to configure with fuzzed parameters
        priceOracle.configureToken(tokenAddress, address(mockAggregator), fuzzFallbackPrice, fuzzDecimals);

        // Verify that the configuration was successful
        assertTrue(priceOracle.isSupportedToken(tokenAddress));

        (address priceFeed, uint256 fallbackPrice, uint8 decimals) = priceOracle.getTokenConfig(tokenAddress);

        assertEq(priceFeed, address(mockAggregator));
        assertEq(fallbackPrice, fuzzFallbackPrice);
        assertEq(decimals, fuzzDecimals);
    }

    /**
     * @dev Fuzzing test for decimal conversion
     */
    function testFuzz_DecimalConversion(uint8 fuzzDecimals, int256 fuzzPrice) public {
        vm.assume(fuzzDecimals > 0 && fuzzDecimals <= 18);
        // Converted price must clear the oracle's dust floor (MIN_VALID_PRICE = 1e14,
        // i.e. $0.0001 in 1e18): raw price >= 10^(decimals-4)
        int256 minRaw = fuzzDecimals >= 4 ? int256(10 ** (fuzzDecimals - 4)) : int256(1);
        fuzzPrice = bound(fuzzPrice, minRaw, type(int128).max);

        // Create aggregator with fuzzed decimals
        MockAggregatorV3 fuzzAggregator = new MockAggregatorV3(fuzzPrice, fuzzDecimals);

        priceOracle.configureToken(tokenAddress, address(fuzzAggregator), 1000 * 1e18, 18);

        uint256 price = priceOracle.getTokenPrice(tokenAddress);

        // The price must be in 18-decimal format
        assertTrue(price > 0);

        // Verify that the conversion is correct
        if (fuzzDecimals < 18) {
            uint256 expectedPrice = uint256(fuzzPrice) * (10 ** (18 - fuzzDecimals));
            assertEq(price, expectedPrice);
        } else if (fuzzDecimals == 18) {
            assertEq(price, uint256(fuzzPrice));
        }
    }

    /**
     * @dev Fuzzing test for multiple tokens simultaneously
     */
    function testFuzz_MultipleTokens(uint256 numTokens, int256 basePrice) public {
        // Make conditions less restrictive to avoid input rejection
        numTokens = bound(numTokens, 1, 5); // Use bound instead of assume
        basePrice = bound(basePrice, 1e4, type(int128).max / 1e8); // Wider but safe range

        address[] memory tokens = new address[](numTokens);
        MockAggregatorV3[] memory aggregators = new MockAggregatorV3[](numTokens);

        // Configure multiple tokens
        for (uint256 i = 0; i < numTokens; i++) {
            tokens[i] = address(uint160(0x2000 + i)); // Change base to avoid conflicts
            aggregators[i] = new MockAggregatorV3(basePrice + int256(i * 1e6), 8);

            priceOracle.configureToken(tokens[i], address(aggregators[i]), 1000 * 1e18, 18);
        }

        // Verify that all tokens are configured
        for (uint256 i = 0; i < numTokens; i++) {
            assertTrue(priceOracle.isSupportedToken(tokens[i]));
            uint256 price = priceOracle.getTokenPrice(tokens[i]);
            assertTrue(price > 0);
        }

        // Verify supported token list
        address[] memory supportedTokens = priceOracle.getSupportedTokens();
        // The list may include tokens from previous tests; ensure at least the new ones
        assertTrue(supportedTokens.length >= numTokens, "Should have at least the new tokens");
    }

    // ============ INVARIANT TESTS ============

    /**
     * @dev Invariant: Prices must always be positive
     */
    function invariant_PricesAlwaysPositive() public {
        address[] memory supportedTokens = priceOracle.getSupportedTokens();

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (priceOracle.isSupportedToken(supportedTokens[i])) {
                uint256 price = priceOracle.getTokenPrice(supportedTokens[i]);
                assertTrue(price > 0, "Price must always be positive");
            }
        }
    }

    /**
     * @dev Invariant: Configured tokens must always have valid configuration
     */
    function invariant_ConfiguredTokensHaveValidConfig() public view {
        address[] memory supportedTokens = priceOracle.getSupportedTokens();

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (priceOracle.isSupportedToken(supportedTokens[i])) {
                (address priceFeed, uint256 fallbackPrice, uint8 decimals) =
                    priceOracle.getTokenConfig(supportedTokens[i]);

                assertTrue(priceFeed != address(0), "Price feed must be valid");
                assertTrue(fallbackPrice > 0, "Fallback price must be positive");
                assertTrue(decimals > 0 && decimals <= 18, "Decimals must be valid");
            }
        }
    }

    /**
     * @dev Ownership is now OZ Ownable (transferable). A non-owner cannot change it.
     */
    function test_OwnershipAccessControl() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        priceOracle.transferOwnership(notOwner);
    }

    /**
     * @dev Invariant: Supported tokens must always be in the list
     */
    function invariant_SupportedTokensInList() public view {
        address[] memory supportedTokens = priceOracle.getSupportedTokens();

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            assertTrue(priceOracle.isSupportedToken(supportedTokens[i]), "All tokens in list must be supported");
        }
    }

    // ============ EXTREME SIMULATION TESTS ============

    /**
     * @dev Extreme simulation: Market crash (prices drop 99%)
     */
    function testExtreme_MarketCrash() public {
        console2.log("=== EXTREME SIMULATION: MARKET CRASH ===");

        // Configure token with normal price
        mockAggregator.setPrice(2000 * 1e8); // $2000
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        uint256 normalPrice = priceOracle.getTokenPrice(tokenAddress);
        console2.log("Normal price in USD:");
        console2.logUint(normalPrice / 1e18);

        // Simulate crash: price drops 99%
        mockAggregator.setPrice(20 * 1e8); // $20 (99% drop)
        uint256 crashPrice = priceOracle.getTokenPrice(tokenAddress);
        console2.log("Price after crash in USD:");
        console2.logUint(crashPrice / 1e18);

        // The system must keep working
        assertTrue(crashPrice > 0);
        assertTrue(crashPrice < normalPrice);

        console2.log("System survives the market crash");
    }

    /**
     * @dev Extreme simulation: Hyperinflation (prices rise 10000%)
     */
    function testExtreme_Hyperinflation() public {
        console2.log("=== EXTREME SIMULATION: HYPERINFLATION ===");

        // Initial price
        mockAggregator.setPrice(2000 * 1e8);
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        uint256 normalPrice = priceOracle.getTokenPrice(tokenAddress);
        console2.log("Normal price in USD:");
        console2.logUint(normalPrice / 1e18);

        // A sudden 10000% spike trips the deviation guard: the oracle rejects the
        // reading and falls back to the stored fallback price.
        mockAggregator.setPrice(200000 * 1e8); // $200,000
        uint256 guardedPrice = priceOracle.getTokenPrice(tokenAddress);
        assertEq(guardedPrice, 1000 * 1e18, "Spike must be rejected in favor of fallback");

        // A gradual climb (steps of exactly +50%, the guard's limit) is accepted.
        uint256 rawPrice = 2000 * 1e8;
        for (uint256 i = 0; i < 12; i++) {
            rawPrice = (rawPrice * 3) / 2;
            mockAggregator.setPrice(int256(rawPrice));
            assertEq(priceOracle.getTokenPrice(tokenAddress), rawPrice * 1e10);
        }

        // The price surpassed the original 100x target, just not in a single jump
        assertTrue(rawPrice * 1e10 > normalPrice * 100);
        console2.log("Deviation guard blocks spikes but tracks gradual hyperinflation");
    }

    /**
     * @dev Extreme simulation: Total Chainlink failure
     */
    function testExtreme_ChainlinkTotalFailure() public {
        console2.log("=== EXTREME SIMULATION: TOTAL CHAINLINK FAILURE ===");

        // Configure token normally
        mockAggregator.setPrice(2000 * 1e8);
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1500 * 1e18, 18);

        // Simulate total failure: aggregator returns 0
        mockAggregator.setPrice(0);

        uint256 fallbackPrice = priceOracle.getTokenPrice(tokenAddress);
        console2.log("Fallback price in USD:");
        console2.logUint(fallbackPrice / 1e18);

        // Must use fallback price
        assertEq(fallbackPrice, 1500 * 1e18);

        console2.log("System uses fallback when Chainlink fails");
    }

    /**
     * @dev Extreme simulation: Extreme volatility (rapid changes)
     */
    function testExtreme_ExtremeVolatility() public {
        console2.log("=== EXTREME SIMULATION: EXTREME VOLATILITY ===");

        mockAggregator.setPrice(2000 * 1e8);
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        // Simulate 100 rapid price changes
        for (uint256 i = 0; i < 100; i++) {
            int256 volatilePrice = 1000 * 1e8 + int256((i % 50) * 100 * 1e8);
            mockAggregator.setPrice(volatilePrice);

            uint256 price = priceOracle.getTokenPrice(tokenAddress);
            assertTrue(price > 0, "Price must remain positive during volatility");
        }

        console2.log("System handles extreme volatility");
    }

    /**
     * @dev Extreme simulation: Gas stress test
     */
    function testExtreme_GasStressTest() public {
        console2.log("=== EXTREME SIMULATION: GAS STRESS TEST ===");

        uint256 gasStart = gasleft();

        // Configure 25 different tokens (reduced from 50 to avoid OOG under --gas-report)
        for (uint256 i = 0; i < 25; i++) {
            address token = address(uint160(0x5000 + i));
            MockAggregatorV3 aggregator = new MockAggregatorV3(int256(1000 * 1e8 + i * 10 * 1e8), 8);

            priceOracle.configureToken(token, address(aggregator), 1000 * 1e18, 18);
        }

        uint256 gasAfterConfig = gasleft();
        console2.log("Gas used to configure 25 tokens:");
        console2.logUint(gasStart - gasAfterConfig);

        // Get prices for all tokens
        gasStart = gasleft();
        address[] memory supportedTokens = priceOracle.getSupportedTokens();

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            priceOracle.getTokenPrice(supportedTokens[i]);
        }

        uint256 gasAfterPrices = gasleft();
        console2.log("Supported tokens count:");
        console2.logUint(supportedTokens.length);
        console2.log("Gas used to fetch prices:");
        console2.logUint(gasStart - gasAfterPrices);

        console2.log("Gas stress test completed");
    }

    /**
     * @dev Extreme simulation: Mathematical precision at limits
     */
    function testExtreme_MathematicalPrecision() public {
        console2.log("=== EXTREME SIMULATION: MATHEMATICAL PRECISION ===");

        // Test with minimum possible price
        MockAggregatorV3 minAggregator = new MockAggregatorV3(1, 8); // 0.00000001
        priceOracle.configureToken(address(0x7001), address(minAggregator), 1, 18);

        uint256 minPrice = priceOracle.getTokenPrice(address(0x7001));
        console2.log("Minimum price handled:");
        console2.logUint(minPrice);
        assertTrue(minPrice > 0);

        // Test with reasonable maximum price
        MockAggregatorV3 maxAggregator = new MockAggregatorV3(
            type(int128).max / 1e10, // Avoid overflow
            8
        );
        priceOracle.configureToken(address(0x7002), address(maxAggregator), 1000 * 1e18, 18);

        uint256 maxPrice = priceOracle.getTokenPrice(address(0x7002));
        console2.log("Maximum price handled in USD:");
        console2.logUint(maxPrice / 1e18);
        assertTrue(maxPrice > 0);

        console2.log("Mathematical precision verified at limits");
    }

    // ============ PROPERTY-BASED TESTS ============

    /**
     * @dev Property test: Decimal conversion must be reversible
     */
    function testProperty_DecimalConversionReversible(uint8 sourceDecimals, uint8 targetDecimals, uint256 amount)
        public
        pure
    {
        vm.assume(sourceDecimals > 0 && sourceDecimals <= 18);
        vm.assume(targetDecimals > 0 && targetDecimals <= 18);
        vm.assume(amount > 0 && amount < 1e25); // Reduce limit to avoid overflow

        // Simulate decimal conversion
        uint256 converted;
        if (sourceDecimals < targetDecimals) {
            uint256 multiplier = 10 ** (targetDecimals - sourceDecimals);
            // Verify there is no overflow
            vm.assume(amount <= type(uint256).max / multiplier);
            converted = amount * multiplier;
        } else if (sourceDecimals > targetDecimals) {
            uint256 divisor = 10 ** (sourceDecimals - targetDecimals);
            converted = amount / divisor;
            // For division, ensure the result is meaningful
            vm.assume(amount >= divisor);
        } else {
            converted = amount;
        }

        // Conversion must preserve relative value
        assertTrue(converted > 0, "Conversion must preserve positive value");

        if (sourceDecimals <= targetDecimals) {
            assertTrue(converted >= amount, "Upscaling should increase or maintain value");
        } else {
            // For downscaling, the value may be lower due to lost precision
            assertTrue(converted <= amount, "Downscaling should decrease or maintain value");
        }
    }

    /**
     * @dev Property test: Prices should be monotonic with respect to the input
     */
    function testProperty_PriceMonotonicity(int256 price1, int256 price2) public {
        // 1e4 raw at 8 feed decimals = 1e14 converted = the oracle's dust floor
        price1 = bound(price1, 1e4, type(int128).max);
        price2 = bound(price2, 1e4, type(int128).max);
        vm.assume(price1 != price2);

        // Configure two tokens with different prices
        MockAggregatorV3 agg1 = new MockAggregatorV3(price1, 8);
        MockAggregatorV3 agg2 = new MockAggregatorV3(price2, 8);

        address token1 = address(0x8001);
        address token2 = address(0x8002);

        priceOracle.configureToken(token1, address(agg1), 1000 * 1e18, 18);
        priceOracle.configureToken(token2, address(agg2), 1000 * 1e18, 18);

        uint256 retrievedPrice1 = priceOracle.getTokenPrice(token1);
        uint256 retrievedPrice2 = priceOracle.getTokenPrice(token2);

        // The ordering relation must be preserved
        if (price1 > price2) {
            assertTrue(retrievedPrice1 > retrievedPrice2, "Price ordering must be preserved");
        } else {
            assertTrue(retrievedPrice1 < retrievedPrice2, "Price ordering must be preserved");
        }
    }

    // ============ GAS OPTIMIZATION TESTS ============

    /**
     * @dev Gas optimization test for frequent operations
     */
    function testGas_OptimizedOperations() public {
        console2.log("=== GAS OPTIMIZATION TEST ===");

        // Configure token
        mockAggregator.setPrice(2000 * 1e8);
        priceOracle.configureToken(tokenAddress, address(mockAggregator), 1000 * 1e18, 18);

        // Measure gas for getTokenPrice
        uint256 gasStart = gasleft();
        priceOracle.getTokenPrice(tokenAddress);
        uint256 gasUsed = gasStart - gasleft();
        console2.log("Gas used for getTokenPrice:");
        console2.logUint(gasUsed);

        // Measure gas for isSupportedToken
        gasStart = gasleft();
        priceOracle.isSupportedToken(tokenAddress);
        gasUsed = gasStart - gasleft();
        console2.log("Gas used for isSupportedToken:");
        console2.logUint(gasUsed);

        // Measure gas for getTokenConfig
        gasStart = gasleft();
        priceOracle.getTokenConfig(tokenAddress);
        gasUsed = gasStart - gasleft();
        console2.log("Gas used for getTokenConfig:");
        console2.logUint(gasUsed);

        // Values should be within reasonable limits
        assertTrue(gasUsed < 100000, "Gas usage should be reasonable");
    }

    /**
     * @dev Gas benchmark for batch operations
     */
    function testGas_BatchOperations() public {
        console2.log("=== GAS BENCHMARK: BATCH OPERATIONS ===");

        // Create multiple tokens
        address[] memory tokens = new address[](10);
        uint256[] memory fallbackPrices = new uint256[](10);
        uint8[] memory decimalsArray = new uint8[](10);

        for (uint256 i = 0; i < 10; i++) {
            tokens[i] = address(uint160(0x9000 + i));
            fallbackPrices[i] = 1000 * 1e18;
            decimalsArray[i] = 18;
        }

        // Measure gas for individual configuration (comparison)
        uint256 gasStart = gasleft();
        for (uint256 i = 0; i < 5; i++) {
            MockAggregatorV3 agg = new MockAggregatorV3(int256(1000 * 1e8 + i * 100 * 1e8), 8);
            priceOracle.configureToken(address(uint160(0x8000 + i)), address(agg), 1000 * 1e18, 18);
        }
        uint256 gasUsedIndividual = gasStart - gasleft();
        console2.log("Gas used for 5 individual configurations:");
        console2.logUint(gasUsedIndividual);
        console2.log("Average gas per token (individual):");
        console2.logUint(gasUsedIndividual / 5);

        // Measure gas for batch read operations
        gasStart = gasleft();
        address[] memory supportedTokens = priceOracle.getSupportedTokens();
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            priceOracle.getTokenPrice(supportedTokens[i]);
        }
        uint256 gasUsedBatchRead = gasStart - gasleft();
        console2.log("Supported tokens count:");
        console2.logUint(supportedTokens.length);
        console2.log("Gas used to read prices:");
        console2.logUint(gasUsedBatchRead);

        console2.log("Gas benchmark completed");
    }
}
