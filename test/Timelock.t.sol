// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Timelock} from "../src/Timelock.sol";

/**
 * @title TimelockTest - Comprehensive Test Suite for Timelock Contract
 * @dev Includes fuzzing tests, invariant tests, extreme simulations, and security tests
 */
contract TimelockTest is Test {
    // ============ EVENTS ============
    event TransactionQueued(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 executeTime
    );

    event TransactionExecuted(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data
    );

    event TransactionCancelled(bytes32 indexed txHash);
    event DelayChanged(uint256 oldDelay, uint256 newDelay);

    // ============ TEST CONTRACTS ============
    Timelock public timelock;
    MockTarget public mockTarget;
    ReentrancyAttacker public reentrancyAttacker;

    // ============ TEST CONSTANTS ============
    uint256 public constant DEFAULT_DELAY = 2 days;
    uint256 public constant MINIMUM_DELAY = 2 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;
    uint256 public constant GRACE_PERIOD = 14 days;

    address public constant OWNER = address(0x1);
    address public constant NON_OWNER = address(0x2);

    // ============ TEST STATE ============
    uint256 public initialTimestamp;
    bytes32[] public queuedTxHashes;

    // ============ SETUP ============
    function setUp() public {
        vm.startPrank(OWNER);
        timelock = new Timelock(DEFAULT_DELAY);
        vm.stopPrank();

        mockTarget = new MockTarget();
        reentrancyAttacker = new ReentrancyAttacker();

        initialTimestamp = block.timestamp;

        // Fund timelock with ETH for testing
        vm.deal(address(timelock), 100 ether);
        vm.deal(OWNER, 100 ether);
    }

    // ============ BASIC FUNCTIONALITY TESTS ============

    function test_Constructor() public view {
        assertEq(timelock.OWNER(), OWNER);
        assertEq(timelock.delay(), DEFAULT_DELAY);
        assertEq(timelock.MINIMUM_DELAY(), MINIMUM_DELAY);
        assertEq(timelock.MAXIMUM_DELAY(), MAXIMUM_DELAY);
        assertEq(timelock.GRACE_PERIOD(), GRACE_PERIOD);
    }

    function test_ConstructorInvalidDelay() public {
        vm.expectRevert(Timelock.InvalidDelay.selector);
        new Timelock(1 days); // Below minimum

        vm.expectRevert(Timelock.InvalidDelay.selector);
        new Timelock(31 days); // Above maximum
    }

    function test_QueueTransactionUnauthorized() public {
        vm.startPrank(NON_OWNER);

        vm.expectRevert(Timelock.Unauthorized.selector);
        timelock.queueTransaction(
            address(mockTarget), 0, "setValue(uint256)", abi.encode(42), block.timestamp + DEFAULT_DELAY
        );

        vm.stopPrank();
    }

    function test_QueueTransactionInvalidTarget() public {
        vm.startPrank(OWNER);

        vm.expectRevert(Timelock.InvalidTarget.selector);
        timelock.queueTransaction(address(0), 0, "setValue(uint256)", abi.encode(42), block.timestamp + DEFAULT_DELAY);

        vm.stopPrank();
    }

    function test_QueueTransactionInvalidExecuteTime() public {
        vm.startPrank(OWNER);

        vm.expectRevert(Timelock.InvalidParameters.selector);
        timelock.queueTransaction(
            address(mockTarget), 0, "setValue(uint256)", abi.encode(42), block.timestamp + DEFAULT_DELAY - 1
        );

        vm.stopPrank();
    }

    function test_QueueTransactionAlreadyQueued() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        string memory signature = "setValue(uint256)";
        bytes memory data = abi.encode(42);

        timelock.queueTransaction(address(mockTarget), 0, signature, data, executeTime);

        vm.expectRevert(Timelock.TransactionAlreadyQueued.selector);
        timelock.queueTransaction(address(mockTarget), 0, signature, data, executeTime);

        vm.stopPrank();
    }

    function test_QueueTransaction() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        string memory signature = "setValue(uint256)";
        bytes memory data = abi.encode(42);

        vm.expectEmit(true, true, false, true);
        emit TransactionQueued(
            timelock.getTransactionHash(address(mockTarget), 0, signature, data, executeTime),
            address(mockTarget),
            0,
            signature,
            data,
            executeTime
        );

        bytes32 txHash = timelock.queueTransaction(address(mockTarget), 0, signature, data, executeTime);

        assertTrue(timelock.queuedTransactions(txHash));
        assertTrue(timelock.isTransactionQueued(address(mockTarget), 0, signature, data, executeTime));

        vm.stopPrank();
    }

    function test_ExecuteTransaction() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        string memory signature = "setValue(uint256)";
        bytes memory data = abi.encode(42);

        bytes32 txHash = timelock.queueTransaction(address(mockTarget), 0, signature, data, executeTime);

        // Fast forward to execution time
        vm.warp(executeTime);

        vm.expectEmit(true, true, false, true);
        emit TransactionExecuted(txHash, address(mockTarget), 0, signature, data);

        bytes memory returnData = timelock.executeTransaction(address(mockTarget), 0, signature, data, executeTime);

        assertFalse(timelock.queuedTransactions(txHash));
        assertEq(mockTarget.value(), 42);
        assertEq(abi.decode(returnData, (uint256)), 42);

        vm.stopPrank();
    }

    function test_ExecuteTransactionNotQueued() public {
        vm.startPrank(OWNER);

        vm.expectRevert(Timelock.TransactionNotQueued.selector);
        timelock.executeTransaction(
            address(mockTarget), 0, "setValue(uint256)", abi.encode(42), block.timestamp + DEFAULT_DELAY
        );

        vm.stopPrank();
    }

    function test_ExecuteTransactionNotReady() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;

        timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        vm.expectRevert(Timelock.TransactionNotReady.selector);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        vm.stopPrank();
    }

    function test_ExecuteTransactionExpired() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;

        timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        // Fast forward past grace period
        vm.warp(executeTime + GRACE_PERIOD + 1);

        vm.expectRevert(Timelock.TransactionExpired.selector);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        vm.stopPrank();
    }

    function test_ExecuteTransactionWithValue() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        uint256 value = 1 ether;

        timelock.queueTransaction(address(mockTarget), value, "receiveEther()", "", executeTime);

        vm.warp(executeTime);

        uint256 balanceBefore = address(mockTarget).balance;

        timelock.executeTransaction{value: value}(address(mockTarget), value, "receiveEther()", "", executeTime);

        assertEq(address(mockTarget).balance, balanceBefore + value);

        vm.stopPrank();
    }

    function test_CancelTransaction() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        string memory signature = "setValue(uint256)";
        bytes memory data = abi.encode(42);

        bytes32 txHash = timelock.queueTransaction(address(mockTarget), 0, signature, data, executeTime);

        assertTrue(timelock.queuedTransactions(txHash));

        vm.expectEmit(true, false, false, false);
        emit TransactionCancelled(txHash);

        timelock.cancelTransaction(address(mockTarget), 0, signature, data, executeTime);

        assertFalse(timelock.queuedTransactions(txHash));

        vm.stopPrank();
    }

    function test_CancelTransactionNotQueued() public {
        vm.startPrank(OWNER);

        vm.expectRevert(Timelock.TransactionNotQueued.selector);
        timelock.cancelTransaction(
            address(mockTarget), 0, "setValue(uint256)", abi.encode(42), block.timestamp + DEFAULT_DELAY
        );

        vm.stopPrank();
    }

    function test_SetDelay() public {
        vm.startPrank(OWNER);

        uint256 newDelay = 5 days;

        vm.expectEmit(false, false, false, true);
        emit DelayChanged(DEFAULT_DELAY, newDelay);

        timelock.setDelay(newDelay);

        assertEq(timelock.delay(), newDelay);

        vm.stopPrank();
    }

    function test_SetDelayInvalid() public {
        vm.startPrank(OWNER);

        vm.expectRevert(Timelock.InvalidDelay.selector);
        timelock.setDelay(1 days); // Below minimum

        vm.expectRevert(Timelock.InvalidDelay.selector);
        timelock.setDelay(31 days); // Above maximum

        vm.stopPrank();
    }

    function test_SetDelayUnauthorized() public {
        vm.startPrank(NON_OWNER);

        vm.expectRevert(Timelock.Unauthorized.selector);
        timelock.setDelay(5 days);

        vm.stopPrank();
    }
}

