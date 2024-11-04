// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {Test} from "forge-std/Test.sol";

import {AccountTestBase} from "./utils/AccountTestBase.t.sol";
import {ERC20Token} from "./utils/ERC20Token.sol";
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

import {PayNSavePlugin} from "../src/PayNSavePlugin.sol";

contract PayNSavePluginTest is Test {
    using ECDSA for bytes32;

    IEntryPoint entryPoint;
    ERC20Token testToken;
    address testTokenAddress;
    PayNSavePlugin payNSavePlugin;

    UpgradeableModularAccount account1;
    address owner1;
    uint256 owner1Key;

    // The account receiving a normal payment from the smart account
    address payable paymentRecipient;

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

        savingsAccount = payable(makeAddr("savingsAccount"));
        paymentRecipient = payable(makeAddr("paymentRecipient"));

        // create a single owner for this account and provide the address to our modular account
        // we'll also add ether to our account to pay for gas fees
        (owner1, owner1Key) = makeAddrAndKey("owner1");
        account1 = UpgradeableModularAccount(
            payable(factory.createAccount(owner1, 0))
        );
        vm.deal(address(account1), 100 ether);

        // Deploy the PayNSavePlugin and get its manifest hash
        payNSavePlugin = new PayNSavePlugin();
        bytes32 manifestHash = keccak256(
            abi.encode(payNSavePlugin.pluginManifest())
        );

        // Set up dependencies for the plugin (using single owner plugin for ownership validation)
        FunctionReference[] memory dependencies = new FunctionReference[](1);
        dependencies[0] = FunctionReferenceLib.pack(
            address(singleOwnerPlugin),
            uint8(ISingleOwnerPlugin.FunctionId.USER_OP_VALIDATION_OWNER)
        );

        // Install the plugin on the account as the owner
        vm.prank(owner1);
        account1.installPlugin({
            plugin: address(payNSavePlugin),
            manifestHash: manifestHash,
            pluginInstallData: "0x",
            dependencies: dependencies
        });

        // Deploy a mock ERC20 token for testing
        testToken = new ERC20Token("Test Token", "TST");
        testTokenAddress = address(testToken);

        // Mint some test tokens to the account for use in the test
        testToken.mint(address(account1), 1000 * 10 ** 6); // Mint 1000 tokens with 6 decimals
    }

    function test_TokenTransfer() public {
        // Create a user operation to trigger the token transfer
        UserOperation memory userOp = UserOperation({
            sender: address(account1),
            nonce: 0,
            initCode: "",
            callData: abi.encodeWithSelector(
                ERC20Token(testTokenAddress).transfer.selector,
                paymentRecipient,
                0.9 * 10 ** 6
            ),
            callGasLimit: CALL_GAS_LIMIT,
            verificationGasLimit: VERIFICATION_GAS_LIMIT,
            preVerificationGas: 0,
            maxFeePerGas: 2,
            maxPriorityFeePerGas: 1,
            paymasterAndData: "",
            signature: ""
        });

        // Sign the user operation with the owner's key
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            owner1Key,
            userOpHash.toEthSignedMessageHash()
        );
        userOp.signature = abi.encodePacked(r, s, v);

        // Execute the user operation
        UserOperation[] memory userOps = new UserOperation[](1);
        userOps[0] = userOp;
        entryPoint.handleOps(userOps, savingsAccount);

        // Assert that the token transfer happened correctly
        uint256 transferredAmount = 0.9 * 10 ** 6; // Assuming 6 decimals
        assertEq(testToken.balanceOf(paymentRecipient), transferredAmount);
        // rounding up to nearest dollar saves 10 cents
        assertEq(testToken.balanceOf(savingsAccount), 0.1 * 10 ** 6);
    }
}
