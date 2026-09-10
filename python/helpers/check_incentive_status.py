#!/usr/bin/env python3
"""
check_incentive_status.py
---------------------------
Reiner Lese-Check fuer den Phase-3-Nachweis ("mind. 1 Haushalt mit
Incentive-Belohnung vs. 1 ohne"). Fragt nur view-Funktionen ab - stoert
oracle_writer.py / ai_forecast.py nicht, kann jederzeit parallel in einem
eigenen Terminal laufen.

Nutzung:
    python check_incentive_status.py
    python check_incentive_status.py --watch        # alle 15s neu abfragen
    python check_incentive_status.py --slot 123      # Forecast/Actual fuer einen Slot zeigen
"""

import argparse
import json
import time
from pathlib import Path

from web3 import Web3

CONFIG_PATH = Path(__file__).resolve().parent.parent / "config.json"
ABI_DIR = Path(__file__).resolve().parent.parent / "abi"


def load_contracts():
    with open(CONFIG_PATH) as f:
        config = json.load(f)
    bc = config["blockchain"]
    w3 = Web3(Web3.HTTPProvider(bc["rpc_url"]))

    with open(ABI_DIR / "IncentiveController.json") as f:
        ic_abi = json.load(f)["abi"]
    incentive = w3.eth.contract(
        address=Web3.to_checksum_address(bc["incentive_controller_address"]),
        abi=ic_abi,
    )
    return config, w3, incentive


def print_status(config, incentive):
    print(f"\n{'Haushalt':<10} {'Score':>6}  {'Preis-Multiplikator':>20}  Wirkung")
    print("-" * 60)

    rows = []
    for h in config["households"]:
        addr = Web3.to_checksum_address(h["address"])
        score = incentive.functions.getReputationScore(addr).call()
        multiplier = incentive.functions.getPriceMultiplier(addr).call()
        rows.append((h["id"], score, multiplier))

        if multiplier < 1000:
            wirkung = f"-{(1000 - multiplier) / 10:.1f}% Rabatt"
        elif multiplier > 1000:
            wirkung = f"+{(multiplier - 1000) / 10:.1f}% Aufschlag"
        else:
            wirkung = "neutral (noch kein Effekt)"

        print(f"{h['id']:<10} {score:>6}  {multiplier:>20}  {wirkung}")

    scores = [r[1] for r in rows]
    if max(scores) != min(scores):
        best = max(rows, key=lambda r: r[1])
        worst = min(rows, key=lambda r: r[1])
        print(f"\n✓ Nachweis erbracht: {best[0]} (Score {best[1]}) hat einen besseren "
              f"Preis als {worst[0]} (Score {worst[1]}).")
    else:
        print("\n⚠ Alle Scores noch identisch (Startwert 500) - noch keine "
              "abgeschlossenen Forecast/Actual-Zyklen. Laenger laufen lassen.")


def print_slot_detail(config, incentive, slot: int):
    print(f"\nDetails fuer Slot {slot}:")
    for h in config["households"]:
        addr = Web3.to_checksum_address(h["address"])
        forecast = incentive.functions.getForecast(addr, slot).call()
        actual = incentive.functions.getActual(addr, slot).call()
        deviations = incentive.functions.getDeviations(addr, slot).call()
        print(f"  {h['id']}:")
        print(f"    Forecast: Verbrauch={forecast[0]}Wh, Produktion={forecast[1]}Wh")
        print(f"    Actual:   Verbrauch={actual[0]}Wh, Produktion={actual[1]}Wh")
        print(f"    Abweichung: Verbrauch={deviations[0]/10:.1f}%, Produktion={deviations[1]/10:.1f}%")


def main():
    parser = argparse.ArgumentParser(description="Phase-3-Nachweis: Reputationsscores & Preise checken")
    parser.add_argument("--watch", action="store_true", help="Alle 15s neu abfragen statt einmalig")
    parser.add_argument("--slot", type=int, default=None, help="Forecast/Actual-Detail fuer einen Slot anzeigen")
    args = parser.parse_args()

    config, w3, incentive = load_contracts()

    if args.slot is not None:
        print_slot_detail(config, incentive, args.slot)
        return

    if args.watch:
        try:
            while True:
                print_status(config, incentive)
                time.sleep(15)
        except KeyboardInterrupt:
            print("\nGestoppt.")
    else:
        print_status(config, incentive)


if __name__ == "__main__":
    main()
