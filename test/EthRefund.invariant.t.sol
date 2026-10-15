// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EthRefund} from "../src/EthRefund.sol";
import {RefundCaller} from "./helpers/RefundCaller.sol";
import {ForceRefundEth} from "./helpers/RefundAdversaries.sol";

contract RefundHandler is Test {
    EthRefund public immutable target;
    RefundCaller public immutable accepting;
    RefundCaller public immutable rejecting;
    RefundCaller public immutable reentrant;

    uint256 public successfulValue;
    uint256 public successfulCalls;
    uint256 public forcedValue;

    constructor(EthRefund target_) {
        target = target_;
        accepting = new RefundCaller(target_);
        rejecting = new RefundCaller(target_);
        reentrant = new RefundCaller(target_);
        rejecting.configure(RefundCaller.Behavior.Reject, 0, "");
    }

    function pay(uint96 seed, uint8 entry) external {
        uint256 amount = bound(uint256(seed), 1, 100 ether);
        (bool success,) = accepting.execute(amount, _payload(entry));
        assertTrue(success, "valid payment failed after prior actions");
        successfulValue += amount;
        successfulCalls++;
    }

    function rejectRefund(uint96 seed, uint8 entry) external {
        uint256 amount = bound(uint256(seed), 1, 100 ether);
        (bool success, bytes memory result) = rejecting.execute(amount, _payload(entry));
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(EthRefund.RefundFailed.selector));
    }

    function reenter(uint96 seed, uint8 outerEntry, uint8 innerEntry, bool catchFailure, bool zeroInnerValue) external {
        uint256 amount = bound(uint256(seed), 1, 100 ether);
        RefundCaller.Behavior behavior =
            catchFailure ? RefundCaller.Behavior.CatchReentry : RefundCaller.Behavior.PropagateReentry;
        reentrant.configure(behavior, zeroInnerValue ? 0 : amount, _payload(innerEntry));

        (bool success, bytes memory result) = reentrant.execute(amount, _payload(outerEntry));

        assertEq(success, catchFailure);
        if (catchFailure) {
            assertFalse(reentrant.reentrySucceeded());
            assertEq(reentrant.reentryResult(), abi.encodeWithSelector(EthRefund.ReentrantCall.selector));
            successfulValue += amount;
            successfulCalls++;
        } else {
            assertEq(result, abi.encodeWithSelector(EthRefund.RefundFailed.selector));
        }
    }

    function zeroPayment(uint8 entry) external {
        (bool success, bytes memory result) = accepting.execute(0, _payload(entry));
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(EthRefund.ZeroAmount.selector));
    }

    /// @dev Track forced value independently of target.balance; never overwrite the target's state.
    function forceEth(uint96 seed) external {
        uint256 amount = bound(uint256(seed), 1, 100 ether);
        vm.deal(address(this), amount);
        new ForceRefundEth{value: amount}(payable(address(target)));
        forcedValue += amount;
        assertEq(address(this).balance, 0);
    }

    /// @dev Reuse the same funded actor through failures and multiple refunds in one transaction.
    function payBatch(uint96 seed, uint8 countSeed, uint8 entry) external {
        uint256 amount = bound(uint256(seed), 1, 100 ether);
        uint256 count = bound(uint256(countSeed), 2, 6);
        uint256 balanceBefore = address(accepting).balance;
        uint256 targetBefore = address(target).balance;
        uint256 callbacksBefore = accepting.callbacks();
        uint256 refundedBefore = accepting.totalRefunded();

        for (uint256 i; i < count; ++i) {
            bytes memory data = _payload(uint8((uint256(entry) + i) % 3));
            (bool failed, bytes memory reason) = rejecting.execute(amount, data);
            assertFalse(failed);
            assertEq(reason, abi.encodeWithSelector(EthRefund.RefundFailed.selector));

            (bool success, bytes memory result) = accepting.execute(amount, data);
            assertTrue(success, "a prior call in this transaction left the guard locked");
            assertEq(result.length, 0);
            assertEq(address(accepting).balance, balanceBefore);
            assertEq(address(target).balance, targetBefore);
            assertEq(accepting.callbacks(), callbacksBefore + i + 1);
            assertEq(accepting.totalRefunded(), refundedBefore + amount * (i + 1));
            successfulValue += amount;
            successfulCalls++;
        }
    }

    function _payload(uint8 entry) private pure returns (bytes memory) {
        if (entry % 3 == 0) return "";
        if (entry % 3 == 1) return abi.encodeCall(EthRefund.refund, ());
        return hex"01020304";
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract EthRefundInvariantTest is Test {
    EthRefund private target;
    RefundHandler private handler;

    function setUp() public {
        target = new EthRefund();
        handler = new RefundHandler(target);
        vm.deal(address(target), 7 ether);
        vm.deal(address(handler.accepting()), 100 ether);
        vm.deal(address(handler.rejecting()), 100 ether);
        vm.deal(address(handler.reentrant()), 100 ether);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = RefundHandler.pay.selector;
        selectors[1] = RefundHandler.rejectRefund.selector;
        selectors[2] = RefundHandler.reenter.selector;
        selectors[3] = RefundHandler.zeroPayment.selector;
        selectors[4] = RefundHandler.forceEth.selector;
        selectors[5] = RefundHandler.payBatch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_NoSenderLosesPrincipalAndPreexistingEthIsUntouched() public view {
        assertEq(address(target).balance, 7 ether + handler.forcedValue());
        assertEq(address(handler.accepting()).balance, 100 ether);
        assertEq(address(handler.rejecting()).balance, 100 ether);
        assertEq(address(handler.reentrant()).balance, 100 ether);
    }

    function invariant_EachSuccessfulPaymentIsRefundedExactlyOnce() public view {
        assertEq(handler.accepting().totalRefunded() + handler.reentrant().totalRefunded(), handler.successfulValue());
        assertEq(handler.accepting().callbacks() + handler.reentrant().callbacks(), handler.successfulCalls());
        assertEq(handler.rejecting().totalRefunded(), 0);
        assertEq(handler.rejecting().callbacks(), 0);
    }

    /// @dev Even a sequence ending in a failed callback must leave the guard usable.
    function afterInvariant() public {
        uint256 previousCallbacks = handler.accepting().callbacks();
        uint256 previousRefunded = handler.accepting().totalRefunded();
        bytes[3] memory payloads = [bytes(""), abi.encodeCall(EthRefund.refund, ()), bytes(hex"ffffffff")];
        for (uint256 i; i < payloads.length; ++i) {
            (bool success,) = handler.accepting().execute(1, payloads[i]);
            assertTrue(success);
            assertEq(handler.accepting().callbacks(), previousCallbacks + i + 1);
            assertEq(handler.accepting().totalRefunded(), previousRefunded + i + 1);
        }
        assertEq(address(handler.accepting()).balance, 100 ether);
        assertEq(address(target).balance, 7 ether + handler.forcedValue());
    }
}
