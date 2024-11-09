// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {UpgradeableModularAccount} from "erc6900/reference-implementation/src/account/UpgradeableModularAccount.sol";
import {FunctionReference} from "erc6900/reference-implementation/src/interfaces/IPluginManager.sol";
import {IStandardExecutor} from "erc6900/reference-implementation/src/interfaces/IStandardExecutor.sol";
import {FunctionReferenceLib} from "erc6900/reference-implementation/src/helpers/FunctionReferenceLib.sol";
import {SingleOwnerPlugin} from "erc6900/reference-implementation/src/plugins/owner/SingleOwnerPlugin.sol";
import {ISingleOwnerPlugin} from "erc6900/reference-implementation/src/plugins/owner/ISingleOwnerPlugin.sol";
import {MSCAFactoryFixture} from "erc6900/reference-implementation/test/mocks/MSCAFactoryFixture.sol";
import {IEntryPoint} from "@eth-infinitism/account-abstraction/interfaces/IEntryPoint.sol";
import {EntryPoint} from "@eth-infinitism/account-abstraction/core/EntryPoint.sol";
import {UserOperation} from "@eth-infinitism/account-abstraction/interfaces/UserOperation.sol";
import {ERC20Token} from "./utils/ERC20Token.sol";
import {console} from "forge-std/console.sol";
import {SavingsPlugin} from "../src/SavingsPlugin.sol";

interface IERC20 {
    function transfer(address, uint256) external;
}

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

    // The account receiving a normal payment from the smart account
    address payable paymentRecipient;

    uint256 constant CALL_GAS_LIMIT = 900_000; // Adjusted gas limit
    uint256 constant VERIFICATION_GAS_LIMIT = 9_000_000;

    uint256 mintAmount;

    function setUp() public {
        // we'll be using the entry point so we can send a user operation through
        // in this case our plugin only accepts calls to subscribe via user operations so this is essential
        entryPoint = IEntryPoint(address(new EntryPoint()));
        console.log("Entry point address: %s", address(entryPoint));

        // our modular smart contract account will be installed with the single owner plugin
        // so we have a way to determine who is authorized to do things on this account
        // we'll use this plugin's validation for our subscribe function
        SingleOwnerPlugin singleOwnerPlugin = new SingleOwnerPlugin();
        MSCAFactoryFixture factory = new MSCAFactoryFixture(
            entryPoint,
            singleOwnerPlugin
        );

        beneficiary = payable(makeAddr("beneficiary")); // normally the bundler
        savingsAccount = payable(makeAddr("savingsAccount")); // where the funds are saved
        paymentRecipient = payable(makeAddr("paymentRecipient")); // arbitrary 3rd party being sent ERC20 from smart account

        // create a single owner for this account and provide the address to our modular account
        // we'll also add ether to our account to pay for gas fees
        (owner1, owner1Key) = makeAddrAndKey("owner1");
        account1 = UpgradeableModularAccount(
            payable(factory.createAccount(owner1, 0))
        );
        account1Address = address(account1);
        vm.deal(account1Address, 1000000 ether);

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
        console.log("Test token address: %s", testTokenAddress);

        // Mint some test tokens to the account for use in the test
        mintAmount = 1000 * 10 ** 6; // Mint 1000 tokens with 6 decimals
        testToken.mint(account1Address, mintAmount);
        assertEq(
            testToken.balanceOf(account1Address),
            mintAmount,
            "Account1 should have been minted tokens"
        );
    }

    /// @notice Test the createAutomation function
    /// @dev Test sending $0.90 to a 3rd party and saving $0.10 automatically
    function test_Transfer() public {
        // register automation to the nearest dollar
        uint256 automationIndex = 0;
        uint256 roundUpTo = 1 * 10 ** 6; // 1 USD with 6 decimals for USD stablecoins

        // Step 1: Create a user operation to set up automation
        UserOperation memory createAutomationUserOp = UserOperation({
            sender: account1Address,
            nonce: 0,
            initCode: "",
            callData: abi.encodeWithSelector(
                savingsPlugin.createAutomation.selector,
                automationIndex,
                savingsAccount,
                roundUpTo
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
        bytes32 createAutomationUserOpHash = entryPoint.getUserOpHash(
            createAutomationUserOp
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(
            owner1Key,
            createAutomationUserOpHash.toEthSignedMessageHash()
        );
        createAutomationUserOp.signature = abi.encodePacked(r1, s1, v1);

        // Execute the createAutomation user operation
        UserOperation[] memory createAutomationUserOps = new UserOperation[](1);
        createAutomationUserOps[0] = createAutomationUserOp;
        entryPoint.handleOps(createAutomationUserOps, beneficiary);

        // send an ERC20 transfer to some 3rd part0
        uint256 sendAmount = 9 * 10 ** 5; // Send 90 cents. Expect 10 cents saved
        console.log("Sending %s tokens to %s", sendAmount, paymentRecipient);
        console.logBytes(
            abi.encodeWithSelector( // data parameter (calls ERC20's `transfer`)
                    IERC20(testTokenAddress).transfer.selector,
                    address(paymentRecipient),
                    sendAmount
                )
        );
        // Create a user operation to trigger the token transfer
        UserOperation memory userOp = UserOperation({
            sender: account1Address,
            nonce: 1,
            initCode: "",
            callData: abi.encodeWithSelector(
                IStandardExecutor(account1Address).execute.selector,
                testTokenAddress, // target address (ERC20 token)
                0, // value (no ETH required)
                abi.encodeWithSelector( // data parameter (calls ERC20's `transfer`)
                        IERC20(testTokenAddress).transfer.selector,
                        address(paymentRecipient),
                        sendAmount
                    )
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
        assertEq(
            testToken.balanceOf(account1Address),
            mintAmount - roundUpTo,
            "Account1 should have fewer tokens"
        );

        assertEq(
            testToken.balanceOf(paymentRecipient),
            sendAmount,
            "Recipient should have received the tokens"
        );

        // assert that automatic savings happened
        uint256 expectedSavings = roundUpTo - sendAmount;
        assertEq(
            testToken.balanceOf(savingsAccount),
            expectedSavings,
            "Savings account should have received 10 cents"
        );
    }

    // savings shouldn't happen if it means the transfer will fail
    // test sending more than a roundUpTo amount and exactly equal to
    // test multiple savings automtions for the same account
    // multiple for different accounts
    // transfer should still succeed even if the savings transfer fails
}
