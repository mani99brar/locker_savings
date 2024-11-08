// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {UpgradeableModularAccount} from "erc6900/reference-implementation/src/account/UpgradeableModularAccount.sol";
import {FunctionReference} from "erc6900/reference-implementation/src/interfaces/IPluginManager.sol";
import {FunctionReferenceLib} from "erc6900/reference-implementation/src/helpers/FunctionReferenceLib.sol";
import {SingleOwnerPlugin} from "erc6900/reference-implementation/src/plugins/owner/SingleOwnerPlugin.sol";
import {ISingleOwnerPlugin} from "erc6900/reference-implementation/src/plugins/owner/ISingleOwnerPlugin.sol";
import {MSCAFactoryFixture} from "erc6900/reference-implementation/test/mocks/MSCAFactoryFixture.sol";

import {IEntryPoint} from "@eth-infinitism/account-abstraction/interfaces/IEntryPoint.sol";
import {EntryPoint} from "@eth-infinitism/account-abstraction/core/EntryPoint.sol";
import {UserOperation} from "@eth-infinitism/account-abstraction/interfaces/UserOperation.sol";
import {ERC20Token} from "./utils/ERC20Token.sol";

import {SavingsPlugin} from "../src/SavingsPlugin.sol";

contract SavingsPluginTest is Test {
    using ECDSA for bytes32;

    IEntryPoint entryPoint;
    UpgradeableModularAccount account1;
    address account1Address;
    SavingsPlugin savingsPlugin;
    address owner1;
    uint256 owner1Key;
    address[] public owners;
    address payable beneficiary;

    // ERC20 token that is being used for payment
    ERC20Token testToken;
    address testTokenAddress;

    // The account receiving the saved funds
    address payable savingsAccount;

    uint256 constant CALL_GAS_LIMIT = 70000;
    uint256 constant VERIFICATION_GAS_LIMIT = 1000000;

    function setUp() public {
        // we'll be using the entry point so we can send a user operation through
        // in this case our plugin only accepts calls to subscribe via user operations so this is essential
        entryPoint = IEntryPoint(address(new EntryPoint()));

        // our modular smart contract account will be installed with the single owner plugin
        // so we have a way to determine who is authorized to do things on this account
        // we'll use this plugin's validation for our subscribe function
        SingleOwnerPlugin singleOwnerPlugin = new SingleOwnerPlugin();
        MSCAFactoryFixture factory = new MSCAFactoryFixture(
            entryPoint,
            singleOwnerPlugin
        );

        // the beneficiary of the fees at the entry point
        beneficiary = payable(makeAddr("beneficiary"));
        savingsAccount = payable(makeAddr("savingsAccount"));

        // create a single owner for this account and provide the address to our modular account
        // we'll also add ether to our account to pay for gas fees
        (owner1, owner1Key) = makeAddrAndKey("owner1");
        account1 = UpgradeableModularAccount(
            payable(factory.createAccount(owner1, 0))
        );
        account1Address = address(account1);
        vm.deal(account1Address, 100 ether);

        // create our counter plugin and grab the manifest hash so we can install it
        // note: plugins are singleton contracts, so we only need to deploy them once
        savingsPlugin = new SavingsPlugin();
        bytes32 manifestHash = keccak256(
            abi.encode(savingsPlugin.pluginManifest())
        );

        // we will have a single function dependency for our counter contract: the single owner user op validation
        // we'll use this to ensure that only an owner can sign a user operation that can successfully subscribe
        FunctionReference[] memory dependencies = new FunctionReference[](1);
        dependencies[0] = FunctionReferenceLib.pack(
            address(singleOwnerPlugin),
            uint8(ISingleOwnerPlugin.FunctionId.USER_OP_VALIDATION_OWNER)
        );

        // install this plugin on the account as the owner
        vm.prank(owner1);
        account1.installPlugin({
            plugin: address(savingsPlugin),
            manifestHash: manifestHash,
            pluginInstallData: "0x",
            dependencies: dependencies
        });

        // Deploy a mock ERC20 token for testing
        testToken = new ERC20Token("Test Token", "TST");
        testTokenAddress = address(testToken);

        // Mint some test tokens to the account for use in the test
        uint256 mintAmount = 1000 * 10 ** 6; // Mint 1000 tokens with 6 decimals
        testToken.mint(account1Address, mintAmount);
        assertEq(
            testToken.balanceOf(account1Address),
            mintAmount,
            "Account1 should have been minted tokens"
        );
    }

    function test_Subscribe() public {
        address service = makeAddr("service");
        // create a user operation which has the calldata to specify we'd like to subscribe
        UserOperation memory userOp = UserOperation({
            sender: account1Address,
            nonce: 0,
            initCode: "",
            callData: abi.encodeCall(SavingsPlugin.subscribe, (service, 10)),
            callGasLimit: CALL_GAS_LIMIT,
            verificationGasLimit: VERIFICATION_GAS_LIMIT,
            preVerificationGas: 0,
            maxFeePerGas: 2,
            maxPriorityFeePerGas: 1,
            paymasterAndData: "",
            signature: ""
        });

        // sign this user operation with the owner, otherwise it will revert due to the singleowner validation
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            owner1Key,
            userOpHash.toEthSignedMessageHash()
        );
        userOp.signature = abi.encodePacked(r, s, v);

        // send our single user operation to subscribe
        UserOperation[] memory userOps = new UserOperation[](1);
        userOps[0] = userOp;
        entryPoint.handleOps(userOps, beneficiary);

        // check that we successfully subscribed!
        (uint256 amount, , bool enabled) = savingsPlugin.subscriptions(
            service,
            account1Address
        );
        assertEq(amount, 10);
        assertEq(enabled, true);
    }

    function test_Collect() public {
        address service = makeAddr("service");
        // create a user operation which has the calldata to specify we'd like to subscribe
        UserOperation memory userOp = UserOperation({
            sender: account1Address,
            nonce: 0,
            initCode: "",
            callData: abi.encodeCall(SavingsPlugin.subscribe, (service, 10)),
            callGasLimit: CALL_GAS_LIMIT,
            verificationGasLimit: VERIFICATION_GAS_LIMIT,
            preVerificationGas: 0,
            maxFeePerGas: 2,
            maxPriorityFeePerGas: 1,
            paymasterAndData: "",
            signature: ""
        });

        // sign this user operation with the owner, otherwise it will revert due to the singleowner validation
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            owner1Key,
            userOpHash.toEthSignedMessageHash()
        );
        userOp.signature = abi.encodePacked(r, s, v);

        // send our single user operation to subscribe
        UserOperation[] memory userOps = new UserOperation[](1);
        userOps[0] = userOp;
        entryPoint.handleOps(userOps, beneficiary);

        // we need to call from the service address
        vm.prank(service);
        skip(4 weeks);
        savingsPlugin.collect(account1Address, 10);
        assertEq(service.balance, 10);
    }
}
