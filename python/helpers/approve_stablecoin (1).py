#!/usr/bin/env python3
"""
approve_stablecoin.py
----------------------
Erteilt dem P2PEnergyMarket-Contract eine "Vollmacht" (ERC-20 approve()) auf
den Stablecoin, damit settleSlot() später via transferFrom() Zahlungen im
Namen der Haushalte ausführen darf.

Private Keys werden NICHT gespeichert, sondern pro Haushalt interaktiv und
verdeckt (getpass) abgefragt. Nichts davon landet in Logs, Dateien oder
der Konsolen-History.

Nutzung:
    pip install web3
    python approve_stablecoin.py
    python approve_stablecoin.py --config ../config.json --amount unlimited
    python approve_stablecoin.py --amount 1000            # 1000 Token (in Decimals-Einheiten)

Erwartetes config.json (relativ, Default "../config.json"):
{
  "blockchain": {
    "rpc_url": "...",
    "chain_id": 11155111,
    "p2p_market_address": "0x...",
    "stablecoin_address": "0x..."
  }
}
"""

import argparse
import getpass
import json
import sys
from pathlib import Path

from eth_account import Account
from web3 import Web3

# ─────────────────────────────────────────────────────────────
#  Minimales ERC-20 ABI (nur was wir brauchen)
# ─────────────────────────────────────────────────────────────

