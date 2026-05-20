const { expect } = require("chai");
const { ethers } = require("hardhat");

function orderValidators(signers) {
  const sorted = [...signers].sort((a, b) => (a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1));
  return sorted;
}

async function signClaim(validatorSigners, bridgeDest, claim) {
  const destAddr = await bridgeDest.getAddress();
  const net = await ethers.provider.getNetwork();
  const domain = {
    name: "TokenBridge",
    version: "1",
    chainId: net.chainId,
    verifyingContract: destAddr,
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
    await bridgeDst.claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs);
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

    await bridgeDst.claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs);
    await expect(
      bridgeDst.claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs),
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
      bridgeDst.claim(fakeId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigs),
    ).to.be.revertedWith("Bridge: transfer id mismatch");
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
      bridgeDst.claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigsWrong),
    ).to.be.reverted;

    const claimRight = { ...claimWrong, destBridge: dstAddr };
    const sigsRight = await signClaim([v, vAlt], bridgeDst, claimRight);
    await bridgeDst.claim(transferId, tokAddr, alice.address, alice.address, amount, 0n, net.chainId, srcAddr, sigsRight);
  });
});
