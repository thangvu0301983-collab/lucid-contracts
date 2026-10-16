// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LucidToken} from "../src/LucidToken.sol";

contract LucidTokenTest is Test {
    string constant DESC = "LUCID is an AI agent that lives in its own Uniswap v4 pool.";
    string constant SITE = "https://lucid.example/";
    string constant IMG = "https://lucid.example/assets/lucid-logo-1024.png";
    string constant X = "https://x.com/lucid_agent";

    LucidToken token;
    address holder = makeAddr("holder");

    function setUp() public {
        token = new LucidToken(holder, DESC, SITE, IMG, X);
    }

    function test_standardGettersAndSupply() public view {
        assertEq(token.name(), "LUCID");
        assertEq(token.symbol(), "LUCID");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(holder), 1_000_000_000e18);
    }

    function test_metadataTuple() public view {
        (string memory d, string memory w, string memory i, bytes memory extra) = token.metadata();
        assertEq(d, DESC);
        assertEq(w, SITE);
        assertEq(i, IMG);
        assertEq(extra.length, 0);
    }

    function test_tokenURIIsInlineBase64Json() public view {
        string memory expectedJson = string(
            abi.encodePacked(
                '{"name":"LUCID","symbol":"LUCID","description":"', DESC, '","image":"', IMG, '","website":"', SITE,
                '","external_url":"', SITE, '","x":"', X, '"}'
            )
        );
        string memory expected = string(abi.encodePacked("data:application/json;base64,", vm.toBase64(bytes(expectedJson))));
        assertEq(token.tokenURI(), expected);
    }

    function test_base64PaddingAllLengths() public {
        // Descriptions of length 20, 21 and 22 cover the three base64 padding cases.
        string[3] memory ds = ["abcdefghijklmnopqrst", "abcdefghijklmnopqrstu", "abcdefghijklmnopqrstuv"];
        for (uint256 k; k < 3; ++k) {
            LucidToken t = new LucidToken(holder, ds[k], SITE, IMG, X);
            string memory json = string(
                abi.encodePacked(
                    '{"name":"LUCID","symbol":"LUCID","description":"', ds[k], '","image":"', IMG, '","website":"',
                    SITE, '","external_url":"', SITE, '","x":"', X, '"}'
                )
            );
            assertEq(t.tokenURI(), string(abi.encodePacked("data:application/json;base64,", vm.toBase64(bytes(json)))));
        }
    }

    function test_rejectsUnsafeOrShortDescription() public {
        vm.expectRevert(LucidToken.BadMetadata.selector);
        new LucidToken(holder, "too short", SITE, IMG, X);
        vm.expectRevert(LucidToken.BadMetadata.selector);
        new LucidToken(holder, 'An AI agent with a "quoted" word', SITE, IMG, X);
        vm.expectRevert(LucidToken.BadMetadata.selector);
        new LucidToken(holder, "An AI agent with a back\\slash in it", SITE, IMG, X);
        vm.expectRevert(LucidToken.BadMetadata.selector);
        new LucidToken(holder, "An AI agent with a\nnew line inside", SITE, IMG, X);
    }

    function test_rejectsNonHttpsLinks() public {
        vm.expectRevert(LucidToken.BadMetadata.selector);
        new LucidToken(holder, DESC, "http://lucid.example/", IMG, X);
        vm.expectRevert(LucidToken.BadMetadata.selector);
        new LucidToken(holder, DESC, SITE, "ipfs://bafy", X);
        vm.expectRevert(LucidToken.BadMetadata.selector);
        new LucidToken(holder, DESC, SITE, IMG, "https://");
        vm.expectRevert(LucidToken.BadMetadata.selector);
        new LucidToken(holder, DESC, "https://lucid example/", IMG, X);
    }

    function test_rejectsZeroLaunchWallet() public {
        vm.expectRevert(LucidToken.ZeroAddress.selector);
        new LucidToken(address(0), DESC, SITE, IMG, X);
    }
}
