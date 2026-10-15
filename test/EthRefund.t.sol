// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {EthRefund} from "../src/EthRefund.sol";
import {RefundCaller, NonPayableCaller, RefundFactory} from "./helpers/RefundCaller.sol";

contract EthRefundTest is Test {
    event Refunded(address indexed sender, uint256 amount);

    EthRefund private target;
    RefundCaller private caller;
    address private alice;

    function setUp() public {
        target = new EthRefund();
        caller = new RefundCaller(target);
        alice = makeAddr("alice");
        vm.deal(alice, 10 ether);
        vm.deal(address(caller), 10 ether);
    }

    function test_PlainEthTransferReturnsFullValueAndEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(target));
        emit Refunded(alice, 1 ether);

        vm.prank(alice);
        (bool success, bytes memory result) = address(target).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(result.length, 0);
        assertEq(alice.balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_ExplicitRefundReturnsFullValue() public {
        vm.prank(alice);
        target.refund{value: 10 ether}();

        assertEq(alice.balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_OneWeiIsRefunded() public {
        vm.prank(alice);
        target.refund{value: 1}();

        assertEq(alice.balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_UnrecognizedCalldataAlsoRefunds() public {
        vm.prank(alice);
        (bool success,) = address(target).call{value: 2 ether}(hex"0102030405060708");

        assertTrue(success);
        assertEq(alice.balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_ContractReceivesRefundBeforeCallReturns() public {
        (bool success,) = caller.execute(3 ether, abi.encodeCall(EthRefund.refund, ()));

        assertTrue(success);
        assertEq(caller.totalRefunded(), 3 ether);
        assertEq(caller.callbacks(), 1);
        assertEq(caller.balanceDuringRefund(), 10 ether);
        assertEq(caller.lastRefundSender(), address(target));
        assertEq(address(caller).balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_RefundGoesToImmediateCallerInsteadOfTransactionOrigin() public {
        address origin = makeAddr("origin");
        vm.deal(origin, 5 ether);
        vm.prank(origin, origin);
        (bool success,) = caller.execute(1 ether, "");

        assertTrue(success);
        assertEq(address(caller).balance, 10 ether);
        assertEq(caller.totalRefunded(), 1 ether);
        assertEq(origin.balance, 5 ether);
    }

    function test_SequentialCallsCanUseEveryEntryPoint() public {
        for (uint8 entry; entry < 3; ++entry) {
            (bool success,) = caller.execute(1 ether, _payload(entry));
            assertTrue(success);
        }

        assertEq(caller.totalRefunded(), 3 ether);
        assertEq(caller.callbacks(), 3);
        assertEq(address(caller).balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_ZeroValueRevertsOnEveryEntryPointWithoutCallback() public {
        for (uint8 entry; entry < 3; ++entry) {
            (bool success, bytes memory result) = caller.execute(0, _payload(entry));
            assertFalse(success);
            assertEq(result, abi.encodeWithSelector(EthRefund.ZeroAmount.selector));
        }

        assertEq(caller.callbacks(), 0);
        assertEq(address(caller).balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_RejectingReceiverRevertsPaymentOnEveryEntryPoint() public {
        caller.configure(RefundCaller.Behavior.Reject, 0, "");
        vm.recordLogs();

        for (uint8 entry; entry < 3; ++entry) {
            (bool success, bytes memory result) = caller.execute(1 ether, _payload(entry));
            assertFalse(success);
            assertEq(result, abi.encodeWithSelector(EthRefund.RefundFailed.selector));
            assertEq(address(caller).balance, 10 ether);
            assertEq(address(target).balance, 0);
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertEq(caller.callbacks(), 0);
    }

    function test_CallerWithoutPayableReceiverCannotLoseItsPayment() public {
        NonPayableCaller nonPayable = new NonPayableCaller();
        vm.deal(address(nonPayable), 1 ether);

        (bool success, bytes memory result) = nonPayable.execute(target, 1 ether);

        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(EthRefund.RefundFailed.selector));
        assertEq(address(nonPayable).balance, 1 ether);
        assertEq(address(target).balance, 0);
    }

    function test_FailedRefundDoesNotLockContractOrBlockOtherSenders() public {
        caller.configure(RefundCaller.Behavior.Reject, 0, "");
        (bool failed,) = caller.execute(1 ether, "");
        assertFalse(failed);

        vm.prank(alice);
        target.refund{value: 2 ether}();
        assertEq(alice.balance, 10 ether);

        caller.configure(RefundCaller.Behavior.Accept, 0, "");
        (bool succeeded,) = caller.execute(1 ether, "");
        assertTrue(succeeded);
        assertEq(caller.totalRefunded(), 1 ether);
    }

    function test_ReceiverExhaustingGasRollsBackPayment() public {
        caller.configure(RefundCaller.Behavior.ExhaustGas, 0, "");

        (bool success, bytes memory result) = caller.execute{gas: 1_000_000}(1 ether, "");

        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(EthRefund.RefundFailed.selector));
        assertEq(address(caller).balance, 10 ether);
        assertEq(address(target).balance, 0);
        caller.configure(RefundCaller.Behavior.Accept, 0, "");
        (bool recovered,) = caller.execute(1 ether, "");
        assertTrue(recovered);
    }

    function test_StipendLimitedSendFailsWithoutLosingValue() public {
        assertFalse(caller.sendWithStipend(1 ether));
        assertEq(address(caller).balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_UncaughtReentryRevertsEntirePayment() public {
        caller.configure(RefundCaller.Behavior.PropagateReentry, 1 ether, abi.encodeCall(EthRefund.refund, ()));

        (bool success, bytes memory result) = caller.execute(1 ether, "");

        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(EthRefund.RefundFailed.selector));
        assertEq(caller.totalRefunded(), 0);
        assertEq(caller.callbacks(), 0);
        assertEq(address(caller).balance, 10 ether);
        assertEq(address(target).balance, 0);
    }

    function test_PreexistingBalanceCannotBeClaimedWithZeroValue() public {
        // Model an ETH credit that bypasses receive(), such as a forced balance transfer.
        vm.deal(address(target), 7 ether);

        (bool success, bytes memory result) = caller.execute(0, "");

        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(EthRefund.ZeroAmount.selector));
        assertEq(address(target).balance, 7 ether);
        assertEq(address(caller).balance, 10 ether);
    }

    function test_FactoryCanDeployWithoutArgumentsOrExternalDependencies() public {
        RefundFactory factory = new RefundFactory();
        EthRefund deployed = factory.deploy(keccak256("refund-test-deployment"));

        assertGt(address(deployed).code.length, 0);
        assertEq(address(deployed).code, address(target).code);
        vm.prank(alice);
        deployed.refund{value: 1 ether}();
        assertEq(alice.balance, 10 ether);
        assertEq(address(deployed).balance, 0);
    }

    function test_DeploymentRejectsEth() public {
        bytes memory initCode = type(EthRefund).creationCode;
        vm.deal(address(this), 1 ether);
        address deployed;
        assembly ("memory-safe") {
            deployed := create(1, add(initCode, 32), mload(initCode))
        }
        assertEq(deployed, address(0));
        assertEq(address(this).balance, 1 ether);
    }

    function test_RuntimeFitsDeploymentPolicy() public view {
        bytes memory code = address(target).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        assertLe(type(EthRefund).creationCode.length, 49_152);

        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }

    function testFuzz_ExactRefundPreservesExistingBalance(uint96 amountSeed, uint96 existingBalance, uint8 entry)
        public
    {
        uint256 amount = bound(uint256(amountSeed), 1, type(uint96).max);
        vm.deal(address(caller), amount);
        vm.deal(address(target), existingBalance);

        (bool success,) = caller.execute(amount, _payload(entry));

        assertTrue(success);
        assertEq(caller.totalRefunded(), amount);
        assertEq(caller.callbacks(), 1);
        assertEq(address(caller).balance, amount);
        assertEq(address(target).balance, existingBalance);
    }

    function testFuzz_ArbitraryCalldataRefunds(uint96 amountSeed, bytes memory data) public {
        uint256 amount = bound(uint256(amountSeed), 1, type(uint96).max);
        vm.deal(alice, amount);

        vm.prank(alice);
        (bool success,) = address(target).call{value: amount}(data);

        assertTrue(success);
        assertEq(alice.balance, amount);
        assertEq(address(target).balance, 0);
    }

    function testFuzz_CaughtReentryCannotDrainBalance(uint8 outerEntry, uint8 innerEntry, bool zeroInnerValue) public {
        vm.deal(address(target), 7 ether);
        caller.configure(RefundCaller.Behavior.CatchReentry, zeroInnerValue ? 0 : 1 ether, _payload(innerEntry));

        (bool success,) = caller.execute(1 ether, _payload(outerEntry));

        assertTrue(success);
        assertFalse(caller.reentrySucceeded());
        assertEq(caller.reentryResult(), abi.encodeWithSelector(EthRefund.ReentrantCall.selector));
        assertEq(caller.totalRefunded(), 1 ether);
        assertEq(caller.callbacks(), 1);
        assertEq(address(caller).balance, 10 ether);
        assertEq(address(target).balance, 7 ether);

        caller.configure(RefundCaller.Behavior.Accept, 0, "");
        (bool laterSuccess,) = caller.execute(1 ether, _payload(innerEntry));
        assertTrue(laterSuccess);
    }

    function _payload(uint8 entry) private pure returns (bytes memory) {
        if (entry % 3 == 0) return "";
        if (entry % 3 == 1) return abi.encodeCall(EthRefund.refund, ());
        return hex"01020304";
    }
}
