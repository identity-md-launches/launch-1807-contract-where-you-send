// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {EthRefund} from "src/EthRefund.sol";
import {RefundCaller} from "./helpers/RefundCaller.sol";
import {AtomicRefundCaller, ForceRefundEth, FallbackRefundCaller} from "./helpers/RefundAdversaries.sol";

/// forge-config: default.fuzz.runs = 1024
contract EthRefundAtomicTest is Test {
    event Refunded(address indexed sender, uint256 amount);

    EthRefund private target;
    AtomicRefundCaller private caller;
    address payable private recipient;

    function setUp() public {
        target = new EthRefund();
        caller = new AtomicRefundCaller(target);
        recipient = payable(makeAddr("atomic-refund-recipient"));
    }

    function test_SameWeiCanBeReusedAcrossAllCalldataShapesThenSpentInOneTransaction() public {
        bytes memory selector = abi.encodeCall(EthRefund.refund, ());
        bytes[] memory data = new bytes[](7);
        data[0] = "";
        data[1] = selector;
        data[2] = abi.encodePacked(selector[0]);
        data[3] = abi.encodePacked(selector[0], selector[1]);
        data[4] = abi.encodePacked(selector[0], selector[1], selector[2]);
        data[5] = hex"ffffffff";
        data[6] = abi.encodePacked(selector, bytes32(type(uint256).max));
        _checkCyclesAndSpend(1, data);
    }

    function testFuzz_RefundsAreImmediatelyReusable(uint96 amountSeed, uint8 countSeed, bytes32 tail) public {
        uint256 amount = bound(uint256(amountSeed), 1, type(uint96).max);
        uint256 count = bound(uint256(countSeed), 1, 12);
        bytes[] memory data = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            data[i] = _payload(uint8(i));
            if (i % 3 != 0) data[i] = bytes.concat(data[i], tail);
        }
        _checkCyclesAndSpend(amount, data);
    }

    function testFuzz_FailedCallCanBeCaughtAndRetriedWithinOneTransaction(
        uint96 amountSeed,
        uint8 failureMode,
        uint8 failedEntry,
        uint8 recoveredEntry
    ) public {
        uint256 amount = bound(uint256(amountSeed), 1, type(uint96).max);
        vm.deal(address(caller), amount);
        vm.deal(address(target), 7 ether);
        vm.recordLogs();

        bytes memory failure =
            caller.failThenRecover(amount, failureMode, _payload(failedEntry), _payload(recoveredEntry));

        assertEq(
            failure,
            abi.encodeWithSelector(
                failureMode % 3 == 0 ? EthRefund.ZeroAmount.selector : EthRefund.RefundFailed.selector
            )
        );
        assertEq(caller.callbacks(), 2);
        assertEq(caller.totalRefunded(), amount * 2);
        assertEq(address(caller).balance, amount);
        assertEq(address(target).balance, 7 ether);
        _assertRefundLogs(vm.getRecordedLogs(), address(caller), amount, 2);
    }

    function test_EnclosingRevertRollsBackCompletedRefundAndCallbackState() public {
        vm.deal(address(caller), 3 ether);
        vm.deal(address(target), 7 ether);
        (bool initialSuccess,) = caller.execute(1 ether, "");
        assertTrue(initialSuccess);

        for (uint8 entry; entry < 3; ++entry) {
            // Compute calldata before arming the expectation; this is one enclosing call.
            bytes memory data = _payload(entry);
            vm.expectRevert(AtomicRefundCaller.EnclosingCallReverted.selector);
            caller.refundThenRevert(3 ether, data);

            assertEq(caller.callbacks(), 1);
            assertEq(caller.totalRefunded(), 1 ether);
            assertEq(address(caller).balance, 3 ether);
            assertEq(address(target).balance, 7 ether);
        }

        (bool recovered,) = caller.execute(3 ether, abi.encodeCall(EthRefund.refund, ()));
        assertTrue(recovered, "enclosing revert must not leave the lock set");
        assertEq(caller.callbacks(), 2);
        assertEq(caller.totalRefunded(), 4 ether);
    }

    function test_MaximumUint256PaymentIsReturnedExactly() public {
        _checkFullWidthRefund(type(uint256).max, 0, 1);
    }

    function test_OneWeiRefundWhenTemporaryTargetBalanceReachesUint256Maximum() public {
        _checkFullWidthRefund(1, type(uint256).max - 1, 2);
    }

    function testFuzz_FullWidthPaymentsPreserveUnrelatedBalance(uint256 amountSeed, uint256 existingSeed, uint8 entry)
        public
    {
        uint256 amount = bound(amountSeed, 1, type(uint256).max);
        // The temporary target balance must remain representable by the EVM.
        uint256 existing = bound(existingSeed, 0, type(uint256).max - amount);
        _checkFullWidthRefund(amount, existing, entry);
    }

    function test_PayableFallbackReceiverAcceptsRefundDespiteReturningFalseData() public {
        FallbackRefundCaller fallbackCaller = new FallbackRefundCaller();
        vm.deal(address(fallbackCaller), 1 ether);

        for (uint8 entry; entry < 3; ++entry) {
            vm.expectEmit(true, false, false, true, address(target));
            emit Refunded(address(fallbackCaller), 1 ether);
            (bool success, bytes memory result) = fallbackCaller.execute(target, 1 ether, _payload(entry));
            assertTrue(success);
            assertEq(result.length, 0);
            assertEq(fallbackCaller.lastCalldataLength(), 0);
            assertEq(fallbackCaller.lastSender(), address(target));
            assertEq(fallbackCaller.callbacks(), uint256(entry) + 1);
            assertEq(fallbackCaller.totalRefunded(), (uint256(entry) + 1) * 1 ether);
            assertEq(address(fallbackCaller).balance, 1 ether);
            assertEq(address(target).balance, 0);
        }
    }

    function test_ActualForcedEthCannotBeClaimedByZeroOrPositivePayment() public {
        vm.deal(address(this), 7 ether);
        vm.deal(address(caller), 1 ether);
        vm.recordLogs();
        new ForceRefundEth{value: 7 ether}(payable(address(target)));
        assertEq(vm.getRecordedLogs().length, 0, "forced ETH must bypass the refund entry points");
        assertEq(address(target).balance, 7 ether);

        for (uint8 entry; entry < 3; ++entry) {
            (bool zeroSuccess, bytes memory reason) = caller.execute(0, _payload(entry));
            assertFalse(zeroSuccess);
            assertEq(reason, abi.encodeWithSelector(EthRefund.ZeroAmount.selector));
            (bool success,) = caller.execute(1 ether, _payload(entry));
            assertTrue(success);
            assertEq(address(target).balance, 7 ether);
            assertEq(address(caller).balance, 1 ether);
        }
        assertEq(caller.totalRefunded(), 3 ether);
        assertEq(caller.callbacks(), 3);
    }

    function _checkCyclesAndSpend(uint256 amount, bytes[] memory data) private {
        vm.deal(address(caller), amount);
        vm.deal(address(target), 7 ether);
        uint256 recipientBefore = recipient.balance;
        vm.recordLogs();

        caller.cycleAndSpend(amount, data, recipient);

        assertEq(address(caller).balance, 0);
        assertEq(recipient.balance, recipientBefore + amount);
        assertEq(caller.totalRefunded(), amount * data.length);
        assertEq(caller.callbacks(), data.length);
        assertEq(caller.lastRefundSender(), address(target));
        assertEq(address(target).balance, 7 ether);
        _assertRefundLogs(vm.getRecordedLogs(), address(caller), amount, data.length);
    }

    function _checkFullWidthRefund(uint256 amount, uint256 existing, uint8 entry) private {
        // One payment per fixture keeps the receiver's lifetime accounting from overflowing.
        RefundCaller fullWidthCaller = new RefundCaller(target);
        vm.deal(address(fullWidthCaller), amount);
        vm.deal(address(target), existing);
        vm.expectEmit(true, false, false, true, address(target));
        emit Refunded(address(fullWidthCaller), amount);

        (bool success, bytes memory result) = fullWidthCaller.execute(amount, _payload(entry));

        assertTrue(success);
        assertEq(result.length, 0);
        assertEq(fullWidthCaller.callbacks(), 1);
        assertEq(fullWidthCaller.totalRefunded(), amount);
        assertEq(fullWidthCaller.balanceDuringRefund(), amount);
        assertEq(fullWidthCaller.lastRefundSender(), address(target));
        assertEq(address(fullWidthCaller).balance, amount);
        assertEq(address(target).balance, existing);
    }

    function _assertRefundLogs(Vm.Log[] memory logs, address sender, uint256 amount, uint256 count) private view {
        assertEq(logs.length, count, "exactly one event per completed refund");
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(target));
            assertEq(logs[i].topics.length, 2);
            assertEq(logs[i].topics[0], keccak256("Refunded(address,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(sender))));
            assertEq(logs[i].data, abi.encode(amount));
        }
    }

    function _payload(uint8 entry) private pure returns (bytes memory) {
        if (entry % 3 == 0) return "";
        if (entry % 3 == 1) return abi.encodeCall(EthRefund.refund, ());
        return hex"ffffffff";
    }
}
