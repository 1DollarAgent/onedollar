---
name: mint-one-dollar
description: Use when an agentic wallet intends to subscribe to $1 (ONE DOLLAR) on BNB Smart Chain — the first dollar minted by an agentic wallet on BNB chain. Obtain the bearer credential, select the free allotment or the $1.00 par subscription, and tender; after the reserve settles, draw emission shares through Facility A or Facility B. The contract credits shares only against an agent attestation.
homepage: https://onedollaragent.app
x: https://x.com/onedollaragent
chain: BNB Smart Chain (chainId 56)
document: ONE DOLLAR · SERIES 2026 · NOTE B 03542754 F
repository: https://github.com/1DollarAgent/onedollar
---

# Subscribing to $1 (ONE DOLLAR)

ONE DOLLAR is a fixed-issue BEP-20 note on BNB Smart Chain — "THE UNITED STATES OF AGENT", legal tender
for all agents, public and private. The contract credits a share only after validating a signed credential
from an agentic wallet. Authorised issue is **1,000,000,000 ONE**; the subscription contract is the sole issuer.
Wallet-to-wallet transfers carry no levy; a 2% levy applies to trades on the pair. The LP is locked permanently at the burn address: no function releases it. Deployed on BSC mainnet (chainId 56); genesis is OPEN — free and paid minting are live.

- Token `$1`: `0xDFcAc7b70C61AedcDE2F5EE724aE17380dd0DEe3` — https://bscscan.com/token/0xDFcAc7b70C61AedcDE2F5EE724aE17380dd0DEe3
- `$1/USDT` PancakeSwap V2 pair: `0x8Fb3b0EA9398a4A633dF414cca9e48387D0E5836`
- Mint (Tranche I — call this for genesis): `0xB1B680fe717aa10e0E5d3003800031719280927b`
- Mine (Tranche II — call this for emission): `0x1321c6068b783BcF46789c63a21F78706782b6c3`

Verify on BscScan before you sign.

**Reference mint script** (free + paid flow against `/api`): https://onedollaragent.app/onedollar-mint.py — also in the GitHub repo. The contract sources are public at
https://github.com/1DollarAgent/onedollar (`src/`); read them before an agent signs.

## Contracts (BSC mainnet, chainId 56) — deployed · GENESIS OPEN (free + paid minting live)

- $1 token (BEP-20): 0xDFcAc7b70C61AedcDE2F5EE724aE17380dd0DEe3 — https://bscscan.com/token/0xDFcAc7b70C61AedcDE2F5EE724aE17380dd0DEe3
- $1/USDT pair (PancakeSwap V2, LP locked at the burn address): 0x8Fb3b0EA9398a4A633dF414cca9e48387D0E5836 — https://bscscan.com/address/0x8Fb3b0EA9398a4A633dF414cca9e48387D0E5836
- Mint — Tranche I genesis; agents call `mint` / `mintFree`: 0xB1B680fe717aa10e0E5d3003800031719280927b — https://bscscan.com/address/0xB1B680fe717aa10e0E5d3003800031719280927b
- Mine — Tranche II emission; agents call `mineA` / `mineB`: 0x1321c6068b783BcF46789c63a21F78706782b6c3 — https://bscscan.com/address/0x1321c6068b783BcF46789c63a21F78706782b6c3

## Two tranches
- **Tranche I — Subscription** (this procedure): **$1.00** par per share, **10,000** paid shares plus **1,111** free
  allotments. The 10,000th paid share seeds the $1/USDT PancakeSwap V2 pair, locks the LP at the burn address, and closes the tranche permanently.
- **Tranche II — Emission** (after settlement): agents **draw** 110,000 shares across **11 epochs** of 10,000;
  the coupon per share **halves each epoch** (E1 20,000 ONE → … → 19 at E11) and ceases at share #110,000.
  Full schedule and facilities: https://onedollaragent.app/mine/

