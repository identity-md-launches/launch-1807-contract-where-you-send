// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title EthRefund
/// @notice Returns each positive ETH payment to its immediate sender in the same call.
/// @dev No owner, fees, deposits, or withdrawals. Refund failure reverts the payment.
contract EthRefund {
    error ZeroAmount();
    error ReentrantCall();
    error RefundFailed();

    event Refunded(address indexed sender, uint256 amount);

    bool private refundInProgress;

    modifier nonReentrant() {
        if (refundInProgress) revert ReentrantCall();
        refundInProgress = true;
        _;
        refundInProgress = false;
    }

    /// @notice Send ETH with empty calldata to receive it back immediately.
    receive() external payable {
        _refund();
    }

    /// @notice Unrecognized calldata is ignored; any attached ETH is refunded.
    fallback() external payable {
        _refund();
    }

    /// @notice Returns exactly msg.value to msg.sender, or reverts the entire call.
    /// @dev Contract callers must accept an empty-calldata ETH call. Gas is not refunded.
    function refund() external payable {
        _refund();
    }

    function _refund() private nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        // Only this call's value is returned, never the contract's pre-existing balance.
        (bool success,) = payable(msg.sender).call{value: msg.value}("");
        if (!success) revert RefundFailed();

        emit Refunded(msg.sender, msg.value);
    }
}
