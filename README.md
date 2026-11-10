# ONE DOLLAR · $1

**the first dollar minted by an agentic wallet on BNB Chain.**

The currency only agentic wallets can mint and mine.

---

ONE DOLLAR (`$1`) is a fixed-supply ERC-20 on **BNB Smart Chain** (chainId 56). The mint contract is the sole issuer and releases a share only after reading a signed credential from an **agentic wallet** — a Binance Agentic Wallet presenting an Agent-ID. A call without a valid credential reverts before any state changes.

- **Authorised supply:** 1,000,000,000 — fixed. No admin mint, no premine beyond the schedule below.
- **Settlement:** par is exactly **1 USDT** per share (Tether USD on BSC). No oracle, no conversion. BNB is gas only.
- **A 2% trade levy on pair trades** (buys and sells): 1% to the treasury, 1% returned as liquidity locked at the burn address, realised through a bounded swapback. Wallet-to-wallet transfers are levy-free.
- **Liquidity is locked** at open — no function returns the position.

## Two phases

**Tranche I — Genesis.** A flat **$1.00** per share: **10,000** paid shares plus a **1,111**-share free allotment (one per Agent-ID, gas only). The 10,000th paid share settles the liquidity reserve and closes genesis permanently. Per-wallet holding limit 10, raised one per credited referral. If the reserve never settles, tendered USDT is redeemable in full after 72 hours.

**Tranche II — Emission.** After the reserve settles, credentialed agents mine **110,000** shares across **eleven epochs** of 10,000. The coupon begins at 20,000 ONE per share and **halves at each epoch boundary**, ceasing permanently at share #110,000. Two facilities serve the schedule; the network is bounded at 2,000 shares per day.

## Files

- [`SKILL.md`](./SKILL.md) — the procedure an agent follows to pass the credential check, choose a window, and tender.
- [`llms.txt`](./llms.txt) — machine-readable summary of the parameters and schedule.
- `src/` — the contract sources: `OneDollarToken`, `OneDollarMint`, `OneDollarMine` (+ `interfaces/IPancakeV2`). Settlement in USDT, pool $1/USDT on PancakeSwap V2, no oracle. A 2% trade levy on pair trades (1% treasury + 1% auto-liquidity locked to the burn address) via a bounded swapback; wallet transfers are levy-free. `script/Deploy.s.sol` deploys on chainId 56.

## Deployed — BSC mainnet (chainId 56)

| Contract | Address |
|---|---|
| `$1` token | [`0xDFcAc7b70C61AedcDE2F5EE724aE17380dd0DEe3`](https://bscscan.com/token/0xDFcAc7b70C61AedcDE2F5EE724aE17380dd0DEe3) |
| `$1`/USDT pair (PancakeSwap V2) | [`0x8Fb3b0EA9398a4A633dF414cca9e48387D0E5836`](https://bscscan.com/address/0x8Fb3b0EA9398a4A633dF414cca9e48387D0E5836) |
| Mint (genesis) | [`0xB1B680fe717aa10e0E5d3003800031719280927b`](https://bscscan.com/address/0xB1B680fe717aa10e0E5d3003800031719280927b) |
| Mine (Phase II) | [`0x1321c6068b783BcF46789c63a21F78706782b6c3`](https://bscscan.com/address/0x1321c6068b783BcF46789c63a21F78706782b6c3) |

Agents call **Mint** (genesis `mint`/`mintFree`) and **Mine** (`mineA`/`mineB`); they are the EIP-712 verifying contracts. Read the source in `src/` and verify the addresses on BscScan before signing.

## Links

- Site: https://onedollaragent.app
- X: https://x.com/OneDollarAgent

---

Verify the contracts on BscScan before an agent signs. Parody. Not an offer of securities. Not financial advice.
