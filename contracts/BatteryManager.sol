// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IOracleStorage.sol";
import "./interfaces/IBatteryManager.sol";

/**
 * @title BatteryManager
 * @notice Phase 2: Lade-/Entladestrategie für Haushaltsbatterien.
 * @dev STARTER-CODE - Teams implementieren die Optimierungslogik.
 *
 *      Idee: Der Contract liest Wetterprognose und aktuellen SoC,
 *            entscheidet pro Slot, ob die Batterie geladen, entladen
 *            oder leer/voll bleibt, und protokolliert die Entscheidung.
 *
 *      Wichtig: Die simulierte SoC-Kurve im OracleStorage läuft unabhängig
 *      von diesen Entscheidungen weiter (sie folgt im Simulator nur
 *      production/consumption) - dieser Contract kann sie NICHT zurückschreiben.
 *      Wirksam wird eure Entscheidung stattdessen dadurch, dass
 *      P2PEnergyMarket.settleSlot() optional decideAction() aufruft und die
 *      gehandelte Energiemenge entsprechend anpasst (siehe P2PEnergyMarket.sol,
 *      Feld `batteryManager` + `setBatteryManager()`).
 *
 *      Dieser Contract implementiert IBatteryManager, damit P2PEnergyMarket
 *      ihn über das Interface ansprechen kann, ohne den vollen Code zu kennen.
 */