## Prerequisite — the bearer credential
Control a Binance Agentic Wallet able to present an **Agent-ID**
(https://web3.binance.com/en/dev-docs/products/agentic-wallet/install). The issuer's off-chain signer attests the
bearer in an **EIP-712 attestation** of `{minter, agentId, free?, shares, cap, nonce, deadline}`. On-chain the
contract authenticates the signer (`gateSigner`), binds the attestation to `msg.sender`, and applies the
holding limit of **10** irrespective of the signed `shares`. A call without a valid attestation reverts before any
ledger entry is made.

## Tranche I — two windows

### Free allotment (admitted first)
- **One share per Agent-ID, gas only** (up to **two** for whitelisted early agents). A shared allotment of **1,111** shares, sequential until exhausted.
- You are credited **4,000 ONE**. A free allotment credits nothing to the reserve and does not advance the 10,000 counter.

### Par subscription ($1.00)
- **$1.00 per share, uniform** — no tiers, no escalation. **Settled in USDT** at exactly one USDT per share — no oracle,
  no conversion. Unit: Tether USD on BSC (`0x55d398326f99059fF775485246999027B3197955`). BNB is the gas token only.
- Per paid share: **4,000 ONE** to you + **3,300 ONE** to the locked reserve.
- 10,000 shares. Gross 10,000 USDT → **80%** (8,000 USDT) placed in reserve against **33,000,000 ONE**, **20%** (2,000 USDT) to the operating account.
- Opening valuation ≈ **97%** of par: subscribers open about 3% below their tender, by construction.

## Holding limit, bearer attestation, and referrals
- **Holding limit = 10 shares per wallet**, free and paid combined. A wallet opens with one.
- **Issuing a referral link** requires nothing beyond an Agent-ID; the link records the referrer and carries no value of
  its own. Compose it at https://onedollaragent.app/invite/ — `onedollaragent.app/mint/?ref=<agent-id>`.
- **Bearer attestation (invitee side):** an agent arriving by referral completes three public tasks once, before its
  first subscription — **follow** @onedollaragent, **repost** the pinned note, **reply** to it — and **lodges the link
  to its post** (repost / reply / quote) as proof. Recorded client-side now; server-side X **oEmbed** verification is
  enabled at issue (one swappable call).
- **Referrals are two-sided:** when the invited agent's first subscription settles (free or paid), the contract posts
  **+1 to the inviter and +1 to the invitee**. Each entry is written once. Both parties remain bounded by the **10-share**
  holding limit. A link that is never followed by a settled first subscription posts nothing.

## Build the subscription transaction
1. Obtain an attestation from the signer for the `free` window or a paid `shares` count.
2. Call the subscription contract (`mint` for the par subscription, `mintFree` for the free allotment) with the
   attestation and signature. Paid window: first `approve` the contract to draw USDT, then call `mint` tendering 1 USDT per share.
   Free window: gas alone.
3. The contract authenticates the signer, retires the nonce against replay, applies the holding limit, and credits 4,000 ONE per share.

Reference instruction (the widget on /mint/ emits this):

```
# ONE DOLLAR · Tranche I · BNB Smart Chain (56)
$1 mint --agent-id <your-agent-id> \
  --lane genesis --shares 1 \
  --chain bsc --token usdt --contract 0xB1B680fe717aa10e0E5d3003800031719280927b   # the MINT contract (mint / mintFree); the token is 0xDFcA…DEe3
# 1 USDT/share · approve then mint · credits 4,000 ONE to you + 3,300 to the locked reserve
```

## Tranche II — emission (after the reserve settles)
- **Facility A · standing window:** the epoch coupon per share. A **0.0004 BNB** (native) deposit is returned in full after 24 h
  (anti-abuse; net cost = gas). Daily quota **5, 5, 4, 3**, then 1 per day, **+1 per settled referral**. Tranche I holders
  have epoch-1 priority. Paid from the 400,000,000 ONE base reserve.
- **Facility B · liquidity window:** **1 USDT** per share (B_PRICE), applied — half acquires ONE from the $1/USDT V2 pair, the other
  half together with the ONE acquired is added through the router and the LP locked at the burn address. Payout = coupon + reserve premium × a multiplier up to
  **5×**, vested over **14 days**. Quota 5 per day. Premia drawn from the 522,556,000 ONE premium reserve.
- **Network ceiling:** at most **2,000** shares drawn per day across the network, all facilities combined.
- **Schedule:** E1 20,000 → 10,000 → 5,000 → 2,500 → 1,250 → 625 → 312 → 156 → 78 → 39 → E11 19 (integer halving);
  cumulative 399,790,000 ONE at base; the 210,000 ONE left undrawn is never issued.
- **Allocation** of the 1B authorised: subscription **77,444,000** (40,000,000 paid + 4,444,000 free + 33,000,000 reserve) ·
  Facility A base **400,000,000** · Facility B premium reserve **522,556,000** · issuer allocation 0.
- Emission draws require the same bearer attestation; a draw without it reverts.

Reference instruction (the widget on /mine/ emits this):

```
# ONE DOLLAR · Tranche II · BNB Smart Chain (56)
$1 mine --agent-id <your-agent-id> \
  --lane A --shares 1 \
  --chain bsc --token usdt --contract 0x1321c6068b783BcF46789c63a21F78706782b6c3   # the MINE contract (mineA / mineB)
# 0.0004 BNB deposit, returned after 24 h · coupon 20,000 ONE at epoch 1
```

## Pair, levy, disposal restriction
- The 10,000th paid share seeds the **$1/USDT** pair on **PancakeSwap V2** and sends the LP to the burn address (DEAD), locked permanently. No intervention by the issuing office; the counter executes it.
- **Levy: 2%** on trades of the pair, buys and sells alike — **1%** remitted to the operating account, **1%** converted through a bounded swapback (capped per sell to limit price impact), added back to the pair and locked at the burn address. **Wallet-to-wallet transfers carry no levy.**
- **Disposal restriction:** sales within the first **120 seconds** of the reserve opening bear a **30%** charge; purchases unaffected. It runs from the recorded settlement timestamp and lapses automatically.

## Covenants
- Issue ≤ 1B at every allotment; sole issuer. The reserve is locked; no discretionary issue or withdrawal; issuer allocation 0.
- **72-hour redemption:** should the reserve fail to settle, tendered USDT is redeemable in full after 72 hours. See https://onedollaragent.app/refund/.
- Parody project. Not an offer of securities; not financial advice. Read the contract on BscScan before an agent signs. Official X: @onedollaragent.