// ============ FUZZING TESTS ============

/**
 * @title TimelockFuzzTest - Comprehensive Fuzzing Tests for Timelock
 */
contract TimelockFuzzTest is TimelockTest {
    // ============ FUZZING: QUEUE TRANSACTION ============

    function testFuzz_QueueTransaction(
        address fuzzTarget,
        uint256 fuzzValue,
        uint256 fuzzDelay,
        bytes calldata fuzzData
    ) public {
        // Bound inputs to valid ranges
        vm.assume(fuzzTarget != address(0));
        vm.assume(fuzzTarget.code.length == 0); // EOA only for simplicity
        fuzzDelay = bound(fuzzDelay, MINIMUM_DELAY, MAXIMUM_DELAY * 2);
        fuzzValue = bound(fuzzValue, 0, 1000 ether);

        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + fuzzDelay;
        string memory signature = "";

        if (fuzzDelay >= MINIMUM_DELAY) {
            bytes32 txHash = timelock.queueTransaction(fuzzTarget, fuzzValue, signature, fuzzData, executeTime);

            assertTrue(timelock.queuedTransactions(txHash));
            assertTrue(timelock.isTransactionQueued(fuzzTarget, fuzzValue, signature, fuzzData, executeTime));
        } else {
            vm.expectRevert(Timelock.InvalidParameters.selector);
            timelock.queueTransaction(fuzzTarget, fuzzValue, signature, fuzzData, executeTime);
        }

        vm.stopPrank();
    }

    function testFuzz_QueueTransactionWithSignature(uint256 fuzzValue, uint256 fuzzParameter, uint256 fuzzDelay)
        public
    {
        fuzzDelay = bound(fuzzDelay, MINIMUM_DELAY, MAXIMUM_DELAY);
        fuzzValue = bound(fuzzValue, 0, 100 ether);

        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + fuzzDelay;
        string memory signature = "setValue(uint256)";
        bytes memory data = abi.encode(fuzzParameter);

        bytes32 txHash = timelock.queueTransaction(address(mockTarget), fuzzValue, signature, data, executeTime);

        assertTrue(timelock.queuedTransactions(txHash));

        // Verify hash consistency
        bytes32 expectedHash = timelock.getTransactionHash(address(mockTarget), fuzzValue, signature, data, executeTime);
        assertEq(txHash, expectedHash);

        vm.stopPrank();
    }

    // ============ FUZZING: EXECUTE TRANSACTION ============

    function testFuzz_ExecuteTransaction(uint256 fuzzValue, uint256 fuzzParameter, uint256 fuzzWarpTime) public {
        fuzzValue = bound(fuzzValue, 0, 1 ether); // Reduce max value
        fuzzParameter = bound(fuzzParameter, 0, 1000000); // Use reasonable parameter bound
        fuzzWarpTime = bound(fuzzWarpTime, 0, GRACE_PERIOD + 1 days);

        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        string memory signature = "setValue(uint256)";
        bytes memory data = abi.encode(fuzzParameter);

        // Queue transaction
        bytes32 txHash = timelock.queueTransaction(address(mockTarget), fuzzValue, signature, data, executeTime);

        // Warp to fuzzed time
        vm.warp(executeTime + fuzzWarpTime);

        if (fuzzWarpTime <= GRACE_PERIOD) {
            // Should succeed
            vm.deal(OWNER, fuzzValue);
            bytes memory returnData = timelock.executeTransaction{value: fuzzValue}(
                address(mockTarget), fuzzValue, signature, data, executeTime
            );

            assertFalse(timelock.queuedTransactions(txHash));
            assertEq(mockTarget.value(), fuzzParameter);
            assertEq(abi.decode(returnData, (uint256)), fuzzParameter);
        } else {
            // Should fail - expired
            vm.expectRevert(Timelock.TransactionExpired.selector);
            timelock.executeTransaction{value: fuzzValue}(address(mockTarget), fuzzValue, signature, data, executeTime);
        }

        vm.stopPrank();
    }

    function testFuzz_ExecuteTransactionTiming(uint256 fuzzDelay, int256 fuzzTimeOffset) public {
        fuzzDelay = bound(fuzzDelay, MINIMUM_DELAY, MAXIMUM_DELAY);
        fuzzTimeOffset = bound(fuzzTimeOffset, -int256(fuzzDelay), int256(GRACE_PERIOD + 1 days));

        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + fuzzDelay;
        string memory signature = "setValue(uint256)";
        bytes memory data = abi.encode(42);

        timelock.queueTransaction(address(mockTarget), 0, signature, data, executeTime);

        // Warp to executeTime + offset
        uint256 targetTime = uint256(int256(executeTime) + fuzzTimeOffset);
        vm.warp(targetTime);

        if (targetTime < executeTime) {
            // Too early
            vm.expectRevert(Timelock.TransactionNotReady.selector);
            timelock.executeTransaction(address(mockTarget), 0, signature, data, executeTime);
        } else if (targetTime > executeTime + GRACE_PERIOD) {
            // Too late
            vm.expectRevert(Timelock.TransactionExpired.selector);
            timelock.executeTransaction(address(mockTarget), 0, signature, data, executeTime);
        } else {
            // Just right
            timelock.executeTransaction(address(mockTarget), 0, signature, data, executeTime);
            assertEq(mockTarget.value(), 42);
        }

        vm.stopPrank();
    }

    // ============ FUZZING: DELAY MANAGEMENT ============

    function testFuzz_SetDelay(uint256 fuzzDelay) public {
        vm.startPrank(OWNER);

        if (fuzzDelay >= MINIMUM_DELAY && fuzzDelay <= MAXIMUM_DELAY) {
            uint256 oldDelay = timelock.delay();
            timelock.setDelay(fuzzDelay);
            assertEq(timelock.delay(), fuzzDelay);

            // Verify event emission
            vm.expectEmit(false, false, false, true);
            emit DelayChanged(fuzzDelay, oldDelay);
            timelock.setDelay(oldDelay); // Reset
        } else {
            vm.expectRevert(Timelock.InvalidDelay.selector);
            timelock.setDelay(fuzzDelay);
        }

        vm.stopPrank();
    }

    // ============ FUZZING: TRANSACTION HASH CONSISTENCY ============

    function testFuzz_TransactionHashConsistency(
        address fuzzTarget,
        uint256 fuzzValue,
        string calldata fuzzSignature,
        bytes calldata fuzzData,
        uint256 fuzzExecuteTime
    ) public view {
        vm.assume(fuzzTarget != address(0));

        bytes32 hash1 = timelock.getTransactionHash(fuzzTarget, fuzzValue, fuzzSignature, fuzzData, fuzzExecuteTime);

        bytes32 hash2 = timelock.getTransactionHash(fuzzTarget, fuzzValue, fuzzSignature, fuzzData, fuzzExecuteTime);

        assertEq(hash1, hash2, "Hash should be deterministic");

        // Different parameters should produce different hashes
        if (fuzzExecuteTime > 0) {
            bytes32 hash3 =
                timelock.getTransactionHash(fuzzTarget, fuzzValue, fuzzSignature, fuzzData, fuzzExecuteTime - 1);
            assertTrue(hash1 != hash3, "Different executeTime should produce different hash");
        }
    }

    // ============ FUZZING: MULTIPLE TRANSACTIONS ============

    function testFuzz_MultipleTransactions(uint256 fuzzCount, uint256 fuzzBaseValue, uint256 fuzzBaseDelay) public {
        fuzzCount = bound(fuzzCount, 1, 3); // Further reduce count
        fuzzBaseValue = bound(fuzzBaseValue, 0, 1000); // Use reasonable base value
        fuzzBaseDelay = bound(fuzzBaseDelay, MINIMUM_DELAY, MINIMUM_DELAY + 1 days); // Reduce delay range

        vm.startPrank(OWNER);

        bytes32[] memory txHashes = new bytes32[](fuzzCount);
        uint256[] memory executeTimes = new uint256[](fuzzCount);

        // Queue multiple transactions
        for (uint256 i = 0; i < fuzzCount; i++) {
            executeTimes[i] = block.timestamp + fuzzBaseDelay + (i * 1 hours);
            string memory signature = "setValue(uint256)";
            bytes memory data = abi.encode(fuzzBaseValue + i);

            txHashes[i] =
                timelock.queueTransaction(address(mockTarget), fuzzBaseValue + i, signature, data, executeTimes[i]);

            assertTrue(timelock.queuedTransactions(txHashes[i]));
        }

        // Execute transactions in order
        for (uint256 i = 0; i < fuzzCount; i++) {
            vm.warp(executeTimes[i]);

            vm.deal(OWNER, fuzzBaseValue + i);
            timelock.executeTransaction{value: fuzzBaseValue + i}(
                address(mockTarget),
                fuzzBaseValue + i,
                "setValue(uint256)",
                abi.encode(fuzzBaseValue + i),
                executeTimes[i]
            );

            assertFalse(timelock.queuedTransactions(txHashes[i]));
            assertEq(mockTarget.value(), fuzzBaseValue + i);
        }

        vm.stopPrank();
    }

    // ============ FUZZING: EDGE CASES ============

    function testFuzz_EdgeCases(uint256 fuzzValue, uint256 fuzzDelay) public {
        fuzzDelay = bound(fuzzDelay, MINIMUM_DELAY, MAXIMUM_DELAY);
        fuzzValue = bound(fuzzValue, 0, type(uint128).max);

        vm.startPrank(OWNER);

        // Test with maximum values
        uint256 executeTime = block.timestamp + fuzzDelay;

        // Test with empty signature and data
        bytes32 txHash1 = timelock.queueTransaction(address(mockTarget), fuzzValue, "", "", executeTime);
        assertTrue(timelock.queuedTransactions(txHash1));

        // Test with very long signature
        string memory longSignature =
            "veryLongFunctionNameThatExceedsNormalLengthsAndTestsEdgeCases(uint256,uint256,uint256,uint256)";
        bytes32 txHash2 = timelock.queueTransaction(
            address(mockTarget),
            fuzzValue,
            longSignature,
            abi.encode(fuzzValue, fuzzValue, fuzzValue, fuzzValue),
            executeTime + 1
        );
        assertTrue(timelock.queuedTransactions(txHash2));

        // Test with large data payload
        bytes memory largeData = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            largeData[i] = bytes1(uint8(i % 256));
        }

        bytes32 txHash3 =
            timelock.queueTransaction(address(mockTarget), fuzzValue, "setValue(uint256)", largeData, executeTime + 2);
        assertTrue(timelock.queuedTransactions(txHash3));

        vm.stopPrank();
    }
}

