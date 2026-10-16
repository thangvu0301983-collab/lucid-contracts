// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LucidVault} from "../src/LucidVault.sol";

contract Reenterer {
    LucidVault vault;

    function set(LucidVault v) external {
        vault = v;
    }

    receive() external payable {
        if (address(vault) != address(0) && address(vault).balance > 0) vault.distribute();
    }
}

contract LucidVaultTest is Test {
    LucidVault vault;
    address guardian = makeAddr("guardian");
    address agent = makeAddr("agent");
    address buyback = makeAddr("buyback");
    address treasury = makeAddr("treasury");
    address liquidity = makeAddr("liquidity");
    address holder = makeAddr("holder");

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new LucidVault(guardian, agent, buyback, treasury, liquidity);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_defaultRouteBurnsSixtyPercent() public {
        _fund(1 ether);
        vault.distribute();
        assertEq(treasury.balance, 0.3 ether);
        assertEq(buyback.balance, 0.6 ether);
        assertEq(vault.synapsePool(), 0.1 ether);
        assertEq(vault.pending(), 0);
        assertEq(address(vault).balance, 0.1 ether);
    }

    function test_rewardRouteKeepsMoodPotForHolders() public {
        vm.prank(agent);
        vault.setNightAction(1, keccak256("sweet"));
        _fund(1 ether);
        vault.distribute();
        assertEq(treasury.balance, 0.3 ether);
        assertEq(vault.synapsePool(), 0.7 ether);
    }

    function test_deepenRouteFeedsLiquidity() public {
        vm.prank(agent);
        vault.setNightAction(2, keccak256("deep"));
        _fund(2 ether);
        vault.distribute();
        assertEq(liquidity.balance, 1.2 ether);
        assertEq(treasury.balance, 0.6 ether);
        assertEq(vault.synapsePool(), 0.2 ether);
    }

    function test_nightSwitchSettlesFeesEarnedUnderTheOldRoute() public {
        _fund(1 ether); // earned under BURN
        vm.prank(agent);
        vault.setNightAction(2, keccak256("deep"));
        assertEq(buyback.balance, 0.6 ether, "old fees followed the old route");
        assertEq(liquidity.balance, 0);
    }

    function test_nightCooldown() public {
        vm.startPrank(agent);
        vault.setNightAction(2, bytes32(0));
        vm.expectRevert(LucidVault.CooldownActive.selector);
        vault.setNightAction(1, bytes32(0));
        vm.warp(block.timestamp + 20 hours);
        vault.setNightAction(1, bytes32(0));
        vm.expectRevert(LucidVault.BadAction.selector);
        vm.warp(block.timestamp + 20 hours);
        vault.setNightAction(3, bytes32(0));
        vm.stopPrank();
    }

    function test_onlyAgentAndGuardian() public {
        vm.expectRevert(LucidVault.NotAgent.selector);
        vault.setNightAction(1, bytes32(0));
        vm.expectRevert(LucidVault.NotAgent.selector);
        vault.rewardSynapse(holder, 1, bytes32(0));
        vm.expectRevert(LucidVault.NotGuardian.selector);
        vault.setAgent(holder);
        vm.expectRevert(LucidVault.NotGuardian.selector);
        vault.setRecipients(holder, holder, holder);
        vm.expectRevert(LucidVault.NotGuardian.selector);
        vault.setGuardian(holder);
    }

    function test_synapseCaps() public {
        _fund(10 ether);
        vault.distribute(); // 1 ETH into the synapse pool
        vm.startPrank(agent);
        vm.expectRevert(LucidVault.SynapseCapExceeded.selector);
        vault.rewardSynapse(holder, 0.11 ether, bytes32(0)); // > 10% per payment
        vault.rewardSynapse(holder, 0.1 ether, bytes32(0));
        vault.rewardSynapse(holder, 0.09 ether, bytes32(0));
        vm.expectRevert(LucidVault.SynapseCapExceeded.selector);
        vault.rewardSynapse(holder, 0.07 ether, bytes32(0)); // day budget 0.25 ETH
        vault.rewardSynapse(holder, 0.06 ether, bytes32(0));
        vm.stopPrank();
        assertEq(holder.balance, 0.25 ether);
        assertEq(vault.synapseWeight(holder), 3);
        assertEq(vault.synapsePool(), 0.75 ether);
        assertEq(vault.pending(), 0, "paying rewards never creates new pending fees");
    }

    function test_safeModeByGuardianGroundsAgent() public {
        vm.prank(agent);
        vault.setNightAction(2, bytes32(0));
        vm.prank(guardian);
        vault.safeMode();
        assertEq(vault.nightAction(), 0, "route back to BURN");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(agent);
        vm.expectRevert(LucidVault.Grounded.selector);
        vault.setNightAction(1, bytes32(0));
        vm.warp(block.timestamp + 14 days);
        vm.prank(agent);
        vault.setNightAction(1, bytes32(0));
    }

    function test_safeModeByAnyoneOnlyAfterSevenSilentDays() public {
        vm.expectRevert(LucidVault.AgentNotStale.selector);
        vault.safeMode();
        vm.warp(block.timestamp + 7 days);
        vault.safeMode();
        assertGt(vault.groundedUntil(), block.timestamp);
    }

    function test_dreamKeepsAgentAlive() public {
        vm.warp(block.timestamp + 6 days);
        vm.prank(agent);
        vault.dream(keccak256("journal"));
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(LucidVault.AgentNotStale.selector);
        vault.safeMode();
    }

    function test_guardianRotations() public {
        vm.startPrank(guardian);
        vault.setAgent(holder);
        vault.setRecipients(holder, holder, holder);
        vault.setGuardian(address(0));
        vm.stopPrank();
        assertEq(vault.agent(), holder);
        assertEq(vault.treasury(), holder);
        assertEq(vault.guardian(), address(0));
    }

    function test_reentrantRecipientCannotDoubleDistribute() public {
        Reenterer r = new Reenterer();
        vm.prank(guardian);
        vault.setRecipients(buyback, address(r), liquidity);
        r.set(vault);
        _fund(1 ether);
        vm.expectRevert(LucidVault.TransferFailed.selector);
        vault.distribute();
    }

    function test_zeroAddressesRejected() public {
        vm.expectRevert(LucidVault.ZeroAddress.selector);
        new LucidVault(address(0), agent, buyback, treasury, liquidity);
    }
}
