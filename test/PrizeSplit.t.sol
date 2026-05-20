// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/lottery/PrizeSplit.sol";
import "../contracts/test/RevertingReceive.sol";

contract PrizeSplitTest is Test {
    PrizeSplit public prizeSplit;
    RevertingReceive public revertingReceive;
    address public admin;
    address public winner1;
    address public winner2;
    address public winner3;
    address public nonWinner;

    uint256 public constant ONE_ETH = 1 ether;
    uint256 public constant DEADLINE_DURATION = 90 days;

    event RoundFunded(uint256 indexed roundId, uint256 amount);
    event RoundFinalized(uint256 indexed roundId, uint256 winnerCount);
    event PrizeClaimed(address indexed winner, uint256 amount, uint256 indexed roundId);
    event PrizeReclaimed(uint256 indexed roundId, uint256 amount);

    function setUp() public {
        admin = address(this);
        winner1 = makeAddr("winner1");
        winner2 = makeAddr("winner2");
        winner3 = makeAddr("winner3");
        nonWinner = makeAddr("nonWinner");

        prizeSplit = new PrizeSplit();
        revertingReceive = new RevertingReceive();
    }

    // ===== Funding and Finalization =====

    function test_FundRound() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        assertEq(prizeSplit.roundId(), 1);
        assertEq(prizeSplit.totalPrize(), ONE_ETH);
    }

    function test_Revert_ZeroFund() public {
        vm.expectRevert("No ETH sent");
        prizeSplit.fundRound{value: 0}();
    }

    function test_Revert_NonAdminFunding() public {
        // Give winner1 some ETH so OutOfFunds doesn't mask the admin check
        vm.deal(winner1, ONE_ETH);
        vm.prank(winner1);
        vm.expectRevert("Not admin");
        prizeSplit.fundRound{value: ONE_ETH}();
    }

    function test_FinalizeRound() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](3);
        winners[0] = winner1;
        winners[1] = winner2;
        winners[2] = winner3;

        uint256 share = ONE_ETH / 3;

        prizeSplit.finalizeRound(1, winners);

        assertEq(prizeSplit.getShare(1, winner1), share);
        assertEq(prizeSplit.claimable(winner1, 1), share);
        assertTrue(prizeSplit.roundDeadline(1) > block.timestamp);
    }

    function test_Revert_DoubleFinalization() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        prizeSplit.finalizeRound(1, winners);

        vm.expectRevert("Already finalized");
        prizeSplit.finalizeRound(1, winners);
    }

    function test_Revert_UnfundedRound() public {
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        vm.expectRevert("No prize pool");
        prizeSplit.finalizeRound(999, winners);
    }

    function test_Revert_EmptyWinners() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](0);
        vm.expectRevert("No winners specified");
        prizeSplit.finalizeRound(1, winners);
    }

    // ===== Pull-based Claims =====

    function test_NormalClaim() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](3);
        winners[0] = winner1;
        winners[1] = winner2;
        winners[2] = winner3;
        prizeSplit.finalizeRound(1, winners);

        uint256 share = ONE_ETH / 3;
        uint256 balanceBefore = winner1.balance;

        vm.prank(winner1);
        vm.expectEmit(true, true, true, true, address(prizeSplit));
        emit PrizeClaimed(winner1, share, 1);
        prizeSplit.claimPrize(1);

        uint256 balanceAfter = winner1.balance;
        assertEq(balanceAfter - balanceBefore, share);
        assertEq(prizeSplit.claimable(winner1, 1), 0);
        assertTrue(prizeSplit.isClaimed(1, winner1));
    }

    function test_Revert_DoubleClaim() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        prizeSplit.finalizeRound(1, winners);

        vm.prank(winner1);
        prizeSplit.claimPrize(1);

        vm.prank(winner1);
        vm.expectRevert("Nothing to claim");
        prizeSplit.claimPrize(1);
    }

    function test_Revert_NonWinnerClaim() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        prizeSplit.finalizeRound(1, winners);

        vm.prank(nonWinner);
        vm.expectRevert("Nothing to claim");
        prizeSplit.claimPrize(1);
    }

    function test_Revert_ClaimUnfinalized() public {
        vm.expectRevert("Round not finalized");
        prizeSplit.claimPrize(999);
    }

    function test_Revert_ClaimExpired() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        prizeSplit.finalizeRound(1, winners);

        // Fast forward past 90-day deadline
        uint256 deadline = prizeSplit.roundDeadline(1);
        vm.warp(deadline + 1);

        vm.prank(winner1);
        vm.expectRevert("Claim period expired");
        prizeSplit.claimPrize(1);
    }

    // ===== Contract Winner Failure Handling =====

    function test_ContractWinnerDoesNotBlockOthers() public {
        uint256 totalPrizeValue = 1.5 ether;
        prizeSplit.fundRound{value: totalPrizeValue}();

        address[] memory winners = new address[](2);
        winners[0] = winner1;
        winners[1] = address(revertingReceive);
        prizeSplit.finalizeRound(1, winners);

        uint256 share = totalPrizeValue / 2;

        // winner1 (EOA) should claim successfully
        uint256 balanceBefore = winner1.balance;
        vm.prank(winner1);
        prizeSplit.claimPrize(1);
        uint256 balanceAfter = winner1.balance;
        assertEq(balanceAfter - balanceBefore, share);
        assertTrue(prizeSplit.isClaimed(1, winner1));
    }

    function test_ContractWinnerClaimRestoreOnFail() public {
        uint256 totalPrizeValue = 1.5 ether;
        prizeSplit.fundRound{value: totalPrizeValue}();

        address[] memory winners = new address[](2);
        winners[0] = winner1;
        winners[1] = address(revertingReceive);
        prizeSplit.finalizeRound(1, winners);

        uint256 share = totalPrizeValue / 2;

        // revertingReceive contract tries to claim — receive() reverts so amount is restored
        revertingReceive.claimPrizeFromContract(address(prizeSplit), 1);

        // Claimable should be restored (transfer failed)
        assertEq(prizeSplit.claimable(address(revertingReceive), 1), share);
        assertFalse(prizeSplit.isClaimed(1, address(revertingReceive)));
    }

    // ===== Treasury Reclaim =====

    receive() external payable {}

    function test_TreasuryReclaimExpired() public {
        uint256 totalPrizeValue = 1.5 ether;
        prizeSplit.fundRound{value: totalPrizeValue}();

        address[] memory winners = new address[](2);
        winners[0] = winner1;
        winners[1] = address(revertingReceive);
        prizeSplit.finalizeRound(1, winners);

        uint256 share = totalPrizeValue / 2;

        // winner1 claims their share
        vm.prank(winner1);
        prizeSplit.claimPrize(1);

        // revertingReceive fails to claim (reverts on receive)
        revertingReceive.claimPrizeFromContract(address(prizeSplit), 1);

        // Fast forward past deadline
        uint256 deadline = prizeSplit.roundDeadline(1);
        vm.warp(deadline + 1);

        // Admin reclaims unclaimed funds (the failed portion)
        uint256 balanceBefore = admin.balance;
        vm.expectEmit(true, true, true, true, address(prizeSplit));
        emit PrizeReclaimed(1, share);
        prizeSplit.reclaimExpired(1);
        uint256 balanceAfter = admin.balance;
        assertEq(balanceAfter - balanceBefore, share);
        assertEq(prizeSplit.claimable(address(revertingReceive), 1), 0);
    }

    function test_Revert_ReclaimBeforeDeadline() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        prizeSplit.finalizeRound(1, winners);

        vm.expectRevert("Deadline not reached");
        prizeSplit.reclaimExpired(1);
    }

    function test_Revert_ReclaimAllClaimed() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        prizeSplit.finalizeRound(1, winners);

        vm.prank(winner1);
        prizeSplit.claimPrize(1);

        vm.warp(block.timestamp + DEADLINE_DURATION + 1);

        vm.expectRevert("Nothing to reclaim");
        prizeSplit.reclaimExpired(1);
    }

    function test_Revert_NonAdminReclaim() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        prizeSplit.finalizeRound(1, winners);

        vm.warp(block.timestamp + DEADLINE_DURATION + 1);

        vm.prank(winner1);
        vm.expectRevert("Not admin");
        prizeSplit.reclaimExpired(1);
    }

    function test_TotalClaimable() public {
        prizeSplit.fundRound{value: ONE_ETH}();
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        prizeSplit.finalizeRound(1, winners);

        assertEq(prizeSplit.getTotalClaimable(winner1), ONE_ETH);

        vm.prank(winner1);
        prizeSplit.claimPrize(1);

        assertEq(prizeSplit.getTotalClaimable(winner1), 0);
    }
}