contract BatteryManager is IBatteryManager {

    // ─────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────

    IOracleStorage public immutable oracle;
    address public owner;

    /// @notice Letzte protokollierte Entscheidung pro Haushalt
    struct Decision {
        Action action;
        uint256 amountWh;
        uint256 slot;
        uint256 timestamp;
    }

    mapping(address => Decision) public lastDecision;
    mapping(address => bool) public isManaged;
    address[] public managedHouseholds;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event HouseholdManaged(address indexed household);
    event DecisionMade(
        address indexed household,
        Action action,
        uint256 amountWh,
        uint256 slot,
        string reason
    );

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(address _oracle) {
        oracle = IOracleStorage(_oracle);
        owner = msg.sender;
    }

    function addHousehold(address household) external {
        require(msg.sender == owner, "Only owner");
        require(!isManaged[household], "Already managed");
        require(oracle.isHouseholdRegistered(household), "Not in oracle");
        isManaged[household] = true;
        managedHouseholds.push(household);
        emit HouseholdManaged(household);
    }

    // ─────────────────────────────────────────────────────────────
    //  Optimierungs-Logik  (HIER IMPLEMENTIEREN TEAMS)
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Trifft eine Lade-/Entladeentscheidung für einen Haushalt.
     *
     *  TODO (Teams):
     *    1. Lese aktuellen SoC via oracle.getLatestBatteryState(household)
     *    2. Lese Meter-Daten: production - consumption = surplus/deficit
     *    3. Lese Wetterdaten: hohe Strahlung = mehr PV erwartet
     *    4. Entscheidungsbeispiel (einfache Heuristik):
     *         - Wenn Überschuss > 0 UND SoC < 90%: CHARGE
     *         - Wenn Defizit > 0 UND SoC > 20%:    DISCHARGE
     *         - Sonst:                              IDLE
     *    5. Komplexere Strategie könnte Wetter berücksichtigen:
     *         - Wenn cloudCover > 80%: Batterie entladen statt einspeisen
     *           (weil morgen weniger PV erwartet)
     *    6. Emit DecisionMade mit reason-String für Transparenz
     */
    function decideAction(address household) external returns (Action, uint256) {
        require(isManaged[household], "Not managed");

        // TODO: Implementierung durch Team
        
        /**
         * Trifft eine Lade-/Entladeentscheidung für einen Haushalt.
         *
         * OPTIMIERUNGSSTRATEGIE:
         *
         *      Schritt 1 - Basis-Heuristik (Netto-Energie + Batteriestand):
         *        - Überschuss (Produktion > Verbrauch) UND SoC < 90%  -> CHARGE
         *          (Batterie hat noch Platz, überschüssige PV-Energie wird
         *          gespeichert statt sofort ins P2P-Netz verkauft zu werden)
         *        - Defizit (Verbrauch > Produktion) UND SoC > 20%     -> DISCHARGE
         *          (Bedarf wird aus der eigenen Batterie gedeckt statt am
         *          P2P-Markt zuzukaufen)
         *        - Sonst (kein klarer Überschuss/Defizit ODER SoC-Grenze
         *          erreicht)                                           -> IDLE
         *        Die 90%/20%-Grenzen sind bewusst gesetzte Sicherheitspuffer,
         *        keine 0%/100%-Vollausnutzung, um die Batterie zu schonen.
         *
         *      Schritt 2 - Wetter-Korrektur (überschreibt Schritt 1 in zwei Fällen):
         *        - Hohe Bewölkung (cloudCover > 80%) verhindert CHARGE, selbst
         *          bei aktuellem Überschuss: bei trübem Ausblick ist die Batterie
         *          eher komplett voll, wenn wenig PV zu erwarten ist -> nicht
         *          sinnvoll, jetzt noch mehr reinzuladen.
         *        - Hohe Bewölkung erzwingt zusätzlich DISCHARGE (falls SoC > 20%),
         *          auch wenn kein akutes Defizit besteht: vorsorglich entladen,
         *          weil für die nächsten Slots weniger PV-Nachschub erwartet wird.
         *
         *      Mengenbegrenzung (unabhängig von der Aktion): der Betrag wird immer
         *      auf das Minimum aus maxRateWh (physisches Rate-Limit der Batterie),
         *      verfügbarem Headroom (beim Laden) bzw. verfügbarer Ladung (beim
         *      Entladen) gedeckelt - nie mehr, als die Batterie tatsächlich
         *      aufnehmen/liefern kann.
         *
         *      Priorisierung it. Aufgabenstellung: PV-Eigenverbrauch > Batterie
         *      laden > Netzeinspeisung. Das "PV-Eigenverbrauch" ist implizit bereits
         *      im netto-Wert enthalten (production - consumption kommt vom Meter,
         *      Eigenverbrauch ist also schon abgezogen, bevor wir hier überhaupt
         *      rechnen) - "Netzeinspeisung" ist der Fall, wenn CHARGE nicht greift
         *      (Batterie voll/cloudy) und der Überschuss stattdessen unverändert
         *      im P2P-Markt landet (siehe P2PEnergyMarket.settleSlot()).
         */

        IOracleStorage.BatteryState memory bs = oracle.getLatestBatteryState(household);
        IOracleStorage.MeterReading memory mr = oracle.getLatestMeterReading(household);
        IOracleStorage.WeatherData memory wd = oracle.getLatestWeather();

        int256 netto = int256(mr.productionWh) - int256(mr.consumptionWh);
        bool cloudy = wd.cloudCover > 80;

        // Basis-Heuristik
        Action action;
        if (netto > 0 && bs.socPercent < 90) {
            action = Action.CHARGE;
        } else if (netto < 0 && bs.socPercent > 20) {
            action = Action.DISCHARGE;
        } else {
            action = Action.IDLE;
        }

        // Wetter-Korrektur (kann die Basis-Heuristik überschreiben)
        string memory reason;
        if (action == Action.CHARGE && cloudy) {
            action = Action.IDLE;
            reason = "cloudy-outlook-skip-charge";
        } else if (action == Action.IDLE && cloudy && bs.socPercent > 20) {
            action = Action.DISCHARGE;
            reason = "cloudy-outlook-preemptive-discharge";
        } else if (action == Action.CHARGE) {
            reason = "surplus-charge";
        } else if (action == Action.DISCHARGE) {
            reason = "deficit-discharge";
        } else {
            reason = "no-action-needed";
        }

        // Mengenbegrenzung
        uint256 amount;
        if (action == Action.CHARGE) {
            uint256 surplus = uint256(netto);
            uint256 headroomWh = ((100 - bs.socPercent) * bs.capacityWh) / 100;
            amount = surplus;
            if (amount > bs.maxRateWh) amount = bs.maxRateWh;
            if (amount > headroomWh) amount = headroomWh;

        } else if (action == Action.DISCHARGE) {
            uint256 deficit = netto < 0 ? uint256(-netto) : 0;
            uint256 availableWh = (bs.socPercent * bs.capacityWh) / 100;
            amount = deficit > 0 ? deficit : bs.maxRateWh; // reiner Wetter-Trigger ohne Defizit: Standard-Rate nutzen
            if (amount > bs.maxRateWh) amount = bs.maxRateWh;
            if (amount > availableWh) amount = availableWh;

        } else {
            amount = 0;
        }

        uint256 slot = oracle.getCurrentSlot();

        lastDecision[household] = Decision({
            action: action,
            amountWh: amount,
            slot: slot,
            timestamp: block.timestamp
        });

        emit DecisionMade(household, action, amount, slot, reason);

        return (action, amount);
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    function getLastDecision(address household) external view returns (Decision memory) {
        return lastDecision[household];
    }

    function getManagedHouseholds() external view returns (address[] memory) {
        return managedHouseholds;
    }
}
