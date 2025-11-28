// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../src/Vault.sol";

contract DeployVault is Script {
    function run() external {
        vm.startBroadcast();
        Vault vault = new Vault(IERC20(address(0)), "Vault", "vT");
        vm.stopBroadcast();
        
        console.log("Vault deployed:", address(vault));
    }
}