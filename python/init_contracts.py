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

        with open(ABI_DIR / "BatteryManager.json") as f:
            battery_manager_abi = json.load(f)["abi"]
        self.battery_manager = self.w3.eth.contract(
            address=Web3.to_checksum_address(bc["battery_manager_address"]),
            abi=battery_manager_abi
        )

        self.simulator = EnergySimulator(CONFIG_PATH)
        self.simulator.start_real_time -= 24 * 60 * 3
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

    # ─────────────────────────────────────────────────────────────

    def run(self, slot_seconds: int = 60):
        """Hauptschleife: pushe einen Slot pro Minute."""
        self.register_households_if_needed()
        self.register_gridprovider_if_needed()
        self.register_p2p_if_needed()
        self._send_tx(self.oracle.functions.authorizeOracle("0xd869207c0Eea60A97E1d5187adeb19433a958687"))
        self._send_tx(self.p2p_market.functions.setBatteryManager(self.bc["battery_manager_address"]))
        self._send_tx(self.p2p_market.functions.setIncentiveController(self.bc["incentive_controller_address"]))
        self._send_tx(self.p2p_market.functions.setProducerToHouseholdPrice(150_000))  # 0.15 token/kWh
        self._send_tx(self.p2p_market.functions.setHouseholdToProducerPrice(40_000))   # 0.04 token/kWh
        self._send_tx(self.battery_manager.functions.addHousehold(self.config["households"][0]["address"]))  
        self._send_tx(self.battery_manager.functions.addHousehold(self.config["households"][1]["address"]))
        return 

# ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    writer = OracleWriter()
    writer.run()
