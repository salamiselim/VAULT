// script/DeployVault.s.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        IERC20 dummyToken = IERC20(0x000000000000000000000000000000000000dEaD);

        Vault vault = new Vault(
            dummyToken,      
            "Hedera Vault",
            "hVLT"
        );

        vm.stopBroadcast();

        console2.log("Vault deployed on Hedera Testnet!");
        console2.log("Address:", address(vault));
        console2.log("Dummy token used: 0x000000000000000000000000000000000000dEaD");
    }
}