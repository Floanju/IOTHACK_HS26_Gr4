// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IOracleStorage.sol";

/**
 * @title BatteryManager
 * @notice Phase 2: Lade-/Entladestrategie für Haushaltsbatterien.
 * @dev STARTER-CODE - Teams implementieren die Optimierungslogik.
 *
 *      Idee: Der Contract liest Wetterprognose und aktuellen SoC,
 *            entscheidet pro Slot, ob die Batterie geladen, entladen
 *            oder leer/voll bleibt, und protokolliert die Entscheidung.
 *
 *      Die eigentliche physische Batterie ist simuliert - das Python-Skript
 *      `battery_optimizer.py` liest die hier protokollierten Entscheidungen
 *      und passt den simulierten SoC im Oracle entsprechend an.
 */
contract BatteryManager {

    enum Action { IDLE, CHARGE, DISCHARGE }

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
        //
        // IOracleStorage.BatteryState memory bs = oracle.getLatestBatteryState(household);
        // IOracleStorage.MeterReading memory mr = oracle.getLatestMeterReading(household);
        // IOracleStorage.WeatherData memory wd = oracle.getLatestWeather();
        //
        // ... eure Logik hier ...
        //
        // lastDecision[household] = Decision({...});
        // emit DecisionMade(household, action, amount, slot, "your-reason");
        // return (action, amount);

        revert("Not implemented yet - this is your job!");
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
