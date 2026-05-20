const { expect } = require("chai");
const { ethers } = require("hardhat");

/** Sepolia + Base chain IDs — dual-network profiles referenced in hardhat.config.js comments. */
const NETWORK_SEPOLIA = 11155111n;
const NETWORK_BASE = 8453n;

function orderValidators(signers) {
  const sorted = [...signers].sort((a, b) => (a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1));
  return sorted;
}

async function signClaim(validatorSigners, bridgeDest, claim, domainOverrides = {}) {
  const destAddr = await bridgeDest.getAddress();
  const net = await ethers.provider.getNetwork();
  const domain = {
    name: "TokenBridge",
    version: "1",
    chainId: domainOverrides.chainId ?? net.chainId,
    verifyingContract: domainOverrides.verifyingContract ?? destAddr,
  };
  const types = {
    Claim: [
      { name: "transferId", type: "bytes32" },
      { name: "token", type: "address" },
      { name: "sender", type: "address" },
      { name: "recipient", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "sourceChainId", type: "uint256" },
      { name: "sourceBridge", type: "address" },
      { name: "destChainId", type: "uint256" },
      { name: "destBridge", type: "address" },
    ],
  };
  const ordered = orderValidators(validatorSigners);
  const sigs = [];
  for (const v of ordered) {
    sigs.push(await v.signTypedData(domain, types, claim));
  }
  return sigs;
}

function computeTransferId(token, sender, recipient, amount, nonce, sourceChainId, sourceBridge) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "address", "uint256", "uint256", "uint256", "address"],
      [token, sender, recipient, amount, nonce, sourceChainId, sourceBridge],
    ),
  );
}

