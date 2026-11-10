// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPancakePair} from "./interfaces/IPancakeV2.sol";
import {OneDollarToken} from "./OneDollarToken.sol";

/// @title OneDollarMint — STAGE 1 GENESIS: flat 1-USDT agent-gated fair mint that seeds + LOCKS the $1/USDT V2 LP
/// @notice SETTLEMENT = USDT (BSC BEP-20, 18 DECIMALS). "$1" is exactly 1 USDT (1e18): the stablecoin IS the unit
///         of account, so there is NO price oracle anywhere. FLAT tokens: 4,000 $1 to the buyer + 3,300 $1 of pool
///         inventory per paid share. Exactly TOTAL_SHARES = OPEN_AT = 10,000 paid shares: the 10,000th share
///         AUTO-OPENS — this contract (the lpAdder) moves 33,000,000 $1 + 8,000 USDT into the PancakeSwap V2
///         $1/USDT pair and mints the LP DIRECTLY to DEAD (0x…dEaD: permanently locked, no withdraw path), then
///         `enableTrading()` turns on the tax and opens transfers. Genesis CLOSES; Stage 2 takes over.
///
///         Raise = 10,000 USDT -> 80% (8,000 USDT) seeds the pool vs 33,000,000 $1 (open mark = 97% of cost),
///         20% (2,000 USDT) to treasury. Payment is `usdt.transferFrom(minter, this, shares * 1e18)`.
///
///         PRE-OPEN FRONT-RUN: tokens are non-transferable until open except minter -> pair (the seed), so the
///         pair cannot be seeded by anyone else. Seeding via `pair.mint` (not the router) is robust to USDT
///         "donate + sync" griefing: such USDT can only GIFT itself to the locked LP (raise the open price), never
///         brick or extract.
///
///         FREE: FREE_TOTAL_POOL = 1,111 shares, gas-only, hard ceiling MAX_FREE_PER_AGENT = 2 per Agent-ID (the
///         2nd early-bird share is an OFF-CHAIN second voucher — the Free EIP-712 struct is unchanged).
///         PER-WALLET CAP = 10 TOTAL (free + paid): base 1, +1 per referral GIVEN (`inviteBoost`, carried into
///         Stage 2) and +1 if ARRIVED via a referral (`referredBonus`, genesis-only), clamped at 10.
///
///         Pre-open USDT is escrowed 100% here and refundable if the pool has not opened within REFUND_WINDOW
///         (3 days) of the first mint.
contract OneDollarMint is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------- locked constants (operator)
    uint256 public constant TOTAL_SHARES = 10_000; // paid genesis cap == pool-open threshold (closes at open)
    uint256 public constant OPEN_AT = 10_000;
    uint256 public constant USER_SHARE = 4_000 ether; // $1 to the minter per share (paid or free), FLAT
    uint256 public constant POOL_SHARE = 3_300 ether; // $1 pool inventory per PAID share, FLAT
    uint256 public constant OPEN_TOKENS = OPEN_AT * POOL_SHARE; // 33,000,000 $1 seeded at open
    uint256 public constant PRICE_USD = 1 ether; // FLAT 1 USDT / share (USDT is 18-dec on BSC)
    uint256 public constant OPEN_RAISE_USD = OPEN_AT * PRICE_USD; // 10,000 USDT
    uint256 public constant TREASURY_BPS = 2_000; // 20% -> treasury at open; 80% seeds the pool
    uint256 public constant OPEN_SEED_USD = OPEN_RAISE_USD * (10_000 - TREASURY_BPS) / 10_000; // 8,000 USDT
    uint256 public constant MAX_PER_TX = 10;
    uint256 public constant REFUND_WINDOW = 3 days;

    uint256 public constant FREE_TOTAL_POOL = 1_111;
    uint256 public constant MAX_FREE_PER_AGENT = 2; // hard on-chain ceiling; the 2nd is early-bird (off-chain whitelist)
    uint256 public constant BASE_CAP = 1;
    uint256 public constant INVITE_BOOST_MAX = 9;
    uint256 public constant WALLET_CAP = BASE_CAP + INVITE_BOOST_MAX; // 10

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant MINT_TYPEHASH = keccak256(
        "Mint(address minter,uint256 shares,uint256 agentId,address inviter,uint256 nonce,uint256 deadline,uint256 maxCost)"
    );
    bytes32 private constant FREE_TYPEHASH =
        keccak256("Free(address minter,uint256 agentId,address inviter,uint256 nonce,uint256 deadline)");

    // ------------------------------------------------------------- immutables
    OneDollarToken public immutable token;
    IERC20 public immutable usdt; // BSC USDT, 18 decimals — the settlement + quote currency
    address public immutable pair; // the official $1/USDT PancakeSwap V2 pair (from the token)
    address public gateSigner;
    address public immutable treasury;
    uint256 public immutable mintStart;

    // ------------------------------------------------------------- state
    uint256 public totalMinted; // PAID genesis shares
    uint256 public totalPaid; // USDT (18-dec)
    uint256 public freeSupply;
    bool public paused = true;
    bool public seeded;
    bool public renounced;
    uint256 public pendingUsdt;
    uint256 public pendingTokens;
    uint256 public openedTime;
    uint256 public firstMintTime;
    uint256 public lpLocked; // V2 LP minted to DEAD at open

    mapping(address => uint256) public sharesMinted; // free + paid, for the 10-cap
    mapping(address => uint256) public genesisPaid; // PAID genesis shares per wallet (Stage-2 epoch-1 priority)
    mapping(uint256 => uint8) public freeMints; // free shares claimed per Agent-ID (<= MAX_FREE_PER_AGENT)
    mapping(bytes32 => bool) public spentNonce;
    mapping(address => uint256) public refundShares;
    mapping(address => uint256) public refundPaid;
    mapping(address => address) public inviterOf;
    mapping(address => uint256) public inviteBoost; // referrals this wallet GAVE, carried into Stage 2
    mapping(address => uint256) public referredBonus; // 1 if this wallet ARRIVED via a valid referral (genesis-only)

    event Minted(address indexed minter, uint256 indexed agentId, uint256 firstShare, uint256 shares, uint256 cost);
    event FreeMinted(address indexed minter, uint256 indexed agentId, uint256 shares);
    event Opened(uint256 usdtIn, uint256 tokensIn, uint256 lpLocked);
    event Seeded();
    event PausedSet(bool paused);
    event Renounced();
    event Refunded(address indexed minter, uint256 shares, uint256 amount);
    event Invited(address indexed invitee, address indexed inviter);
    event GateSignerSet(address indexed signer);

    error NotTreasury();
    error AdminRenounced();
    error Paused();
    error NotSeeded();
    error BadShares();
    error SoldOut();
    error Quota();
    error OverMaxCost();
    error BadSignature();
    error Replayed();
    error NotStarted();
    error RefundClosed();
    error NothingToRefund();
    error ZeroAddress();
    error BadToken();

    struct Config {
        address token;
        address usdt;
        address gateSigner;
        address treasury;
        uint256 mintStart;
    }

    constructor(Config memory c) {
        if (c.token == address(0) || c.usdt == address(0) || c.gateSigner == address(0) || c.treasury == address(0)) {
            revert ZeroAddress();
        }
        token = OneDollarToken(c.token);
        usdt = IERC20(c.usdt);
        gateSigner = c.gateSigner;
        treasury = c.treasury;
        mintStart = c.mintStart;
        if (address(OneDollarToken(c.token).usdt()) != c.usdt) revert BadToken();
        pair = OneDollarToken(c.token).pair();
        if (pair == address(0)) revert BadToken();
    }

    // ------------------------------------------------------------- pricing (no oracle: 1 share == 1 USDT)
    function priceUsd(uint256) public pure returns (uint256) {
        return PRICE_USD;
    }

    function costUsd(uint256 shares) public pure returns (uint256) {
        return shares * PRICE_USD;
    }

    /// @notice USDT (18-dec) owed for `shares`: exactly shares x 1e18.
    function quoteUsdt(uint256 shares) public pure returns (uint256) {
        return costUsd(shares);
    }

    // ------------------------------------------------------------- views
    function opened() public view returns (bool) {
        return totalMinted >= OPEN_AT;
    }

    /// @notice True once an Agent-ID has claimed at least one free share (compat view over `freeMints`).
    function freeClaimed(uint256 agentId) external view returns (bool) {
        return freeMints[agentId] > 0;
    }

    /// @notice Per-wallet genesis cap: base 1 + referrals GIVEN + (1 if arrived via referral), clamped at 10.
    function effectiveCap(address w) public view returns (uint256) {
        uint256 boost = inviteBoost[w];
        if (boost > INVITE_BOOST_MAX) boost = INVITE_BOOST_MAX;
        uint256 c = BASE_CAP + boost + referredBonus[w];
        if (c > WALLET_CAP) c = WALLET_CAP;
        return c;
    }

    /// @notice V2 LP of the official pair held by DEAD (genesis seed + every auto-LP / Mode-B add): unwithdrawable.
    function lockedLiquidity() public view returns (uint256) {
        return IPancakePair(pair).balanceOf(DEAD);
    }

    /// @notice Pair reserves as (usdt, token).
    function reserves() public view returns (uint256 rUsdt, uint256 rToken) {
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        (rUsdt, rToken) = IPancakePair(pair).token0() == address(usdt) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    // ------------------------------------------------------------- treasury admin
    function _onlyTreasury() private view {
        if (msg.sender != treasury) revert NotTreasury();
        if (renounced) revert AdminRenounced();
    }

    function seed() external {
        _onlyTreasury();
        seeded = true;
        emit Seeded();
    }

    function setPaused(bool next) external {
        _onlyTreasury();
        if (!next && !seeded) revert NotSeeded();
        paused = next;
        emit PausedSet(next);
    }

    function setPoolBlocked(address pool, bool blocked) external {
        _onlyTreasury();
        token.setPoolBlocked(pool, blocked);
    }

    function setGateSigner(address next) external {
        _onlyTreasury();
        if (next == address(0)) revert ZeroAddress();
        gateSigner = next;
        emit GateSignerSet(next);
    }

    function renounce() external {
        _onlyTreasury();
        if (!seeded) revert NotSeeded();
        renounced = true;
        paused = false;
        token.disableBlocks();
        emit Renounced();
    }

    // ------------------------------------------------------------- paid genesis (USDT, flat 1 USDT/share)
    /// @param maxCost voucher-bound ceiling on the USDT charged (kept in the EIP-712 struct; cost is flat anyway).
    function mint(
        uint256 shares,
        uint256 agentId,
        address inviter,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig,
        uint256 maxCost
    ) external nonReentrant {
        if (paused) revert Paused();
        if (block.timestamp < mintStart) revert NotStarted();
        if (shares == 0 || shares > MAX_PER_TX) revert BadShares();
        if (totalMinted + shares > TOTAL_SHARES) revert SoldOut(); // genesis closes at 10,000
        if (block.timestamp > deadline) revert BadSignature();

        bytes32 digest =
            _digest(keccak256(abi.encode(MINT_TYPEHASH, msg.sender, shares, agentId, inviter, nonce, deadline, maxCost)));
        if (spentNonce[digest]) revert Replayed();
        _requireSigner(digest, sig, gateSigner);
        spentNonce[digest] = true;

        _bindAndCount(msg.sender, inviter, shares);
        genesisPaid[msg.sender] += shares;

        uint256 cost = costUsd(shares);
        if (cost > maxCost) revert OverMaxCost();
        usdt.safeTransferFrom(msg.sender, address(this), cost); // exact; reverts on short allowance/balance
        _process(msg.sender, agentId, shares, cost);
    }

    // ------------------------------------------------------------- free genesis ($0, gas-only)
    function mintFree(uint256 agentId, address inviter, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        nonReentrant
    {
        if (paused) revert Paused();
        if (block.timestamp < mintStart) revert NotStarted();
        if (block.timestamp > deadline) revert BadSignature();
        if (freeMints[agentId] >= MAX_FREE_PER_AGENT) revert Quota();
        if (freeSupply + 1 > FREE_TOTAL_POOL) revert SoldOut();

        bytes32 digest = _digest(keccak256(abi.encode(FREE_TYPEHASH, msg.sender, agentId, inviter, nonce, deadline)));
        if (spentNonce[digest]) revert Replayed();
        _requireSigner(digest, sig, gateSigner);
        spentNonce[digest] = true;

        _bindAndCount(msg.sender, inviter, 1);
        freeMints[agentId] += 1;
        freeSupply += 1;
        if (firstMintTime == 0) firstMintTime = block.timestamp;

        token.mint(msg.sender, USER_SHARE);
        emit FreeMinted(msg.sender, agentId, 1);
    }

    /// @dev Binds a referral on the wallet's FIRST mint and credits BOTH sides (two-sided). Self-referral rejected.
    function _bindAndCount(address minter, address inviter, uint256 shares) private {
        if (sharesMinted[minter] == 0 && inviter != address(0) && inviter != minter) {
            inviterOf[minter] = inviter;
            inviteBoost[inviter] += 1;
            referredBonus[minter] = 1;
            emit Invited(minter, inviter);
        }
        if (sharesMinted[minter] + shares > effectiveCap(minter)) revert Quota();
        sharesMinted[minter] += shares;
    }

    // ------------------------------------------------------------- settlement (pre-open only; opens at 10,000)
    function _process(address minter, uint256 agentId, uint256 shares, uint256 cost) private {
        if (firstMintTime == 0) firstMintTime = block.timestamp;
        uint256 first = totalMinted + 1;
        bool crossed;

        for (uint256 n = first; n < first + shares; n++) {
            totalPaid += PRICE_USD;
            pendingUsdt += PRICE_USD;
            pendingTokens += POOL_SHARE;
            token.mint(address(this), POOL_SHARE);
            if (n == OPEN_AT) crossed = true;
        }
        totalMinted = first + shares - 1;
        token.mint(minter, shares * USER_SHARE);

        if (crossed) {
            _open();
        } else {
            refundShares[minter] += shares;
            refundPaid[minter] += cost;
        }
        emit Minted(minter, agentId, first, shares, cost);
    }

    // ------------------------------------------------------------- PancakeSwap V2 open (LP LOCKED AT DEAD)
    /// @dev The lpAdder: moves the full escrowed seed into the pair and mints the LP straight to DEAD. The only
    ///      LP recipient in this contract is DEAD and there is no LP-removal path anywhere.
    function _open() private {
        uint256 escrowed = pendingUsdt;
        uint256 tokens = pendingTokens; // == OPEN_TOKENS
        pendingUsdt = 0;
        pendingTokens = 0;
        uint256 treasuryCut = escrowed * TREASURY_BPS / 10_000;
        uint256 seedUsdt = escrowed - treasuryCut;
        if (treasuryCut > 0) usdt.safeTransfer(treasury, treasuryCut);

        IERC20(address(token)).safeTransfer(pair, tokens); // minter -> pair: the ONLY pre-open transfer path
        usdt.safeTransfer(pair, seedUsdt);
        uint256 liquidity = IPancakePair(pair).mint(DEAD); // LP welded to DEAD forever
        lpLocked = liquidity;
        token.enableTrading();
        openedTime = block.timestamp;
        emit Opened(seedUsdt, tokens, liquidity);
    }

    // ------------------------------------------------------------- refund (3 days)
    function refund() external nonReentrant {
        if (opened()) revert RefundClosed();
        if (firstMintTime == 0 || block.timestamp < firstMintTime + REFUND_WINDOW) revert RefundClosed();
        uint256 shares = refundShares[msg.sender];
        uint256 amount = refundPaid[msg.sender];
        if (shares == 0 || amount == 0) revert NothingToRefund();

        refundShares[msg.sender] = 0;
        refundPaid[msg.sender] = 0;
        totalMinted -= shares;
        totalPaid -= amount;
        pendingUsdt -= amount;
        pendingTokens -= shares * POOL_SHARE;
        genesisPaid[msg.sender] -= shares;

        token.burnFromHolder(msg.sender, shares * USER_SHARE);
        token.burnFromHolder(address(this), shares * POOL_SHARE);

        usdt.safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, shares, amount);
    }

    // ------------------------------------------------------------- helpers
    function _digest(bytes32 structHash) private view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("OneDollar Mint"), keccak256("1"), block.chainid, address(this))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _requireSigner(bytes32 digest, bytes calldata sig, address who) private pure {
        (address got, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        if (err != ECDSA.RecoverError.NoError || got != who) revert BadSignature();
    }
}
