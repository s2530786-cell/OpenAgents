const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("RandomLottery", function () {
  const ticketPrice = ethers.parseEther("0.01");
  const roundDuration = 3600n;

  let lottery;
  let owner;
  let p1;
  let p2;
  let p3;

  function commitment(randomNumber, player) {
    return ethers.keccak256(
      ethers.solidityPacked(["uint256", "address"], [randomNumber, player])
    );
  }

  beforeEach(async function () {
    [owner, p1, p2, p3] = await ethers.getSigners();
    const RandomLottery = await ethers.getContractFactory("RandomLottery");
    lottery = await RandomLottery.deploy(ticketPrice);
  });

  async function startFreshRound() {
    await lottery.startRound(roundDuration);
  }

  async function enterThreeAndReveal(r1, r2, r3) {
    await lottery.connect(p1).buyTicket(commitment(r1, await p1.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p2).buyTicket(commitment(r2, await p2.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p3).buyTicket(commitment(r3, await p3.getAddress()), {
      value: ticketPrice,
    });
    await time.increase(roundDuration + 1n);
    await lottery.connect(p1).reveal(r1);
    await lottery.connect(p2).reveal(r2);
    await lottery.connect(p3).reveal(r3);
  }

  it("rejects draw with fewer than 3 participants", async function () {
    await startFreshRound();
    await lottery.connect(p1).buyTicket(commitment(11n, await p1.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p2).buyTicket(commitment(22n, await p2.getAddress()), {
      value: ticketPrice,
    });
    await time.increase(roundDuration + 1n);
    await lottery.connect(p1).reveal(11n);
    await lottery.connect(p2).reveal(22n);

    await expect(lottery.drawWinner()).to.be.revertedWith(
      "Insufficient participants"
    );
  });

  it("rejects draw until all players reveal", async function () {
    await startFreshRound();
    await lottery.connect(p1).buyTicket(commitment(1n, await p1.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p2).buyTicket(commitment(2n, await p2.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p3).buyTicket(commitment(3n, await p3.getAddress()), {
      value: ticketPrice,
    });
    await time.increase(roundDuration + 1n);
    await lottery.connect(p1).reveal(1n);
    await lottery.connect(p2).reveal(2n);

    await expect(lottery.drawWinner()).to.be.revertedWith("Not all revealed");
  });

  it("draws winner after full commit-reveal (no prevrandao)", async function () {
    await startFreshRound();
    await enterThreeAndReveal(10n, 20n, 30n);
    await expect(lottery.drawWinner()).to.emit(lottery, "WinnerSelected");
    expect(await lottery.roundEnd()).to.equal(0n);
  });

  it("enforces draw cooldown between draws", async function () {
    const shortRound = 100n;
    await lottery.startRound(shortRound);
    await lottery.connect(p1).buyTicket(commitment(10n, await p1.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p2).buyTicket(commitment(20n, await p2.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p3).buyTicket(commitment(30n, await p3.getAddress()), {
      value: ticketPrice,
    });
    await time.increase(shortRound + 1n);
    await lottery.connect(p1).reveal(10n);
    await lottery.connect(p2).reveal(20n);
    await lottery.connect(p3).reveal(30n);
    await lottery.drawWinner();

    await lottery.startRound(shortRound);
    await lottery.connect(p1).buyTicket(commitment(11n, await p1.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p2).buyTicket(commitment(21n, await p2.getAddress()), {
      value: ticketPrice,
    });
    await lottery.connect(p3).buyTicket(commitment(31n, await p3.getAddress()), {
      value: ticketPrice,
    });
    await time.increase(shortRound + 1n);
    await lottery.connect(p1).reveal(11n);
    await lottery.connect(p2).reveal(21n);
    await lottery.connect(p3).reveal(31n);

    await expect(lottery.drawWinner()).to.be.revertedWith("Draw cooldown active");
    await time.increase(10 * 60 + 1);
    await expect(lottery.drawWinner()).to.not.be.reverted;
  });

  it("handles ETH-rejecting winner via pending pull payout", async function () {
    const signers = await ethers.getSigners();
    const treasury = signers[4];

    const Rejecting = await ethers.getContractFactory("RejectingWinner");
    const rejector = await Rejecting.deploy();
    await rejector.init(await lottery.getAddress());
    const rejectorAddr = await rejector.getAddress();

    let pending = 0n;
    let roundId = 0n;
    for (let i = 0; i < 32 && pending === 0n; i++) {
      if (i > 0) {
        await time.increase(10 * 60 + 1);
      }
      await startFreshRound();
      const r1 = BigInt(i + 1);
      const r2 = BigInt(i + 101);
      const r3 = BigInt(i + 201);

      await lottery.connect(p1).buyTicket(commitment(r1, await p1.getAddress()), {
        value: ticketPrice,
      });
      await rejector.enter(commitment(r2, rejectorAddr), { value: ticketPrice });
      await lottery.connect(p3).buyTicket(commitment(r3, await p3.getAddress()), {
        value: ticketPrice,
      });

      await time.increase(roundDuration + 1n);
      await lottery.connect(p1).reveal(r1);
      await rejector.reveal(r2);
      await lottery.connect(p3).reveal(r3);

      roundId = await lottery.currentRound();
      await expect(lottery.drawWinner()).to.not.be.reverted;
      pending = await lottery.pendingPrizes(roundId);
    }

    expect(pending).to.equal(ethers.parseEther("0.03"));

    const before = await ethers.provider.getBalance((await treasury.getAddress()));
    await rejector.claim(roundId, (await treasury.getAddress()));
    const after = await ethers.provider.getBalance((await treasury.getAddress()));
    expect(after - before).to.equal(pending);
    expect(await lottery.pendingPrizes(roundId)).to.equal(0n);
  });

  it("clears commitments when a new round starts", async function () {
    await startFreshRound();
    await enterThreeAndReveal(1n, 2n, 3n);
    await lottery.drawWinner();
    await lottery.startRound(roundDuration);

    await expect(
      lottery.connect(p1).buyTicket(commitment(9n, await p1.getAddress()), {
        value: ticketPrice,
      })
    ).to.not.be.reverted;
  });
});
