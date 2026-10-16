// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LUCID token
/// @notice Fixed-supply ERC-20. 1,000,000,000 LUCID minted once to the launch wallet
///         (the Programmable graph initializer). No owner, no mint, no pause, no tax in the
///         token itself: every economic rule lives in the Uniswap v4 hook.
/// @dev    Self-contained (no external imports) so the Programmable source bundle is small
///         and the exact-source verification is trivial.
contract LucidToken {
    string public constant name = "LUCID";
    string public constant symbol = "LUCID";
    uint8 public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Public presentation, fixed at deployment (the token has no owner, so nobody can change it later).
    string private _description;
    string private _website;
    string private _image;
    string private _x;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();
    error BadMetadata();

    /// @param launchWallet Receives the whole supply. In a Programmable launch this is the graph
    ///        initializer, which places 100% of it in the pool as a permanent position (fair launch:
    ///        no team, treasury or vesting allocations exist).
    /// @param description_ Public description shown by explorers and Programmable.
    /// @param website_ https:// website. @param image_ https:// image. @param x_ https://x.com/<handle>.
    constructor(
        address launchWallet,
        string memory description_,
        string memory website_,
        string memory image_,
        string memory x_
    ) {
        if (launchWallet == address(0)) revert ZeroAddress();
        if (bytes(description_).length < 20 || !_jsonSafe(description_)) revert BadMetadata();
        if (!_isHttps(website_) || !_isHttps(image_) || !_isHttps(x_)) revert BadMetadata();
        _description = description_;
        _website = website_;
        _image = image_;
        _x = x_;
        balanceOf[launchWallet] = TOTAL_SUPPLY;
        emit Transfer(address(0), launchWallet, TOTAL_SUPPLY);
    }

    /// @notice Programmable token metadata: (description, website, image, extraData).
    function metadata()
        external
        view
        returns (string memory description, string memory website, string memory image, bytes memory extraData)
    {
        return (_description, _website, _image, "");
    }

    /// @notice The same presentation as inline JSON, including the X profile.
    function tokenURI() external view returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"', name, '","symbol":"', symbol, '","description":"', _description,
            '","image":"', _image, '","website":"', _website, '","external_url":"', _website,
            '","x":"', _x, '"}'
        );
        return string(abi.encodePacked("data:application/json;base64,", _base64(json)));
    }

    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    // ------------------------------------------------------------------ metadata helpers
    /// @dev No quotes, backslashes or control bytes, so the strings drop into JSON unescaped.
    function _jsonSafe(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c < 0x20 || c == 0x22 || c == 0x5c || c == 0x7f) return false;
        }
        return true;
    }

    function _isHttps(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length <= 8 || b.length > 2048 || !_jsonSafe(s)) return false;
        bytes memory p = "https://";
        for (uint256 i; i < 8; ++i) {
            if (b[i] != p[i]) return false;
        }
        for (uint256 i = 8; i < b.length; ++i) {
            if (b[i] == 0x20) return false;
        }
        return true;
    }

    function _base64(bytes memory data) private pure returns (string memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 len = data.length;
        if (len == 0) return "";
        bytes memory out = new bytes(4 * ((len + 2) / 3));
        uint256 j;
        for (uint256 i; i < len; i += 3) {
            uint256 a = uint8(data[i]);
            uint256 b = i + 1 < len ? uint8(data[i + 1]) : 0;
            uint256 c = i + 2 < len ? uint8(data[i + 2]) : 0;
            uint256 n = (a << 16) | (b << 8) | c;
            out[j++] = table[(n >> 18) & 63];
            out[j++] = table[(n >> 12) & 63];
            out[j++] = i + 1 < len ? table[(n >> 6) & 63] : bytes1("=");
            out[j++] = i + 2 < len ? table[n & 63] : bytes1("=");
        }
        return string(out);
    }
}
