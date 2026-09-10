#!/usr/bin/env python3
"""
set_incentive_controller.py
----------------------------
Verknuepft den deployten IncentiveController mit P2PEnergyMarket
(setIncentiveController() ist onlyOwner). Ohne diesen Schritt bleibt
Phase 3 wirkungslos - settleSlot() nutzt sonst weiterhin den unveraenderten
energyPricePerKwh, unabhaengig davon was der IncentiveController berechnet.

Private Key wird NICHT gespeichert, sondern interaktiv und verdeckt (getpass)
abgefragt - nur der Owner-Key wird gebraucht.

Nutzung:
    pip install web3
    python set_incentive_controller.py
    python set_incentive_controller.py --config ../config.json
"""

import argparse
import getpass
import json
import sys
from pathlib import Path

from eth_account import Account
from web3 import Web3

MARKET_ABI = [
    {
        "inputs": [{"name": "_incentiveController", "type": "address"}],
        "name": "setIncentiveController",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "incentiveController",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "owner",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def load_config(config_path: Path) -> dict:
    if not config_path.exists():
        sys.exit(f"[Fehler] config.json nicht gefunden unter: {config_path}")

    with config_path.open("r", encoding="utf-8") as f:
        cfg = json.load(f)

    bc = cfg.get("blockchain")
    if not bc:
        sys.exit("[Fehler] config.json enthält keinen 'blockchain'-Block.")

    required = ["rpc_url", "chain_id", "p2p_market_address", "incentive_controller_address"]
    missing = [k for k in required if not bc.get(k)]
    if missing:
        sys.exit(f"[Fehler] Folgende Felder fehlen in config.json -> blockchain: {missing}")

    for key in ("p2p_market_address", "incentive_controller_address"):
        if "REPLACE" in bc[key].upper():
            sys.exit(f"[Fehler] '{key}' in config.json ist noch ein Platzhalter.")

    return bc


def main():
    parser = argparse.ArgumentParser(description="IncentiveController mit P2PEnergyMarket verknüpfen")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "config.json",
        help="Pfad zur config.json (Default: ../config.json relativ zu diesem Skript)",
    )
    args = parser.parse_args()

    bc = load_config(args.config)

    print(f"Verbinde mit RPC: {bc['rpc_url']} (chainId={bc['chain_id']})")
    w3 = Web3(Web3.HTTPProvider(bc["rpc_url"]))
    if not w3.is_connected():
        sys.exit("[Fehler] Verbindung zum RPC-Endpoint fehlgeschlagen.")

    market_address = Web3.to_checksum_address(bc["p2p_market_address"])
    incentive_address = Web3.to_checksum_address(bc["incentive_controller_address"])
    market = w3.eth.contract(address=market_address, abi=MARKET_ABI)

    on_chain_owner = market.functions.owner().call()
    current = market.functions.incentiveController().call()
    print(f"P2PEnergyMarket:         {market_address}")
    print(f"Contract-Owner:          {on_chain_owner}")
    print(f"Aktueller IncentiveController: {current}")
    print(f"Neuer IncentiveController:     {incentive_address}")

    if current.lower() == incentive_address.lower():
        print("\nBereits korrekt verknüpft, nichts zu tun.")
        return

    owner_key = getpass.getpass("\nPrivate Key des Owners eingeben (verdeckt): ").strip()
    if not owner_key.startswith("0x"):
        owner_key = "0x" + owner_key
    try:
        owner_account = Account.from_key(owner_key)
    except Exception as e:
        sys.exit(f"[Fehler] Ungültiger Private Key: {e}")
    finally:
        owner_key = "0" * 64

    if owner_account.address.lower() != on_chain_owner.lower():
        print(
            f"\n⚠️  Warnung: der eingegebene Key gehört zu {owner_account.address}, "
            f"aber der Contract-Owner ist {on_chain_owner}. "
            "setIncentiveController() wird mit 'Only owner' revertieren."
        )
        proceed = input("Trotzdem fortfahren? (y/N): ").strip().lower()
        if proceed != "y":
            sys.exit("Abgebrochen.")

    nonce = w3.eth.get_transaction_count(owner_account.address, "pending")
    gas_price = int(w3.eth.gas_price * 1.2)

    tx = market.functions.setIncentiveController(incentive_address).build_transaction(
        {
            "chainId": bc["chain_id"],
            "from": owner_account.address,
            "nonce": nonce,
            "gasPrice": gas_price,
        }
    )
    try:
        estimated_gas = w3.eth.estimate_gas(tx)
        tx["gas"] = int(estimated_gas * 1.2)
    except Exception:
        tx["gas"] = 100_000

    signed_tx = owner_account.sign_transaction(tx)
    raw_tx = getattr(signed_tx, "raw_transaction", None) or signed_tx.rawTransaction

    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    print(f"\nTx gesendet: {tx_hash.hex()} - warte auf Bestätigung ...")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    if receipt.status == 1:
        print(f"✓ Erfolgreich verknüpft (Block {receipt.blockNumber}).")
    else:
        print(f"✗ Transaktion fehlgeschlagen (Status 0). Tx-Hash: {tx_hash.hex()}")


if __name__ == "__main__":
    main()
