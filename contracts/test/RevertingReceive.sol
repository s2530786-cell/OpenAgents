// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RevertingReceive
/// @notice A contract that reverts on receive (simulates a contract without receive())
/// @dev Used to test that PrizeSplit handles failed ETH transfers gracefully.
contract RevertingReceive {
    /// @notice Claim prize from PrizeSplit on behalf of this contract.
    /// @param prizeSplit The PrizeSplit contract address
    /// @param roundId The round ID to claim from
    function claimPrizeFromContract(address prizeSplit, uint256 roundId) external {
        (bool sent, ) = prizeSplit.call(abi.encodeWithSignature("claimPrize(uint256)", roundId));
        require(sent, "Claim call failed");
    }

    /// @notice Always revert on receive to simulate a contract without receive()
    receive() external payable {
        revert("RevertingReceive: no ETH accepted");
    }
}
