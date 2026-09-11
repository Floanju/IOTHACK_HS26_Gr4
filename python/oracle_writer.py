"""
oracle_writer.py

VOLLSTÄNDIG VORGEGEBEN - Teams modifizieren dieses Skript NICHT.

Liest Daten vom EnergySimulator und schreibt sie jeden Slot in den
OracleStorage Smart Contract auf Sepolia.

Verantwortlichkeiten:
  - Slot-Counter im Oracle aktualisieren
  - Pro Haushalt: Meter- und Batteriedaten on-chain schreiben
  - Wetterdaten on-chain schreiben
  - Nonce-Management & Retry bei Gas-Problemen

Hinweis zum Timing (bekannte Einschränkung, kein Bug in eurem Contract-Code):
  Pro Slot werden hier bis zu 8 sequenzielle Transaktionen gesendet
  (updateSlot, updateWeather, pro Haushalt updateMeter + updateBattery).
  Bei ~12s Blockzeit auf Sepolia kann ein Durchlauf locker die Ziel-Slotdauer
  von 60s überschreiten. `OracleStorage.currentSlot` läuft nach
  `block.timestamp`, nicht nach Anzahl `updateSlot()`-Aufrufen - er kann also
  auch mal Sprünge machen, wenn ein Durchlauf länger als 60s dauert. Plant
  eure Contract-Logik (v.a. settleSlot()) so, dass sie nicht auf exakte
  60-Sekunden-Abstände zwischen Slots angewiesen ist.

  Zusätzlich: Die simulierte Tageszeit und der Batterie-SoC leben nur im
  Prozessspeicher des EnergySimulator (siehe data_simulator.py). Bei jedem
  Neustart dieses Skripts (z.B. beim Debuggen) beginnt die simulierte Uhrzeit
  wieder bei 0 und der SoC wieder bei 50% - das ist erwartetes Verhalten,
  kein Fehler in eurem Contract-Code.

Voraussetzung:
  - .env mit ORACLE_PRIVATE_KEY (Wallet, die als autorisierter Oracle eingetragen ist)
  - config.json mit deployten Contract-Adressen
"""

import json
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

from data_simulator import EnergySimulator

load_dotenv()

CONFIG_PATH = Path(__file__).parent / "config.json"
ABI_DIR = Path(__file__).parent / "abi"

ORACLE_PRIVATE_KEY = os.getenv("ORACLE_PRIVATE_KEY")
if not ORACLE_PRIVATE_KEY:
    print("ERROR: ORACLE_PRIVATE_KEY in .env nicht gesetzt")
    sys.exit(1)


# ─────────────────────────────────────────────────────────────────────