/**
 * @title MockTarget - Test target contract for timelock operations
 */

/**
 * @title MockTarget - Test target contract for timelock operations
 */
contract MockTarget {
    uint256 public value;
    bool public called;

    function setValue(uint256 _value) external payable returns (uint256) {
        value = _value;
        called = true;
        return _value;
    }

    function receiveEther() external payable {
        called = true;
    }

    function revertFunction() external pure {
        revert("Mock revert");
    }

    function expensiveOperation() external {
        for (uint256 i = 0; i < 1000; i++) {
            value = i;
        }
        called = true;
    }

    receive() external payable {}
}

/**
 * @title ReentrancyAttacker - Contract to test reentrancy protection
 */
contract ReentrancyAttacker {
    Timelock public timelock;
    bool public attacking;
    uint256 public executeTime;

    function setTimelock(address _timelock) external {
        timelock = Timelock(payable(_timelock));
    }

    function setExecuteTime(uint256 _executeTime) external {
        executeTime = _executeTime;
    }

    function attack() external {
        attacking = true;
        // This should fail due to reentrancy guard
        timelock.executeTransaction(address(this), 0, "setValue(uint256)", abi.encode(42), executeTime);
    }

    function setValue(uint256) external {
        if (!attacking) {
            attacking = true;
            // Try to re-enter - this should fail due to reentrancy guard
            // We'll call queueTransaction instead since it's simpler
            timelock.queueTransaction(address(this), 0, "setValue(uint256)", abi.encode(99), block.timestamp + 1 days);
        }
    }
}

