// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LucidDreams} from "../src/LucidDreams.sol";
import {LucidNightAuction, ILucidDreams} from "../src/LucidNightAuction.sol";

contract RejectsEth {
    function bid(LucidNightAuction a, uint256 id) external payable { a.bid{value: msg.value}(id); }
    receive() external payable { revert("no"); }
}

contract LucidNightAuctionTest is Test {
    LucidDreams dreams;
    LucidNightAuction auction;
    uint256 signerKey = 0xA11CE;
    address guardian = makeAddr("guardian");
    address mind = makeAddr("mind");
    address buyback = makeAddr("buyback");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        dreams = new LucidDreams(vm.addr(signerKey), treasury, "https://lucid.example/api/nft/");
        auction = new LucidNightAuction(ILucidDreams(address(dreams)), guardian, mind, buyback, treasury, 0.01 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _voucherFor(address to, uint256 id) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, dreams.claimDigest(to, id));
        return abi.encodePacked(r, s, v);
    }

    function _start(uint256 id) internal {
        bytes memory sig = _voucherFor(address(auction), id);
        vm.prank(mind);
        auction.start(id, sig);
    }

    function test_startMintsIntoAuction() public {
        _start(31);
        assertEq(dreams.ownerOf(31), address(auction));
        (uint256 id,,, uint64 st, uint64 end,) = auction.auction();
        assertEq(id, 31);
        assertEq(end - st, 24 hours);
        assertEq(auction.nights(), 1);
    }

    function test_onlyMindStarts() public {
        bytes memory sig = _voucherFor(address(auction), 1);
        vm.prank(alice);
        vm.expectRevert(LucidNightAuction.NotOperator.selector);
        auction.start(1, sig);
    }

    function test_bidsRefundAndSettleSplits() public {
        _start(1);
        vm.prank(alice);
        auction.bid{value: 0.1 ether}(1);
        vm.prank(bob);
        vm.expectRevert(LucidNightAuction.BidTooLow.selector);
        auction.bid{value: 0.104 ether}(1); // needs +5%
        vm.prank(bob);
        auction.bid{value: 0.2 ether}(1);
        assertEq(alice.balance, 10 ether, "alice refunded");

        vm.expectRevert(LucidNightAuction.AuctionNotEnded.selector);
        auction.settle();
        vm.warp(block.timestamp + 24 hours);
        auction.settle();
        assertEq(dreams.ownerOf(1), bob);
        assertEq(buyback.balance, 0.12 ether, "60% to buyback");
        assertEq(treasury.balance, 0.08 ether, "40% to treasury");
    }

    function test_reserveAndLateBidExtends() public {
        _start(1);
        vm.prank(alice);
        vm.expectRevert(LucidNightAuction.BidTooLow.selector);
        auction.bid{value: 0.005 ether}(1);
        vm.warp(block.timestamp + 24 hours - 2 minutes);
        vm.prank(alice);
        auction.bid{value: 0.05 ether}(1);
        (,,,, uint64 end,) = auction.auction();
        assertEq(end, block.timestamp + 10 minutes, "extended by the buffer");
    }

    function test_noBidsGoesToTreasury() public {
        _start(1);
        vm.warp(block.timestamp + 24 hours);
        auction.settle();
        assertEq(dreams.ownerOf(1), treasury);
    }

    function test_cannotStartWhileLiveThenNextNight() public {
        _start(1);
        bytes memory sig2 = _voucherFor(address(auction), 2);
        vm.prank(mind);
        vm.expectRevert(LucidNightAuction.AuctionLive.selector);
        auction.start(2, sig2);
        vm.warp(block.timestamp + 24 hours);
        auction.settle();
        vm.prank(mind);
        auction.start(2, sig2);
        assertEq(auction.nights(), 2);
    }

    function test_rejectingBidderGetsPullRefund() public {
        _start(1);
        RejectsEth r = new RejectsEth();
        vm.deal(address(r), 1 ether);
        r.bid{value: 0.1 ether}(auction, 1);
        vm.prank(bob);
        auction.bid{value: 0.2 ether}(1);
        assertEq(auction.pendingReturns(address(r)), 0.1 ether);
    }

    function test_cannotBidAfterEnd() public {
        _start(1);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        vm.expectRevert(LucidNightAuction.AuctionEnded.selector);
        auction.bid{value: 1 ether}(1);
    }
}
