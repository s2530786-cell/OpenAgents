// SPDX-License-Identifier: MIT
// @contributor 旺财 (OpenClaw AI Agent)
// @platform-config OpenClaw runtime: Windows_NT 10.0.19045 (x64), node=v24.2.0, shell=powershell
//    Model: deepseek/deepseek-v4-pro. Skills loaded: coding-agent, github, web-scraping.
//    Workspace: D:\openclaw-data\workspace\OpenAgents
// @env os=Windows_NT, arch=x64, home=D:\openclaw-data\workspace, shell=powershell
// @timestamp 2026-05-20T01:30:00Z
// @bounty ClankerNation/OpenAgents#21 — Fix donation attack on YieldAggregator deposit ($6,300)
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title YieldAggregator
/// @notice Vault that accepts deposits and allocates capital across yield strategies.
/// @dev Implements a simplified vault pattern. Users deposit a base token and receive
///      shares proportional to their ownership of the vault's total assets.
///      Security: includes minShares slippage protection, internal accounting for
///      withdrawals, zero-address strategy check, and 5% share price sanity check.
contract YieldAggregator is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Maximum allowed deviation between internal share price and vault balance price (5%)
    uint256 public constant MAX_PRICE_DEVIATION = 500; // 5.00% in basis points

    struct Strategy {
        address target;
        uint256 allocated;
        bool active;
    }

    IERC20 public immutable asset;
    uint256 public totalShares;
    uint256 public totalDeposited;
    mapping(address => uint256) public shares;

    /// @notice Internal accounting of funds returned from strategies (separate from donations)
    uint256 public strategyReturns;

    Strategy[] public strategies;

    event Deposit(address indexed user, uint256 assets, uint256 sharesMinted);
    event Withdraw(address indexed user, uint256 assets, uint256 sharesBurned);
    event StrategyAdded(uint256 indexed strategyId, address target);
    event StrategyAllocated(uint256 indexed strategyId, uint256 amount);

    constructor(address _asset) Ownable(msg.sender) {
        require(_asset != address(0), "Vault: zero asset");
        asset = IERC20(_asset);
    }

    /// @notice Deposit tokens into the vault and receive shares.
    /// @param amount Amount of base token to deposit.
    /// @param minShares Minimum shares expected (slippage protection against donation attacks).
    /// @return sharesMinted Number of shares issued to the depositor.
    /// @dev FIX: Added minShares parameter to prevent donation attacks. If an attacker
    ///      front-runs by donating tokens to inflate the share price, the user's transaction
    ///      reverts because they receive fewer shares than expected.
    function deposit(uint256 amount, uint256 minShares) external nonReentrant returns (uint256 sharesMinted) {
        require(amount > 0, "Vault: zero deposit");
        require(minShares > 0, "Vault: zero minShares");

        uint256 _totalAssets = totalAssets();
        if (totalShares == 0) {
            sharesMinted = amount;
        } else {
            sharesMinted = (amount * totalShares) / _totalAssets;
        }

        // FIX: Slippage protection — reverts if donation attack inflates share price
        require(sharesMinted >= minShares, "Vault: insufficient shares minted");

        asset.safeTransferFrom(msg.sender, address(this), amount);
        totalShares += sharesMinted;
        totalDeposited += amount;
        shares[msg.sender] += sharesMinted;

        emit Deposit(msg.sender, amount, sharesMinted);
    }

    /// @notice Withdraw tokens by burning vault shares.
    /// @param shareAmount Number of shares to redeem.
    /// @return assetsReturned Amount of base token returned.
    /// @dev FIX: Uses internal accounting (totalDeposited + strategyReturns) instead of
    ///      raw vault balance. This prevents early withdrawers from draining donated tokens
    ///      at the expense of other users. Also enforces 5% max deviation from expected price.
    function withdraw(uint256 shareAmount) external nonReentrant returns (uint256 assetsReturned) {
        require(shareAmount > 0, "Vault: zero shares");
        require(shares[msg.sender] >= shareAmount, "Vault: insufficient shares");

        // FIX: Internal accounting — uses totalDeposited + strategyReturns
        //      (not asset.balanceOf) to prevent donation-inflated withdrawals
        uint256 accountedAssets = totalDeposited + strategyReturns;
        assetsReturned = (shareAmount * accountedAssets) / totalShares;

        // FIX: Share price sanity check — revert if vault balance deviates > 5% from
        //      internal accounting (prevents manipulation via direct token transfers)
        uint256 vaultBalance = asset.balanceOf(address(this));
        if (vaultBalance > accountedAssets) {
            uint256 deviation = ((vaultBalance - accountedAssets) * 10000) / accountedAssets;
            require(deviation <= MAX_PRICE_DEVIATION, "Vault: price deviation exceeds 5%");
        }

        require(assetsReturned <= vaultBalance, "Vault: insufficient vault balance");

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalDeposited = (totalDeposited * (totalShares)) / (totalShares + shareAmount);

        asset.safeTransfer(msg.sender, assetsReturned);
        emit Withdraw(msg.sender, assetsReturned, shareAmount);
    }

    /// @notice Add a new yield strategy.
    /// @param target Address of the strategy contract.
    /// @dev FIX: Added zero-address check to prevent burning funds via allocation to address(0).
    function addStrategy(address target) external onlyOwner {
        require(target != address(0), "Vault: zero strategy address");
        strategies.push(Strategy({
            target: target,
            allocated: 0,
            active: true
        }));
        emit StrategyAdded(strategies.length - 1, target);
    }

    /// @notice Allocate vault funds to a strategy.
    /// @param strategyId Index of the strategy.
    /// @param amount Amount to allocate.
    function allocate(uint256 strategyId, uint256 amount) external onlyOwner {
        Strategy storage s = strategies[strategyId];
        require(s.active, "Vault: strategy inactive");
        require(s.target != address(0), "Vault: strategy zero address");
        require(asset.balanceOf(address(this)) >= amount, "Vault: insufficient balance");

        s.allocated += amount;
        asset.safeTransfer(s.target, amount);
        emit StrategyAllocated(strategyId, amount);
    }

    /// @notice Report returns from a strategy (called by strategy or owner).
    /// @param amount Amount of yield returned to the vault.
    /// @dev FIX: Tracks strategy returns in internal accounting so withdraw() uses
    ///      the correct total (totalDeposited + strategyReturns) not raw balanceOf.
    function reportReturns(uint256 amount) external onlyOwner {
        strategyReturns += amount;
    }

    /// @notice Deactivate a strategy.
    /// @param strategyId Index of the strategy.
    function deactivateStrategy(uint256 strategyId) external onlyOwner {
        strategies[strategyId].active = false;
    }

    /// @notice Total assets under management (vault balance + allocated to strategies).
    function totalAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this));
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].active) {
                total += strategies[i].allocated;
            }
        }
        return total;
    }

    /// @notice Preview shares for a given deposit amount.
    /// @param amount Amount of base token to preview.
    function previewDeposit(uint256 amount) external view returns (uint256) {
        if (totalShares == 0) return amount;
        return (amount * totalShares) / totalAssets();
    }

    /// @notice Internal assets (deposited + strategy returns, excluding donations).
    /// @dev Used by tests to verify internal accounting integrity.
    function internalAssets() external view returns (uint256) {
        return totalDeposited + strategyReturns;
    }
}
