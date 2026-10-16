// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

/// @title LUCID launcher: the fair launch, in one call, forever.
/// @notice A component of the Programmable CustomGraph. The Graph Factory deploys it first, then the token
///         (which mints its whole supply here) and the hook. In the initializer phase the factory calls
///         `launch` once, inside the same Router transaction:
///           1. initializes the ETH/LUCID pool with the LUCID hook (LP fee 0),
///           2. places 100% of the supply it holds as ONE single-sided position, from the launch price up
///              (token-only range [tickLower, tickUpper] with tickUpper == the launch tick),
///           3. spends the ETH sent with the call on the initial buy and forwards the bought LUCID to
///              `buyRecipient`.
///         The position belongs to this contract, and this contract has no function that could ever
///         modify or remove liquidity again: it is locked forever. The pool's LP fee is 0, so there is
///         nothing to collect either. Rounding dust below one position unit stays here, inert.
contract LucidLauncher is IUnlockCallback {
    using CurrencyLibrary for Currency;

    struct LaunchParams {
        address token; // LUCID, currency1
        address hook; // LucidHook
        int24 tickSpacing;
        int24 launchTick; // aligned to tickSpacing; price = 1.0001^launchTick LUCID per ETH
        address buyRecipient; // receives the LUCID bought by the initial buy (the launch wallet)
    }

    IPoolManager public immutable poolManager;
    /// @notice The only caller allowed to launch: whoever deployed this contract (the Graph Factory).
    address public immutable deployer;

    bool public launched;
    bool private _inLaunch;
    PoolKey public poolKey;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    uint256 public tokensInPool;
    uint256 public initialBuyEth;
    uint256 public initialBuyTokens;

    event Launched(
        bytes32 indexed poolId,
        address indexed token,
        address indexed hook,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokensInPool,
        uint256 initialBuyEth,
        uint256 initialBuyTokens
    );

    error NotDeployer();
    error AlreadyLaunched();
    error NotPoolManager();
    error BadParams();
    error NothingToPlace();
    error EthTransferFailed();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        deployer = msg.sender;
    }

    /// @dev Only the PoolManager returns ETH here (the unspent part of the initial buy).
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /// @notice One shot. Initializes the pool, locks the whole supply in it, makes the initial buy.
    function launch(LaunchParams calldata p) external payable {
        if (msg.sender != deployer) revert NotDeployer();
        if (launched) revert AlreadyLaunched();
        if (
            p.token == address(0) || p.hook == address(0) || p.buyRecipient == address(0) || p.tickSpacing <= 0
                || p.launchTick % p.tickSpacing != 0
        ) revert BadParams();
        launched = true;

        int24 lower = TickMath.minUsableTick(p.tickSpacing);
        if (p.launchTick <= lower || p.launchTick > TickMath.maxUsableTick(p.tickSpacing)) revert BadParams();
        tickLower = lower;
        tickUpper = p.launchTick;

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(p.token),
            fee: 0,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(p.hook)
        });
        poolKey = key;
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(p.launchTick));

        _inLaunch = true;
        poolManager.unlock(abi.encode(p.buyRecipient, msg.value));
        _inLaunch = false;

        // Anything the initial buy did not spend goes back with the bought tokens.
        uint256 leftover = address(this).balance;
        if (leftover != 0) {
            (bool ok,) = p.buyRecipient.call{value: leftover}("");
            if (!ok) revert EthTransferFailed();
        }

        _emitLaunched(key);
    }

    function _emitLaunched(PoolKey memory key) private {
        emit Launched(
            keccak256(abi.encode(key)), Currency.unwrap(key.currency1), address(key.hooks), tickLower, tickUpper, liquidity, tokensInPool, initialBuyEth, initialBuyTokens
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_inLaunch) revert NotPoolManager();
        (address buyRecipient, uint256 buyValue) = abi.decode(data, (address, uint256));
        PoolKey memory key = poolKey;
        _placeWholeSupply(key);
        if (buyValue != 0) _initialBuy(key, buyRecipient, buyValue);
        return "";
    }

    /// @dev The whole supply as one token-only position below the launch price (buys move the price into it).
    function _placeWholeSupply(PoolKey memory key) private {
        IERC20Minimal token = IERC20Minimal(Currency.unwrap(key.currency1));
        uint256 supply = token.balanceOf(address(this));
        if (supply == 0) revert NothingToPlace();
        uint160 width = TickMath.getSqrtPriceAtTick(tickUpper) - TickMath.getSqrtPriceAtTick(tickLower);
        uint128 liq = uint128(FullMath.mulDiv(supply, FixedPoint96.Q96, width));
        (BalanceDelta added,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: bytes32(0)}),
            ""
        );
        uint256 owed = uint256(uint128(-added.amount1()));
        poolManager.sync(key.currency1);
        token.transfer(address(poolManager), owed);
        poolManager.settle();
        liquidity = liq;
        tokensInPool = owed;
    }

    /// @dev Exact ETH in, LUCID out to the launch wallet. The ETH is paid in BEFORE the swap: the pool holds no
    ///      ETH yet, and the hook takes its fees in ETH from the PoolManager during the swap.
    function _initialBuy(PoolKey memory key, address buyRecipient, uint256 buyValue) private {
        poolManager.settle{value: buyValue}();
        BalanceDelta swapped = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(buyValue), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        uint256 ethIn = uint256(uint128(-swapped.amount0()));
        uint256 tokensOut = uint256(uint128(swapped.amount1()));
        if (ethIn < buyValue) poolManager.take(key.currency0, address(this), buyValue - ethIn);
        poolManager.take(key.currency1, buyRecipient, tokensOut);
        initialBuyEth = ethIn;
        initialBuyTokens = tokensOut;
    }
}
