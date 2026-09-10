"""
settlement_trigger.py

STARTER-CODE - Teams passen die TODO-Blöcke an ihren eigenen Contract an.

Ruft jede Simulationsminute settleSlot() auf dem P2PEnergyMarket-Contract auf.
Damit wird der vom Oracle gefütterte Slot abgerechnet:
  - Produzenten erhalten Stablecoins
  - Konsumenten zahlen Stablecoins

Voraussetzung:
  - .env mit TRIGGER_PRIVATE_KEY (sollte NICHT derselbe Key sein wie ein
    parallel laufender Oracle-/Meter-Feeder, sonst Nonce-Konflikte)
  - config.json mit p2p_market_address gesetzt
  - Konsumenten müssen vorher approve() auf den Stablecoin aufgerufen haben

Logging: INFO für normalen Ablauf, WARNING für auffällige aber nicht-fatale
Zustände (z.B. State hat sich während des Sendens verändert), ERROR für
fehlgeschlagene Settlements und Exceptions.
"""

import json
import logging
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from web3.exceptions import ContractLogicError, TransactionNotFound

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("settlement_trigger")

CONFIG_PATH = Path(__file__).parent / "config.json"
ABI_DIR = Path(__file__).parent / "abi"

PRIVATE_KEY = os.getenv("TRIGGER_PRIVATE_KEY") or os.getenv("DEPLOYER_PRIVATE_KEY")
if not PRIVATE_KEY:
    log.error("TRIGGER_PRIVATE_KEY in .env nicht gesetzt")
    sys.exit(1)