ERC20_ABI = [
    {
        "constant": False,
        "inputs": [
            {"name": "spender", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "name": "approve",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    {
        "constant": True,
        "inputs": [
            {"name": "owner", "type": "address"},
            {"name": "spender", "type": "address"},
        ],
        "name": "allowance",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "constant": True,
        "inputs": [],
        "name": "decimals",
        "outputs": [{"name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "constant": True,
        "inputs": [],
        "name": "symbol",
        "outputs": [{"name": "", "type": "string"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "constant": True,
        "inputs": [{"name": "account", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]

MAX_UINT256 = 2**256 - 1


# ─────────────────────────────────────────────────────────────
#  Config laden
# ─────────────────────────────────────────────────────────────

def load_config(config_path: Path) -> dict:
    if not config_path.exists():
        sys.exit(f"[Fehler] config.json nicht gefunden unter: {config_path}")

    with config_path.open("r", encoding="utf-8") as f:
        cfg = json.load(f)

    bc = cfg.get("blockchain")
    if not bc:
        sys.exit("[Fehler] config.json enthält keinen 'blockchain'-Block.")

    required = ["rpc_url", "chain_id", "p2p_market_address", "stablecoin_address"]
    missing = [k for k in required if not bc.get(k)]
    if missing:
        sys.exit(f"[Fehler] Folgende Felder fehlen in config.json -> blockchain: {missing}")

    placeholders = {
        k: v for k, v in bc.items()
        if isinstance(v, str) and "REPLACE" in v.upper()
    }
    # Nur bei den beiden Adressen meckern, die wir hier wirklich brauchen
    for key in ("p2p_market_address", "stablecoin_address"):
        if key in placeholders:
            sys.exit(
                f"[Fehler] '{key}' in config.json ist noch ein Platzhalter "
                f"({bc[key]}). Bitte zuerst mit der echten Adresse befüllen."
            )

    return bc


# ─────────────────────────────────────────────────────────────
#  Accounts interaktiv einlesen
# ─────────────────────────────────────────────────────────────

def collect_accounts() -> list[Account]:
    """Fragt Private Keys nacheinander ab (verdeckt), bis Enter ohne Eingabe kommt."""
    accounts: list[Account] = []
    print("\nPrivate Keys der Haushalte eingeben (verdeckt, wird nicht angezeigt).")
    print("Leere Eingabe (einfach Enter) beendet die Liste.\n")

    while True:
        idx = len(accounts) + 1
        raw_key = getpass.getpass(f"  Private Key Haushalt #{idx} (oder Enter zum Beenden): ").strip()
        if not raw_key:
            break

        if not raw_key.startswith("0x"):
            raw_key = "0x" + raw_key

        try:
            account = Account.from_key(raw_key)
        except Exception as e:
            print(f"    [Fehler] Ungültiger Private Key, wird übersprungen: {e}")
            continue
        finally:
            # Best-effort: Referenz auf den Klartext-Key loswerden
            raw_key = "0" * 64

        print(f"    -> erkannte Adresse: {account.address}")
        accounts.append(account)

    return accounts


# ─────────────────────────────────────────────────────────────
#  Approve-Logik
# ─────────────────────────────────────────────────────────────

def approve_for_account(
    w3: Web3,
    stablecoin,
    account: Account,
    spender: str,
    amount_wei: int,
    chain_id: int,
    symbol: str,
    decimals: int,
) -> None:
    address = account.address

    current_allowance = stablecoin.functions.allowance(address, spender).call()
    if current_allowance == amount_wei:
        print(f"    Allowance bereits auf Zielwert, überspringe Transaktion.")
        return

    nonce = w3.eth.get_transaction_count(address, "pending")
    gas_price = w3.eth.gas_price

    tx = stablecoin.functions.approve(spender, amount_wei).build_transaction(
        {
            "chainId": chain_id,
            "from": address,
            "nonce": nonce,
            "gasPrice": gas_price,
        }
    )

    # Gas-Limit schätzen (mit etwas Puffer)
    try:
        estimated_gas = w3.eth.estimate_gas(tx)
        tx["gas"] = int(estimated_gas * 1.2)
    except Exception:
        tx["gas"] = 60_000  # Fallback für ein simples ERC-20 approve()

    signed_tx = account.sign_transaction(tx)
    raw_tx = getattr(signed_tx, "raw_transaction", None) or signed_tx.rawTransaction

    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    print(f"    Tx gesendet: {tx_hash.hex()} - warte auf Bestätigung ...")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    if receipt.status == 1:
        human_amount = "unlimited" if amount_wei == MAX_UINT256 else amount_wei / (10**decimals)
        print(f"    ✓ Erfolgreich. Allowance für {spender} = {human_amount} {symbol}")
    else:
        print(f"    ✗ Transaktion fehlgeschlagen (Status 0). Tx-Hash: {tx_hash.hex()}")


# ─────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="ERC-20 approve() für P2PEnergyMarket erteilen")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "config.json",
        help="Pfad zur config.json (Default: ../config.json relativ zu diesem Skript)",
    )
    parser.add_argument(
        "--amount",
        type=str,
        default="unlimited",
        help="'unlimited' (Default, empfohlen für Demo/Hackathon) oder eine konkrete "
             "Zahl in ganzen Token-Einheiten (z.B. 1000)",
    )
    args = parser.parse_args()

    bc = load_config(args.config)

    print(f"Verbinde mit RPC: {bc['rpc_url']} (chainId={bc['chain_id']})")
    w3 = Web3(Web3.HTTPProvider(bc["rpc_url"]))
    if not w3.is_connected():
        sys.exit("[Fehler] Verbindung zum RPC-Endpoint fehlgeschlagen.")

    spender = Web3.to_checksum_address(bc["p2p_market_address"])
    stablecoin_address = Web3.to_checksum_address(bc["stablecoin_address"])
    stablecoin = w3.eth.contract(address=stablecoin_address, abi=ERC20_ABI)

    try:
        symbol = stablecoin.functions.symbol().call()
    except Exception:
        symbol = "TOKEN"
    try:
        decimals = stablecoin.functions.decimals().call()
    except Exception:
        decimals = 18

    if args.amount.lower() == "unlimited":
        amount_wei = MAX_UINT256
    else:
        amount_wei = int(float(args.amount) * (10**decimals))

    print(f"Stablecoin: {symbol} (decimals={decimals}) @ {stablecoin_address}")
    print(f"Spender (P2PEnergyMarket): {spender}")
    print(f"Approval-Betrag: {'unlimited' if amount_wei == MAX_UINT256 else args.amount}")

    accounts = collect_accounts()
    if not accounts:
        sys.exit("\nKeine Accounts eingegeben - nichts zu tun.")

    print(f"\n{len(accounts)} Account(s) gesammelt. Starte Approve-Transaktionen ...\n")

    for account in accounts:
        print(f"[{account.address}]")
        try:
            approve_for_account(
                w3=w3,
                stablecoin=stablecoin,
                account=account,
                spender=spender,
                amount_wei=amount_wei,
                chain_id=bc["chain_id"],
                symbol=symbol,
                decimals=decimals,
            )
        except Exception as e:
            print(f"    [Fehler] {e}")
        print()

    print("Fertig.")


if __name__ == "__main__":
    main()
