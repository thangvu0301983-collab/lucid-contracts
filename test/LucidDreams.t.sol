// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LucidDreams} from "../src/LucidDreams.sol";

contract LucidDreamsTest is Test {
    LucidDreams dreams;
    uint256 signerKey = 0xA11CE;
    address signer;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        signer = vm.addr(signerKey);
        dreams = new LucidDreams(signer, treasury, "https://lucid.example/api/nft/");
        vm.deal(bob, 10 ether);
    }

    function _voucher(address to, uint256 id) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, dreams.claimDigest(to, id));
        return abi.encodePacked(r, s, v);
    }

    function test_claimGift() public {
        bytes memory sig = _voucher(alice, 7);
        vm.prank(alice);
        dreams.claim(7, sig);
        assertEq(dreams.ownerOf(7), alice);
        assertEq(dreams.totalMinted(), 1);
        assertEq(dreams.tokenURI(7), "https://lucid.example/api/nft/7");
    }

    function test_voucherIsBoundToWallet() public {
        bytes memory sig = _voucher(alice, 7);
        vm.prank(bob);
        vm.expectRevert(LucidDreams.BadSignature.selector);
        dreams.claim(7, sig);
    }

    function test_cannotClaimTwice() public {
        bytes memory sig = _voucher(alice, 7);
        vm.startPrank(alice);
        dreams.claim(7, sig);
        vm.expectRevert(LucidDreams.AlreadyClaimed.selector);
        dreams.claim(7, sig);
        vm.stopPrank();
    }

    function test_listAndBuy() public {
        bytes memory sig = _voucher(alice, 1);
        vm.startPrank(alice);
        dreams.claim(1, sig);
        dreams.list(1, 1 ether);
        vm.stopPrank();

        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        dreams.buy{value: 1 ether}(1);

        assertEq(dreams.ownerOf(1), bob);
        assertEq(treasury.balance, 0.025 ether, "2.5% fee");
        assertEq(alice.balance - aliceBefore, 0.975 ether, "seller proceeds");
        (address seller,) = dreams.listings(1);
        assertEq(seller, address(0), "listing cleared");
    }

    function test_wrongPriceReverts() public {
        bytes memory sig = _voucher(alice, 1);
        vm.startPrank(alice);
        dreams.claim(1, sig);
        dreams.list(1, 1 ether);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(LucidDreams.WrongPrice.selector);
        dreams.buy{value: 0.5 ether}(1);
    }

    function test_onlyOwnerCanList() public {
        bytes memory sig = _voucher(alice, 1);
        vm.prank(alice);
        dreams.claim(1, sig);
        vm.prank(bob);
        vm.expectRevert(LucidDreams.NotTokenOwner.selector);
        dreams.list(1, 1 ether);
    }

    function test_transferClearsListing() public {
        bytes memory sig = _voucher(alice, 1);
        vm.startPrank(alice);
        dreams.claim(1, sig);
        dreams.list(1, 1 ether);
        dreams.transferFrom(alice, bob, 1);
        vm.stopPrank();
        (address seller,) = dreams.listings(1);
        assertEq(seller, address(0));
        vm.prank(makeAddr("carol"));
        vm.deal(makeAddr("carol"), 2 ether);
        vm.expectRevert(LucidDreams.NotListed.selector);
        dreams.buy{value: 1 ether}(1);
    }

    function test_cancel() public {
        bytes memory sig = _voucher(alice, 1);
        vm.startPrank(alice);
        dreams.claim(1, sig);
        dreams.list(1, 1 ether);
        dreams.cancel(1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(LucidDreams.NotListed.selector);
        dreams.buy{value: 1 ether}(1);
    }

    function test_royaltyAndInterfaces() public view {
        (address r, uint256 amt) = dreams.royaltyInfo(1, 1 ether);
        assertEq(r, treasury);
        assertEq(amt, 0.025 ether);
        assertTrue(dreams.supportsInterface(0x2a55205a));
        assertTrue(dreams.supportsInterface(0x80ac58cd)); // ERC721
    }

    function test_feeCap() public {
        vm.expectRevert(LucidDreams.FeeTooHigh.selector);
        dreams.setFee(treasury, 1_001);
    }

    function test_onlyOwnerAdmin() public {
        vm.prank(bob);
        vm.expectRevert(LucidDreams.NotOwner.selector);
        dreams.setSigner(bob);
    }
}
