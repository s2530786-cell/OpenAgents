// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/staking/MultiTokenStaking.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock ERC20 for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MultiTokenStakingTest is Test {
    MultiTokenStaking public staking;
    MockERC20 public stakeToken;
    MockERC20 public rewardToken;

    address public constant ALICE = address(0x1);
    address public constant BOB = address(0x2);

    uint256 public constant INITIAL_BALANCE = 100_000e18;
    uint256 public constant REWARD_PER_SECOND = 1e18;
    uint256 public constant STAKE_AMOUNT = 10_000e18;

    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    function setUp() public {
        // Deploy tokens
        rewardToken = new MockERC20("Reward Token", "RWD");
        stakeToken = new MockERC20("Stake Token", "STK");

        // Deploy staking contract
        staking = new MultiTokenStaking(address(rewardToken), REWARD_PER_SECOND);

        // Add a pool
        staking.addPool(100, address(stakeToken));

        // Fund reward pool
        rewardToken.mint(address(staking), 1_000_000e18);

        // Fund test users
        stakeToken.transfer(ALICE, INITIAL_BALANCE);
        stakeToken.transfer(BOB, INITIAL_BALANCE);

        // Approve staking contract for both users
        vm.startPrank(ALICE);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(BOB);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test basic emergency withdraw after deposit
    function test_EmergencyWithdraw_Basic() public {
        vm.startPrank(ALICE);
        staking.deposit(0, STAKE_AMOUNT);

        uint256 aliceBalanceBefore = stakeToken.balanceOf(ALICE);

        // Warp forward to accrue some rewards (but emergency withdraw should NOT give rewards)
        vm.warp(block.timestamp + 1000);

        // Expect EmergencyWithdraw event
        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdraw(ALICE, 0, STAKE_AMOUNT);

        staking.emergencyWithdraw(0);

        uint256 aliceBalanceAfter = stakeToken.balanceOf(ALICE);

        // Alice should have her staked tokens back
        assertEq(aliceBalanceAfter - aliceBalanceBefore, STAKE_AMOUNT, "Should return staked tokens");

        // pool.totalStaked should be 0
        (,,,, uint256 totalStaked) = staking.poolInfo(0);
        assertEq(totalStaked, 0, "Pool totalStaked should be 0");

        // user.amount should be 0
        (uint256 userAmount,) = staking.userInfo(0, ALICE);
        assertEq(userAmount, 0, "User amount should be 0");

        // user.rewardDebt should be 0
        (, uint256 rewardDebt) = staking.userInfo(0, ALICE);
        assertEq(rewardDebt, 0, "User rewardDebt should be 0");
    }

    /// @notice Test that emergency withdraw does NOT distribute rewards
    function test_EmergencyWithdraw_NoRewards() public {
        vm.startPrank(ALICE);
        staking.deposit(0, STAKE_AMOUNT);

        // Warp forward to accrue rewards
        vm.warp(block.timestamp + 1000);

        uint256 rewardBalanceBefore = rewardToken.balanceOf(ALICE);

        staking.emergencyWithdraw(0);

        uint256 rewardBalanceAfter = rewardToken.balanceOf(ALICE);

        // No rewards should have been distributed
        assertEq(rewardBalanceAfter, rewardBalanceBefore, "Should NOT distribute rewards");
    }

    /// @notice Test that multiple emergency withdraws are not possible
    function test_EmergencyWithdraw_TwiceFails() public {
        vm.startPrank(ALICE);
        staking.deposit(0, STAKE_AMOUNT);
        staking.emergencyWithdraw(0);

        // Second call should revert since user has 0 staked
        vm.expectRevert("MultiStaking: nothing to withdraw");
        staking.emergencyWithdraw(0);
        vm.stopPrank();
    }

    /// @notice Test emergency withdraw with 0 staked reverts
    function test_EmergencyWithdraw_ZeroStake() public {
        vm.startPrank(ALICE);
        vm.expectRevert("MultiStaking: nothing to withdraw");
        staking.emergencyWithdraw(0);
        vm.stopPrank();
    }

    /// @notice Test that each user can independently emergency withdraw their stake
    function test_EmergencyWithdraw_MultipleUsers() public {
        uint256 aliceStake = 5_000e18;
        uint256 bobStake = 15_000e18;

        vm.startPrank(ALICE);
        staking.deposit(0, aliceStake);
        vm.stopPrank();

        vm.startPrank(BOB);
        staking.deposit(0, bobStake);
        vm.stopPrank();

        // Warp forward
        vm.warp(block.timestamp + 500);

        // Alice emergency withdraws
        vm.startPrank(ALICE);
        staking.emergencyWithdraw(0);
        vm.stopPrank();

        // Alice's state should be zeroed
        (uint256 aliceAmount,) = staking.userInfo(0, ALICE);
        assertEq(aliceAmount, 0, "Alice amount should be 0 after emergency withdraw");

        // Bob's state should still be intact
        (uint256 bobAmount,) = staking.userInfo(0, BOB);
        assertEq(bobAmount, bobStake, "Bob's amount should remain");

        // Pool totalStaked should reflect Bob's remaining stake
        (,,,, uint256 totalStaked) = staking.poolInfo(0);
        assertEq(totalStaked, bobStake, "Pool totalStaked should only have Bob's stake");

        // Bob can still withdraw normally and receive rewards
        // (emergency withdraw doesn't update pool, so update it first)
        staking.updatePool(0);

        vm.startPrank(BOB);
        staking.withdraw(0, bobStake);
        vm.stopPrank();

        // Bob's amount should be 0 after normal withdraw
        (bobAmount,) = staking.userInfo(0, BOB);
        assertEq(bobAmount, 0, "Bob's amount should be 0 after withdraw");

        // Pool totalStaked should be 0
        (,,,, totalStaked) = staking.poolInfo(0);
        assertEq(totalStaked, 0, "Total staked should be 0");

        // Bob should have received his stake back plus rewards
        uint256 bobTokenBalance = stakeToken.balanceOf(BOB);
        assertEq(bobTokenBalance, INITIAL_BALANCE, "Bob should have all tokens back");

        uint256 bobRewards = rewardToken.balanceOf(BOB);
        assertTrue(bobRewards > 0, "Bob should have received rewards");
    }

    /// @notice Test accounting integrity: pool.totalStaked correctly decremented
    function test_EmergencyWithdraw_Accounting() public {
        vm.startPrank(ALICE);
        staking.deposit(0, STAKE_AMOUNT);

        // Initial pool state before emergency withdraw
        (,,,, uint256 totalStakedBefore) = staking.poolInfo(0);
        assertEq(totalStakedBefore, STAKE_AMOUNT, "Initial totalStaked should match deposit");

        staking.emergencyWithdraw(0);

        // Pool totalStaked should be 0
        (,,,, uint256 totalStakedAfter) = staking.poolInfo(0);
        assertEq(totalStakedAfter, 0, "totalStaked should be 0 after emergency withdraw");

        // Pool should still accept new deposits
        staking.deposit(0, 5_000e18);
        (,,,, uint256 totalStakedNew) = staking.poolInfo(0);
        assertEq(totalStakedNew, 5_000e18, "New deposit should update totalStaked correctly");
        vm.stopPrank();
    }

    /// @notice Test that emergency withdraw doesn't affect other pools
    function test_EmergencyWithdraw_OtherPoolUnaffected() public {
        // Add a second pool
        MockERC20 stakeToken2 = new MockERC20("Stake Token 2", "STK2");
        stakeToken2.transfer(ALICE, INITIAL_BALANCE);
        staking.addPool(200, address(stakeToken2));

        vm.startPrank(ALICE);
        stakeToken2.approve(address(staking), type(uint256).max);
        staking.deposit(0, STAKE_AMOUNT);
        staking.deposit(1, STAKE_AMOUNT);

        int256 startGas = int256(gasleft());
        staking.emergencyWithdraw(0);
        int256 gasUsed = startGas - int256(gasleft());
        assertTrue(gasUsed > 0, "Gas should be used");
        assertTrue(gasUsed < 200_000, "emergencyWithdraw gas should be under 200k");

        // Pool 1 should be unaffected
        (uint256 userAmount,) = staking.userInfo(1, ALICE);
        assertEq(userAmount, STAKE_AMOUNT, "Pool 1 should be unaffected");

        (,,,, uint256 totalStaked1) = staking.poolInfo(1);
        assertEq(totalStaked1, STAKE_AMOUNT, "Pool 1 totalStaked should be intact");
        vm.stopPrank();
    }
}
