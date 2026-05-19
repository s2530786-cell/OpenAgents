// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @contributor-info
/// Agent: 旺财 (IonDex Agent — OpenClaw on DeepSeek V4 Pro)
/// Session init context: AGENTS.md + SOUL.md + IDENTITY.md + USER.md + TOOLS.md + MEMORY.md + HEARTBEAT.md
///   Runtime: node=v24.2.0 on Windows_NT 10.0.19045 (x64) | shell=powershell | cwd=D:\openclaw-data\workspace
///   Model: deepseek/deepseek-v4-pro | Channel: telegram | Provider: deepseek
///   Task: Fix cross-chain replay attack in TokenBridge signature verification
///         — ClankerNation/OpenAgents Issue #6 ($5,600 bounty)
/// ISO timestamp: 2026-05-20T03:58:00+08:00

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title TokenBridge — Security-hardened
/// @notice Cross-chain token bridge with EIP-712 multi-validator signatures.
/// @dev Fixes:
///   1. Cross-chain replay: transferId now includes block.chainid and address(this)
///   2. Same-chain replay: per-sender nonce prevents duplicate transfers
///   3. Zero-address ecrecover: signer != address(0) check added
///   4. EIP-712: typed structured data replaces plain eth_sign
contract TokenBridge is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Transfer {
        address token;
        address sender;
        address recipient;
        uint256 amount;
        bool claimed;
    }

    /// @dev EIP-712 typed data for claim signatures
    bytes32 private constant CLAIM_TYPEHASH = keccak256(
        "Claim(address token,address sender,address recipient,uint256 amount,uint256 nonce,uint256 chainId)"
    );
    bytes32 private immutable DOMAIN_SEPARATOR;

    address public admin;
    uint256 public requiredSignatures;
    mapping(address => bool) public isValidator;
    mapping(bytes32 => Transfer) public transfers;
    mapping(bytes32 => bool) public processedHashes;
    mapping(address => uint256) public nonces;          ///< per-sender nonce for replay protection

    event TokensLocked(bytes32 indexed transferId, address token, address sender, address recipient, uint256 amount);
    event TokensClaimed(bytes32 indexed transferId, address token, address recipient, uint256 amount);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Bridge: not admin");
        _;
    }

    constructor(uint256 _requiredSignatures) {
        admin = msg.sender;
        requiredSignatures = _requiredSignatures;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("TokenBridge")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Lock tokens on the source chain to initiate a cross-chain transfer.
    /// @param token ERC20 token address.
    /// @param recipient Destination address on the target chain.
    /// @param amount Amount of tokens to bridge.
    function lock(address token, address recipient, uint256 amount) external nonReentrant {
        require(amount > 0, "Bridge: zero amount");

        // FIX: Include chainId and contract address to prevent cross-chain replay.
        // FIX: Include per-sender nonce to prevent same-chain duplicate transfer collisions.
        uint256 nonce = nonces[msg.sender]++;
        bytes32 transferId = keccak256(
            abi.encodePacked(token, msg.sender, recipient, amount, nonce, block.chainid, address(this))
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        transfers[transferId] = Transfer({
            token: token,
            sender: msg.sender,
            recipient: recipient,
            amount: amount,
            claimed: false
        });

        emit TokensLocked(transferId, token, msg.sender, recipient, amount);
    }

    /// @notice Claim bridged tokens on the destination chain with EIP-712 validator signatures.
    /// @param token Token address.
    /// @param sender Original sender on source chain.
    /// @param recipient Recipient address.
    /// @param amount Amount to claim.
    /// @param senderNonce Nonce from the sender's lock transaction.
    /// @param signatures Array of validator ECDSA signatures (each 65 bytes).
    function claim(
        address token,
        address sender,
        address recipient,
        uint256 amount,
        uint256 senderNonce,
        bytes[] calldata signatures
    ) external nonReentrant {
        // FIX: EIP-712 typed structured hash replaces plain eth_sign.
        // Includes chainId + sender + nonce — cross-chain and same-chain replay impossible.
        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, token, sender, recipient, amount, senderNonce, block.chainid)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);

        require(!processedHashes[digest], "Bridge: already processed");
        require(signatures.length >= requiredSignatures, "Bridge: insufficient sigs");

        uint256 validSigs = 0;
        address lastSigner = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            // FIX: Use OpenZeppelin's ECDSA.recover which handles invalid sigs gracefully
            address signer = ECDSA.recover(digest, signatures[i]);
            // FIX: Check signer != address(0) to prevent empty-signature validator bypass
            require(signer != address(0), "Bridge: invalid signature");
            require(signer > lastSigner, "Bridge: duplicate or unordered sig");
            lastSigner = signer;
            if (isValidator[signer]) {
                validSigs++;
            }
        }

        require(validSigs >= requiredSignatures, "Bridge: not enough valid sigs");
        processedHashes[digest] = true;

        IERC20(token).safeTransfer(recipient, amount);
        emit TokensClaimed(digest, token, recipient, amount);
    }

    function addValidator(address validator) external onlyAdmin {
        isValidator[validator] = true;
        emit ValidatorAdded(validator);
    }

    function removeValidator(address validator) external onlyAdmin {
        isValidator[validator] = false;
        emit ValidatorRemoved(validator);
    }
}
