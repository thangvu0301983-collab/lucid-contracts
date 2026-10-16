// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @title LUCID Hook: a token that grows a mind
/// @notice Uniswap v4 hook for the ETH/LUCID pool on Ethereum, launched through Programmable.
///
/// The nervous system:
///   * Reflexes (this contract, every swap): the Programmable platform fee (rate and recipient set at deployment), the project fee and the
///     launch flinch (anti-snipe) run inside the swap, deterministically.
///   * Reason (the LUCID agent, off-chain): proposes the project fee with `setPolicy`.
///   * Memory: every decision and every nightly dream carries a hash of its written text.
///
/// Autonomy is earned, not granted. The agent's room to act grows in on-chain stages that the
/// chain itself measures (pool age + cumulative ETH volume). Nobody can skip a stage:
///   Newborn  (from launch)            fee locked at 1.00%
///   Infant   (2 days,  3 ETH)         0.75% - 1.50%, step 25 bps, cooldown 6h
///   Child    (7 days,  25 ETH)        0.50% - 2.50%, step 50 bps, cooldown 2h
///   Adult    (21 days, 100 ETH)       0.50% - 3.00%, step 50 bps, cooldown 1h
/// If the mind has to be put in safe mode it is grounded: for 14 days it acts one stage younger.
///
/// Synapses ("neurons that fire together wire together"): 10% of project fees stay in this
/// contract as the synapse pool. When the agent adopts a holder's idea it may pay that holder
/// from the pool, at most 10% of the pool per payment and 25% per day, and the holder's synapse
/// weight grows by one. The agent can do nothing else with funds.
///
/// Nights: 60% of project fees is the mood pot. Once a night the mind sets where it goes,
/// following the mood of the Dream of the Night chosen by holders: burn (buyback & burn vault),
/// reward (synapse pool) or deepen (liquidity vault). 30% treasury, 10% synapse pool are fixed.
contract LucidHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // ------------------------------------------------------------------ constants
    uint256 public constant PPM = 1_000_000;
    uint256 public constant BPS = 10_000;

    /// @dev Ceiling for the Programmable platform fee: 10,000 ppm = 1.00%. The actual rate is set once at
    ///      deployment (platformFeePpm) to whatever Programmable's review confirms, and can never change.
    uint256 public constant MAX_PLATFORM_FEE_PPM = 10_000;
    uint16 public constant DEFAULT_FEE_BPS = 100; // 1.00%

    // Launch flinch: extra fee on buys, decaying linearly to zero.
    uint16 public constant FLINCH_START_BPS = 300; // +3% at t=0, falling linearly to 0: a launch buy pays at most 4% project fee
    uint32 public constant FLINCH_DURATION = 5 minutes;

    // Growth stages
    uint8 public constant EMBRYO = 0; // before the pool exists
    uint8 public constant NEWBORN = 1;
    uint8 public constant INFANT = 2;
    uint8 public constant CHILD = 3;
    uint8 public constant ADULT = 4;
    uint32 public constant INFANT_AGE = 2 days;
    uint32 public constant CHILD_AGE = 7 days;
    uint32 public constant ADULT_AGE = 21 days;
    uint256 public constant INFANT_VOLUME = 3 ether;
    uint256 public constant CHILD_VOLUME = 25 ether;
    uint256 public constant ADULT_VOLUME = 100 ether;
    uint32 public constant GROUNDED_FOR = 14 days;
    uint32 public constant AGENT_STALE_AFTER = 7 days; // dead-man switch

    // Project fee split (sums to 10_000). The synapse share stays in this contract.
    // 60% is the mood pot: where it goes is decided each night by the Dream of the Night.
    uint16 public constant SHARE_MOOD_BPS = 6_000;
    uint16 public constant SHARE_TREASURY_BPS = 3_000;
    uint16 public constant SHARE_SYNAPSE_BPS = 1_000;

    // Night actions for the mood pot
    uint8 public constant NIGHT_BURN = 0; // to the buyback & burn vault (nightmares burn)
    uint8 public constant NIGHT_REWARD = 1; // stays in the synapse pool (sweet dreams pay the synapses)
    uint8 public constant NIGHT_DEEPEN = 2; // to the liquidity vault (deep dreams deepen the pool)
    uint32 public constant NIGHT_COOLDOWN = 20 hours;

    // Synapse payout caps
    uint16 public constant SYNAPSE_MAX_PER_PAYMENT_BPS = 1_000; // 10% of pool
    uint16 public constant SYNAPSE_MAX_PER_DAY_BPS = 2_500; // 25% of pool at start of day

    // ------------------------------------------------------------------ immutables
    IPoolManager public immutable poolManager;
    Currency public immutable token; // LUCID
    address public immutable platformFeeRecipient; // Programmable, set at deployment
    uint256 public immutable platformFeePpm; // Programmable's rate in ppm, set at deployment (1..MAX_PLATFORM_FEE_PPM)

    // ------------------------------------------------------------------ roles & recipients
    address public guardian;
    address public agent;
    address public buybackVault;
    address public treasury;
    address public liquidityVault;

    // ------------------------------------------------------------------ policy
    struct Policy {
        uint16 feeBps; // last fee set by the agent (clamped to the current stage when used)
        uint64 updatedAt; // last sign of life from the agent
        bytes32 rationale; // hash of the written reasoning or dream (text published off-chain)
        uint32 epoch; // number of policy changes
    }

    Policy public policy;
    uint64 public lastFeeChangeAt;
    uint64 public groundedUntil;
    uint8 public nightAction; // NIGHT_BURN by default
    uint64 public lastNightAt;
    bytes32 public nightDream; // hash of the Dream of the Night that chose the action

    // ------------------------------------------------------------------ pool binding
    PoolId public poolId;
    bool public initialized;
    uint64 public launchedAt;

    // ------------------------------------------------------------------ accounting
    uint256 public cumulativeVolumeEth; // gross ETH leg of every swap
    uint256 public accruedProjectFees; // waiting for distribute()
    uint256 public synapsePool; // ETH reserved for synapse rewards
    uint256 public totalPlatformFeesPaid;
    uint256 public totalProjectFeesCollected;
    uint256 public totalSynapsePaid;
    mapping(address => uint32) public synapseWeight;
    uint64 public synapseDay;
    uint256 public synapseDayBudget;
    uint256 public synapseDaySpent;

    // ------------------------------------------------------------------ metadata (Programmable Explore)
    string private _description;
    string private _website;
    string private _image;
    bool public metadataFrozen;

    // ------------------------------------------------------------------ events
    event PolicyUpdated(
        uint32 indexed epoch, uint8 indexed stage, uint16 oldFeeBps, uint16 newFeeBps, bytes32 rationale
    );
    event Dream(uint64 indexed day, bytes32 journalHash);
    event SafeMode(address indexed by, uint64 groundedUntil);
    event SynapseFired(address indexed holder, uint256 amount, bytes32 indexed ideaHash, uint32 weight);
    event AgentChanged(address indexed oldAgent, address indexed newAgent);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event RecipientsChanged(address buybackVault, address treasury, address liquidityVault);
    event FeesTaken(PoolId indexed id, bool isBuy, uint256 ethBasis, uint256 platformFee, uint256 projectFee);
    event Distributed(uint8 indexed nightAction, uint256 mood, uint256 treasury, uint256 synapse);
    event NightAction(uint64 indexed day, uint8 action, bytes32 dreamHash);
    event MetadataUpdated(string description, string website, string image);
    event MetadataFrozen();

    // ------------------------------------------------------------------ errors
    error NotPoolManager();
    error NotAgent();
    error NotGuardian();
    error HookNotImplemented();
    error AlreadyInitialized();
    error WrongPool();
    error StageLocked();
    error FeeOutOfBounds();
    error StepTooLarge();
    error CooldownActive();
    error AgentNotStale();
    error SynapseCapExceeded();
    error BadAction();
    error ZeroAddress();
    error PlatformFeeOutOfBounds();
    error Frozen();
    error TransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        Currency _token,
        address _platformFeeRecipient,
        uint256 _platformFeePpm,
        address _guardian,
        address _agent,
        address _buybackVault,
        address _treasury,
        address _liquidityVault
    ) {
        if (
            _platformFeeRecipient == address(0) || _guardian == address(0) || _agent == address(0)
                || _buybackVault == address(0) || _treasury == address(0) || _liquidityVault == address(0)
                || Currency.unwrap(_token) == address(0)
        ) revert ZeroAddress();
        if (_platformFeePpm == 0 || _platformFeePpm > MAX_PLATFORM_FEE_PPM) revert PlatformFeeOutOfBounds();

        Hooks.validateHookPermissions(this, getHookPermissions());

        poolManager = _poolManager;
        token = _token;
        platformFeeRecipient = _platformFeeRecipient;
        platformFeePpm = _platformFeePpm;
        guardian = _guardian;
        agent = _agent;
        buybackVault = _buybackVault;
        treasury = _treasury;
        liquidityVault = _liquidityVault;

        policy = Policy({feeBps: DEFAULT_FEE_BPS, updatedAt: uint64(block.timestamp), rationale: bytes32(0), epoch: 0});
    }

    receive() external payable {}

    // ================================================================== permissions
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ================================================================== growth
    /// @notice Stage the mind has earned from the chain's own measurements.
    function earnedStage() public view returns (uint8) {
        if (launchedAt == 0) return EMBRYO;
        uint256 age = block.timestamp - launchedAt;
        uint256 vol = cumulativeVolumeEth;
        if (age >= ADULT_AGE && vol >= ADULT_VOLUME) return ADULT;
        if (age >= CHILD_AGE && vol >= CHILD_VOLUME) return CHILD;
        if (age >= INFANT_AGE && vol >= INFANT_VOLUME) return INFANT;
        return NEWBORN;
    }

    /// @notice Stage in force right now: earned stage, minus one while grounded (never below Newborn).
    function stage() public view returns (uint8) {
        uint8 s = earnedStage();
        if (block.timestamp < groundedUntil && s > NEWBORN) s -= 1;
        return s;
    }

    /// @notice Guardrails for a stage: fee floor, ceiling, max step per change, cooldown.
    function stageParams(uint8 s) public pure returns (uint16 minFee, uint16 maxFee, uint16 step, uint32 cooldown) {
        if (s == ADULT) return (50, 300, 50, 1 hours);
        if (s == CHILD) return (50, 250, 50, 2 hours);
        if (s == INFANT) return (75, 150, 25, 6 hours);
        return (DEFAULT_FEE_BPS, DEFAULT_FEE_BPS, 0, 0); // Embryo / Newborn: locked
    }

    /// @notice Project fee actually charged: the agent's fee clamped to the current stage.
    function effectiveFeeBps() public view returns (uint16) {
        (uint16 lo, uint16 hi,,) = stageParams(stage());
        uint16 f = policy.feeBps;
        if (f < lo) return lo;
        if (f > hi) return hi;
        return f;
    }

    // ================================================================== reason (agent)
    /// @notice Move the project fee inside the current stage's guardrails.
    /// @param rationale hash of the agent's written reasoning (published off-chain, e.g. IPFS)
    function setPolicy(uint16 newFeeBps, bytes32 rationale) external onlyAgent {
        uint8 s = stage();
        if (s <= NEWBORN) revert StageLocked();
        (uint16 lo, uint16 hi, uint16 step, uint32 cooldown) = stageParams(s);
        if (newFeeBps < lo || newFeeBps > hi) revert FeeOutOfBounds();
        uint16 cur = effectiveFeeBps();
        uint16 diff = newFeeBps > cur ? newFeeBps - cur : cur - newFeeBps;
        if (diff > step) revert StepTooLarge();
        if (lastFeeChangeAt != 0 && block.timestamp < uint256(lastFeeChangeAt) + cooldown) revert CooldownActive();

        Policy memory p = policy;
        policy = Policy({feeBps: newFeeBps, updatedAt: uint64(block.timestamp), rationale: rationale, epoch: p.epoch + 1});
        lastFeeChangeAt = uint64(block.timestamp);
        emit PolicyUpdated(p.epoch + 1, s, cur, newFeeBps, rationale);
    }

    /// @notice Nightly sign of life: the hash of the day's dream journal. Allowed at every stage.
    function dream(bytes32 journalHash) external onlyAgent {
        policy.updatedAt = uint64(block.timestamp);
        policy.rationale = journalHash;
        emit Dream(uint64(block.timestamp / 1 days), journalHash);
    }

    /// @notice Once a night: the mood of the Dream of the Night decides where the mood pot goes.
    ///         Fees earned under the previous night's action are distributed first, so a new vote
    ///         never re-routes fees that were earned before it (and calling distribute() just
    ///         before the switch gains nothing).
    function setNightAction(uint8 action, bytes32 dreamHash) external onlyAgent {
        if (action > NIGHT_DEEPEN) revert BadAction();
        if (lastNightAt != 0 && block.timestamp < uint256(lastNightAt) + NIGHT_COOLDOWN) revert CooldownActive();
        _distribute();
        nightAction = action;
        nightDream = dreamHash;
        lastNightAt = uint64(block.timestamp);
        policy.updatedAt = uint64(block.timestamp);
        emit NightAction(uint64(block.timestamp / 1 days), action, dreamHash);
    }

    /// @notice Pay a holder whose idea the mind adopted. Capped per payment and per day.
    function rewardSynapse(address holder, uint256 amount, bytes32 ideaHash) external onlyAgent {
        if (holder == address(0)) revert ZeroAddress();
        uint64 today = uint64(block.timestamp / 1 days) + 1; // +1 so day numbering never collides with the unset value 0
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
        _send(holder, amount);
        emit SynapseFired(holder, amount, ideaHash, w);
    }

    /// @notice Reset the fee to 1% and ground the mind for 14 days.
    ///         Guardian at any time; anyone once the agent has been silent for 7 days.
    function safeMode() external {
        if (msg.sender != guardian) {
            if (block.timestamp < uint256(policy.updatedAt) + AGENT_STALE_AFTER) revert AgentNotStale();
        }
        policy.feeBps = DEFAULT_FEE_BPS;
        policy.updatedAt = uint64(block.timestamp);
        policy.epoch += 1;
        groundedUntil = uint64(block.timestamp + GROUNDED_FOR);
        emit SafeMode(msg.sender, groundedUntil);
    }

    // ================================================================== guardian admin
    function setAgent(address newAgent) external onlyGuardian {
        if (newAgent == address(0)) revert ZeroAddress();
        emit AgentChanged(agent, newAgent);
        agent = newAgent;
    }

    function setRecipients(address _buybackVault, address _treasury, address _liquidityVault) external onlyGuardian {
        if (_buybackVault == address(0) || _treasury == address(0) || _liquidityVault == address(0)) {
            revert ZeroAddress();
        }
        buybackVault = _buybackVault;
        treasury = _treasury;
        liquidityVault = _liquidityVault;
        emit RecipientsChanged(_buybackVault, _treasury, _liquidityVault);
    }

    /// @notice Hand the guardian role to a DAO, or to address(0) to renounce.
    function setGuardian(address newGuardian) external onlyGuardian {
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }

    function setMetadata(string calldata description_, string calldata website_, string calldata image_)
        external
        onlyGuardian
    {
        if (metadataFrozen) revert Frozen();
        _description = description_;
        _website = website_;
        _image = image_;
        emit MetadataUpdated(description_, website_, image_);
    }

    function freezeMetadata() external onlyGuardian {
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    // ================================================================== distribution
    /// @notice Split accrued project fees. Permissionless. The synapse share stays here.
    function distribute() external {
        _distribute();
    }

    function _distribute() internal {
        uint256 amount = accruedProjectFees;
        if (amount == 0) return;
        accruedProjectFees = 0;

        uint256 toMood = amount * SHARE_MOOD_BPS / BPS;
        uint256 toTreasury = amount * SHARE_TREASURY_BPS / BPS;
        uint256 toSynapse = amount - toMood - toTreasury;

        uint8 a = nightAction;
        if (a == NIGHT_REWARD) synapsePool += toSynapse + toMood;
        else synapsePool += toSynapse;
        _send(treasury, toTreasury);
        if (a == NIGHT_BURN) _send(buybackVault, toMood);
        else if (a == NIGHT_DEEPEN) _send(liquidityVault, toMood);
        emit Distributed(a, toMood, toTreasury, toSynapse);
    }

    // ================================================================== views
    /// @notice Effective project fee for a buy right now (fee + decaying launch flinch).
    function currentBuyFeeBps() public view returns (uint256) {
        uint256 fee = effectiveFeeBps();
        if (launchedAt != 0 && block.timestamp < uint256(launchedAt) + FLINCH_DURATION) {
            uint256 elapsed = block.timestamp - launchedAt;
            fee += uint256(FLINCH_START_BPS) * (FLINCH_DURATION - elapsed) / FLINCH_DURATION;
        }
        return fee;
    }

    function currentSellFeeBps() public view returns (uint256) {
        return effectiveFeeBps();
    }

    function quoteFees(uint256 ethAmount, bool isBuy) public view returns (uint256 platformFee, uint256 projectFee) {
        platformFee = ethAmount * platformFeePpm / PPM;
        uint256 bps = isBuy ? currentBuyFeeBps() : currentSellFeeBps();
        projectFee = ethAmount * bps / BPS;
    }

    // ---- Programmable Explore metadata -------------------------------------------------
    function name() external pure returns (string memory) {
        return "LUCID Hook";
    }

    function symbol() external pure returns (string memory) {
        return "LUCID";
    }

    function metadata()
        external
        view
        returns (string memory description, string memory website, string memory image, bytes memory extraData)
    {
        return (_description, _website, _image, abi.encode(stage(), effectiveFeeBps(), policy.epoch, policy.rationale));
    }

    // ================================================================== hook callbacks
    function beforeInitialize(address, PoolKey calldata key, uint160) external override onlyPoolManager returns (bytes4) {
        if (initialized) revert AlreadyInitialized();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != Currency.unwrap(token) || key.fee != 0) {
            revert WrongPool();
        }
        initialized = true;
        poolId = key.toId();
        launchedAt = uint64(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev ETH is currency0. ETH is the *specified* currency when (buy & exactIn) or
    ///      (sell & exactOut): the fee is taken here. Otherwise it is taken in afterSwap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();

        bool exactIn = params.amountSpecified < 0;
        bool isBuy = params.zeroForOne;
        bool ethSpecified = (isBuy && exactIn) || (!isBuy && !exactIn);
        if (!ethSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 ethBasis = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _takeFees(key.currency0, ethBasis, isBuy);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool exactIn = params.amountSpecified < 0;
        bool isBuy = params.zeroForOne;
        bool ethSpecified = (isBuy && exactIn) || (!isBuy && !exactIn);
        if (ethSpecified) return (IHooks.afterSwap.selector, 0);

        int128 amount0 = delta.amount0();
        uint256 ethBasis = amount0 >= 0 ? uint256(uint128(amount0)) : uint256(uint128(-amount0));
        uint256 fee = _takeFees(key.currency0, ethBasis, isBuy);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    // ---- unused callbacks (permissions disabled; revert defensively) --------------------
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ================================================================== internals
    function _takeFees(Currency eth, uint256 ethBasis, bool isBuy) internal returns (uint256 total) {
        (uint256 platformFee, uint256 projectFee) = quoteFees(ethBasis, isBuy);
        if (platformFee != 0) poolManager.take(eth, platformFeeRecipient, platformFee);
        if (projectFee != 0) poolManager.take(eth, address(this), projectFee);
        cumulativeVolumeEth += ethBasis;
        accruedProjectFees += projectFee;
        totalPlatformFeesPaid += platformFee;
        totalProjectFeesCollected += projectFee;
        emit FeesTaken(poolId, isBuy, ethBasis, platformFee, projectFee);
        return platformFee + projectFee;
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
