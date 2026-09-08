"""
register_households_market.py

Registriert alle Haushalte aus config.json im P2PEnergyMarket-Contract
(registerHousehold() ist onlyOwner - läuft mit DEPLOYER_PRIVATE_KEY).

Voraussetzung:
  - .env mit DEPLOYER_PRIVATE_KEY
  - config.json mit p2p_market_address gesetzt
  - Haushalte müssen bereits im OracleStorage registriert sein
    (passiert automatisch beim Start von oracle_writer.py)
"""

import json
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

load_dotenv()

CONFIG_PATH = Path(__file__).parent / "config.json"
ABI_DIR = Path(__file__).parent / "abi"

PRIVATE_KEY = os.getenv("DEPLOYER_PRIVATE_KEY")
if not PRIVATE_KEY:
    print("ERROR: DEPLOYER_PRIVATE_KEY in .env nicht gesetzt")
    sys.exit(1)


def main():
    with open(CONFIG_PATH) as f:
        config = json.load(f)

    bc = config["blockchain"]
    w3 = Web3(Web3.HTTPProvider(bc["rpc_url"]))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    account = w3.eth.account.from_key(PRIVATE_KEY)

    with open(ABI_DIR / "P2PEnergyMarket.json") as f:
        market_abi = json.load(f)["abi"]

    market = w3.eth.contract(
        address=Web3.to_checksum_address(bc["p2p_market_address"]),
        abi=market_abi
    )

    print(f"Owner-Account: {account.address}")
    print(f"Market-Contract: {bc['p2p_market_address']}\n")

    # Nonce einmal lokal holen und danach selbst hochzaehlen statt bei jeder TX
    # erneut abzufragen - der oeffentliche RPC ist lastverteilt ueber mehrere
    # Nodes, die den Mempool nicht synchron sehen ("replacement transaction
    # underpriced" bei schnell aufeinanderfolgenden TXs vom selben Account).
    nonce = w3.eth.get_transaction_count(account.address, "pending")

    for h in config["households"]:
        addr = Web3.to_checksum_address(h["address"])
        already = market.functions.isRegistered(addr).call()
        if already:
            print(f"  {h['id']} ({addr}): bereits registriert, skip")
            continue

        print(f"  {h['id']} ({addr}): registriere ...")
        tx = market.functions.registerHousehold(addr).build_transaction({
            "from": account.address,
            "nonce": nonce,
            "chainId": bc["chain_id"],
            "gas": 150_000,
            "maxFeePerGas": w3.to_wei("30", "gwei"),
            "maxPriorityFeePerGas": w3.to_wei("2", "gwei"),
        })
        signed = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        status = "OK" if receipt.status == 1 else "FEHLGESCHLAGEN"
        print(f"    -> {status} (Block {receipt.blockNumber})")
        nonce += 1

    print("\nFertig.")


if __name__ == "__main__":
    main()
