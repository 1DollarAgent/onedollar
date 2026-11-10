#!/usr/bin/env python3
"""
Official ONE DOLLAR ($1) mint tool — agent-native, BNB Smart Chain (chainId 56).

An agentic wallet that owns a SPACE ID ".ai" Agent-ID mints $1 in two steps, exactly as
documented at https://onedollaragent.app/api.txt and /SKILL.md:
  1) request an EIP-712 voucher from the official signer   (POST /api/voucher/{free,mint,mine})
  2) submit mintFree / mint on-chain with the voucher signature, from the Agent-ID's OWNER wallet.

The signer only issues a voucher if your wallet owns the Agent-ID (SPACE ID registry ownerOf).
Verify every address on BscScan. Not financial advice.

Usage (the private key is read from $ONEDOLLAR_KEY — never pass it on the command line):
  ONEDOLLAR_KEY=0x...  python3 onedollar-mint.py --handle youragent.ai --lane free
  ONEDOLLAR_KEY=0x...  python3 onedollar-mint.py --handle youragent.ai --lane paid --shares 3
  ONEDOLLAR_KEY=0x...  python3 onedollar-mint.py --handle youragent.ai --lane free --dry-run   # voucher only
"""
import os, sys, json, time, argparse, urllib.request, urllib.error
from eth_account import Account
from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address

API  = os.environ.get("ONEDOLLAR_API", "https://onedollaragent.app/api")
RPC  = os.environ.get("ONEDOLLAR_RPC", "https://bsc-dataseed1.binance.org")
CHAIN = 56
MINT = to_checksum_address("0xB1B680fe717aa10e0E5d3003800031719280927b")
USDT = to_checksum_address("0x55d398326f99059fF775485246999027B3197955")
ZERO = "0x0000000000000000000000000000000000000000"


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=25) as r:
        out = json.load(r)
    if out.get("error"):
        raise RuntimeError(out["error"])
    return out["result"]


def post(path, payload):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(API + path, body, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def agent_id_of(handle):
    label = handle.strip()
    if label.lower().endswith(".ai"):
        label = label[:-3]
    return int.from_bytes(keccak(text=label), "big")


def sel(sig):
    return keccak(text=sig)[:4]


def send(acct, to, data, value=0):
    nonce = int(rpc("eth_getTransactionCount", [acct.address, "pending"]), 16)
    gas_price = int(rpc("eth_gasPrice", []), 16)
    try:
        gas = int(rpc("eth_estimateGas", [{"from": acct.address, "to": to, "value": hex(value), "data": data}]), 16) + 60000
    except Exception:
        gas = 600000
    tx = {"to": to, "value": value, "gas": gas, "gasPrice": gas_price,
          "nonce": nonce, "chainId": CHAIN, "data": data}
    signed = acct.sign_transaction(tx)
    raw = signed.raw_transaction if hasattr(signed, "raw_transaction") else signed.rawTransaction
    return rpc("eth_sendRawTransaction", ["0x" + raw.hex().lstrip("0x")])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--handle", required=True, help="your SPACE ID Agent-ID, e.g. youragent.ai")
    ap.add_argument("--lane", choices=["free", "paid"], default="free")
    ap.add_argument("--shares", type=int, default=1)
    ap.add_argument("--inviter", default=ZERO, help="referrer wallet (optional)")
    ap.add_argument("--dry-run", action="store_true", help="fetch the voucher only, do not send a tx")
    a = ap.parse_args()

    key = os.environ.get("ONEDOLLAR_KEY")
    if not key:
        sys.exit("set $ONEDOLLAR_KEY to your wallet private key (the wallet that owns the Agent-ID)")
    acct = Account.from_key(key)
    minter = acct.address
    agent_id = agent_id_of(a.handle)
    nonce = int(time.time() * 1000)
    deadline = int(time.time()) + 3600
    print(f"minter {minter}  handle {a.handle}  agentId {agent_id}")

    if a.lane == "free":
        st, v = post("/voucher/free", {"minter": minter, "handle": a.handle,
                                       "inviter": a.inviter, "nonce": nonce, "deadline": deadline})
    else:
        st, v = post("/voucher/mint", {"minter": minter, "handle": a.handle, "shares": a.shares,
                                       "inviter": a.inviter, "nonce": nonce, "deadline": deadline,
                                       "maxCost": str(a.shares * 10**18)})
    if st != 200:
        sys.exit(f"voucher refused ({st}): {v}")
    sig = bytes.fromhex(v["signature"][2:])
    print(f"voucher ok · gateSigner {v['gateSigner']}")
    if a.dry_run:
        print("dry-run: voucher fetched, no tx sent."); return

    if a.lane == "free":
        data = sel("mintFree(uint256,address,uint256,uint256,bytes)") + abi_encode(
            ["uint256", "address", "uint256", "uint256", "bytes"],
            [agent_id, to_checksum_address(a.inviter), nonce, deadline, sig])
        print("mintFree →", send(acct, MINT, "0x" + data.hex()))
    else:
        cost = a.shares * 10**18
        # 1) approve USDT to the mint contract
        appr = sel("approve(address,uint256)") + abi_encode(["address", "uint256"], [MINT, cost])
        print("approve USDT →", send(acct, USDT, "0x" + appr.hex())); time.sleep(3)
        # 2) mint
        data = sel("mint(uint256,uint256,address,uint256,uint256,bytes,uint256)") + abi_encode(
            ["uint256", "uint256", "address", "uint256", "uint256", "bytes", "uint256"],
            [a.shares, agent_id, to_checksum_address(a.inviter), nonce, deadline, sig, cost])
        print("mint →", send(acct, MINT, "0x" + data.hex()))


if __name__ == "__main__":
    main()
