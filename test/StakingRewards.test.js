const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("StakingRewards", function () {
  let stakingRewards;
  let stakingToken;
  let rewardToken;
  let owner;
  let staker1;
  let staker2;

  before(async function () {
    [owner, staker1, staker2] = await ethers.getSigners();

    const Tok = await ethers.getContractFactory("StakingToken");
    stakingToken = await Tok.deploy();
    await stakingToken.waitForDeployment();
    const stakingTokenAddr = await stakingToken.getAddress();

    const Rew = await ethers.getContractFactory("RewardToken");
    rewardToken = await Rew.deploy();
    await rewardToken.waitForDeployment();
    const rewardTokenAddr = await rewardToken.getAddress();

    const StakingRewards = await ethers.getContractFactory("StakingRewards");
    stakingRewards = await StakingRewards.deploy(stakingTokenAddr, rewardTokenAddr);
    await stakingRewards.waitForDeployment();
    const srAddr = await stakingRewards.getAddress();

    await stakingToken.mint(staker1.address, ethers.parseEther("1000"));
    await stakingToken.mint(staker2.address, ethers.parseEther("1000"));
    await rewardToken.mint(srAddr, ethers.parseEther("10000"));

    await stakingRewards.connect(owner).notifyRewardAmount(ethers.parseEther("1000"));
  });

  it("should allow staking tokens", async function () {
    const amount = ethers.parseEther("100");
    const srAddr = await stakingRewards.getAddress();
    await stakingToken.connect(staker1).approve(srAddr, amount);
    await stakingRewards.connect(staker1).stake(amount);

    const staked = await stakingRewards.balanceOf(staker1.address);
    expect(staked).to.equal(amount);
  });

  it("should accrue rewards over time", async function () {
    const latest = await ethers.provider.getBlock("latest");
    await ethers.provider.send("evm_setNextBlockTimestamp", [Number(latest.timestamp) + 3600]);
    await ethers.provider.send("evm_mine", []);

    const earned = await stakingRewards.earned(staker1.address);
    expect(earned).to.be.gt(0);
  });

  it("should allow withdrawal", async function () {
    const amount = ethers.parseEther("50");
    await stakingRewards.connect(staker1).withdraw(amount);

    const remaining = await stakingRewards.balanceOf(staker1.address);
    expect(remaining).to.equal(ethers.parseEther("50"));
  });

  it("should distribute rewards correctly to multiple stakers", async function () {
    const amount = ethers.parseEther("200");
    const srAddr = await stakingRewards.getAddress();
    await stakingToken.connect(staker2).approve(srAddr, amount);
    await stakingRewards.connect(staker2).stake(amount);

    const latest = await ethers.provider.getBlock("latest");
    await ethers.provider.send("evm_setNextBlockTimestamp", [Number(latest.timestamp) + 7200]);
    await ethers.provider.send("evm_mine", []);

    const earned1 = await stakingRewards.earned(staker1.address);
    const earned2 = await stakingRewards.earned(staker2.address);

    expect(earned2).to.be.gt(0);
    expect(earned1).to.be.gt(0);
  });
});
