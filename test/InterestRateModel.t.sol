// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/lending/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel public model;

    address public admin = address(0x1);
    address public nonAdmin = address(0x2);

    uint256 public constant INIT_BASE_RATE = 0.01e18;      // 1%
    uint256 public constant INIT_MULTIPLIER = 0.1e18;      // 10%
    uint256 public constant INIT_JUMP_MULTIPLIER = 1e18;   // 100%
    uint256 public constant INIT_KINK = 0.8e18;            // 80%

    event RateParametersUpdated(
        uint256 oldBaseRate, uint256 newBaseRate,
        uint256 oldMultiplier, uint256 newMultiplier,
        uint256 oldJumpMultiplier, uint256 newJumpMultiplier
    );

    function setUp() public {
        vm.startPrank(admin);
        model = new InterestRateModel(
            INIT_BASE_RATE,
            INIT_MULTIPLIER,
            INIT_JUMP_MULTIPLIER,
            INIT_KINK
        );
        vm.stopPrank();
    }

    // ==================== Deployment ====================

    function test_InitialParameters() public view {
        assertEq(model.baseRate(), INIT_BASE_RATE);
        assertEq(model.multiplier(), INIT_MULTIPLIER);
        assertEq(model.jumpMultiplier(), INIT_JUMP_MULTIPLIER);
        assertEq(model.kink(), INIT_KINK);
        assertEq(model.admin(), admin);
    }

    function test_InitialGetParameters() public view {
        InterestRateModel.RateParameters memory params = model.getParameters();
        assertEq(params.baseRate, INIT_BASE_RATE);
        assertEq(params.multiplier, INIT_MULTIPLIER);
        assertEq(params.jumpMultiplier, INIT_JUMP_MULTIPLIER);
        assertEq(params.kink, INIT_KINK);
    }

    // ==================== Access Control ====================

    function test_RevertNonAdminUpdateParams() public {
        vm.prank(nonAdmin);
        vm.expectRevert("Not admin");
        model.updateParams(0.02e18, 0.2e18, 2e18, 0.9e18);
    }

    function test_RevertNonAdminUpdateBaseRate() public {
        vm.prank(nonAdmin);
        vm.expectRevert("Not admin");
        model.updateBaseRate(0.02e18);
    }

    function test_RevertNonAdminUpdateMultiplier() public {
        vm.prank(nonAdmin);
        vm.expectRevert("Not admin");
        model.updateMultiplier(0.2e18);
    }

    function test_RevertNonAdminUpdateJumpMultiplier() public {
        vm.prank(nonAdmin);
        vm.expectRevert("Not admin");
        model.updateJumpMultiplier(2e18);
    }

    function test_RevertNonAdminUpdateKink() public {
        vm.prank(nonAdmin);
        vm.expectRevert("Not admin");
        model.updateKink(0.9e18);
    }

    // ==================== updateParams - Event ====================

    function test_UpdateParamsEmitsRateParametersUpdated() public {
        uint256 newBase = 0.02e18;
        uint256 newMulti = 0.2e18;
        uint256 newJump = 2e18;
        uint256 newKink = 0.9e18;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RateParametersUpdated(INIT_BASE_RATE, newBase, INIT_MULTIPLIER, newMulti, INIT_JUMP_MULTIPLIER, newJump);
        model.updateParams(newBase, newMulti, newJump, newKink);
    }

    function test_UpdateParamsUpdatesState() public {
        uint256 newBase = 0.02e18;
        uint256 newMulti = 0.2e18;
        uint256 newJump = 2e18;
        uint256 newKink = 0.9e18;

        vm.prank(admin);
        model.updateParams(newBase, newMulti, newJump, newKink);

        assertEq(model.baseRate(), newBase);
        assertEq(model.multiplier(), newMulti);
        assertEq(model.jumpMultiplier(), newJump);
        assertEq(model.kink(), newKink);
    }

    function test_UpdateParamsGetParameters() public {
        uint256 newBase = 0.02e18;
        uint256 newMulti = 0.2e18;
        uint256 newJump = 2e18;
        uint256 newKink = 0.9e18;

        vm.prank(admin);
        model.updateParams(newBase, newMulti, newJump, newKink);

        InterestRateModel.RateParameters memory params = model.getParameters();
        assertEq(params.baseRate, newBase);
        assertEq(params.multiplier, newMulti);
        assertEq(params.jumpMultiplier, newJump);
        assertEq(params.kink, newKink);
    }

    // ==================== Individual Setters ====================

    function test_UpdateBaseRateEmitsEvent() public {
        uint256 newValue = 0.02e18;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RateParametersUpdated(INIT_BASE_RATE, newValue, INIT_MULTIPLIER, INIT_MULTIPLIER, INIT_JUMP_MULTIPLIER, INIT_JUMP_MULTIPLIER);
        model.updateBaseRate(newValue);
    }

    function test_UpdateBaseRateState() public {
        uint256 newValue = 0.02e18;

        vm.prank(admin);
        model.updateBaseRate(newValue);

        assertEq(model.baseRate(), newValue);
        assertEq(model.multiplier(), INIT_MULTIPLIER);
        assertEq(model.jumpMultiplier(), INIT_JUMP_MULTIPLIER);
        assertEq(model.kink(), INIT_KINK);

        InterestRateModel.RateParameters memory params = model.getParameters();
        assertEq(params.baseRate, newValue);
        assertEq(params.multiplier, INIT_MULTIPLIER);
        assertEq(params.jumpMultiplier, INIT_JUMP_MULTIPLIER);
        assertEq(params.kink, INIT_KINK);
    }

    function test_UpdateMultiplierEmitsEvent() public {
        uint256 newValue = 0.2e18;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RateParametersUpdated(INIT_BASE_RATE, INIT_BASE_RATE, INIT_MULTIPLIER, newValue, INIT_JUMP_MULTIPLIER, INIT_JUMP_MULTIPLIER);
        model.updateMultiplier(newValue);
    }

    function test_UpdateMultiplierState() public {
        uint256 newValue = 0.2e18;

        vm.prank(admin);
        model.updateMultiplier(newValue);

        assertEq(model.baseRate(), INIT_BASE_RATE);
        assertEq(model.multiplier(), newValue);
        assertEq(model.jumpMultiplier(), INIT_JUMP_MULTIPLIER);
        assertEq(model.kink(), INIT_KINK);

        InterestRateModel.RateParameters memory params = model.getParameters();
        assertEq(params.baseRate, INIT_BASE_RATE);
        assertEq(params.multiplier, newValue);
        assertEq(params.jumpMultiplier, INIT_JUMP_MULTIPLIER);
        assertEq(params.kink, INIT_KINK);
    }

    function test_UpdateJumpMultiplierEmitsEvent() public {
        uint256 newValue = 2e18;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RateParametersUpdated(INIT_BASE_RATE, INIT_BASE_RATE, INIT_MULTIPLIER, INIT_MULTIPLIER, INIT_JUMP_MULTIPLIER, newValue);
        model.updateJumpMultiplier(newValue);
    }

    function test_UpdateJumpMultiplierState() public {
        uint256 newValue = 2e18;

        vm.prank(admin);
        model.updateJumpMultiplier(newValue);

        assertEq(model.baseRate(), INIT_BASE_RATE);
        assertEq(model.multiplier(), INIT_MULTIPLIER);
        assertEq(model.jumpMultiplier(), newValue);
        assertEq(model.kink(), INIT_KINK);

        InterestRateModel.RateParameters memory params = model.getParameters();
        assertEq(params.baseRate, INIT_BASE_RATE);
        assertEq(params.multiplier, INIT_MULTIPLIER);
        assertEq(params.jumpMultiplier, newValue);
        assertEq(params.kink, INIT_KINK);
    }

    function test_UpdateKinkState() public {
        uint256 newValue = 0.9e18;

        vm.prank(admin);
        model.updateKink(newValue);

        assertEq(model.baseRate(), INIT_BASE_RATE);
        assertEq(model.multiplier(), INIT_MULTIPLIER);
        assertEq(model.jumpMultiplier(), INIT_JUMP_MULTIPLIER);
        assertEq(model.kink(), newValue);

        InterestRateModel.RateParameters memory params = model.getParameters();
        assertEq(params.baseRate, INIT_BASE_RATE);
        assertEq(params.multiplier, INIT_MULTIPLIER);
        assertEq(params.jumpMultiplier, INIT_JUMP_MULTIPLIER);
        assertEq(params.kink, newValue);
    }
}