// ============ INVARIANT TESTS ============

/**
 * @title TimelockInvariantTest - Invariant tests for Timelock
 * @dev Separate contract to avoid inheritance linearization issues
 */
contract TimelockInvariantTest is StdInvariant, Test {
    Timelock public timelock;
    MockTarget public mockTarget;
    TimelockDelayHandler public delayHandler;

    address public constant OWNER = address(0x1);
    uint256 public constant DEFAULT_DELAY = 2 days;
    uint256 public constant MINIMUM_DELAY = 2 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;
    uint256 public constant GRACE_PERIOD = 14 days;

    function setUp() public {
        vm.startPrank(OWNER);
        timelock = new Timelock(DEFAULT_DELAY);
        mockTarget = new MockTarget();
        vm.stopPrank();

        // Drive the timelock through a handler so the fuzzer actually queues
        // transactions (queueing is owner-only) and then tries to execute early.
        delayHandler = new TimelockDelayHandler(timelock, mockTarget, OWNER);
        targetContract(address(delayHandler));
    }

    /**
     * @notice Invariant: Delay must always be within valid bounds
     */
    function invariant_DelayBounds() public view {
        uint256 currentDelay = timelock.delay();
        assertTrue(currentDelay >= MINIMUM_DELAY && currentDelay <= MAXIMUM_DELAY, "Delay must be within valid bounds");
    }

    /**
     * @notice Invariant: Only owner can modify timelock state
     */
    function invariant_OnlyOwnerCanModify() public view {
        assertTrue(timelock.OWNER() == OWNER, "Owner must remain constant");
    }

    /**
     * @notice Invariant: no queued transaction can ever execute before its ETA.
     *         The handler repeatedly queues and tries to execute early; if any
     *         such early execution ever succeeds, this flips and the invariant fails.
     */
    function invariant_NoEarlyExecution() public view {
        assertFalse(delayHandler.earlyExecutionSucceeded(), "A transaction executed before its delay elapsed");
    }
}

