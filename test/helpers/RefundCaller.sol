// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EthRefund} from "../../src/EthRefund.sol";

/// @dev Test-only sender that exercises refund callbacks and failed external calls.
contract RefundCaller {
    enum Behavior {
        Accept,
        Reject,
        CatchReentry,
        PropagateReentry,
        ExhaustGas
    }

    error Rejected();
    error ReentryNotCaught();

    EthRefund public immutable target;
    Behavior public behavior;
    bytes public reentryData;
    uint256 public reentryValue;
    bool public reentrySucceeded;
    bytes public reentryResult;
    uint256 public totalRefunded;
    uint256 public callbacks;
    uint256 public balanceDuringRefund;
    address public lastRefundSender;

    constructor(EthRefund target_) {
        target = target_;
    }

    function configure(Behavior behavior_, uint256 value_, bytes memory data_) external {
        behavior = behavior_;
        reentryValue = value_;
        reentryData = data_;
    }

    function execute(uint256 amount, bytes memory data) external returns (bool success, bytes memory result) {
        return address(target).call{value: amount}(data);
    }

    function sendWithStipend(uint256 amount) external returns (bool success) {
        return payable(address(target)).send(amount);
    }

    receive() external payable {
        if (behavior == Behavior.Reject) revert Rejected();
        if (behavior == Behavior.ExhaustGas) {
            // Consume all forwarded gas without an unbounded test loop.
            assembly {
                invalid()
            }
        }

        totalRefunded += msg.value;
        callbacks++;
        balanceDuringRefund = address(this).balance;
        lastRefundSender = msg.sender;

        if (behavior == Behavior.CatchReentry || behavior == Behavior.PropagateReentry) {
            (reentrySucceeded, reentryResult) = address(target).call{value: reentryValue}(reentryData);
            if (!reentrySucceeded && behavior == Behavior.PropagateReentry) revert ReentryNotCaught();
        }
    }
}

contract NonPayableCaller {
    function execute(EthRefund target, uint256 amount) external returns (bool success, bytes memory result) {
        return address(target).call{value: amount}("");
    }
}

contract RefundFactory {
    function deploy(bytes32 salt) external returns (EthRefund) {
        return new EthRefund{salt: salt}();
    }
}
