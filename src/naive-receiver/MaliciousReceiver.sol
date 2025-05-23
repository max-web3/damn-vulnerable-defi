// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {WETH, NaiveReceiverPool} from "./NaiveReceiverPool.sol";
import "forge-std/Test.sol";

contract MaliciousReceiver is IERC3156FlashBorrower {
    address receiver;

    constructor(address payable _addr) {
        receiver = _addr;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external view
        returns (bytes32)
    {
        console.log(token, amount, fee);
        console.log("balance ", address(this).balance);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function transfer() external {
        payable(receiver).transfer(address(this).balance);
    }

    // Internal function where the funds received would be used
    function _executeActionDuringFlashLoan() internal {}
}