class OracleWriter:
    """
    Schreibt simulierte Daten on-chain.
    """

    def __init__(self):
        with open(CONFIG_PATH) as f:
            self.config = json.load(f)

        bc = self.config["blockchain"]
        self.bc = bc
        self.w3 = Web3(Web3.HTTPProvider(bc["rpc_url"]))
        # Manche Sepolia-RPCs liefern PoA-extra-data
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)

        self.account = self.w3.eth.account.from_key(ORACLE_PRIVATE_KEY)
        print(f"Oracle Account: {self.account.address}")
        balance_eth = self.w3.from_wei(self.w3.eth.get_balance(self.account.address), "ether")
        print(f"Sepolia ETH Balance: {balance_eth}")

        # Lokal verfolgte Nonce statt vor jeder TX neu abzufragen - der oeffentliche
        # RPC ist lastverteilt ueber mehrere Nodes, die den Mempool nicht synchron
        # sehen ("replacement transaction underpriced" / "nonce too low" bei den
        # vielen sequenziellen TXs pro Slot).
        self._nonce = None

        # Contract laden
        with open(ABI_DIR / "OracleStorage.json") as f:
            oracle_abi = json.load(f)["abi"]
        self.oracle = self.w3.eth.contract(
            address=Web3.to_checksum_address(bc["oracle_storage_address"]),
            abi=oracle_abi
        )
        with open(ABI_DIR / "P2PEnergyMarket.json") as f:
            p2p_market_abi = json.load(f)["abi"]
        self.p2p_market = self.w3.eth.contract(
            address=Web3.to_checksum_address(bc["p2p_market_address"]),
            abi=p2p_market_abi
        )

        self.simulator = EnergySimulator(CONFIG_PATH)
        print(f"DEBUG: Simulator start time: {self.simulator.start_real_time}")
        self.chain_id = bc["chain_id"]


    # ─────────────────────────────────────────────────────────────

    def _send_tx(self, contract_function, max_retries: int = 3):
        """Baut, signiert, sendet eine Transaktion - mit Retry, Nonce-Management und Status-Check."""
        nonce = self.w3.eth.get_transaction_count(self.account.address, "pending")
        priority_fee_gwei = 2
        last_exc = None

        for attempt in range(max_retries):
            try:
                base_tx = {
                    "from": self.account.address,
                    "nonce": nonce,  # fixed across retries - we're replacing, not queuing
                    "chainId": self.chain_id,
                    "maxFeePerGas": self.w3.to_wei("30", "gwei"),
                    "maxPriorityFeePerGas": self.w3.to_wei(str(priority_fee_gwei), "gwei"),
                }
                try:
                    estimated = contract_function.estimate_gas(base_tx)
                    gas_limit = int(estimated * 1.3)
                except Exception as est_err:
                    raise RuntimeError(f"Simulation failed, not sending: {est_err}") from est_err

                tx = contract_function.build_transaction({**base_tx, "gas": gas_limit})
                signed = self.w3.eth.account.sign_transaction(tx, ORACLE_PRIVATE_KEY)
                tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)

                receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

                if receipt.status != 1:
                    raise RuntimeError(f"Tx {tx_hash.hex()} mined but reverted (status={receipt.status})")
                return receipt

            except Exception as e:
                last_exc = e
                print(f"  TX fehlgeschlagen (Versuch {attempt+1}): {e}")
                # Same nonce next time, but bump priority fee so the replacement
                # is valid (nodes require >= a % bump over the pending tx's fee)
                # and actually propagates instead of being silently dropped.
                priority_fee_gwei = int(priority_fee_gwei * 1.5) + 1
                time.sleep(5)

        raise RuntimeError(f"Max retries erreicht: {last_exc}")
    # ─────────────────────────────────────────────────────────────

    def register_households_if_needed(self):
        """Stellt sicher, dass alle konfigurierten Haushalte im Oracle registriert sind."""
        for h in self.config["households"]:
            addr = Web3.to_checksum_address(h["address"])
            registered = self.oracle.functions.isHouseholdRegistered(addr).call()
            if registered:
                print(f"Haushalt {h['id']} ({addr}) bereits registriert.")
                continue
            print(f"Registriere Haushalt {h['id']} ({addr}) ...")
            self._send_tx(self.oracle.functions.registerHousehold(addr))

    def register_gridprovider_if_needed(self):
        """Registriert den Gridprovider im P2P Market und im Oracle."""
        grid_addr = Web3.to_checksum_address(self.config["grid_provider"]["address"])
        
        # 1. Oracle Registration (Required for updateMeter to succeed)
        registered_oracle = self.oracle.functions.isHouseholdRegistered(grid_addr).call()
        if not registered_oracle:
            print(f"Registriere Grid im Oracle ({grid_addr}) ...")
            self._send_tx(self.oracle.functions.registerHousehold(grid_addr))
            
        # 2. P2P Market Producer Registration
        registered_p2p = self.p2p_market.functions.isRegisteredProducer(grid_addr).call()
        if not registered_p2p:
            print(f"Registriere Grid als Producer im P2P ({grid_addr}) ...")
            self._send_tx(self.p2p_market.functions.registerProducer(grid_addr))

    def register_p2p_if_needed(self):
        """Stellt sicher, dass alle konfigurierten Haushalte im P2P Market registriert sind."""
        for h in self.config["households"]:
            addr = Web3.to_checksum_address(h["address"])
            
            # Check isRegistered instead of isRegisteredProducer
            registered_p2p = self.p2p_market.functions.isRegistered(addr).call()
            
            if not registered_p2p:
                print(f"Registriere Haushalt {h['id']} ({addr}) im P2P-Market...")
                # Call registerHousehold instead of registerProducer
                self._send_tx(self.p2p_market.functions.registerHousehold(addr))

    def register_grid_operator_if_needed(self):
        """Registriert EKR (Netzbetreiber) als Producer im P2P Market - EKR ist kein
        Haushalt und wird daher separat von register_households_if_needed() behandelt."""
        ekr = self.config.get("grid_operator")
        if not ekr:
            return
        addr = Web3.to_checksum_address(ekr["address"])
        registered = self.p2p_market.functions.isRegisteredProducer(addr).call()
        if registered:
            print(f"Netzbetreiber {ekr['id']} ({addr}) bereits als Producer registriert.")
            return
        print(f"Registriere Netzbetreiber {ekr['id']} ({addr}) als Producer ...")
        self._send_tx(self.p2p_market.functions.registerProducer(addr))

    def sync_grid_operator_prices(self):
        """Schreibt EKRs Ankaufs-/Verkaufspreis in den P2P Market, falls abweichend.

        buy_price_per_kwh:  Preis, den EKR fuer von Haushalten gekaufte
                             Ueberschuss-Energie zahlt (householdToProducerPrice).
        sell_price_per_kwh: Preis, den EKR fuer an Haushalte verkaufte Energie
                             verlangt (producerToHouseholdPrice).
        """
        ekr = self.config.get("grid_operator")
        if not ekr:
            return
        buy_price = ekr["buy_price_per_kwh"]
        sell_price = ekr["sell_price_per_kwh"]

        if self.p2p_market.functions.householdToProducerPrice().call() != buy_price:
            print(f"Setze EKR-Ankaufspreis (Haushalt -> EKR) auf {buy_price} ...")
            self._send_tx(self.p2p_market.functions.setHouseholdToProducerPrice(buy_price))

        if self.p2p_market.functions.producerToHouseholdPrice().call() != sell_price:
            print(f"Setze EKR-Verkaufspreis (EKR -> Haushalt) auf {sell_price} ...")
            self._send_tx(self.p2p_market.functions.setProducerToHouseholdPrice(sell_price))

    # ─────────────────────────────────────────────────────────────

    def push_slot(self):
        """Liest Simulator-Daten und schreibt sie als kompletten Slot on-chain."""
        data = self.simulator.get_current_readings()

        # 1. Slot-Counter aktualisieren
        print(f"\n→ Slot {time.strftime('%H:%M:%S')} (Sim-h={data['sim_hour']:.2f})")
        self._send_tx(self.oracle.functions.updateSlot())

        # 2. Wetterdaten schreiben
        w = data["weather"]
        self._send_tx(self.oracle.functions.updateWeather(
            w["irradiance_wm2"],
            w["temperature_c_x10"],
            w["cloud_cover"]
        ))
        print(f"  Wetter: {w['irradiance_wm2']} W/m², {w['cloud_cover']}% Wolken")

        # 3. Pro Haushalt: Meter und Battery
        for h in data["households"]:
            addr = Web3.to_checksum_address(h["address"])
            self._send_tx(self.oracle.functions.updateMeter(
                addr,
                h["consumption_wh"],
                h["production_wh"]
            ))
            if h["battery_capacity_wh"] >= 0:
                self._send_tx(self.oracle.functions.updateBattery(
                    addr,
                    h["battery_soc"],
                    h["battery_capacity_wh"],
                    h["battery_max_rate_wh"]
                ))
            print(f"{h['household_id']}: "
                  f"V={h['consumption_wh']}Wh, P={h['production_wh']}Wh, "
                  f"SoC={h['battery_soc']}%")
        print("settleSlot() wird im P2P-Market aufgerufen, um den Slot abzuschliessen.")
        self._send_tx(self.p2p_market.functions.settleSlot())
        time.sleep(1)  # Kurze Pause, damit die nächste Runde nicht sofort startet

    # ─────────────────────────────────────────────────────────────

    def run(self, slot_seconds: int = 60):
        """Hauptschleife: pushe einen Slot pro Minute."""
        print("\n=== Oracle Writer gestartet ===\n")
        # self.run_init()
        try:
            while True:
                start = time.time()
                self.push_slot()
                elapsed = time.time() - start
                wait = max(0, slot_seconds - elapsed)
                print(f"  (warte {wait:.0f}s bis nächster Slot)")
                time.sleep(wait)
        except KeyboardInterrupt:
            print("\nOracle Writer gestoppt.")


# ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    writer = OracleWriter()
    writer.run()
