// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LUCID Vault
/// @notice LUCID's mind on-chain. The LUCID pool runs Programmable's sealed, protected launch kernel
///         (ProtectedNative30HookV1); this vault is that kernel's immutable creator-fee recipient.
///         Anyone may call the kernel fee vault's claimCreator() to push accrued creator fees (ETH) here.
///
///         Every ETH that arrives is split by distribute():
///           60% mood pot  -> where the night's Dream of the Night sends it:
///                            BURN   -> buyback vault (nightmares burn)
///                            REWARD -> stays here in the synapse pool (sweet dreams pay)
///                            DEEPEN -> liquidity vault (deep dreams deepen the pool)
///           30% treasury
///           10% synapse pool (holder rewards paid by the agent, capped)
///
///         The agent chooses the night route (at most once per 20 hours) and pays holder rewards inside caps.
///         The guardian (a Safe) can rotate the agent, the recipients or itself, and ground the agent.
///         Nobody can withdraw the vault's ETH except through these routes.
contract LucidVault {
    uint16 public constant BPS = 10_000;
    uint16 public constant SHARE_MOOD_BPS = 6_000;
    uint16 public constant SHARE_TREASURY_BPS = 3_000;
    uint16 public constant SHARE_SYNAPSE_BPS = 1_000;

    uint8 public constant NIGHT_BURN = 0;
    uint8 public constant NIGHT_REWARD = 1;
    uint8 public constant NIGHT_DEEPEN = 2;

    uint32 public constant NIGHT_COOLDOWN = 20 hours;
    uint32 public constant GROUNDED_FOR = 14 days;
    uint32 public constant AGENT_STALE_AFTER = 7 days;
    uint16 public constant SYNAPSE_MAX_PER_PAYMENT_BPS = 1_000; // 10% of the pool per payment
    uint16 public constant SYNAPSE_MAX_PER_DAY_BPS = 2_500; // 25% of the pool at the start of the day

    address public guardian;
    address public agent;
    address public buybackVault;
    address public treasury;
    address public liquidityVault;

    uint8 public nightAction; // starts at NIGHT_BURN
    bytes32 public nightDream;
    uint64 public lastNightAt;
    uint64 public lastAgentActionAt;
    uint64 public groundedUntil;

    uint256 public synapsePool;
    uint256 public totalSynapsePaid;
    uint256 public totalDistributed;
    uint64 public synapseDay;
    uint256 public synapseDayBudget;
    uint256 public synapseDaySpent;
    mapping(address => uint32) public synapseWeight;

    bool private _locked;

    event Received(address indexed from, uint256 amount);
    event Distributed(uint8 indexed action, uint256 toMood, uint256 toTreasury, uint256 toSynapse);
    event NightAction(uint64 indexed day, uint8 action, bytes32 dreamHash);
    event Dream(uint64 indexed day, bytes32 journalHash);
    event SynapseFired(address indexed holder, uint256 amount, bytes32 ideaHash, uint32 weight);
    event SafeMode(address indexed by, uint64 groundedUntil);
    event AgentChanged(address indexed oldAgent, address indexed newAgent);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event RecipientsChanged(address buybackVault, address treasury, address liquidityVault);

    error ZeroAddress();
    error NotAgent();
    error NotGuardian();
    error Grounded();
    error BadAction();
    error CooldownActive();
    error AgentNotStale();
    error SynapseCapExceeded();
    error TransferFailed();
    error Reentrant();

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /// @dev The agent acts only while not grounded.
    modifier onlyActiveAgent() {
        if (msg.sender != agent) revert NotAgent();
        if (block.timestamp < groundedUntil) revert Grounded();
        _;
    }

    constructor(address guardian_, address agent_, address buybackVault_, address treasury_, address liquidityVault_) {
        if (
            guardian_ == address(0) || agent_ == address(0) || buybackVault_ == address(0) || treasury_ == address(0)
                || liquidityVault_ == address(0)
        ) revert ZeroAddress();
        guardian = guardian_;
        agent = agent_;
        buybackVault = buybackVault_;
        treasury = treasury_;
        liquidityVault = liquidityVault_;
        lastAgentActionAt = uint64(block.timestamp);
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice ETH waiting to be split (everything except the synapse pool).
    function pending() public view returns (uint256) {
        return address(this).balance - synapsePool;
    }

    // ================================================================== permissionless
    /// @notice Split everything pending under the current night route. Anyone may call it.
    function distribute() external nonReentrant {
        _distribute();
    }

    /// @notice Ground the agent for 14 days and reset the route to BURN.
    ///         Guardian at any time; anyone once the agent has been silent for 7 days.
    function safeMode() external {
        if (msg.sender != guardian && block.timestamp < uint256(lastAgentActionAt) + AGENT_STALE_AFTER) {
            revert AgentNotStale();
        }
        nightAction = NIGHT_BURN;
        groundedUntil = uint64(block.timestamp + GROUNDED_FOR);
        emit SafeMode(msg.sender, groundedUntil);
    }

    // ================================================================== agent
    /// @notice Nightly sign of life: the hash of the day's dream journal.
    function dream(bytes32 journalHash) external {
        if (msg.sender != agent) revert NotAgent();
        lastAgentActionAt = uint64(block.timestamp);
        emit Dream(uint64(block.timestamp / 1 days), journalHash);
    }

    /// @notice Once a night: the mood of the Dream of the Night decides where the mood pot goes.
    ///         Fees that arrived under the previous route are distributed first.
    function setNightAction(uint8 action, bytes32 dreamHash) external onlyActiveAgent nonReentrant {
        if (action > NIGHT_DEEPEN) revert BadAction();
        if (lastNightAt != 0 && block.timestamp < uint256(lastNightAt) + NIGHT_COOLDOWN) revert CooldownActive();
        _distribute();
        nightAction = action;
        nightDream = dreamHash;
        lastNightAt = uint64(block.timestamp);
        lastAgentActionAt = uint64(block.timestamp);
        emit NightAction(uint64(block.timestamp / 1 days), action, dreamHash);
    }

    /// @notice Pay a holder whose idea the mind adopted. Capped per payment and per day.
    function rewardSynapse(address holder, uint256 amount, bytes32 ideaHash) external onlyActiveAgent nonReentrant {
        if (holder == address(0)) revert ZeroAddress();
        uint64 today = uint64(block.timestamp / 1 days) + 1; // +1 so day numbering never equals the unset value 0
        if (today != synapseDay) {
            synapseDay = today;
            synapseDayBudget = synapsePool * SYNAPSE_MAX_PER_DAY_BPS / BPS;
            synapseDaySpent = 0;
        }
        if (amount > synapsePool * SYNAPSE_MAX_PER_PAYMENT_BPS / BPS) revert SynapseCapExceeded();
        if (synapseDaySpent + amount > synapseDayBudget) revert SynapseCapExceeded();
        synapsePool -= amount;
        synapseDaySpent += amount;
        totalSynapsePaid += amount;
        uint32 w = synapseWeight[holder] + 1;
        synapseWeight[holder] = w;
        lastAgentActionAt = uint64(block.timestamp);
        _send(holder, amount);
        emit SynapseFired(holder, amount, ideaHash, w);
    }

    // ================================================================== guardian
    function setAgent(address newAgent) external onlyGuardian {
        if (newAgent == address(0)) revert ZeroAddress();
        emit AgentChanged(agent, newAgent);
        agent = newAgent;
        lastAgentActionAt = uint64(block.timestamp);
    }

    function setRecipients(address buybackVault_, address treasury_, address liquidityVault_) external onlyGuardian {
        if (buybackVault_ == address(0) || treasury_ == address(0) || liquidityVault_ == address(0)) revert ZeroAddress();
        buybackVault = buybackVault_;
        treasury = treasury_;
        liquidityVault = liquidityVault_;
        emit RecipientsChanged(buybackVault_, treasury_, liquidityVault_);
    }

    /// @notice Hand the guardian role to a DAO, or to address(0) to renounce.
    function setGuardian(address newGuardian) external onlyGuardian {
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ================================================================== internals
    function _distribute() internal {
        uint256 amount = pending();
        if (amount == 0) return;
        uint256 toMood = amount * SHARE_MOOD_BPS / BPS;
        uint256 toTreasury = amount * SHARE_TREASURY_BPS / BPS;
        uint256 toSynapse = amount - toMood - toTreasury;
        uint8 a = nightAction;
        // Book the synapse share before any ETH leaves, so pending() can never count it again.
        synapsePool += a == NIGHT_REWARD ? toSynapse + toMood : toSynapse;
        totalDistributed += amount;
        _send(treasury, toTreasury);
        if (a == NIGHT_BURN) _send(buybackVault, toMood);
        else if (a == NIGHT_DEEPEN) _send(liquidityVault, toMood);
        emit Distributed(a, toMood, toTreasury, toSynapse);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
