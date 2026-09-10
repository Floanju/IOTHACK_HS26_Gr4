"""
ai_forecast.py

STARTER-CODE - Teams ersetzen das Modell durch eigene Wahl.
Nur relevant für Phase 3 (optional).

Granularitaet: "stuendlich" lt. Challenge-Vorgabe = alle 4 Minuten Realzeit
(1 Sim-Stunde = 4 echte Minuten). Ein einzelner Oracle-Slot ist mit 15
Sim-Minuten feiner als das - der Forecast-Loop erzwingt daher eine
Mindestzykluszeit von 4 Minuten (MIN_CYCLE_SECONDS), reagiert aber weiterhin
auf den naechsten TATSAECHLICH geschriebenen Slot statt einen zu erraten
(sonst passen Forecast- und Actual-Slot bei unregelmaessig schreibenden
Oracle-Writern nie zusammen - siehe Kommentare im Forecast-Loop).

Zwei getrennte Prognosen pro Haushalt und Slot:
  - PV-Produktion: physikalisch via PVPhysicalModel (pvlib), braucht KEINE
    Trainingsdaten - nutzt nur pv_peak_kwp + aktuelles Oracle-Wetter.
  - Verbrauch: ForecastModel (Default: lineare Regression) auf historischen
    Daten direkt aus den on-chain Events von OracleStorage (MeterUpdated +
    WeatherUpdated) - nicht aus einer lokalen Datei, damit alle im Team
    dieselbe Historie sehen, unabhaengig davon, wer gerade oracle_writer.py
    laufen laesst. Solange zu wenig Historie da ist, wird eine einfache
    Baseline-Schaetzung aus config.json (base_consumption_kwh_per_hour)
    verwendet, damit trotzdem von Anfang an Forecasts submitted werden.
Erwartung: Teams ersetzen ForecastModel mit XGBoost, LSTM, Prophet, etc.

Einschraenkungen der on-chain-Historie (nicht rekonstruierbar, da nie
on-chain gespeichert):
  - cloud_cover ist nicht Teil von WeatherUpdated() -> faellt als Feature weg
  - sim_hour/sim_dayofweek (die fiktive, beschleunigte Simulator-Uhr) gab es
    nur im Prozessspeicher des jeweiligen lokalen Simulators - stattdessen
    wird die echte Stunde/Wochentag aus dem block.timestamp der Events
    verwendet (das waere auch die Groesse, mit der ein System ohne
    Python-Simulator arbeiten wuerde).

Voraussetzung:
  - .env mit AI_PRIVATE_KEY (autorisiert in IncentiveController)
  - pvlib installiert (siehe requirements.txt)
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pvlib
from dotenv import load_dotenv
from sklearn.linear_model import LinearRegression
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

from data_simulator import SIM_MINUTES_PER_SLOT

load_dotenv()

CONFIG_PATH = Path(__file__).parent / "config.json"
ABI_DIR = Path(__file__).parent / "abi"

PRIVATE_KEY = os.getenv("AI_PRIVATE_KEY") or os.getenv("DEPLOYER_PRIVATE_KEY")
if not PRIVATE_KEY:
    print("ERROR: AI_PRIVATE_KEY in .env nicht gesetzt")
    sys.exit(1)


# ─────────────────────────────────────────────────────────────────────
#  Datenextraktion aus on-chain Events
# ─────────────────────────────────────────────────────────────────────

# RPC-Limit fuer eth_getLogs-Blockbereiche (oeffentliche Nodes begrenzen das,
# z.B. "exceed maximum block range: 50000" - knapp darunter bleiben).
MAX_LOG_BLOCK_RANGE = 45_000


def _get_logs_safe(event, argument_filters=None):
    """get_logs(from_block=0) scheitert auf manchen oeffentlichen RPCs an
    Range-Limits - falls das passiert, auf die letzten Bloecke innerhalb
    des erlaubten Bereichs zurueckfallen."""
    kwargs = {"from_block": 0}
    if argument_filters:
        kwargs["argument_filters"] = argument_filters
    try:
        return event.get_logs(**kwargs)
    except Exception:
        latest = event.w3.eth.block_number
        kwargs["from_block"] = max(0, latest - MAX_LOG_BLOCK_RANGE)
        return event.get_logs(**kwargs)


def load_weather_by_slot(oracle):
    """Holt alle WeatherUpdated-Events einmal - wird fuer alle Haushalte
    gemeinsam genutzt, statt pro Haushalt neu abgefragt zu werden."""
    weather_logs = _get_logs_safe(oracle.events.WeatherUpdated)
    return {
        log["args"]["slot"]: (log["args"]["irradiance"], log["args"]["temperature"])
        for log in weather_logs
    }


def load_training_data(oracle, household_address: str, weather_by_slot: dict, min_rows: int = 50):
    """Holt Verbrauch + Wetter + Zeitfeatures direkt aus den on-chain Events
    von OracleStorage fuer das Verbrauchsmodell. Produktion wird nicht
    trainiert, sondern physikalisch berechnet (siehe PVPhysicalModel)."""
    household_address = Web3.to_checksum_address(household_address)

    meter_logs = _get_logs_safe(
        oracle.events.MeterUpdated,
        argument_filters={"household": household_address},
    )
    if len(meter_logs) < min_rows:
        return None, None

    # Zeitpunkt pro Slot ohne get_block()-Call pro Event: OracleStorage.updateSlot()
    # setzt currentSlot = (block.timestamp - startTimestamp) / SLOT_DURATION (60s),
    # also laesst sich der Zeitpunkt direkt aus dem Slot zurueckrechnen - ein
    # get_block() je Event waere bei vielen Datenpunkten viel zu langsam.
    start_timestamp = oracle.functions.startTimestamp().call()
    SLOT_DURATION = 60

    rows, targets = [], []
    for log in meter_logs:
        slot = log["args"]["slot"]
        if slot not in weather_by_slot:
            continue
        irradiance, temperature_x10 = weather_by_slot[slot]

        approx_ts = start_timestamp + slot * SLOT_DURATION
        dt = datetime.fromtimestamp(approx_ts, tz=timezone.utc)

        rows.append([dt.hour, dt.weekday(), irradiance, temperature_x10])
        targets.append(log["args"]["consumption"])

    if len(rows) < min_rows:
        return None, None
    return np.array(rows, dtype=float), np.array(targets, dtype=float)


# ─────────────────────────────────────────────────────────────────────
#  PV-Produktionsprognose (physikalisch, angelehnt an pv_vorhersage_rotkreuz.ipynb)
# ─────────────────────────────────────────────────────────────────────

# Typischer Temperaturkoeffizient fuer kristalline Silizium-Module (%-Leistung/°C)
PV_GAMMA_PDC = -0.004
# Pauschale Systemverluste (Verkabelung, Wechselrichter etc.)
PV_SYSTEM_LOSS_FRACTION = 0.10


class PVPhysicalModel:
    """
    Berechnet die erwartete PV-Produktion direkt aus Anlagengroesse + Wetter,
    via pvlib.pvsystem.pvwatts_dc() - im Gegensatz zu ForecastModel braucht das
    KEINE Trainingsdaten. Kann also schon Vorhersagen liefern, bevor genug
    Slots in data/history.db gesammelt wurden.

    Vereinfachung ggue. dem vollen pvlib-Modell aus dem Notebook: unser
    simulierter Wetter-Feed liefert nur einen einzelnen Einstrahlungswert
    (kein GHI/DNI/DHI getrennt, keine Sonnenstandsberechnung noetig) und
    bildet Bewoelkung schon in diesem Wert ab (siehe data_simulator._generate_weather) -
    daher reicht das einfachere PVWatts-Modell statt der vollen POA-Zerlegung.
    """

    def __init__(self, pv_peak_kwp: float):
        self.pdc0_w = pv_peak_kwp * 1000  # Nennleistung in Watt

    def predict_production_wh(self, irradiance_wm2: float, temperature_c: float) -> float:
        if self.pdc0_w == 0:
            return 0.0

        pdc_w = pvlib.pvsystem.pvwatts_dc(
            effective_irradiance=irradiance_wm2,
            temp_cell=temperature_c,
            pdc0=self.pdc0_w,
            gamma_pdc=PV_GAMMA_PDC,
        )
        pdc_w *= (1 - PV_SYSTEM_LOSS_FRACTION)

        wh_per_slot = pdc_w * (SIM_MINUTES_PER_SLOT / 60.0)
        return max(0.0, wh_per_slot)


# ─────────────────────────────────────────────────────────────────────
#  Verbrauchsmodell  (HIER ERSETZEN TEAMS)
# ─────────────────────────────────────────────────────────────────────

class ForecastModel:
    """
    Default: einfache lineare Regression.

    TODO (Teams): Ersetzt diese Klasse durch ein leistungsfähigeres Modell.
    Empfehlungen:
      - sklearn.ensemble.GradientBoostingRegressor (robust, einfach)
      - xgboost.XGBRegressor (schnell, sehr genau)
      - prophet (gut für saisonale Muster)
      - tensorflow/keras LSTM (für Sequenzdaten - aufwendiger)

    Wichtig: Methode predict(X) muss eine Vorhersage zurückgeben.

    Hinweis: Die PV-Produktion wird nicht mehr hier vorhergesagt, sondern
    physikalisch von PVPhysicalModel berechnet (siehe oben) - kein
    zweites, unnoetiges ML-Modell fuer eine Groesse, die sich direkt aus
    Anlagenleistung + Wetter ableiten laesst.
    """
    def __init__(self):
        self.model_consumption = LinearRegression()
        self.is_trained = False

    def train(self, X, y_consumption):
        self.model_consumption.fit(X, y_consumption)
        self.is_trained = True

    def predict(self, X):
        if not self.is_trained:
            raise RuntimeError("Modell nicht trainiert")
        cons = self.model_consumption.predict(X)
        return np.maximum(0, cons)


# ─────────────────────────────────────────────────────────────────────
#  On-chain Submitter
# ─────────────────────────────────────────────────────────────────────

def submit_forecast_onchain(w3, contract, account, household_addr, slot, expected_cons, expected_prod):
    nonce = w3.eth.get_transaction_count(account.address, "pending")
    tx = contract.functions.submitForecast(
        Web3.to_checksum_address(household_addr),
        slot,
        int(expected_cons),
        int(expected_prod)
    ).build_transaction({
        "from": account.address,
        "nonce": nonce,
        "chainId": w3.eth.chain_id,
        "gas": 250_000,
        "maxFeePerGas": w3.to_wei("30", "gwei"),
        "maxPriorityFeePerGas": w3.to_wei("2", "gwei"),
    })
    signed = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)


def submit_actual_onchain(w3, contract, account, household_addr, slot, actual_cons, actual_prod):
    nonce = w3.eth.get_transaction_count(account.address, "pending")
    tx = contract.functions.submitActual(
        Web3.to_checksum_address(household_addr),
        slot,
        int(actual_cons),
        int(actual_prod)
    ).build_transaction({
        "from": account.address,
        "nonce": nonce,
        "chainId": w3.eth.chain_id,
        "gas": 250_000,
        "maxFeePerGas": w3.to_wei("30", "gwei"),
        "maxPriorityFeePerGas": w3.to_wei("2", "gwei"),
    })
    signed = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)


# ─────────────────────────────────────────────────────────────────────
#  Hauptschleife
# ─────────────────────────────────────────────────────────────────────

def main():
    with open(CONFIG_PATH) as f:
        config = json.load(f)

    bc = config["blockchain"]
    w3 = Web3(Web3.HTTPProvider(bc["rpc_url"]))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    account = w3.eth.account.from_key(PRIVATE_KEY)

    with open(ABI_DIR / "IncentiveController.json") as f:
        ic_abi = json.load(f)["abi"]
    with open(ABI_DIR / "OracleStorage.json") as f:
        oracle_abi = json.load(f)["abi"]

    incentive = w3.eth.contract(
        address=Web3.to_checksum_address(bc["incentive_controller_address"]),
        abi=ic_abi
    )
    oracle = w3.eth.contract(
        address=Web3.to_checksum_address(bc["oracle_storage_address"]),
        abi=oracle_abi
    )

    print(f"AI Forecaster gestartet, Account: {account.address}\n")

    # Pro Haushalt: PV-Modell ist sofort einsatzbereit (keine Trainingsdaten
    # noetig), Verbrauchsmodell nur falls schon genug Historie da ist - sonst
    # Baseline-Schaetzung aus config.json, bis genug Daten gesammelt sind.
    weather_by_slot = load_weather_by_slot(oracle)

    household_models = {}
    for h in config["households"]:
        pv_model = PVPhysicalModel(h.get("pv_peak_kwp", 0.0))

        consumption_model = None
        X, y_consumption = load_training_data(oracle, h["address"], weather_by_slot)
        if X is not None:
            consumption_model = ForecastModel()
            consumption_model.train(X, y_consumption)
            print(f"  ✓ {h['id']}: Verbrauchsmodell trainiert auf {len(X)} Samples")
        else:
            print(f"  ⚠ {h['id']}: Zu wenig Trainingsdaten fuer Verbrauchsmodell, nutze Baseline-Schaetzung")

        household_models[h["id"]] = {
            "config": h,
            "pv_model": pv_model,
            "consumption_model": consumption_model,
        }

    print()

    # Prognosegranularitaet lt. Challenge: "stuendlich" = alle 4 Minuten
    # Realzeit (siehe README/PDF, 1 Sim-Stunde = 4 echte Minuten). Ein
    # einzelner Oracle-Slot ist mit 15 Sim-Minuten feiner als das - deshalb
    # hier eine Mindestzykluszeit erzwingen, statt bei jedem einzelnen Slot
    # zu prognostizieren.
    MIN_CYCLE_SECONDS = 4 * 60

    # Forecast-Loop
    while True:
        try:
            cycle_start = time.time()
            slot_before = oracle.functions.getCurrentSlot().call()

            # NICHT "current_slot + 1" vorab raten: die Oracle-Writer schreiben
            # unregelmaessig (beobachtet: 150-400s Luecken statt fix 60s) und
            # landen dabei auf JEDEM beliebigen currentSlot-Wert, abhaengig von
            # der seit Vertrags-Deployment vergangenen Echtzeit - ein geratener
            # "+1"-Slot wird so gut wie nie tatsaechlich beschrieben. Stattdessen
            # abwarten, bis sich currentSlot wirklich aendert, und DIESEN Wert
            # fuer Forecast + Actual verwenden.
            print(f"\n→ Warte auf naechsten Slot (aktuell {slot_before}) ...")
            SLOT_POLL_INTERVAL = 15
            SLOT_MAX_WAIT = 10 * 60
            waited = 0
            target_slot = None
            while waited < SLOT_MAX_WAIT:
                time.sleep(SLOT_POLL_INTERVAL)
                waited += SLOT_POLL_INTERVAL
                s = oracle.functions.getCurrentSlot().call()
                if s != slot_before:
                    target_slot = s
                    break

            if target_slot is None:
                print(f"  Kein neuer Slot nach {SLOT_MAX_WAIT}s - naechster Versuch")
                continue

            # Hole aktuelles Wetter als Feature-Quelle für die Forecast
            weather = oracle.functions.getLatestWeather().call()
            # Features für nächsten Slot - UTC statt Lokalzeit, damit es zur
            # Trainingsdaten-Extraktion aus block.timestamp passt (load_training_data):
            now_utc = datetime.now(timezone.utc)
            features = np.array([[
                now_utc.hour, now_utc.weekday(),
                weather[0], weather[1]
            ]])

            print(f"\n→ Erzeuge Forecast für Slot {target_slot}")

            for h_id, hm in household_models.items():
                h_cfg = hm["config"]

                # PV-Produktion: physikalisch, immer verfuegbar
                temperature_c = weather[1] / 10.0  # Contract speichert *10 (Fixedpoint)
                prod = hm["pv_model"].predict_production_wh(weather[0], temperature_c)

                # Verbrauch: ML-Modell falls trainiert, sonst Baseline aus config.json
                if hm["consumption_model"] is not None:
                    cons = hm["consumption_model"].predict(features)[0]
                else:
                    base_kwh_per_hour = h_cfg.get("base_consumption_kwh_per_hour", 0.0)
                    cons = base_kwh_per_hour * 1000 * (SIM_MINUTES_PER_SLOT / 60.0)

                print(f"  {h_id}: Verbrauch={cons:.0f}Wh, Produktion={prod:.0f}Wh")

                submit_forecast_onchain(
                    w3, incentive, account,
                    h_cfg["address"], target_slot, cons, prod
                )

            # Actuals fuer GENAU den Slot, der eben forecasted wurde - nicht
            # fuer irgendeine "aktuellste" Messung. getMeterAtSlot() statt
            # getLatestMeterReading(), sonst passen Forecast- und Actual-Slot
            # bei mehreren parallel laufenden Oracle-Writern nie zusammen.
            #
            # target_slot wurde oben schon als real existierender Slot
            # beobachtet - hier daher nur eine kurze Karenzzeit, bis
            # updateMeter() fuer alle Haushalte innerhalb desselben
            # push_slot()-Zyklus nachgezogen hat (statt der langen Wartezeit
            # von oben, die auf den naechsten Slot ueberhaupt wartet).
            GRACE_POLL_INTERVAL = 5
            GRACE_MAX_WAIT = 60
            grace_waited = 0
            meters = {}
            while grace_waited < GRACE_MAX_WAIT and len(meters) < len(household_models):
                for h_id, hm in household_models.items():
                    addr = Web3.to_checksum_address(hm["config"]["address"])
                    if addr in meters:
                        continue
                    mr = oracle.functions.getMeterAtSlot(addr, target_slot).call()
                    if mr[2] != 0:
                        meters[addr] = mr
                if len(meters) < len(household_models):
                    time.sleep(GRACE_POLL_INTERVAL)
                    grace_waited += GRACE_POLL_INTERVAL

            print(f"\n→ Submitte actuals für Slot {target_slot} (nach {grace_waited}s Karenzzeit)")
            for h_id, hm in household_models.items():
                h_cfg = hm["config"]
                addr = Web3.to_checksum_address(h_cfg["address"])

                meter = meters.get(addr)
                if meter is None:
                    print(f"  {h_id}: noch keine Daten fuer Slot {target_slot}, ueberspringe")
                    continue

                actual_cons = meter[0]
                actual_prod = meter[1]
                print(f"  {h_id}: actual cons={actual_cons}, prod={actual_prod}")

                submit_actual_onchain(
                    w3, incentive, account,
                    h_cfg["address"], target_slot, actual_cons, actual_prod
                )

            # Mindestabstand von 4 Minuten zwischen zwei Prognose-Zyklen
            # einhalten (siehe MIN_CYCLE_SECONDS oben) - falls das reaktive
            # Warten auf den naechsten Slot schneller fertig war.
            elapsed = time.time() - cycle_start
            remaining = MIN_CYCLE_SECONDS - elapsed
            if remaining > 0:
                print(f"  Zyklus war nach {elapsed:.0f}s fertig, warte weitere "
                      f"{remaining:.0f}s bis zum naechsten 4-Minuten-Zyklus ...")
                time.sleep(remaining)

        except Exception as e:
            print(f"  Fehler: {e}")
            time.sleep(60)


if __name__ == "__main__":
    main()