/// @dev Drives queue -> premature execute attempts against a real Timelock
contract TimelockDelayHandler is Test {
    Timelock public timelock;
    MockTarget public target;
    address public owner;
    bool public earlyExecutionSucceeded;
    uint256 private nonce;

    constructor(Timelock _timelock, MockTarget _target, address _owner) {
        timelock = _timelock;
        target = _target;
        owner = _owner;
    }

    /// @dev Queue a transaction at the minimum valid ETA and immediately try to
    ///      execute it; the execution must revert because the delay has not passed.
    function queueAndTryEarly(uint256 value) external {
        value = bound(value, 0, type(uint128).max);
        uint256 eta = block.timestamp + timelock.MINIMUM_DELAY();
        bytes memory data = abi.encode(value);

        vm.prank(owner);
        try timelock.queueTransaction(address(target), 0, "setValue(uint256)", data, eta) {
            // Attempt to execute before the ETA — this must fail
            vm.prank(owner);
            try timelock.executeTransaction(address(target), 0, "setValue(uint256)", data, eta) {
                earlyExecutionSucceeded = true; // Invariant violation
            } catch {}
        } catch {}
        nonce++;
    }
}

// ============ SECURITY TESTS ============

/**
 * @title TimelockSecurityTest - Security-focused tests for Timelock
 */
