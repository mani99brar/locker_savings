// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {BasePlgin} from "modular-account-libs/plugins/BasePlugin.sol";
import {IPluginExecutor} from "modular-account-libs/interfaces/IPluginExecutor.sol";
import {IStandardExecutor} from "modular-account-libs/interfaces/IStandardExecutor.sol";
import {ManifestFunction, ManifestExecutionHook, ManifestAssociatedFunctionType, ManifestAssociatedFunction, PluginManifest, PluginMetadata, IPlugin} from "modular-account-libs/interfaces/IPlugin.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

enum FunctionId {
    EXECUTE_FUNCTION,
    EXECUTE_BATCH_FUNCTION
}

/// @title Savings Plugin
/// @author Locker
/// @notice This plugin lets users automatically save when making payments
contract SavingsPlugin is BasePlugin {
    string public constant NAME = "Locker Savings Plugin";
    string public constant VERSION = "0.0.2";
    string public constant AUTHOR = "Locker Team";

    uint256 internal constant _MANIFEST_DEPENDENCY_INDEX_OWNER_USER_OP_VALIDATION = 0;

    struct SavingsAutomation {
        address savingsAccount;
        uint256 roundUpTo;
        bool enabled;
    }

    mapping(address => mapping(uint256 => SavingsAutomation)) public savingsAutomations;

    function createAutomation(
        uint256 automationIndex,
        address savingsAccount,
        uint256 roundUpTo
    ) external {
        savingsAutomations[msg.sender][automationIndex] = SavingsAutomation(
            savingsAccount,
            roundUpTo,
            true
        );
    }

    function onInstall(bytes calldata) external pure override {}

    function onUninstall(bytes calldata) external pure override {}

    function preExecutionHook(
        uint8 functionId,
        address,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes memory) {
        SavingsAutomation memory automation = savingsAutomations[msg.sender][0];
        if (automation.enabled && automation.roundUpTo > 0) {
            uint256 roundUpTo = automation.roundUpTo;
            (address tokenAddress, uint256 ethValue, bytes memory innerData) = abi.decode(
                data[4:],
                (address, uint256, bytes)
            );
            bytes4 transferSelector;
            address recipient;
            uint256 transferAmount;
            assembly {
                transferSelector := mload(add(innerData, 32))
                recipient := mload(add(innerData, 36))
                transferAmount := mload(add(innerData, 68))
            }
            uint256 roundUpAmount = ((transferAmount + roundUpTo - 1) / roundUpTo) * roundUpTo;
            uint256 savingsAmount = roundUpAmount - transferAmount;
            if (savingsAmount > 0) {
                IPluginExecutor(msg.sender).executeFromPluginExternal(
                    tokenAddress,
                    0,
                    abi.encodeWithSelector(
                        IERC20.transfer.selector,
                        automation.savingsAccount,
                        savingsAmount
                    )
                );
            }
        }
        return "";
    }


    function pluginManifest() external pure override returns (PluginManifest memory) {
        PluginManifest memory manifest;
        manifest.executionFunctions = new bytes4[](1);
        manifest.executionFunctions[0] = this.createAutomation.selector;

        manifest.executionHooks = new ManifestExecutionHook[](1);

        ManifestFunction memory execHook = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.SELF,
            functionId: uint8(FunctionId.EXECUTE_FUNCTION),
            dependencyIndex: _MANIFEST_DEPENDENCY_INDEX_OWNER_USER_OP_VALIDATION
        });

        ManifestFunction memory none = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.NONE,
            functionId: 0,
            dependencyIndex: 0
        });

        manifest.executionHooks[0] = ManifestExecutionHook(
            IStandardExecutor.execute.selector,
            execHook,
            none
        );

        return manifest;
    }

    function pluginMetadata() external pure virtual override returns (PluginMetadata memory) {
        PluginMetadata memory metadata;
        metadata.name = NAME;
        metadata.version = VERSION;
        metadata.author = AUTHOR;
        return metadata;
    }
}
