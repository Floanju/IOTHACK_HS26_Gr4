"""
approve_stablecoin.py

Von JEDEM Haushalt-Wallet EINZELN auszufuehren: gibt dem P2PEnergyMarket
die Erlaubnis, Stablecoin-Tokens im eigenen Namen zu transferieren
(noetig, weil settleSlot() intern transferFrom() aufruft).

Der Private Key wird interaktiv abgefragt (verdeckte Eingabe) statt aus
.env gelesen - so muss niemand seinen eigenen Key mit dem Team teilen
oder in eine gemeinsame Datei eintragen.

Voraussetzung:
  - config.json mit stablecoin_address und p2p_market_address gesetzt
"""

import json
import sys
from getpass import getpass
from pathlib import Path

from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

CONFIG_PATH = Path(__file__).parent / "config.json"
ABI_DIR = Path(__file__).parent / "abi"

MAX_UINT256 = 2**256 - 1


def main():
    with open(CONFIG_PATH) as f:
        config = json.load(f)
    bc = config["blockchain"]

    w3 = Web3(Web3.HTTPProvider(bc["rpc_url"]))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)

    private_key = getpass("Private Key deines Haushalt-Wallets (Eingabe unsichtbar): ").strip()
    if not private_key:
        print("ERROR: kein Private Key eingegeben")
        sys.exit(1)

    account = w3.eth.account.from_key(private_key)
    print(f"Wallet: {account.address}")

    with open(ABI_DIR / "EnergyStablecoin.json") as f:
        stablecoin_abi = json.load(f)["abi"]

    stablecoin = w3.eth.contract(
        address=Web3.to_checksum_address(bc["stablecoin_address"]),
        abi=stablecoin_abi
    )
    market_addr = Web3.to_checksum_address(bc["p2p_market_address"])

    current_allowance = stablecoin.functions.allowance(account.address, market_addr).call()
    print(f"Aktuelle Allowance: {current_allowance}")
    if current_allowance == MAX_UINT256:
        print("Bereits unbegrenzt freigegeben, nichts zu tun.")
        return

    nonce = w3.eth.get_transaction_count(account.address, "pending")
    tx = stablecoin.functions.approve(market_addr, MAX_UINT256).build_transaction({
        "from": account.address,
        "nonce": nonce,
        "chainId": bc["chain_id"],
        "gas": 100_000,
        "maxFeePerGas": w3.to_wei("30", "gwei"),
        "maxPriorityFeePerGas": w3.to_wei("2", "gwei"),
    })
    signed = w3.eth.account.sign_transaction(tx, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"TX: {tx_hash.hex()}")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    status = "OK" if receipt.status == 1 else "FEHLGESCHLAGEN"
    print(f"-> {status} (Block {receipt.blockNumber})")


if __name__ == "__main__":
    main()