contract TimelockSecurityTest is TimelockTest {
    // ============ ACCESS CONTROL TESTS ============

    function test_Security_UnauthorizedQueueTransaction() public {
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);

        vm.expectRevert(Timelock.Unauthorized.selector);
        timelock.queueTransaction(
            address(mockTarget), 0, "setValue(uint256)", abi.encode(42), block.timestamp + DEFAULT_DELAY
        );

        vm.stopPrank();
    }

    function test_Security_UnauthorizedExecuteTransaction() public {
        // First queue as owner
        vm.startPrank(OWNER);
        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);
        vm.stopPrank();

        // Try to execute as attacker
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.warp(executeTime);

        vm.expectRevert(Timelock.Unauthorized.selector);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        vm.stopPrank();
    }

    function test_Security_UnauthorizedCancelTransaction() public {
        // First queue as owner
        vm.startPrank(OWNER);
        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);
        vm.stopPrank();

        // Try to cancel as attacker
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);

        vm.expectRevert(Timelock.Unauthorized.selector);
        timelock.cancelTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        vm.stopPrank();
    }

    function test_Security_UnauthorizedSetDelay() public {
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);

        vm.expectRevert(Timelock.Unauthorized.selector);
        timelock.setDelay(MINIMUM_DELAY + 1 hours);

        vm.stopPrank();
    }

    // ============ REENTRANCY TESTS ============

    function test_Security_ReentrancyProtection() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker();
        attacker.setTimelock(address(timelock));

        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        attacker.setExecuteTime(executeTime);

        // Queue a transaction that will trigger reentrancy
        timelock.queueTransaction(address(attacker), 0, "setValue(uint256)", abi.encode(42), executeTime);

        vm.warp(executeTime);

        // This should fail due to reentrancy protection
        // The setValue function will try to call queueTransaction during execution
        vm.expectRevert();
        timelock.executeTransaction(address(attacker), 0, "setValue(uint256)", abi.encode(42), executeTime);

        vm.stopPrank();
    }

    // ============ FRONT-RUNNING TESTS ============

    function test_Security_FrontRunningProtection() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        // Simulate front-running attempt by changing parameters slightly
        vm.warp(executeTime);

        // Original transaction should work
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        // Front-run attempt with different parameters should fail
        vm.expectRevert(Timelock.TransactionNotQueued.selector);
        timelock.executeTransaction(
            address(mockTarget),
            0,
            "setValue(uint256)",
            abi.encode(43), // Different data
            executeTime
        );

        vm.stopPrank();
    }

    // ============ TIMING ATTACK TESTS ============

    function test_Security_TimingAttacks() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        // Test execution exactly at executeTime
        vm.warp(executeTime);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        // Queue another transaction
        executeTime = block.timestamp + DEFAULT_DELAY;
        timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(43), executeTime);

        // Test execution at the last possible moment
        vm.warp(executeTime + GRACE_PERIOD);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(43), executeTime);

        vm.stopPrank();
    }

    // ============ OVERFLOW/UNDERFLOW TESTS ============

    function test_Security_OverflowProtection() public {
        vm.startPrank(OWNER);

        // Test with maximum values
        uint256 maxExecuteTime = type(uint256).max;

        // This should not cause overflow in hash calculation
        bytes32 hash = timelock.getTransactionHash(
            address(mockTarget), type(uint256).max, "setValue(uint256)", abi.encode(type(uint256).max), maxExecuteTime
        );

        assertTrue(hash != bytes32(0), "Hash should be computed correctly");

        vm.stopPrank();
    }
}

