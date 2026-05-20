// SPDX-License-Identifier: MIT
// @contributor Cursor Agent (user session)
// @platform-config Cursor IDE on Windows; task: fix ClankerNation/OpenAgents#16 RandomLottery prevrandao manipulation per issue acceptance criteria and CONTRIBUTING.md (Solidity style, NatSpec, tests).
// @env os=Windows_NT, arch=x64, home_dir=C:\Users\admin, working_dir=C:\Users\admin\.cursor\projects\empty-window\OpenAgents, shell=powershell
// @timestamp 2026-05-20T12:00:00Z
pragma solidity ^0.8.20;

/// @title RandomLottery
/// @notice On-chain lottery using commit-reveal randomness (not block.prevrandao)
/// @dev Players commit during ticket purchase, reveal after the round ends, then owner draws.
contract RandomLottery {
    address public owner;
    uint256 public ticketPrice;
    uint256 public roundEnd;
    uint256 public currentRound;
    uint256 public lastDrawTime;

    uint256 public constant MIN_PARTICIPANTS = 3;
    uint256 public constant DRAW_COOLDOWN = 10 minutes;

    address[] public players;
    mapping(uint256 => address) public roundWinners;

    mapping(address => bytes32) public commitments;
    mapping(address => bool) public hasRevealed;
    mapping(address => uint256) public revealedNumbers;
    mapping(uint256 => uint256) public pendingPrizes;

    uint256 public revealCount;
    uint256 public accumulatedEntropy;

    event TicketPurchased(address indexed player, uint256 round, bytes32 commitment);
    event Revealed(address indexed player, uint256 round, uint256 randomNumber);
    event RoundStarted(uint256 indexed round, uint256 endTime);
    event WinnerSelected(address indexed winner, uint256 prize, uint256 round);
    event PrizePending(address indexed winner, uint256 round, uint256 amount);
    event PrizeWithdrawn(address indexed winner, uint256 round, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint256 _ticketPrice) {
        owner = msg.sender;
        ticketPrice = _ticketPrice;
    }

    /// @notice Start a new lottery round.
    function startRound(uint256 duration) external onlyOwner {
        require(roundEnd == 0 || block.timestamp > roundEnd, "Round active");
        _clearRoundState();
        currentRound++;
        roundEnd = block.timestamp + duration;
        emit RoundStarted(currentRound, roundEnd);
    }

    /// @notice Buy a ticket with a commitment hash for commit-reveal randomness.
    /// @param commitment keccak256(abi.encodePacked(randomNumber, msg.sender))
    function buyTicket(bytes32 commitment) external payable {
        require(roundEnd != 0, "Round inactive");
        require(block.timestamp < roundEnd, "Round ended");
        require(msg.value == ticketPrice, "Wrong ticket price");
        require(commitment != bytes32(0), "Zero commitment");
        require(commitments[msg.sender] == bytes32(0), "Already entered");

        players.push(msg.sender);
        commitments[msg.sender] = commitment;
        emit TicketPurchased(msg.sender, currentRound, commitment);
    }

    /// @notice Reveal the committed random number after the round ends.
    function reveal(uint256 randomNumber) external {
        require(roundEnd != 0, "Round inactive");
        require(block.timestamp >= roundEnd, "Round not ended");

        bytes32 commitment = commitments[msg.sender];
        require(commitment != bytes32(0), "No commitment");
        require(!hasRevealed[msg.sender], "Already revealed");
        require(
            keccak256(abi.encodePacked(randomNumber, msg.sender)) == commitment,
            "Invalid reveal"
        );

        hasRevealed[msg.sender] = true;
        revealedNumbers[msg.sender] = randomNumber;
        accumulatedEntropy ^= randomNumber;
        revealCount++;

        emit Revealed(msg.sender, currentRound, randomNumber);
    }

    /// @notice Draw a winner after all participants have revealed.
    function drawWinner() external onlyOwner {
        require(roundEnd != 0, "Round inactive");
        require(block.timestamp >= roundEnd, "Round not ended");
        require(
            block.timestamp >= lastDrawTime + DRAW_COOLDOWN,
            "Draw cooldown active"
        );
        require(players.length >= MIN_PARTICIPANTS, "Insufficient participants");
        require(revealCount == players.length, "Not all revealed");

        uint256 entropy = uint256(
            keccak256(
                abi.encodePacked(
                    accumulatedEntropy,
                    currentRound,
                    blockhash(block.number - 1)
                )
            )
        );
        address winner = players[entropy % players.length];
        uint256 prize = address(this).balance;
        uint256 roundId = currentRound;

        roundWinners[roundId] = winner;
        lastDrawTime = block.timestamp;
        roundEnd = 0;

        (bool sent, ) = winner.call{value: prize}("");
        if (sent) {
            emit WinnerSelected(winner, prize, roundId);
        } else {
            pendingPrizes[roundId] = prize;
            emit PrizePending(winner, roundId, prize);
        }
    }

    /// @notice Pull-pattern fallback when the winner cannot receive ETH via call.
    /// @param recipient Payee address (e.g. winner EOA treasury if winner is a rejecting contract).
    function withdrawPrize(uint256 roundId, address payable recipient) external {
        require(msg.sender == roundWinners[roundId], "Not winner");
        require(recipient != address(0), "Zero recipient");
        uint256 prize = pendingPrizes[roundId];
        require(prize > 0, "No pending prize");

        pendingPrizes[roundId] = 0;
        (bool sent, ) = recipient.call{value: prize}("");
        require(sent, "Withdraw failed");
        emit PrizeWithdrawn(msg.sender, roundId, prize);
    }

    function getPlayers() external view returns (address[] memory) {
        return players;
    }

    function getPoolSize() external view returns (uint256) {
        return address(this).balance;
    }

    function _clearRoundState() private {
        uint256 len = players.length;
        for (uint256 i = 0; i < len; i++) {
            address player = players[i];
            delete commitments[player];
            delete hasRevealed[player];
            delete revealedNumbers[player];
        }
        delete players;
        revealCount = 0;
        accumulatedEntropy = 0;
    }
}
