// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {LucidDreams} from "../src/LucidDreams.sol";
import {LucidNightAuction, ILucidDreams} from "../src/LucidNightAuction.sol";

/// @notice Deploys LUCID Dreams (NFT + marketplace) and the Night Auction.
///
///   DREAM_SIGNER=0x...      address of the website's voucher key (server DREAM_SIGNER_KEY)
///   DREAM_TREASURY=0x...    receives the 2.5% sale fee, royalties and 40% of auction proceeds (use a Safe)
///   DREAM_BUYBACK=0x...     receives 60% of auction proceeds for buyback & burn
///   DREAM_GUARDIAN=0x...    can change the auction operator, reserve and recipients (use a Safe)
///   DREAM_OPERATOR=0x...    the LUCID mind key that opens each night (agent AGENT_PRIVATE_KEY address)
///   DREAM_RESERVE_WEI=10000000000000000   reserve price (0.01 ETH)
///   DREAM_BASE_URI=https://tenmien.com/api/nft/
///   forge script script/DeployDreams.s.sol --rpc-url $ETH_RPC_URL --broadcast --account deployer
///
/// Then set DREAMS_CONTRACT and AUCTION_CONTRACT in server/.env and agent/.env, and restart.
contract DeployDreams is Script {
    function run() external returns (LucidDreams dreams, LucidNightAuction auction) {
        vm.startBroadcast();
        dreams = new LucidDreams(vm.envAddress("DREAM_SIGNER"), vm.envAddress("DREAM_TREASURY"), vm.envString("DREAM_BASE_URI"));
        auction = new LucidNightAuction(
            ILucidDreams(address(dreams)),
            vm.envAddress("DREAM_GUARDIAN"),
            vm.envAddress("DREAM_OPERATOR"),
            vm.envAddress("DREAM_BUYBACK"),
            vm.envAddress("DREAM_TREASURY"),
            vm.envUint("DREAM_RESERVE_WEI")
        );
        vm.stopBroadcast();
        console2.log("LucidDreams:      ", address(dreams));
        console2.log("LucidNightAuction:", address(auction));
    }
}
