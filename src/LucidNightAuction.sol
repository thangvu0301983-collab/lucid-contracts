// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface ILucidDreams {
    function claim(uint256 dreamId, bytes calldata signature) external;
    function transferFrom(address from, address to, uint256 id) external;
    function ownerOf(uint256 id) external view returns (address);
}

/// @title LUCID Night Auction
/// @notice One dream a night, forever. Every night the LUCID mind paints its own dream, the website
///         signs a gift voucher for this contract, and the dream is minted straight into a 24-hour
///         English auction. Bids in the last 10 minutes extend it. Anyone can settle.
///         Proceeds: 60% to the buyback & burn vault, 40% to the treasury that pays for the mind.
contract LucidNightAuction is ReentrancyGuard {
    struct Auction {
        uint256 dreamId;
        uint256 amount; // highest bid, wei
        address bidder;
        uint64 startTime;
        uint64 endTime;
        bool settled;
    }

    uint32 public constant DURATION = 24 hours;
    uint32 public constant TIME_BUFFER = 10 minutes;
    uint16 public constant MIN_INCREMENT_BPS = 500; // +5% per bid
    uint16 public constant BUYBACK_BPS = 6_000;

    ILucidDreams public immutable dreams;
    address public guardian;
    address public operator; // the LUCID mind key: can only start the next night
    address public buybackVault;
    address public treasury;
    uint256 public reservePrice;

    Auction public auction;
    uint256 public nights;
    mapping(address => uint256) public pendingReturns;

    event NightStarted(uint256 indexed night, uint256 indexed dreamId, uint64 endTime);
    event Bid(uint256 indexed dreamId, address indexed bidder, uint256 amount, bool extended);
    event NightSettled(uint256 indexed dreamId, address winner, uint256 amount, uint256 toBuyback, uint256 toTreasury);

    error NotOperator();
    error NotGuardian();
    error AuctionLive();
    error NoAuction();
    error AuctionEnded();
    error AuctionNotEnded();
    error AlreadySettled();
    error BidTooLow();
    error WrongDream();
    error ZeroAddress();
    error PayFailed();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(ILucidDreams _dreams, address _guardian, address _operator, address _buyback, address _treasury, uint256 _reserve) {
        if (address(_dreams) == address(0) || _guardian == address(0) || _operator == address(0) || _buyback == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        dreams = _dreams;
        guardian = _guardian;
        operator = _operator;
        buybackVault = _buyback;
        treasury = _treasury;
        reservePrice = _reserve;
    }

    /// @notice Mint tonight's dream into this contract (voucher signed for this address) and open bidding.
    function start(uint256 dreamId, bytes calldata voucher) external onlyOperator {
        Auction memory a = auction;
        if (a.startTime != 0 && !a.settled) revert AuctionLive();
        dreams.claim(dreamId, voucher);
        uint64 end = uint64(block.timestamp + DURATION);
        auction = Auction({dreamId: dreamId, amount: 0, bidder: address(0), startTime: uint64(block.timestamp), endTime: end, settled: false});
        unchecked {
            nights++;
        }
        emit NightStarted(nights, dreamId, end);
    }

    function bid(uint256 dreamId) external payable nonReentrant {
        Auction memory a = auction;
        if (a.startTime == 0 || a.settled) revert NoAuction();
        if (a.dreamId != dreamId) revert WrongDream();
        if (block.timestamp >= a.endTime) revert AuctionEnded();
        uint256 min = a.amount == 0 ? reservePrice : a.amount + a.amount * MIN_INCREMENT_BPS / 10_000;
        if (msg.value < min || msg.value == 0) revert BidTooLow();

        bool extended = a.endTime - block.timestamp < TIME_BUFFER;
        auction.amount = msg.value;
        auction.bidder = msg.sender;
        if (extended) auction.endTime = uint64(block.timestamp + TIME_BUFFER);

        if (a.bidder != address(0)) _refund(a.bidder, a.amount);
        emit Bid(dreamId, msg.sender, msg.value, extended);
    }

    /// @notice Close the night. Permissionless once the timer ends. No bids: the dream goes to the treasury.
    function settle() external nonReentrant {
        Auction memory a = auction;
        if (a.startTime == 0) revert NoAuction();
        if (a.settled) revert AlreadySettled();
        if (block.timestamp < a.endTime) revert AuctionNotEnded();
        auction.settled = true;

        address to = a.bidder == address(0) ? treasury : a.bidder;
        dreams.transferFrom(address(this), to, a.dreamId);

        uint256 toBuyback = a.amount * BUYBACK_BPS / 10_000;
        uint256 toTreasury = a.amount - toBuyback;
        _pay(buybackVault, toBuyback);
        _pay(treasury, toTreasury);
        emit NightSettled(a.dreamId, a.bidder, a.amount, toBuyback, toTreasury);
    }

    /// @notice Pull a refund that could not be pushed (e.g. the outbid wallet rejects ETH).
    function withdraw() external nonReentrant {
        uint256 v = pendingReturns[msg.sender];
        pendingReturns[msg.sender] = 0;
        _pay(msg.sender, v);
    }

    function minNextBid() external view returns (uint256) {
        Auction memory a = auction;
        return a.amount == 0 ? reservePrice : a.amount + a.amount * MIN_INCREMENT_BPS / 10_000;
    }

    // ------------------------------------------------------------------ admin
    function setOperator(address o) external onlyGuardian {
        if (o == address(0)) revert ZeroAddress();
        operator = o;
    }

    function setReservePrice(uint256 r) external onlyGuardian {
        reservePrice = r;
    }

    function setRecipients(address b, address t) external onlyGuardian {
        if (b == address(0) || t == address(0)) revert ZeroAddress();
        buybackVault = b;
        treasury = t;
    }

    function setGuardian(address g) external onlyGuardian {
        guardian = g;
    }

    // ------------------------------------------------------------------ internals
    function _refund(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount, gas: 30_000}("");
        if (!ok) pendingReturns[to] += amount;
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayFailed();
    }
}
