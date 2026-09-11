# Energy Trading Challenge — IOTHACK HS26, Gruppe 4

Peer-to-Peer Energiehandel für ein simuliertes Quartier: Haushalte mit PV-Anlage,
Batterie und Smart Meter handeln überschüssigen bzw. fehlenden Strom direkt
untereinander ab, abgerechnet in einem ERC-20-Stablecoin auf dem Sepolia-Testnet.
Mess- und Wetterdaten kommen von einem Python-Simulator, der sie über ein
On-Chain-Oracle einspeist; mehrere statische Web-Dashboards visualisieren den
aktuellen Zustand und die Historie.

## Architektur

```
data_simulator.py  →  oracle_writer.py  →  OracleStorage.sol  →  P2PEnergyMarket.sol
 (synth. Meter/PV/      (schreibt jeden        (autorisierte         (settleSlot():
  Batterie/Wetter)       Slot on-chain)          Schreiber)           matcht Produzenten/
                                                       │               Konsumenten, transferiert
                                                       │               Stablecoin, ruft optional
                                                       ▼               BatteryManager +
                                          BatteryManager.sol           IncentiveController)
                                          (Phase 2, optional)
                                          IncentiveController.sol
                                          (Phase 3, optional, gefüttert
                                           von ai_forecast.py)

settlement_trigger.py  →  ruft settleSlot() periodisch auf

web/*/index.html  →  liest alle Contracts read-only via web3.js (CDN, kein Build-Schritt)
```

Alle vier Contracts sind über Interfaces entkoppelt (`interfaces/IOracleStorage.sol`,
`IBatteryManager.sol`, `IIncentiveController.sol`, `IEnergyStablecoin.sol`), damit
`P2PEnergyMarket` gegen Phase 2/3 auch dann kompiliert, wenn diese noch nicht
deployed sind (`address(0)` = Feature deaktiviert).

| Contract | Phase | Status | Zweck |
|---|---|---|---|
| `OracleStorage.sol` | — | vorgegeben, nicht ändern | Zentraler On-Chain-Speicher für Meter-, Batterie- und Wetterdaten; Schreibzugriff nur für autorisierte Oracle-Adressen |
| `P2PEnergyMarket.sol` | 1 | Starter-Code | Registrierung von Haushalten/Producern, Slot-Settlement (Netto-Matching + Stablecoin-Transfer) |
| `BatteryManager.sol` | 2, optional | Starter-Code (`decideAction` noch `revert`) | Lade-/Entladeentscheidung pro Haushalt, wirkt sich nur auf dessen eigenes Netto aus |
| `IncentiveController.sol` | 3, optional | Starter-Code | Preis-Multiplikator je nach Prognosetreue, gefüttert von `ai_forecast.py` |

Jede Batterie ist strikt pro Haushalt gekapselt (kein gemeinsamer Speicher/Pool) —
siehe `BatteryManager.sol` (`mapping(address => Decision)`) und
`P2PEnergyMarket._nettoForHouseholdAtSlot()`.

## Projektstruktur

```
contracts/                 Solidity-Contracts (Hardhat 3, Solidity 0.8.34)
  interfaces/               Interfaces für die lose Kopplung zwischen den Contracts
python/                    Simulation, Oracle-Feeder, Settlement, optionale AI-Phase
  config.json                Haushalte, Netzbetreiber, Wetter- und Blockchain-Parameter
  data_simulator.py          erzeugt synthetische Meter-/PV-/Batterie-/Wetterdaten
  oracle_writer.py           schreibt jeden Slot Simulator-Daten nach OracleStorage
  battery_optimizer.py       optionale Off-Chain-Variante der Lade-/Entladelogik
  settlement_trigger.py      ruft periodisch P2PEnergyMarket.settleSlot() auf
  ai_forecast.py             Phase 3: trainiert Prognosemodell, füttert IncentiveController
  deploy_helper.py           deployt einen Contract aus python/abi/<Name>.json
  helpers/                   Setup-Skripte (Haushalte registrieren, Stablecoin-Allowance) +
                              zwei ältere Standalone-Dashboards (mittlerweile durch web/ abgelöst)
  abi/                       kompilierte ABI + Bytecode je Contract (Input für deploy_helper.py)
web/                       statische Dashboards (kein Build-Schritt, nur web3.js via CDN)
  index.html                  Landing-Page: Oracle-/Market-Adresse eintragen, Links zu allen Seiten
  overview/                   Read-only-Übersicht: Haushalte, Meter-/Wetterverlauf, Batterie-SoC
                               (mit Charge/Discharge-Schattierung), Incentive, Market & Oracle
  admin/                       Haushalte/Producer registrieren, Oracle-Schreibrechte, Preise setzen
  selfservice/                 Stablecoin-Allowance für den eigenen Haushalt verwalten
  transactions/                 Handels-/Transferhistorie, letztes Settlement, Kontoübersicht
pv_vorhersage_rotkreuz.ipynb  Notebook: PV-Prognose für Rotkreuz/ZG über die Energiedashboard-API
                                (Grundlage/Inspiration für ai_forecast.py bzw. den Simulator)
hardhat.config.ts, tsconfig.json, package.json   Hardhat-3-Minimalsetup für die Contracts
```