describe("TokenBridge (Issue #6)", function () {
  let token;
  let bridgeSrc;
  let bridgeDst;
  let owner;
  let alice;
  let v;
  let vAlt;

  const amount = ethers.parseEther("100");

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    alice = signers[1];
    v = signers[2];
    vAlt = signers[3];

    const Token = await ethers.getContractFactory("MockERC20");
    token = await Token.deploy("T", "T");
    await token.waitForDeployment();

    const Bridge = await ethers.getContractFactory("TokenBridge");
    bridgeSrc = await Bridge.deploy(2);
    await bridgeSrc.waitForDeployment();
    bridgeDst = await Bridge.deploy(2);
    await bridgeDst.waitForDeployment();

    await bridgeDst.connect(owner).addValidator(v.address);
    await bridgeDst.connect(owner).addValidator(vAlt.address);

    const tokAddr = await token.getAddress();
    await token.mint(alice.address, amount * 20n);
    await token.mint(await bridgeDst.getAddress(), amount * 20n);
    await token.connect(alice).approve(await bridgeSrc.getAddress(), amount * 20n);
  });

  it("increments per-sender nonce on repeated locks (no transferId collision)", async function () {
    const net = await ethers.provider.getNetwork();
    const tokAddr = await token.getAddress();
    const srcAddr = await bridgeSrc.getAddress();

    await bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount);
    await bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount);

    expect(await bridgeSrc.nonces(alice.address)).to.equal(2n);

    const id0 = computeTransferId(tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr);
    const id1 = computeTransferId(tokAddr, alice.address, alice.address, amount, 1n, net.chainId, srcAddr);
    expect(id0).to.not.equal(id1);
  });

  it("emit TokensLocked with nonce and canonical transferId", async function () {
    const net = await ethers.provider.getNetwork();
    const tokAddr = await token.getAddress();
    const srcAddr = await bridgeSrc.getAddress();
    const transferId = computeTransferId(tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr);

    await expect(bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount))
      .to.emit(bridgeSrc, "TokensLocked")
      .withArgs(transferId, tokAddr, alice.address, alice.address, amount, 0n);
  });

  it("claims with ordered validator EIP-712 signatures", async function () {
    const net = await ethers.provider.getNetwork();
    const tokAddr = await token.getAddress();
    const srcAddr = await bridgeSrc.getAddress();
    const dstAddr = await bridgeDst.getAddress();

    await bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount);
    const transferId = computeTransferId(tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr);

    const claim = {
      transferId,
      token: tokAddr,
      sender: alice.address,
      recipient: alice.address,
      amount,
      nonce: 0n,
      sourceChainId: net.chainId,
      sourceBridge: srcAddr,
      destChainId: net.chainId,
      destBridge: dstAddr,
    };
    const sigs = await signClaim([v, vAlt], bridgeDst, claim);

    const before = await token.balanceOf(alice.address);
    await bridgeDst.connect(alice).claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs);
    expect((await token.balanceOf(alice.address)) - before).to.equal(amount);
  });

  it("reverts on double claim (replay)", async function () {
    const net = await ethers.provider.getNetwork();
    const tokAddr = await token.getAddress();
    const srcAddr = await bridgeSrc.getAddress();
    const dstAddr = await bridgeDst.getAddress();

    await bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount);
    const transferId = computeTransferId(tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr);

    const claim = {
      transferId,
      token: tokAddr,
      sender: alice.address,
      recipient: alice.address,
      amount,
      nonce: 0n,
      sourceChainId: net.chainId,
      sourceBridge: srcAddr,
      destChainId: net.chainId,
      destBridge: dstAddr,
    };
    const sigs = await signClaim([v, vAlt], bridgeDst, claim);

    await bridgeDst.connect(alice).claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs);
    await expect(
      bridgeDst.connect(alice).claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs),
    ).to.be.revertedWith("Bridge: already processed");
  });

  it("reverts when transferId does not match canonical hash", async function () {
    const net = await ethers.provider.getNetwork();
    const tokAddr = await token.getAddress();
    const srcAddr = await bridgeSrc.getAddress();
    const dstAddr = await bridgeDst.getAddress();

    await bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount);
    const transferId = computeTransferId(tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr);

    const fakeId = ethers.keccak256(ethers.toUtf8Bytes("wrong"));
    const claim = {
      transferId,
      token: tokAddr,
      sender: alice.address,
      recipient: alice.address,
      amount,
      nonce: 0n,
      sourceChainId: net.chainId,
      sourceBridge: srcAddr,
      destChainId: net.chainId,
      destBridge: dstAddr,
    };
    const sigs = await signClaim([v, vAlt], bridgeDst, claim);

    await expect(
      bridgeDst.connect(alice).claim(fakeId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs),
    ).to.be.revertedWith("Bridge: transfer id mismatch");
  });

  it("rejects EIP-712 signatures for wrong chainId (cross-chain replay)", async function () {
    const net = await ethers.provider.getNetwork();
    const tokAddr = await token.getAddress();
    const srcAddr = await bridgeSrc.getAddress();
    const dstAddr = await bridgeDst.getAddress();

    await bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount);
    const transferId = computeTransferId(tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr);

    const claim = {
      transferId,
      token: tokAddr,
      sender: alice.address,
      recipient: alice.address,
      amount,
      nonce: 0n,
      sourceChainId: net.chainId,
      sourceBridge: srcAddr,
      destChainId: net.chainId,
      destBridge: dstAddr,
    };
    const wrongChainSigs = await signClaim([v, vAlt], bridgeDst, claim, { chainId: 99999n });

    await expect(
      bridgeDst.connect(alice).claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, wrongChainSigs),
    ).to.be.reverted;
  });

  it("rejects invalid signatures (ECDSA recover failure)", async function () {
    const net = await ethers.provider.getNetwork();
    const tokAddr = await token.getAddress();
    const srcAddr = await bridgeSrc.getAddress();
    const dstAddr = await bridgeDst.getAddress();

    await bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount);
    const transferId = computeTransferId(tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr);

    const badSig = ethers.hexlify(ethers.randomBytes(65));
    const sigs = [badSig, badSig];

    await expect(
      bridgeDst.connect(alice).claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs),
    ).to.be.reverted;
  });

  it("exposes correct EIP-712 domain separator", async function () {
    const net = await ethers.provider.getNetwork();
    const dstAddr = await bridgeDst.getAddress();
    const domain = await bridgeDst.eip712Domain();
    expect(domain.name).to.equal("TokenBridge");
    expect(domain.version).to.equal("1");
    expect(domain.chainId).to.equal(net.chainId);
    expect(domain.verifyingContract).to.equal(dstAddr);
  });

  it("rejects signatures built for wrong destBridge, then accepts corrected claim", async function () {
    const net = await ethers.provider.getNetwork();
    const tokAddr = await token.getAddress();
    const srcAddr = await bridgeSrc.getAddress();
    const dstAddr = await bridgeDst.getAddress();

    await bridgeSrc.connect(alice).lock(tokAddr, alice.address, amount);
    const transferId = computeTransferId(tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr);

    const claimWrong = {
      transferId,
      token: tokAddr,
      sender: alice.address,
      recipient: alice.address,
      amount,
      nonce: 0n,
      sourceChainId: net.chainId,
      sourceBridge: srcAddr,
      destChainId: net.chainId,
      destBridge: srcAddr,
    };
    const sigsWrong = await signClaim([v, vAlt], bridgeDst, claimWrong);

    await expect(
      bridgeDst.connect(alice).claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigsWrong),
    ).to.be.reverted;

    const claimRight = { ...claimWrong, destBridge: dstAddr };
    const sigsRight = await signClaim([v, vAlt], bridgeDst, claimRight);
    await bridgeDst.connect(alice).claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigsRight);
  });

  describe("cross-chain (dual Hardhat network — Sepolia / Base profiles)", function () {
    it("lock transferId differs across chain deployments (Bug 1)", async function () {
      const signers = await ethers.getSigners();
      const aliceLocal = signers[1];
      const Bridge = await ethers.getContractFactory("TokenBridge");
      const Token = await ethers.getContractFactory("MockERC20");

      const token = await Token.deploy("T", "T");
      await token.waitForDeployment();
      const tokAddr = await token.getAddress();

      const bridgeSepolia = await Bridge.deploy(2);
      await bridgeSepolia.waitForDeployment();
      const bridgeBase = await Bridge.deploy(2);
      await bridgeBase.waitForDeployment();

      const sepAddr = await bridgeSepolia.getAddress();
      const baseAddr = await bridgeBase.getAddress();

      const idSepolia = computeTransferId(
        tokAddr,
        aliceLocal.address,
        aliceLocal.address,
        amount,
        0n,
        NETWORK_SEPOLIA,
        sepAddr,
      );
      const idBase = computeTransferId(
        tokAddr,
        aliceLocal.address,
        aliceLocal.address,
        amount,
        0n,
        NETWORK_BASE,
        baseAddr,
      );
      expect(idSepolia).to.not.equal(idBase);

      await token.mint(aliceLocal.address, amount * 2n);
      await token.connect(aliceLocal).approve(sepAddr, amount);
      await token.connect(aliceLocal).approve(baseAddr, amount);

      const net = await ethers.provider.getNetwork();
      await bridgeSepolia.connect(aliceLocal).lock(tokAddr, aliceLocal.address, amount);
      await bridgeBase.connect(aliceLocal).lock(tokAddr, aliceLocal.address, amount);

      const idOnChainSepolia = computeTransferId(
        tokAddr,
        aliceLocal.address,
        aliceLocal.address,
        amount,
        0n,
        net.chainId,
        sepAddr,
      );
      const idOnChainBase = computeTransferId(
        tokAddr,
        aliceLocal.address,
        aliceLocal.address,
        amount,
        0n,
        net.chainId,
        baseAddr,
      );
      expect(idOnChainSepolia).to.not.equal(idOnChainBase);
    });

    it("cross-chain replay prevented across network profiles", async function () {
      const signers = await ethers.getSigners();
      const ownerLocal = signers[0];
      const aliceLocal = signers[1];
      const vLocal = signers[2];
      const vAltLocal = signers[3];
      const Bridge = await ethers.getContractFactory("TokenBridge");
      const Token = await ethers.getContractFactory("MockERC20");
      const net = await ethers.provider.getNetwork();

      const token = await Token.deploy("T", "T");
      await token.waitForDeployment();
      const tokAddr = await token.getAddress();

      const bridgeSrc = await Bridge.deploy(2);
      await bridgeSrc.waitForDeployment();
      const srcAddr = await bridgeSrc.getAddress();

      await token.mint(aliceLocal.address, amount);
      await token.connect(aliceLocal).approve(srcAddr, amount);
      await bridgeSrc.connect(aliceLocal).lock(tokAddr, aliceLocal.address, amount);

      const transferId = computeTransferId(
        tokAddr,
        aliceLocal.address,
        aliceLocal.address,
        amount,
        0n,
        net.chainId,
        srcAddr,
      );

      const bridgeDst = await Bridge.deploy(2);
      await bridgeDst.waitForDeployment();
      const dstAddr = await bridgeDst.getAddress();
      await bridgeDst.connect(ownerLocal).addValidator(vLocal.address);
      await bridgeDst.connect(ownerLocal).addValidator(vAltLocal.address);
      await token.mint(dstAddr, amount);

      const validClaim = {
        transferId,
        token: tokAddr,
        sender: aliceLocal.address,
        recipient: aliceLocal.address,
        amount,
        nonce: 0n,
        sourceChainId: net.chainId,
        sourceBridge: srcAddr,
        destChainId: net.chainId,
        destBridge: dstAddr,
      };
      const validSigs = await signClaim([vLocal, vAltLocal], bridgeDst, validClaim);
      await bridgeDst.connect(aliceLocal).claim(
        transferId,
        tokAddr,
        aliceLocal.address,
        aliceLocal.address,
        amount,
        0n,
        net.chainId,
        srcAddr,
        validSigs,
      );

      const replayClaim = {
        ...validClaim,
        destChainId: NETWORK_BASE,
      };
      const replaySigs = await signClaim([vLocal, vAltLocal], bridgeDst, replayClaim);
      await expect(
        bridgeDst.connect(aliceLocal).claim(
          transferId,
          tokAddr,
          aliceLocal.address,
          aliceLocal.address,
          amount,
          0n,
          net.chainId,
          srcAddr,
          replaySigs,
        ),
      ).to.be.reverted;
    });
  });
});