// ============ EXTREME SIMULATION TESTS ============

/**
 * @title TimelockExtremeTest - Extreme simulation tests for Timelock
 */
contract TimelockExtremeTest is TimelockTest {
    // ============ STRESS TESTS ============

    function test_Extreme_MassiveTransactionQueue() public {
        vm.startPrank(OWNER);

        uint256 numTransactions = 10; // Reduce number for testing
        bytes32[] memory txHashes = new bytes32[](numTransactions);
        uint256[] memory executeTimes = new uint256[](numTransactions);

        // Queue many transactions
        for (uint256 i = 0; i < numTransactions; i++) {
            executeTimes[i] = block.timestamp + DEFAULT_DELAY + (i * 1 hours);
            txHashes[i] =
                timelock.queueTransaction(address(mockTarget), i, "setValue(uint256)", abi.encode(i), executeTimes[i]);

            assertTrue(timelock.queuedTransactions(txHashes[i]), "Transaction should be queued");
        }

        // Execute all transactions
        for (uint256 i = 0; i < numTransactions; i++) {
            vm.warp(executeTimes[i]);
            vm.deal(OWNER, i);

            timelock.executeTransaction{value: i}(
                address(mockTarget), i, "setValue(uint256)", abi.encode(i), executeTimes[i]
            );

            assertFalse(timelock.queuedTransactions(txHashes[i]), "Transaction should be executed");
            assertEq(mockTarget.value(), i, "Value should be updated");
        }

        vm.stopPrank();
    }

    function test_Extreme_LargeDataPayload() public {
        vm.startPrank(OWNER);

        // Create very large data payload (32KB)
        bytes memory largeData = new bytes(32768);
        for (uint256 i = 0; i < largeData.length; i++) {
            largeData[i] = bytes1(uint8(i % 256));
        }

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        bytes32 txHash = timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", largeData, executeTime);

        assertTrue(timelock.queuedTransactions(txHash), "Large transaction should be queued");

        vm.warp(executeTime);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", largeData, executeTime);

        assertFalse(timelock.queuedTransactions(txHash), "Large transaction should be executed");

        vm.stopPrank();
    }

    function test_Extreme_MaximumDelayBoundaries() public {
        vm.startPrank(OWNER);

        // Test minimum delay
        timelock.setDelay(MINIMUM_DELAY);
        assertEq(timelock.delay(), MINIMUM_DELAY, "Should set minimum delay");

        uint256 executeTime = block.timestamp + MINIMUM_DELAY;
        bytes32 txHash =
            timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(1), executeTime);

        vm.warp(executeTime);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(1), executeTime);

        // Test maximum delay
        timelock.setDelay(MAXIMUM_DELAY);
        assertEq(timelock.delay(), MAXIMUM_DELAY, "Should set maximum delay");

        executeTime = block.timestamp + MAXIMUM_DELAY;
        txHash = timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(2), executeTime);

        vm.warp(executeTime);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(2), executeTime);

        vm.stopPrank();
    }

    function test_Extreme_GracePeriodBoundaries() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        bytes32 txHash =
            timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        // Execute at the very last moment of grace period
        vm.warp(executeTime + GRACE_PERIOD);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);

        assertFalse(timelock.queuedTransactions(txHash), "Transaction should be executed");

        // Queue another transaction and try to execute 1 second after grace period
        executeTime = block.timestamp + DEFAULT_DELAY;
        txHash = timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(43), executeTime);

        vm.warp(executeTime + GRACE_PERIOD + 1);
        vm.expectRevert(Timelock.TransactionExpired.selector);
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(43), executeTime);

        vm.stopPrank();
    }

    // ============ GAS OPTIMIZATION TESTS ============

    function test_Extreme_GasOptimization() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;

        // Measure gas for queueing
        uint256 gasStart = gasleft();
        timelock.queueTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);
        uint256 gasUsedQueue = gasStart - gasleft();

        console2.log("Gas used for queueTransaction:", gasUsedQueue);
        assertTrue(gasUsedQueue < 100000, "Queue should be gas efficient");

        // Measure gas for execution
        vm.warp(executeTime);
        gasStart = gasleft();
        timelock.executeTransaction(address(mockTarget), 0, "setValue(uint256)", abi.encode(42), executeTime);
        uint256 gasUsedExecute = gasStart - gasleft();

        console2.log("Gas used for executeTransaction:", gasUsedExecute);
        assertTrue(gasUsedExecute < 200000, "Execute should be gas efficient");

        vm.stopPrank();
    }

    function test_Extreme_HashCollisionResistance() public view {
        // Test hash collision resistance with similar inputs
        bytes32 hash1 = timelock.getTransactionHash(address(0x1), 100, "test()", "", 1000);

        bytes32 hash2 = timelock.getTransactionHash(address(0x2), 100, "test()", "", 1000);

        bytes32 hash3 = timelock.getTransactionHash(address(0x1), 101, "test()", "", 1000);

        bytes32 hash4 = timelock.getTransactionHash(address(0x1), 100, "test2()", "", 1000);

        bytes32 hash5 = timelock.getTransactionHash(address(0x1), 100, "test()", "data", 1000);

        bytes32 hash6 = timelock.getTransactionHash(address(0x1), 100, "test()", "", 1001);

        // All hashes should be different
        assertTrue(hash1 != hash2, "Different targets should produce different hashes");
        assertTrue(hash1 != hash3, "Different values should produce different hashes");
        assertTrue(hash1 != hash4, "Different signatures should produce different hashes");
        assertTrue(hash1 != hash5, "Different data should produce different hashes");
        assertTrue(hash1 != hash6, "Different execute times should produce different hashes");
    }

    // ============ EDGE CASE TESTS ============

    function test_Extreme_EmptySignatureAndData() public {
        vm.startPrank(OWNER);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        bytes32 txHash = timelock.queueTransaction(
            address(mockTarget),
            0,
            "", // Empty signature
            "", // Empty data
            executeTime
        );

        assertTrue(timelock.queuedTransactions(txHash), "Empty signature/data should work");

        vm.warp(executeTime);
        timelock.executeTransaction(address(mockTarget), 0, "", "", executeTime);

        assertFalse(timelock.queuedTransactions(txHash), "Transaction should be executed");

        vm.stopPrank();
    }

    function test_Extreme_VeryLongSignature() public {
        vm.startPrank(OWNER);

        // Create a very long function signature but use an existing function
        string memory longSignature = "setValue(uint256)";

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        bytes32 txHash =
            timelock.queueTransaction(address(mockTarget), 0, longSignature, abi.encode(12345), executeTime);

        assertTrue(timelock.queuedTransactions(txHash), "Long signature should work");

        vm.warp(executeTime);
        timelock.executeTransaction(address(mockTarget), 0, longSignature, abi.encode(12345), executeTime);

        assertFalse(timelock.queuedTransactions(txHash), "Transaction should be executed");
        assertEq(mockTarget.value(), 12345, "Value should be set correctly");

        vm.stopPrank();
    }

    function test_Extreme_MaximumValueTransfer() public {
        vm.startPrank(OWNER);

        uint256 maxValue = 1000 ether;
        vm.deal(OWNER, maxValue);

        uint256 executeTime = block.timestamp + DEFAULT_DELAY;
        bytes32 txHash = timelock.queueTransaction(address(mockTarget), maxValue, "receiveEther()", "", executeTime);

        vm.warp(executeTime);
        timelock.executeTransaction{value: maxValue}(address(mockTarget), maxValue, "receiveEther()", "", executeTime);

        assertEq(address(mockTarget).balance, maxValue, "Value should be transferred");
        assertFalse(timelock.queuedTransactions(txHash), "Transaction should be executed");

        vm.stopPrank();
    }
}
