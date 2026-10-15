// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EthRefund} from "src/EthRefund.sol";
import {RefundCaller} from "./RefundCaller.sol";

/// @dev All target interactions within a method occur in one transaction, including on Forge 1.8.
contract AtomicRefundCaller is RefundCaller {
    error EnclosingCallReverted();

    constructor(EthRefund target_) RefundCaller(target_) {}

    function cycleAndSpend(uint256 amount, bytes[] calldata payloads, address payable recipient) external {
        uint256 startingBalance = address(this).balance;
        uint256 expectedCallbacks = callbacks;
        uint256 expectedRefunded = totalRefunded;
        for (uint256 i; i < payloads.length; ++i) {
            (bool success, bytes memory result) = address(target).call{value: amount}(payloads[i]);
            require(success && result.length == 0, "refund call failed");
            require(address(this).balance == startingBalance, "principal not restored before next call");
            require(callbacks == ++expectedCallbacks, "missing or duplicate callback");
            expectedRefunded += amount;
            require(totalRefunded == expectedRefunded, "incorrect callback value");
        }
        (bool spent,) = recipient.call{value: amount}("");
        require(spent, "refunded ETH unavailable to spend");
    }

    /// @dev Catch a failed payment, then reuse the same principal twice before returning.
    function failThenRecover(uint256 amount, uint8 failureMode, bytes calldata badData, bytes calldata goodData)
        external
        returns (bytes memory failure)
    {
        uint256 startingBalance = address(this).balance;
        uint256 startingCallbacks = callbacks;
        uint256 startingRefunded = totalRefunded;
        failureMode %= 3;
        behavior = failureMode == 1 ? Behavior.Reject : Behavior.PropagateReentry;
        reentryValue = amount;
        reentryData = goodData;

        (bool success, bytes memory result) = address(target).call{value: failureMode == 0 ? 0 : amount}(badData);
        require(!success, "invalid payment succeeded");
        require(address(this).balance == startingBalance, "failed payment retained principal");
        require(callbacks == startingCallbacks && totalRefunded == startingRefunded, "callback did not roll back");
        failure = result;

        behavior = Behavior.Accept;
        for (uint256 i; i < 2; ++i) {
            (success, result) = address(target).call{value: amount}(goodData);
            require(success && result.length == 0, "guard unusable after failure");
            require(address(this).balance == startingBalance, "successful payment retained principal");
            require(callbacks == startingCallbacks + i + 1, "incorrect recovery callback count");
            require(totalRefunded == startingRefunded + amount * (i + 1), "incorrect recovery value");
        }
    }

    function refundThenRevert(uint256 amount, bytes calldata data) external {
        uint256 previousCallbacks = callbacks;
        (bool success,) = address(target).call{value: amount}(data);
        require(success && callbacks == previousCallbacks + 1, "refund did not complete before outer revert");
        revert EnclosingCallReverted();
    }
}

/// @dev Test fixture only. A forced credit bypasses the application's receive/fallback code.
contract ForceRefundEth {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

/// @dev No receive function: refunds must reach the payable fallback with empty calldata.
contract FallbackRefundCaller {
    address public lastSender;
    uint256 public lastCalldataLength;
    uint256 public callbacks;
    uint256 public totalRefunded;

    function execute(EthRefund target, uint256 amount, bytes calldata data)
        external
        returns (bool success, bytes memory result)
    {
        return address(target).call{value: amount}(data);
    }

    fallback(bytes calldata data) external payable returns (bytes memory) {
        lastSender = msg.sender;
        lastCalldataLength = data.length;
        ++callbacks;
        totalRefunded += msg.value;
        // A successful EVM call need not return an ABI-encoded true value.
        return abi.encode(false);
    }
}
