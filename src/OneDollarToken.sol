// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPancakeFactory, IPancakePair, IPancakeRouter02} from "./interfaces/IPancakeV2.sol";

interface IMintTreasury {
    function treasury() external view returns (address);
}

/// @dev PancakeSwap V2 `pair.swap` rejects `to == token0/token1`, so the token's own swapback cannot receive USDT
///      directly. This one-purpose receiver takes the USDT and hands it straight back to the token (only caller).
contract SwapReceiver {
    using SafeERC20 for IERC20;

    address public immutable token;

    constructor() {
        token = msg.sender;
    }

    function pull(IERC20 asset) external returns (uint256 amount) {
        require(msg.sender == token, "receiver: only token");
        amount = asset.balanceOf(address(this));
        if (amount > 0) asset.safeTransfer(token, amount);
    }
}

/// @title OneDollarToken — one dollar ($1) — agent-gated fair-mint on BNB Smart Chain (PancakeSwap V2, AGC-style tax)
/// @notice Fixed-cap ERC-20. Two authorised issuers under ONE hard cap, both wired once at init:
///           - `minter` = OneDollarMint  (Stage 1 GENESIS: paid + free shares, seeds + LOCKS the $1/USDT V2 LP at DEAD)
///           - `miner`  = OneDollarMine  (Stage 2 EMISSION: halving mine, Mode A + Mode B)
///         `mint` reverts past MAX_SUPPLY on every path. Before trading is enabled only `minter` can move
///         tokens (launch-phase lock: the only pre-open movement is the genesis seed minter -> pair), which
///         makes the anti-snipe open timestamp tamper-proof (no third party can seed the pair before genesis).
///
///         FEE = TRANSFER TAX ON THE PAIR (AGC pattern), 2% on BUY and SELL only (from == pair or to == pair).
///         Wallet<->wallet transfers are TAX-FREE. `minter`, `miner` and this contract are exempt (so the
///         genesis seed, the Mode-B protocol buy/LP-add and the swapback itself are untaxed).
///           - BUY  2.00% = 1.00% ops (-> treasury) + 1.00% auto-LP.
///           - SELL 2.00% = 1.00% ops + 1.00% auto-LP; in the first ANTISNIPE_WINDOW (120 s) after open:
///             30.00% = 29.00% ops + 1.00% auto-LP (sells only, buys unaffected, expires exactly at +120 s).
///         The tax is withheld in $1 inside this contract (opsTokens / lpTokens buckets) and REALIZED by a
///         CAPPED SWAPBACK on sells (operator-accepted bounded "dump", AGC-style): at most
///         min(SWAP_MAX, pair $1 reserve x SWAP_IMPACT_BPS) per sell is processed — the ops part is swapped
///         $1 -> USDT and sent to treasury; the LP part is half-swapped to USDT and paired with the kept $1,
///         `addLiquidity` to DEAD (permanently locked; there is no LP-removal path anywhere). Guarded by an
///         `inSwap` lock and try/catch so a failing swapback can never block a trade.
///
///         Supply (deterministic, price-independent), exact:
///           GENESIS  paid 10,000 x 4,000 = 40,000,000 · free 1,111 x 4,000 = 4,444,000 · pool 10,000 x 3,300 = 33,000,000
///           EMISSION A mint-base 400,000,000 · B reserve 522,556,000 · foundation 0
///           TOTAL = 1,000,000,000 == MAX_SUPPLY. Unused emission reserve is never minted.
contract OneDollarToken is ERC20 {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether; // 1B hard cap across BOTH issuers
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------- tax (operator-locked)
    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 200; // 2.00%
    uint256 public constant SELL_TAX_BPS = 200; // 2.00%
    uint256 public constant ANTISNIPE_SELL_BPS = 3_000; // 30.00% on sells in the window
    uint256 public constant ANTISNIPE_WINDOW = 120 seconds;
    uint256 public constant LP_BPS = 100; // 1.00% of every taxed transfer -> auto-LP (locked at DEAD)
    // ops share = tax - LP share (1.00% normally, 29.00% in the anti-snipe window) -> treasury as USDT
    uint256 public constant SWAP_MAX = 500_000 ether; // hard cap of $1 processed per swapback
    uint256 public constant SWAP_IMPACT_BPS = 200; // and at most 2% of the pair's $1 reserve per swapback
    uint256 public constant MIN_SWAPBACK = 1_000 ether; // skip dust swapbacks

    IERC20 public immutable usdt; // quote / settlement (BSC USDT, 18-dec)
    IPancakeRouter02 public immutable router; // PancakeSwap V2 router
    address public immutable pair; // the official $1/USDT V2 pair (created in the constructor)
    SwapReceiver public immutable receiver; // catches swapback USDT (V2 forbids the token itself as swap `to`)

    address public deployer;
    address public minter; // genesis (Stage 1)
    address public miner; // emission (Stage 2)
    address public treasury;
    bool public tradingEnabled;
    uint256 public tradingOpenedAt;
    bool public blocksDisabled;
    mapping(address => bool) public blockedPool;

    uint256 public opsTokens; // withheld $1 earmarked for treasury (realized as USDT by swapback)
    uint256 public lpTokens; // withheld $1 earmarked for auto-LP (locked at DEAD by swapback)
    uint256 public lpUsdtCarry; // LP-side USDT dust carried to the next swapback
    uint256 public totalOpsUsdt; // USDT delivered to treasury by swapbacks (lifetime)
    uint256 public totalLpLocked; // V2 LP tokens minted to DEAD by swapbacks (lifetime)
    bool private _inSwap;

    event TradingEnabled(uint256 at);
    event PoolBlocked(address indexed pool, bool blocked);
    event BlocksDisabled();
    event TaxTaken(address indexed from, address indexed to, bool isSell, uint256 opsPart, uint256 lpPart);
    event SwapBack(uint256 tokensSwapped, uint256 usdtToTreasury, uint256 lpTokensLocked);

    error NotDeployer();
    error NotMinter();
    error NotIssuer();
    error NotSelf();
    error AlreadyInitialized();
    error ZeroAddress();
    error TransfersClosed();
    error PoolRejected();
    error SupplyCap();

    constructor(address usdt_, address router_) ERC20("one dollar", "$1") {
        if (usdt_ == address(0) || router_ == address(0)) revert ZeroAddress();
        usdt = IERC20(usdt_);
        router = IPancakeRouter02(router_);
        pair = IPancakeFactory(IPancakeRouter02(router_).factory()).createPair(address(this), usdt_);
        receiver = new SwapReceiver();
        deployer = msg.sender;
    }

    /// @notice One-time wiring of BOTH issuers; clears the deployer afterwards.
    function initialize(address minter_, address miner_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (minter != address(0)) revert AlreadyInitialized();
        if (minter_ == address(0) || miner_ == address(0)) revert ZeroAddress();
        minter = minter_;
        miner = miner_;
        deployer = address(0);
        address t = IMintTreasury(minter_).treasury();
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    /// @notice Issuance: genesis mint OR emission mine, both under the single 1B cap.
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter && msg.sender != miner) revert NotIssuer();
        if (totalSupply() + amount > MAX_SUPPLY) revert SupplyCap();
        _mint(to, amount);
    }

    function enableTrading() external onlyMinter {
        if (tradingEnabled) return;
        tradingEnabled = true;
        tradingOpenedAt = block.timestamp;
        emit TradingEnabled(block.timestamp);
    }

    /// @notice Burns from `holder` — only the genesis mint, only to un-mint a refunded pre-open stake.
    function burnFromHolder(address holder, uint256 amount) external onlyMinter {
        _burn(holder, amount);
    }

    /// @notice Burn your own tokens once trading is enabled.
    function burn(uint256 amount) external {
        if (!tradingEnabled) revert TransfersClosed();
        _burn(msg.sender, amount);
    }

    function setPoolBlocked(address pool, bool blocked) external onlyMinter {
        if (pool == pair) revert PoolRejected(); // the official venue can never be blocked
        blockedPool[pool] = blocked;
        emit PoolBlocked(pool, blocked);
    }

    function disableBlocks() external onlyMinter {
        blocksDisabled = true;
        emit BlocksDisabled();
    }

    // ------------------------------------------------------------- views
    function rejects(address to) public view returns (bool) {
        if (to == pair) return false;
        if (blockedPool[to] && !blocksDisabled) return true;
        return false;
    }

    function antiSnipeActive() public view returns (bool) {
        return tradingEnabled && block.timestamp < tradingOpenedAt + ANTISNIPE_WINDOW;
    }

    function inSwap() external view returns (bool) {
        return _inSwap;
    }

    /// @notice $1 the next swapback may process: min(SWAP_MAX, pair $1 reserve x 2%).
    function swapCap() public view returns (uint256 cap) {
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        uint256 tokenReserve = IPancakePair(pair).token0() == address(this) ? uint256(r0) : uint256(r1);
        cap = tokenReserve * SWAP_IMPACT_BPS / BPS;
        if (cap > SWAP_MAX) cap = SWAP_MAX;
    }

    // ------------------------------------------------------------- transfers (tax on the pair only)
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value); // mint / burn
            return;
        }
        if (!tradingEnabled) {
            if (from != minter) revert TransfersClosed(); // launch phase: only the genesis mint moves tokens
            super._update(from, to, value);
            return;
        }
        if (rejects(to)) revert PoolRejected();

        bool isBuy = from == pair;
        bool isSell = to == pair;
        bool exempt = _inSwap || from == minter || to == minter || from == miner || to == miner
            || from == address(this) || to == address(this);
        if (exempt || (!isBuy && !isSell)) {
            super._update(from, to, value); // wallet <-> wallet and protocol legs: tax-free
            return;
        }

        if (isSell) _swapBack(); // realize withheld tax (bounded) before the sell lands

        uint256 taxBps = isSell ? (antiSnipeActive() ? ANTISNIPE_SELL_BPS : SELL_TAX_BPS) : BUY_TAX_BPS;
        uint256 tax = value * taxBps / BPS;
        if (tax > 0) {
            uint256 lpPart = value * LP_BPS / BPS;
            uint256 opsPart = tax - lpPart;
            opsTokens += opsPart;
            lpTokens += lpPart;
            super._update(from, address(this), tax);
            emit TaxTaken(from, to, isSell, opsPart, lpPart);
        }
        super._update(from, to, value - tax);
    }

    // ------------------------------------------------------------- capped swapback (bounded, try/catch)
    function _swapBack() private {
        uint256 bal = opsTokens + lpTokens;
        if (bal < MIN_SWAPBACK) return;
        uint256 cap = swapCap();
        uint256 amt = bal > cap ? cap : bal;
        if (amt == 0) return;
        _inSwap = true;
        try this.swapBackExec(amt) {} catch {}
        _inSwap = false;
    }

    /// @dev Self-call target so a failing swapback reverts in isolation (try/catch) and never blocks a trade.
    function swapBackExec(uint256 amt) external {
        if (msg.sender != address(this)) revert NotSelf();
        uint256 bal = opsTokens + lpTokens;
        uint256 lpPart = amt * lpTokens / bal;
        uint256 opsPart = amt - lpPart;
        uint256 lpKeep = lpPart / 2;
        uint256 toSwap = opsPart + (lpPart - lpKeep);

        // 1. the "dump": a bounded $1 -> USDT market sell of the ops part + half the LP part
        uint256 got;
        if (toSwap > 0) {
            _approve(address(this), address(router), toSwap);
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = address(usdt);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(toSwap, 0, path, address(receiver), block.timestamp);
            got = receiver.pull(usdt);
        }
        uint256 opsUsdt = toSwap == 0 ? 0 : got * opsPart / toSwap;
        uint256 lpUsdt = got - opsUsdt + lpUsdtCarry;
        lpUsdtCarry = 0;

        // 2. ops -> treasury as USDT
        if (opsUsdt > 0) usdt.safeTransfer(treasury, opsUsdt);

        // 3. LP: kept $1 + its USDT -> addLiquidity to DEAD (permanently locked)
        uint256 liq;
        uint256 usedT;
        uint256 usedU;
        if (lpKeep > 0 && lpUsdt > 0) {
            _approve(address(this), address(router), lpKeep);
            usdt.forceApprove(address(router), lpUsdt);
            (usedT, usedU, liq) = router.addLiquidity(
                address(this), address(usdt), lpKeep, lpUsdt, 0, 0, DEAD, block.timestamp
            );
        }
        opsTokens -= opsPart;
        lpTokens = lpTokens - lpPart + (lpKeep - usedT); // un-used kept $1 stays earmarked for LP
        lpUsdtCarry = lpUsdt - usedU;
        totalOpsUsdt += opsUsdt;
        totalLpLocked += liq;
        emit SwapBack(toSwap, opsUsdt, liq);
    }
}
