// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RandomLottery} from "./RandomLottery.sol";

contract RejectingWinner {
    RandomLottery public lottery;

    function init(address _lottery) external {
        lottery = RandomLottery(_lottery);
    }

    function enter(bytes32 commitment) external payable {
        lottery.buyTicket{value: msg.value}(commitment);
    }

    function reveal(uint256 randomNumber) external {
        lottery.reveal(randomNumber);
    }

    function claim(uint256 roundId, address payable recipient) external {
        lottery.withdrawPrize(roundId, recipient);
    }
}