# Minimales ABI-Fragment, nur für Diagnose-Zwecke - wir brauchen nicht das
# volle OracleStorage-ABI, nur diese eine View-Funktion, um liveSlot vor und
# nach dem Senden zu vergleichen.
ORACLE_DIAG_ABI = [
    {
        "inputs": [],
        "name": "getCurrentSlot",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]


def get_revert_reason(w3: Web3, tx: dict, block_identifier) -> str:
    """
    Repliziert die fehlgeschlagene Transaktion als eth_call auf demselben
    Block (inkl. gleichem Gas-Limit - sonst wird ein 'out of gas' beim
    Replay nicht reproduziert).
    """
    call_tx = {k: v for k, v in tx.items() if k in ("from", "to", "data", "value", "gas")}
    try:
        w3.eth.call(call_tx, block_identifier=block_identifier)
        return ("unbekannt (Replay-Call ist NICHT fehlgeschlagen, auch mit gleichem "
                "Gas-Limit - State hat sich vermutlich zwischen TX-Erstellung und "
                "Mining veraendert)")
    except ContractLogicError as e:
        return str(e)
    except Exception as e:
        return f"Replay-Call Fehler (raw): {e}"


def try_debug_trace(w3: Web3, tx_hash) -> None:
    """
    Optional: funktioniert nur, wenn der RPC-Node debug_traceTransaction
    unterstuetzt (z.B. lokales Anvil/Hardhat/Ganache).
    """
    try:
        trace = w3.manager.request_blocking(
            "debug_traceTransaction", [tx_hash.hex(), {"tracer": "callTracer"}]
        )
        log.info("Trace: %s", json.dumps(trace, default=str)[:800])
    except Exception as e:
        log.info("debug_traceTransaction nicht verfuegbar: %s", e)


def unstick_pending_tx(w3: Web3, account, bc, private_key: str) -> bool:
    """
    Prueft, ob eine unbestaetigte TX im Mempool haengt (pending > latest).

    Dieser Account kann von mehr als einem Prozess genutzt werden (z.B.
    einem Oracle-/Simulator-Skript). Auf einem geteilten Key per
    Replace-by-Fee automatisch draufzufeuern ist gefaehrlich - man wuerde
    ggf. eine legitime TX des anderen Prozesses ersetzen/canceln. Deshalb
    standardmaessig nur warnen, nicht automatisch senden. Auto-Replace nur,
    wenn TRIGGER_AUTO_UNSTICK=true explizit gesetzt ist.

    Gibt True zurueck, wenn diese Runde uebersprungen werden soll.
    """
    latest = w3.eth.get_transaction_count(account.address, "latest")
    pending = w3.eth.get_transaction_count(account.address, "pending")

    if pending <= latest:
        return False

    log.warning(
        "Account hat %d unbestaetigte TX (nonce %d..%d). Ueberspringe diese Runde.",
        pending - latest, latest, pending - 1,
    )

    if os.getenv("TRIGGER_AUTO_UNSTICK", "false").lower() == "true":
        stuck_nonce = latest
        latest_block = w3.eth.get_block("latest")
        base_fee = latest_block.get("baseFeePerGas", w3.to_wei("1", "gwei"))
        max_fee = base_fee * 3 + w3.to_wei("10", "gwei")
        bump_tx = {
            "from": account.address,
            "to": account.address,
            "value": 0,
            "nonce": stuck_nonce,
            "chainId": bc["chain_id"],
            "gas": 21_000,
            "maxFeePerGas": max_fee,
            "maxPriorityFeePerGas": w3.to_wei("10", "gwei"),
        }
        try:
            signed = w3.eth.account.sign_transaction(bump_tx, private_key)
            h = w3.eth.send_raw_transaction(signed.raw_transaction)
            log.info("[TRIGGER_AUTO_UNSTICK=true] Replace-TX gesendet: %s", h.hex())
            w3.eth.wait_for_transaction_receipt(h, timeout=120)
        except Exception as e:
            log.error("Replace fehlgeschlagen: %r", e)

    return True


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

    oracle_address = market.functions.oracle().call()
    oracle_diag = w3.eth.contract(
        address=Web3.to_checksum_address(oracle_address),
        abi=ORACLE_DIAG_ABI
    )
    max_slots_per_settle = market.functions.MAX_SLOTS_PER_SETTLE().call()

    log.info("Settlement-Trigger gestartet, Account: %s", account.address)
    log.info("Market-Contract: %s", bc["p2p_market_address"])

    account_code = w3.eth.get_code(account.address)
    if account_code and account_code != b"":
        log.warning(
            "Account %s hat Code gesetzt (%s...), evtl. EIP-7702-Delegation.",
            account.address, account_code.hex()[:20],
        )

    while True:
        try:
            log.info("Trigger settleSlot()")

            # ─────────────────────────────────────────────────────
            # TODO (Teams): Anpassen falls eure settleSlot() Parameter braucht
            #
            # Beispiele fuer Erweiterungen:
            #   - settleSlot(uint256 slot)              -> Slot-Argument uebergeben
            #   - settleHousehold(address household)    -> einzeln pro Haushalt
            #   - settleSlotWithLimit(uint256 maxGas)   -> mit Gas-Limit
            #
            # Aktuell: nimmt an, dass settleSlot() ohne Argumente aufrufbar ist.
            # ─────────────────────────────────────────────────────

            if unstick_pending_tx(w3, account, bc, PRIVATE_KEY):
                time.sleep(60)
                continue

            fn = market.functions.settleSlot()

            live_slot_before = oracle_diag.functions.getCurrentSlot().call()
            last_settled_before = market.functions.lastSettledSlot().call()
            planned_to = min(live_slot_before, last_settled_before + max_slots_per_settle)
            n_slots_planned = planned_to - last_settled_before
            log.info(
                "liveSlot=%d, lastSettledSlot=%d -> geplanter Bereich [%d..%d] (%d Slot(s))",
                live_slot_before, last_settled_before,
                last_settled_before + 1, planned_to, n_slots_planned,
            )

            try:
                estimated_gas = fn.estimate_gas({"from": account.address})
            except ContractLogicError as e:
                if "Slot already settled" in str(e):
                    log.info(
                        "Nichts zu settlen: liveSlot=%d == lastSettledSlot=%d. "
                        "Warte auf neue Oracle-Daten.",
                        live_slot_before, last_settled_before,
                    )
                else:
                    log.error("Simulation schlaegt fehl, TX wird NICHT gesendet: %s", e)
                time.sleep(60)
                continue

            gas_limit = int(estimated_gas * 1.6)  # Puffer fuer evtl. zusaetzlichen Slot
            log.info("Geschaetztes Gas: %d -> Limit mit Puffer: %d", estimated_gas, gas_limit)

            nonce = w3.eth.get_transaction_count(account.address, "pending")
            tx = fn.build_transaction({
                "from": account.address,
                "nonce": nonce,
                "chainId": bc["chain_id"],
                "gas": gas_limit,
                "maxFeePerGas": w3.to_wei("30", "gwei"),
                "maxPriorityFeePerGas": w3.to_wei("2", "gwei"),
            })
            signed = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            log.info("TX gesendet: %s", tx_hash.hex())
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

            if receipt.status == 1:
                log.info("Settlement erfolgreich (Block %d)", receipt.blockNumber)
            else:
                log.error("Settlement fehlgeschlagen (Block %d)", receipt.blockNumber)
                live_slot_after = oracle_diag.functions.getCurrentSlot().call()
                if live_slot_after != live_slot_before:
                    log.warning(
                        "liveSlot hat sich waehrend des Sendens geaendert: %d -> %d. "
                        "TX wurde fuer %d Slot(s) budgetiert, musste beim Mining aber "
                        "vermutlich %d Slot(s) abdecken.",
                        live_slot_before, live_slot_after,
                        n_slots_planned, live_slot_after - last_settled_before,
                    )
                reason = get_revert_reason(w3, tx, receipt.blockNumber)
                log.error("Grund: %s", reason)
                try_debug_trace(w3, tx_hash)

        except TransactionNotFound:
            log.error("TX wurde nicht gefunden (evtl. verworfen/Reorg) - retry naechste Runde")
        except ContractLogicError as e:
            log.error("Contract-Revert: %s", e)
        except Exception as e:
            log.error("Fehler: %r", e)

        time.sleep(60)  # 1 Slot warten


if __name__ == "__main__":
    main()