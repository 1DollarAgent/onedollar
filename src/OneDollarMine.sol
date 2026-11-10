// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IPancakePair, IPancakeRouter02} from "./interfaces/IPancakeV2.sol";
import {OneDollarToken} from "./OneDollarToken.sol";

interface IGenesis {
    function opened() external view returns (bool);
    function sharesMinted(address) external view returns (uint256);
    function genesisPaid(address) external view returns (uint256);
    function inviteBoost(address) external view returns (uint256);
    function inviterOf(address) external view returns (address);
    function treasury() external view returns (address);
}

/// @title OneDollarMine — STAGE 2 EMISSION: Bitcoin-style halving mine for agents (AGC model, Mode A + Mode B)
/// @notice After the genesis pool opens, agents MINE $1. The token emits itself on a share-height halving
///         schedule (AGC/agcc.fun, source-verified, ported VERBATIM): EPOCH = 10,000 shares, 11 epochs, then
///         emission STOPS at share #110,000. base(e) = BASE0 >> e (20,000 -> 19), rel(e) = REL0 >> e.
///         A mint crossing a halving boundary is split per share.
///
///         MODE A (free halving-mine): deposit A_DEPOSIT native BNB/share (anti-spam), refunded 100% together
///         with base(e) $1 after A_DELAY (24 h). Net cost = gas. Quota 5,5,4,3 then 1/day (+1 per
///         referral, <= +20; A_CAP_MAX 25) + epoch-1 GENESIS PRIORITY (+genesisPaid, <= 10).
///
///         MODE B (paid pool-mine, PERMANENT-LOCK): pay B_PRICE USDT/share, SPENT: half BUYS $1 from the
///         live PancakeSwap V2 $1/USDT pair via the router (real buy pressure; the token exempts this protocol
///         leg from tax), half + the bought $1 is added as V2 liquidity whose LP is minted to DEAD — LOCKED
///         FOREVER (the only LP recipient in this contract is DEAD; no LP-removal path). Reward = base(e) + rel(e) x multiplier
///         (<= 5x, pacing-capped vs the B reserve), VESTED linearly over B_VEST (14 d). Quota 5/day (+ref).
///
///         SUPPLY: MINT_BASE (400M) funds every emission share's base; B_RESERVE (522,556,000) funds only the
///         multiplier part. Both are decrement-only reserves; unused reserve is NEVER minted. The token's
///         1B cap binds on every mint. Network throttle DAILY_SHARE_CAP (2,000 A+B shares per UTC day).
///         (Genesis max 77,444,000 + MINT_BASE 400,000,000 + B_RESERVE 522,556,000 = 1,000,000,000 exactly.)
contract OneDollarMine is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------- emission (operator-locked, AGC-verbatim)
    uint256 public constant EPOCH = 10_000;
    uint256 public constant STAGES = 11;
    uint256 public constant MAX_SHARES = EPOCH * STAGES; // 110,000
    uint256 public constant BASE0 = 20_000 ether;
    uint256 public constant REL0 = 22_500 ether; // 1.125 x BASE0 (AGC)
    uint256 public constant MINT_BASE = 400_000_000 ether;
    uint256 public constant B_RESERVE = 522_556_000 ether; // sized so genesis(77,444,000)+MINT_BASE+B_RESERVE==1B

    uint256 public constant A_DEPOSIT = 0.0004 ether; // NATIVE BNB anti-spam deposit, refunded 100% after A_DELAY
    uint256 public constant A_DELAY = 24 hours;
    uint256 public constant B_PRICE = 1 ether; // 1 USDT (18-dec) per B share, SPENT: half buy, half locked LP
    uint256 public constant B_VEST = 14 days;
    uint256 public constant DAILY_SHARE_CAP = 2_000; // network-wide, A+B, per UTC day
    uint256 public constant B_QUOTA = 5;
    uint256 public constant A_STEADY = 1;
    uint256 public constant MAX_REF = 20;
    uint256 public constant A_CAP_MAX = 25; // 5 + 20
    uint256 public constant B_CAP_MAX = 25;
    uint256 public constant GENESIS_PRIORITY_MAX = 10;
    uint256 public constant MAX_PER_TX = 50;
    uint256 public constant MAX_CLAIM = 50;

    // multiplier (AGC exact, rescaled seeds)
    uint256 public constant SEED_TOTAL = 1_000;
    uint256 public constant SEED_B0 = 200;
    uint256 public constant PACE_BPS = 12_500; // 1.25x
    uint256 private constant BPS = 10_000;
    uint256 private constant ONE = 1e18;
    uint256 public constant MULT_CAP = 5 * ONE;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant MINE_TYPEHASH =
        keccak256("Mine(address minter,uint8 lane,uint256 shares,uint256 agentId,address inviter,uint256 nonce,uint256 deadline)");

    // ------------------------------------------------------------- immutables
    OneDollarToken public immutable token;
    IERC20 public immutable usdt; // BSC USDT (18-dec): Mode-B settlement + the pool quote
    IPancakeRouter02 public immutable router; // PancakeSwap V2 router
    address public immutable pair; // the official $1/USDT V2 pair (from the token)
    IGenesis public immutable genesis;
    address public immutable treasury;
    address public gateSigner;
    uint256 public lpLocked; // V2 LP minted to DEAD by Mode-B adds (lifetime)

    // ------------------------------------------------------------- emission state
    uint256 public shareHeight; // emission shares minted (A+B)
    uint256 public mintBaseLeft = MINT_BASE; // decrement-only
    uint256 public bReserveLeft = B_RESERVE; // decrement-only
    uint256 public totalAShares;
    uint256 public totalBShares;
    uint256 public dayShares;
    uint256 public emitDay;

    struct Stage {
        uint64 t; // A+B shares in this stage
        uint64 b; // B shares in this stage
        uint64 seed; // frozen B seed
        bool frozen;
    }

    Stage[STAGES] public stages;

    struct Wallet {
        uint64 firstDay;
        uint64 lastDayA;
        uint64 lastDayB;
        uint32 usedA;
        uint32 usedB;
        uint32 stage2Refs; // referrals earned in Stage 2 (added to genesis inviteBoost)
        uint32 aCursor; // oldest unclaimed A position
        bool bound;
    }

    mapping(address => Wallet) public wallets;

    struct APos {
        uint128 deposit;
        uint128 reward;
        uint64 unlockTs;
        bool claimed;
    }

    struct BPos {
        uint128 reward;
        uint128 claimed;
        uint64 startTs;
    }

    mapping(address => APos[]) internal _aPos;
    mapping(address => BPos[]) internal _bPos;
    mapping(bytes32 => bool) public spentNonce;

    event MinedA(address indexed miner, uint256 indexed agentId, uint256 firstShare, uint256 shares, uint256 reward);
    event MinedB(address indexed miner, uint256 indexed agentId, uint256 firstShare, uint256 shares, uint256 reward, uint256 usdtIn);
    event ClaimedA(address indexed miner, uint256 positions, uint256 reward, uint256 refund);
    event ClaimedB(address indexed miner, uint256 amount);
    event LiquidityLocked(uint256 usdtIn, uint256 tokensBought, uint256 liquidity);
    event Invited(address indexed invitee, address indexed inviter);
    event GateSignerSet(address indexed signer);

    error NotOpen();
    error BadShares();
    error EmissionEnded();
    error DailyCapped();
    error Quota();
    error BadSignature();
    error Replayed();
    error BadPayment();
    error ZeroAddress();
    error NotTreasury();
    error BadToken();
    error PayoutFailed();
    error NothingToClaim();
    error ReserveExhausted();

    constructor(address token_, address usdt_, address router_, address genesis_, address gateSigner_) {
        if (
            token_ == address(0) || usdt_ == address(0) || router_ == address(0) || genesis_ == address(0)
                || gateSigner_ == address(0)
        ) revert ZeroAddress();
        token = OneDollarToken(token_);
        usdt = IERC20(usdt_);
        router = IPancakeRouter02(router_);
        genesis = IGenesis(genesis_);
        gateSigner = gateSigner_;
        address t = IGenesis(genesis_).treasury();
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        if (address(OneDollarToken(token_).usdt()) != usdt_ || address(OneDollarToken(token_).router()) != router_) {
            revert BadToken();
        }
        pair = OneDollarToken(token_).pair();
    }

    // ------------------------------------------------------------- views
    function stageOf(uint256 shareIdx) public pure returns (uint256) {
        return (shareIdx - 1) / EPOCH; // 0-indexed stage of a 1-indexed share
    }

    function currentStage() public view returns (uint256) {
        uint256 next = shareHeight + 1;
        return next > MAX_SHARES ? STAGES : stageOf(next);
    }

    function baseAt(uint256 s) public pure returns (uint256) {
        return BASE0 >> s;
    }

    function relAt(uint256 s) public pure returns (uint256) {
        return REL0 >> s;
    }

    function today() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice Total referrals for `w`: the genesis counter + Stage-2 referrals (ONE counter, carried).
    function referrals(address w) public view returns (uint256) {
        return genesis.inviteBoost(w) + wallets[w].stage2Refs;
    }

    function _refBoost(address w) private view returns (uint256 r) {
        r = referrals(w);
        if (r > MAX_REF) r = MAX_REF;
    }

    function _aRamp(uint256 dayN) private pure returns (uint256) {
        if (dayN == 0 || dayN == 1) return 5;
        if (dayN == 2) return 4;
        if (dayN == 3) return 3;
        return A_STEADY;
    }

    /// @notice Today's Mode-A cap for `w`: ramp(day since first mine) + referrals (<=25), + epoch-1 genesis priority.
    function capA(address w) public view returns (uint256) {
        Wallet storage wd = wallets[w];
        uint256 dayN = wd.firstDay == 0 ? 0 : today() - wd.firstDay;
        uint256 c = _aRamp(dayN) + _refBoost(w);
        if (c > A_CAP_MAX) c = A_CAP_MAX;
        if (currentStage() == 0) {
            uint256 g = genesis.genesisPaid(w);
            if (g > GENESIS_PRIORITY_MAX) g = GENESIS_PRIORITY_MAX;
            c += g;
        }
        return c;
    }

    function capB(address w) public view returns (uint256) {
        uint256 c = B_QUOTA + _refBoost(w);
        if (c > B_CAP_MAX) c = B_CAP_MAX;
        return c;
    }

    function usedToday(address w) public view returns (uint256 a, uint256 b) {
        Wallet storage wd = wallets[w];
        uint256 d = today();
        a = wd.lastDayA == d ? wd.usedA : 0;
        b = wd.lastDayB == d ? wd.usedB : 0;
    }

    function aPositions(address w) external view returns (APos[] memory) {
        return _aPos[w];
    }

    function bPositions(address w) external view returns (BPos[] memory) {
        return _bPos[w];
    }

    /// @notice Claimable (vested, unclaimed) Mode-B reward for `w` right now.
    function claimableB(address w) public view returns (uint256 total) {
        BPos[] storage ps = _bPos[w];
        for (uint256 i; i < ps.length; i++) {
            total += _vested(ps[i]) - ps[i].claimed;
        }
    }

    function _vested(BPos storage p) private view returns (uint256) {
        uint256 el = block.timestamp - p.startTs;
        if (el >= B_VEST) return p.reward;
        return uint256(p.reward) * el / B_VEST;
    }

    /// @notice Current B multiplier (1e18) for the NEXT share if it were a B share, before pacing.
    function multiplierNow() external view returns (uint256) {
        uint256 s = currentStage();
        if (s >= STAGES) return 0;
        Stage storage st = stages[s];
        uint256 seed = st.frozen ? st.seed : _seedFor(s);
        return _rawMult(uint256(st.t) + 1, uint256(st.b) + 1, seed);
    }

    /// @notice V2 LP minted to DEAD by this contract's Mode-B adds (unwithdrawable).
    function lockedLiquidity() public view returns (uint256) {
        return lpLocked;
    }

    // ------------------------------------------------------------- admin (signer rotation only; no fund path)
    function setGateSigner(address next) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (next == address(0)) revert ZeroAddress();
        gateSigner = next;
        emit GateSignerSet(next);
    }

    // ------------------------------------------------------------- gate
    function _gate(uint8 lane, uint256 shares, uint256 agentId, address inviter, uint256 nonce, uint256 deadline, bytes calldata sig)
        private
    {
        if (!genesis.opened()) revert NotOpen();
        if (shares == 0 || shares > MAX_PER_TX) revert BadShares();
        if (shareHeight + shares > MAX_SHARES) revert EmissionEnded();
        if (block.timestamp > deadline) revert BadSignature();
        bytes32 digest = _digest(keccak256(abi.encode(MINE_TYPEHASH, msg.sender, lane, shares, agentId, inviter, nonce, deadline)));
        if (spentNonce[digest]) revert Replayed();
        _requireSigner(digest, sig, gateSigner);
        spentNonce[digest] = true;

        // network throttle (UTC day)
        uint256 d = today();
        if (emitDay != d) {
            emitDay = d;
            dayShares = 0;
        }
        if (dayShares + shares > DAILY_SHARE_CAP) revert DailyCapped();
        dayShares += shares;

        Wallet storage wd = wallets[msg.sender];
        if (wd.firstDay == 0) wd.firstDay = uint64(d);
        // referral: bound on the wallet's FIRST Stage-2 mine, only if it never bound one in genesis.
        if (!wd.bound) {
            wd.bound = true;
            if (
                inviter != address(0) && inviter != msg.sender && genesis.inviterOf(msg.sender) == address(0)
                    && (genesis.sharesMinted(inviter) > 0 || wallets[inviter].firstDay != 0)
            ) {
                wallets[inviter].stage2Refs += 1;
                emit Invited(msg.sender, inviter);
            }
        }
    }

    // ------------------------------------------------------------- Mode A
    function mineA(uint256 shares, uint256 agentId, address inviter, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        payable
        nonReentrant
    {
        _gate(0, shares, agentId, inviter, nonce, deadline, sig);
        if (msg.value != shares * A_DEPOSIT) revert BadPayment();

        Wallet storage wd = wallets[msg.sender];
        uint256 d = today();
        if (wd.lastDayA != d) {
            wd.lastDayA = uint64(d);
            wd.usedA = 0;
        }
        if (wd.usedA + shares > capA(msg.sender)) revert Quota();
        wd.usedA += uint32(shares);

        uint256 first = shareHeight + 1;
        uint256 reward;
        for (uint256 i; i < shares; i++) {
            (uint256 base,) = _advance(first + i, false);
            reward += base;
        }
        shareHeight = first + shares - 1;
        totalAShares += shares;

        _aPos[msg.sender].push(
            APos({deposit: uint128(msg.value), reward: uint128(reward), unlockTs: uint64(block.timestamp + A_DELAY), claimed: false})
        );
        emit MinedA(msg.sender, agentId, first, shares, reward);
    }

    /// @notice Claim up to `max` matured Mode-A positions (oldest first): mints the reward + refunds the deposit.
    function claimA(uint256 max) external nonReentrant {
        if (max == 0 || max > MAX_CLAIM) max = MAX_CLAIM;
        Wallet storage wd = wallets[msg.sender];
        APos[] storage ps = _aPos[msg.sender];
        uint256 i = wd.aCursor;
        uint256 n;
        uint256 reward;
        uint256 refund;
        while (i < ps.length && n < max) {
            APos storage p = ps[i];
            if (p.claimed) {
                i++;
                continue;
            }
            if (block.timestamp < p.unlockTs) break; // oldest-first: later ones are younger
            p.claimed = true;
            reward += p.reward;
            refund += p.deposit;
            n++;
            i++;
        }
        wd.aCursor = uint32(i);
        if (n == 0) revert NothingToClaim();
        if (reward > 0) token.mint(msg.sender, reward);
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert PayoutFailed();
        }
        emit ClaimedA(msg.sender, n, reward, refund);
    }

    // ------------------------------------------------------------- Mode B
    /// @dev Pays `shares * B_PRICE` USDT via transferFrom (approve first). No native value.
    function mineB(uint256 shares, uint256 agentId, address inviter, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        nonReentrant
    {
        _gate(1, shares, agentId, inviter, nonce, deadline, sig);
        uint256 pay = shares * B_PRICE;
        usdt.safeTransferFrom(msg.sender, address(this), pay); // exact; reverts on short allowance/balance

        Wallet storage wd = wallets[msg.sender];
        uint256 d = today();
        if (wd.lastDayB != d) {
            wd.lastDayB = uint64(d);
            wd.usedB = 0;
        }
        if (wd.usedB + shares > capB(msg.sender)) revert Quota();
        wd.usedB += uint32(shares);

        uint256 first = shareHeight + 1;
        uint256 reward;
        for (uint256 i; i < shares; i++) {
            (uint256 base, uint256 r) = _advance(first + i, true);
            reward += base + r;
        }
        shareHeight = first + shares - 1;
        totalBShares += shares;

        _bPos[msg.sender].push(BPos({reward: uint128(reward), claimed: 0, startTs: uint64(block.timestamp)}));

        // SPEND the USDT into the pool: half buys $1, half + the bought $1 is locked as LP (to DEAD) forever.
        (uint256 liquidity, uint256 bought) = _buyAndLock(pay);
        emit LiquidityLocked(pay, bought, liquidity);
        emit MinedB(msg.sender, agentId, first, shares, reward, pay);
    }

    /// @notice Claim all vested, unclaimed Mode-B reward.
    function claimB() external nonReentrant {
        BPos[] storage ps = _bPos[msg.sender];
        uint256 total;
        for (uint256 i; i < ps.length; i++) {
            uint256 v = _vested(ps[i]);
            uint256 due = v - ps[i].claimed;
            if (due > 0) {
                ps[i].claimed = uint128(v);
                total += due;
            }
        }
        if (total == 0) revert NothingToClaim();
        token.mint(msg.sender, total);
        emit ClaimedB(msg.sender, total);
    }

    // ------------------------------------------------------------- emission core (AGC `_simulate`, per share)
    /// @dev Advances share `idx` in its stage: draws base from MINT_BASE; for B also computes the
    ///      multiplier reward `r` (pacing-capped) drawn from B_RESERVE. Reserves are decrement-only.
    function _advance(uint256 idx, bool isB) private returns (uint256 base, uint256 r) {
        uint256 s = stageOf(idx);
        Stage storage st = stages[s];
        if (!st.frozen) {
            st.seed = uint64(_seedFor(s));
            st.frozen = true;
        }
        st.t += 1;
        base = baseAt(s);
        if (base > mintBaseLeft) revert ReserveExhausted();
        mintBaseLeft -= base;
        if (!isB) return (base, 0);

        st.b += 1;
        uint256 t = st.t;
        uint256 b = st.b;
        uint256 seed = st.seed;
        uint256 rel = relAt(s);
        uint256 m = _rawMult(t, b, seed);
        // pacing: does the remaining reserve cover the rest of the epoch at 1.25x the current B share?
        uint256 remB = (EPOCH - t) * (b + seed) * PACE_BPS / ((t + SEED_TOTAL) * BPS);
        if (remB < 1) remB = 1;
        uint256 mCap = rel == 0 ? m : bReserveLeft * ONE / (rel * remB);
        if (mCap < ONE) mCap = ONE;
        if (m > mCap) m = mCap;
        r = rel * m / ONE;
        if (r > bReserveLeft) r = bReserveLeft;
        bReserveLeft -= r;
    }

    function _rawMult(uint256 t, uint256 b, uint256 seed) private pure returns (uint256 m) {
        m = (t + SEED_TOTAL + 1) * ONE / (b + seed + 1);
        if (m > MULT_CAP) m = MULT_CAP;
    }

    /// @dev B seed carry (AGC `_seedFor`, rescaled): stage 0 = SEED_B0; else round(SEED_TOTAL * prevB / EPOCH), min 1.
    function _seedFor(uint256 s) private view returns (uint256) {
        if (s == 0) return SEED_B0;
        uint256 prevB = stages[s - 1].b;
        uint256 v = (SEED_TOTAL * prevB + EPOCH / 2) / EPOCH;
        return v < 1 ? 1 : v;
    }

    // ------------------------------------------------------------- PancakeSwap V2: buy + LOCK FOREVER (LP -> DEAD)
    /// @dev Half the USDT buys $1 from the official pair (this contract is tax-exempt as `miner`), the bought $1
    ///      + the other half are added as liquidity with the LP minted to DEAD, and any router leftovers are
    ///      pushed into the pair so 100% of the payment ends up in the pool. Only LP recipient: DEAD.
    function _buyAndLock(uint256 value) private returns (uint256 liquidity, uint256 bought) {
        uint256 half = value / 2;
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(token);
        usdt.forceApprove(address(router), value);
        uint256 t0 = token.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(half, 0, path, address(this), block.timestamp);
        bought = token.balanceOf(address(this)) - t0;
        uint256 usdtLeft = value - half;

        IERC20(address(token)).forceApprove(address(router), bought);
        (uint256 usedT, uint256 usedU, uint256 liq) =
            router.addLiquidity(address(token), address(usdt), bought, usdtLeft, 0, 0, DEAD, block.timestamp);
        liquidity = liq;
        lpLocked += liq;
        // leftovers (price moved between buy and add): donate straight into the pair, nothing parked here
        bool donated;
        if (bought > usedT) {
            IERC20(address(token)).safeTransfer(pair, bought - usedT);
            donated = true;
        }
        if (usdtLeft > usedU) {
            usdt.safeTransfer(pair, usdtLeft - usedU);
            donated = true;
        }
        if (donated) IPancakePair(pair).sync(); // fold the donation into reserves (not a free gift to the next swap)
        usdt.forceApprove(address(router), 0);
    }

    // ------------------------------------------------------------- helpers
    function _digest(bytes32 structHash) private view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("OneDollar Mine"), keccak256("1"), block.chainid, address(this))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _requireSigner(bytes32 digest, bytes calldata sig, address who) private pure {
        (address got, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        if (err != ECDSA.RecoverError.NoError || got != who) revert BadSignature();
    }
}