## Setup

### Smart Contracts (Node.js / Hardhat)

```bash
npm install
npx hardhat compile
```

Es ist keine feste Sepolia-Netzwerkkonfiguration in `hardhat.config.ts` hinterlegt —
Deployment läuft stattdessen über `python/deploy_helper.py` (siehe unten), das
direkt gegen die in `python/abi/` abgelegten ABI/Bytecode-Artefakte arbeitet.

### Simulation & Oracle (Python)

```bash
cd python
python -m venv .venv               # oder das vorhandene .venv im Repo-Root nutzen
.venv\Scripts\activate              # Windows
pip install -r requirements.txt
```

Benötigt `web3>=7.0,<8.0` (ältere Versionen nutzen `geth_poa_middleware` statt
`ExtraDataToPOAMiddleware` und schlagen beim Import fehl).

Lege `python/.env` an (git-ignored) mit den Private Keys, die die jeweiligen
Skripte brauchen:

| Variable | Genutzt von | Zweck |
|---|---|---|
| `DEPLOYER_PRIVATE_KEY` | `deploy_helper.py` | deployt Contracts; Fallback für die übrigen Keys |
| `ORACLE_PRIVATE_KEY` | `oracle_writer.py` | muss als Oracle in `OracleStorage.authorizeOracle()` eingetragen sein |
| `TRIGGER_PRIVATE_KEY` | `settlement_trigger.py`, `battery_optimizer.py` | ruft `settleSlot()` / `decideAction()` auf — **nicht** derselbe Key wie der Oracle-Feeder (sonst Nonce-Konflikte) |
| `AI_PRIVATE_KEY` | `ai_forecast.py` | muss in `IncentiveController` als autorisierte AI-Adresse eingetragen sein |

`python/config.json` enthält Haushaltsadressen, Netzbetreiber-Konditionen,
Wetterparameter sowie die deployten Contract-Adressen (`blockchain`-Block) und
wird von so gut wie allen Skripten gelesen.

## Ablauf (End-to-End)

1. **Deployen**: `python deploy_helper.py OracleStorage`, dann `P2PEnergyMarket`,
   optional `BatteryManager` und `IncentiveController` — Adressen jeweils in
   `python/config.json` nachtragen und via `setBatteryManager()` /
   `setIncentiveController()` im Market verknüpfen.
2. **Setup**: Haushalte im Oracle registrieren, dann
   `python python/helpers/register_households.py` (Market-Registrierung, owner-only)
   und `python python/helpers/approve_stablecoin.py` (ERC-20-Allowance je Haushalt)
   — alternativ über das `web/admin`- bzw. `web/selfservice`-Dashboard.
3. **Simulation starten**: `python python/oracle_writer.py` läuft dauerhaft und
   schreibt jeden Slot (Default 60 s) neue Meter-/Batterie-/Wetterdaten.
4. **Settlement**: `python python/settlement_trigger.py` läuft parallel und rechnet
   fällige Slots ab (Matching + Stablecoin-Transfer).
5. **Optional Phase 2/3**: `python python/battery_optimizer.py` für die Off-Chain-
   Ladelogik, `python python/ai_forecast.py` für Prognosen ins `IncentiveController`.
6. **Beobachten**: `web/index.html` öffnen (z. B. `python -m http.server` in `web/`),
   Oracle- und Market-Adresse eintragen — von dort aus verlinken sich alle
   Unterseiten (Overview/Admin/Self-Service/Transactions) mit denselben
   URL-Parametern weiter.

## Sicherheitshinweis

Private Keys gehören ausschließlich in `python/.env` (git-ignored) bzw. werden von
den Helper-Skripten interaktiv per `getpass` abgefragt — niemals in `config.json`,
Code oder Commits speichern.
