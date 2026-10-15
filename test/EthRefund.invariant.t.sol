// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EthRefund} from "../src/EthRefund.sol";
import {RefundCaller} from "./helpers/RefundCaller.sol";

contract RefundHandler is Test {
    EthRefund public immutable target;
    RefundCaller public immutable accepting;
    RefundCaller public immutable rejecting;
    RefundCaller public immutable reentrant;

    uint256 public successfulValue;
    uint256 public successfulCalls;

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

    function _payload(uint8 entry) private pure returns (bytes memory) {
        if (entry % 3 == 0) return "";
        if (entry % 3 == 1) return abi.encodeCall(EthRefund.refund, ());
        return hex"01020304";
    }
}

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

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = RefundHandler.pay.selector;
        selectors[1] = RefundHandler.rejectRefund.selector;
        selectors[2] = RefundHandler.reenter.selector;
        selectors[3] = RefundHandler.zeroPayment.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_NoSenderLosesPrincipalAndPreexistingEthIsUntouched() public view {
        assertEq(address(target).balance, 7 ether);
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
        (bool success,) = handler.accepting().execute(1, "");
        assertTrue(success);
        assertEq(handler.accepting().callbacks(), previousCallbacks + 1);
        assertEq(address(handler.accepting()).balance, 100 ether);
        assertEq(address(target).balance, 7 ether);
    }
}
