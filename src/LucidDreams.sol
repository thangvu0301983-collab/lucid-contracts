// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {LibString} from "solmate/src/utils/LibString.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title LUCID Dreams
/// @notice Dream NFTs. A holder writes a dream on the LUCID website, the LUCID mind paints it, and the
///         website gifts it: it signs a claim voucher, and the dreamer mints the NFT paying only gas.
///         Owners can list their dream for sale here; buyers pay ETH, a small fee goes to the LUCID
///         treasury, the rest to the seller. No names, no emails: the website shows aliases only.
contract LucidDreams is ERC721, EIP712, ReentrancyGuard {
    using LibString for uint256;

    struct Listing {
        address seller;
        uint96 price; // wei
    }

    bytes32 public constant CLAIM_TYPEHASH = keccak256("Claim(address to,uint256 dreamId)");
    uint16 public constant MAX_FEE_BPS = 1_000; // 10% hard cap

    address public owner;
    address public signer; // website key that signs claim vouchers
    address public feeRecipient; // LUCID treasury
    uint16 public feeBps = 250; // 2.5% marketplace fee and EIP-2981 royalty
    string public baseURI;
    bool public baseURIFrozen;
    uint256 public totalMinted;

    mapping(uint256 => Listing) public listings;

    event DreamClaimed(uint256 indexed dreamId, address indexed to);
    event Listed(uint256 indexed dreamId, address indexed seller, uint256 price);
    event Unlisted(uint256 indexed dreamId);
    event Sold(uint256 indexed dreamId, address indexed seller, address indexed buyer, uint256 price, uint256 fee);
    event SignerChanged(address signer);
    event BaseURIChanged(string baseURI);

    error NotOwner();
    error AlreadyClaimed();
    error BadSignature();
    error NotTokenOwner();
    error NotListed();
    error WrongPrice();
    error ZeroPrice();
    error FeeTooHigh();
    error Frozen();
    error ZeroAddress();
    error PayFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _signer, address _feeRecipient, string memory _baseURI)
        ERC721("LUCID Dreams", "DREAM")
        EIP712("LUCID Dreams", "1")
    {
        if (_signer == address(0) || _feeRecipient == address(0)) revert ZeroAddress();
        owner = msg.sender;
        signer = _signer;
        feeRecipient = _feeRecipient;
        baseURI = _baseURI;
    }

    // ------------------------------------------------------------------ gift: claim with a voucher
    /// @notice Mint a gifted dream to the caller. The voucher is bound to the caller's address.
    function claim(uint256 dreamId, bytes calldata signature) external {
        if (_ownerOf[dreamId] != address(0)) revert AlreadyClaimed();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, msg.sender, dreamId)));
        if (ECDSA.recover(digest, signature) != signer) revert BadSignature();
        _mint(msg.sender, dreamId);
        unchecked {
            totalMinted++;
        }
        emit DreamClaimed(dreamId, msg.sender);
    }

    /// @notice EIP-712 digest the website signs. Exposed so off-chain code can check it.
    function claimDigest(address to, uint256 dreamId) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, to, dreamId)));
    }

    // ------------------------------------------------------------------ marketplace
    function list(uint256 dreamId, uint96 price) external {
        if (_ownerOf[dreamId] != msg.sender) revert NotTokenOwner();
        if (price == 0) revert ZeroPrice();
        listings[dreamId] = Listing(msg.sender, price);
        emit Listed(dreamId, msg.sender, price);
    }

    function cancel(uint256 dreamId) external {
        Listing memory l = listings[dreamId];
        if (l.seller == address(0)) revert NotListed();
        // the seller, or anyone once the seller no longer owns the token (stale listing)
        if (msg.sender != l.seller && _ownerOf[dreamId] == l.seller) revert NotTokenOwner();
        delete listings[dreamId];
        emit Unlisted(dreamId);
    }

    function buy(uint256 dreamId) external payable nonReentrant {
        Listing memory l = listings[dreamId];
        if (l.seller == address(0) || _ownerOf[dreamId] != l.seller) revert NotListed();
        if (msg.value != l.price) revert WrongPrice();
        delete listings[dreamId];

        _move(l.seller, msg.sender, dreamId);

        uint256 fee = uint256(l.price) * feeBps / 10_000;
        _pay(feeRecipient, fee);
        _pay(l.seller, uint256(l.price) - fee);
        emit Sold(dreamId, l.seller, msg.sender, l.price, fee);
    }

    /// @dev Any normal transfer clears a listing so a stale price can never be bought.
    function transferFrom(address from, address to, uint256 id) public override {
        if (listings[id].seller != address(0)) {
            delete listings[id];
            emit Unlisted(id);
        }
        super.transferFrom(from, to, id);
    }

    // ------------------------------------------------------------------ metadata & royalties
    function tokenURI(uint256 id) public view override returns (string memory) {
        if (_ownerOf[id] == address(0)) revert NotListed();
        return string.concat(baseURI, id.toString());
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (feeRecipient, salePrice * feeBps / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId); // EIP-2981
    }

    // ------------------------------------------------------------------ admin
    function setSigner(address s) external onlyOwner {
        if (s == address(0)) revert ZeroAddress();
        signer = s;
        emit SignerChanged(s);
    }

    function setFee(address recipient, uint16 bps) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        feeRecipient = recipient;
        feeBps = bps;
    }

    function setBaseURI(string calldata u) external onlyOwner {
        if (baseURIFrozen) revert Frozen();
        baseURI = u;
        emit BaseURIChanged(u);
    }

    function freezeBaseURI() external onlyOwner {
        baseURIFrozen = true;
    }

    function transferOwnership(address o) external onlyOwner {
        owner = o;
    }

    // ------------------------------------------------------------------ internals
    function _move(address from, address to, uint256 id) internal {
        unchecked {
            _balanceOf[from]--;
            _balanceOf[to]++;
        }
        _ownerOf[id] = to;
        delete getApproved[id];
        emit Transfer(from, to, id);
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayFailed();
    }
}
