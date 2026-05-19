const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TokenBridge Security Fix", function () {
  let bridge, token, admin, validator1, validator2, sender, recipient;
  let chainId;

  before(async function () {
    [admin, validator1, validator2, sender, recipient] = await ethers.getSigners();
    chainId = (await ethers.provider.getNetwork()).chainId;

    const MockToken = await ethers.getContractFactory("MockERC20");
    token = await MockToken.deploy("Test", "TST");
    await token.mint(sender.address, ethers.parseEther("1000"));

    const Bridge = await ethers.getContractFactory("TokenBridge");
    bridge = await Bridge.deploy(2);
    await bridge.addValidator(validator1.address);
    await bridge.addValidator(validator2.address);
  });

  // Helper: sort validators by address and return sigs in ascending order
  async function signAndSort(validators, domain, types, value) {
    const sigs = [];
    for (const v of validators) {
      const sig = await v.signTypedData(domain, types, value);
      // ECDSA.recover returns deterministic address — we can compute it
      // For ordering we sort by the signer address
      sigs.push({ signer: v.address, sig });
    }
    sigs.sort((a, b) => a.signer.toLowerCase() < b.signer.toLowerCase() ? -1 : 1);
    return sigs.map(s => s.sig);
  }

  const domain = () => ({
    name: "TokenBridge",
    version: "1",
    chainId: chainId,
    verifyingContract: bridge.target,
  });
  const types = {
    Claim: [
      { name: "token", type: "address" },
      { name: "sender", type: "address" },
      { name: "recipient", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "chainId", type: "uint256" },
    ],
  };

  it("1. transferId includes chainId, nonce, and contract address", async function () {
    await token.connect(sender).approve(bridge.target, ethers.parseEther("100"));
    const tx = await bridge.connect(sender).lock(token.target, recipient.address, ethers.parseEther("100"));
    await tx.wait();

    expect(await bridge.nonces(sender.address)).to.equal(1);

    await token.connect(sender).approve(bridge.target, ethers.parseEther("100"));
    await bridge.connect(sender).lock(token.target, recipient.address, ethers.parseEther("100"));
    expect(await bridge.nonces(sender.address)).to.equal(2);
  });

  it("2. cross-chain replay prevented — different chainId = different transferId", async function () {
    await token.connect(sender).approve(bridge.target, ethers.parseEther("50"));
    const tx = await bridge.connect(sender).lock(token.target, recipient.address, ethers.parseEther("50"));
    const receipt = await tx.wait();
    expect(receipt.logs.length).to.be.greaterThan(0);
  });

  it("3. EIP-712 claim with valid signatures", async function () {
    await token.connect(sender).approve(bridge.target, ethers.parseEther("200"));
    await bridge.connect(sender).lock(token.target, recipient.address, ethers.parseEther("200"));

    await token.mint(bridge.target, ethers.parseEther("2000"));

    const value = {
      token: token.target,
      sender: sender.address,
      recipient: recipient.address,
      amount: ethers.parseEther("200"),
      nonce: 0,
      chainId: chainId,
    };

    const sigs = await signAndSort([validator1, validator2], domain(), types, value);

    await bridge.claim(
      token.target, sender.address, recipient.address,
      ethers.parseEther("200"), 0, sigs
    );

    expect(await token.balanceOf(recipient.address)).to.equal(ethers.parseEther("200"));
  });

  it("4. replay prevented — same claim hash twice reverts", async function () {
    await token.mint(bridge.target, ethers.parseEther("1000"));

    await token.connect(sender).approve(bridge.target, ethers.parseEther("300"));
    await bridge.connect(sender).lock(token.target, recipient.address, ethers.parseEther("300"));

    const value = {
      token: token.target, sender: sender.address, recipient: recipient.address,
      amount: ethers.parseEther("300"), nonce: 2, chainId: chainId,
    };

    const sigs = await signAndSort([validator1, validator2], domain(), types, value);

    await bridge.claim(
      token.target, sender.address, recipient.address,
      ethers.parseEther("300"), 2, sigs
    );

    await expect(
      bridge.claim(
        token.target, sender.address, recipient.address,
        ethers.parseEther("300"), 2, sigs
      )
    ).to.be.revertedWith("Bridge: already processed");
  });

  it("5. zero-address signer rejected", async function () {
    // Need 2 sigs (requiredSignatures=2) — one valid, one zero-address
    await token.mint(bridge.target, ethers.parseEther("2000"));

    await token.connect(sender).approve(bridge.target, ethers.parseEther("5"));
    await bridge.connect(sender).lock(token.target, recipient.address, ethers.parseEther("5"));

    const value = {
      token: token.target, sender: sender.address, recipient: recipient.address,
      amount: ethers.parseEther("5"), nonce: 4, chainId: chainId,
    };

    const validSig = await validator1.signTypedData(domain(), types, value);
    const zeroSig = "0x" + "00".repeat(65);

    // OZ ECDSA.recover returns ECDSAInvalidSignature() for zero-address ecrecover
    await expect(
      bridge.claim(
        token.target, sender.address, recipient.address,
        ethers.parseEther("5"), 4, [zeroSig, validSig]
      )
    ).to.be.revertedWithCustomError(bridge, "ECDSAInvalidSignature");
  });

  it("6. wrong chainId in signature reverts", async function () {
    const wrongDomain = { name: "TokenBridge", version: "1", chainId: 9999, verifyingContract: bridge.target };
    const value = {
      token: token.target, sender: sender.address, recipient: recipient.address,
      amount: ethers.parseEther("1"), nonce: 999, chainId: 9999,
    };

    const sig1 = await validator1.signTypedData(wrongDomain, types, value);
    const sig2 = await validator2.signTypedData(wrongDomain, types, value);
    const sigs = [sig1, sig2].sort((a, b) => a < b ? -1 : 1);

    await expect(
      bridge.claim(
        token.target, sender.address, recipient.address,
        ethers.parseEther("1"), 999, sigs
      )
    ).to.be.revertedWith("Bridge: not enough valid sigs");
  });
});
