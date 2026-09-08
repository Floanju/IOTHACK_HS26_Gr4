// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IEnergyStablecoin.sol";
import "./interfaces/IOracleStorage.sol";
import "./interfaces/IBatteryManager.sol";
import "./interfaces/IIncentiveController.sol";

/**
 * @title P2PEnergyMarket
 * @notice Phase 1: Direkter Energiehandel zwischen Haushalten.
 * @dev STARTER-CODE - Teams implementieren die TODO-Blöcke.
 *
 *      Logik (Beispiel-Vorschlag):
 *        1. Pro Slot: Lese alle Meter-Daten aus dem Oracle
 *        2. Berechne pro Haushalt: Überschuss = produktion - verbrauch
 *        3. Matche Produzenten (Überschuss > 0) mit Konsumenten (Defizit)
 *        4. Transferiere Stablecoin von Konsument an Produzent
 *
 *      Wichtig: Konsumenten müssen vorab approve() auf den Stablecoin aufrufen,
 *               damit der Contract Tokens in ihrem Namen transferieren kann.
 */
contract P2PEnergyMarket {

    // ─────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────

    IEnergyStablecoin public immutable stablecoin;
    IOracleStorage public immutable oracle;

    address public owner;
    address[] public households;
    mapping(address => bool) public isRegistered;

    /// @notice Energiepreis in Token-Einheiten pro kWh (6 Decimals).
    /// @dev Beispiel: 100_000 = 0.10 Token / kWh
    uint256 public energyPricePerKwh = 100_000;

    /// @notice Letzter abgerechneter Slot, um Doppelabrechnung zu verhindern
    uint256 public lastSettledSlot;

    /// @notice Optionale Phase-2-Integration: BatteryManager-Contract.
    /// @dev Default = address(0) -> keine Batterie-Logik aktiv, settleSlot()
    ///      verhält sich dann wie in Phase 1 (reiner Meter-Nettowert wird
    ///      gehandelt). Setzen via setBatteryManager() NACH dem Deployment
    ///      (Reihenfolge laut README bleibt: OracleStorage -> P2PEnergyMarket
    ///      -> BatteryManager, danach hier eintragen - deshalb Setter statt
    ///      Constructor-Arg, sonst würde die Deploy-Reihenfolge kollidieren).
    IBatteryManager public batteryManager;

    /// @notice Optionale Phase-3-Integration: IncentiveController-Contract.
    /// @dev Default = address(0) -> kein Preis-Incentive aktiv, settleSlot()
    ///      nutzt dann den unveränderten energyPricePerKwh (wie in Phase 1/2).
    ///      Setzen via setIncentiveController() NACH dem Deployment (Reihenfolge
    ///      laut README: ... -> IncentiveController, danach hier eintragen).
    IIncentiveController public incentiveController;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event HouseholdRegistered(address indexed household);
    event EnergyTraded(
        address indexed producer,
        address indexed consumer,
        uint256 energyWh,
        uint256 amountPaid,
        uint256 slot
    );
    /// @notice Direkter Transfer zwischen Produzent und Konsument fehlgeschlagen
    ///         (z.B. Compliance-Sperre beim Stablecoin) - restliche Matches laufen weiter.
    event TradeFailed(
        address indexed producer,
        address indexed consumer,
        uint256 energyWh,
        uint256 amount,
        uint256 slot
    );
    event SlotSettled(uint256 indexed slot, uint256 totalEnergyTraded, uint256 totalPaid);
    event PriceUpdated(uint256 newPricePerKwh);
    event BatteryManagerUpdated(address indexed batteryManager);
    event IncentiveControllerUpdated(address indexed incentiveController);

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /**
     * @param _stablecoin Adresse des bereitgestellten ERC-20 Stablecoins
     * @param _oracle Adresse des OracleStorage Contracts
     */
    constructor(address _stablecoin, address _oracle) {
        stablecoin = IEnergyStablecoin(_stablecoin);
        oracle = IOracleStorage(_oracle);
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────
    //  Registrierung
    // ─────────────────────────────────────────────────────────────

    /// @notice Registriert einen Haushalt für den Marktplatz
    function registerHousehold(address household) external onlyOwner {
        require(!isRegistered[household], "Already registered");
        require(oracle.isHouseholdRegistered(household), "Not in oracle");
        households.push(household);
        isRegistered[household] = true;
        emit HouseholdRegistered(household);
    }

    function setEnergyPrice(uint256 newPricePerKwh) external onlyOwner {
        energyPricePerKwh = newPricePerKwh;
        emit PriceUpdated(newPricePerKwh);
    }

    /// @notice Verknüpft optional den BatteryManager-Contract (Phase 2).
    /// @dev address(0) = deaktiviert (Standard) -> settleSlot() verhält sich
    ///      wie in Phase 1. Erst NACH dem Deployment von BatteryManager aufrufen.
    function setBatteryManager(address _batteryManager) external onlyOwner {
        batteryManager = IBatteryManager(_batteryManager);
        emit BatteryManagerUpdated(_batteryManager);
    }

    /// @notice Verknüpft optional den IncentiveController-Contract (Phase 3).
    /// @dev address(0) = deaktiviert (Standard) -> settleSlot() nutzt den
    ///      unveränderten energyPricePerKwh. Erst NACH dem Deployment von
    ///      IncentiveController aufrufen.
    function setIncentiveController(address _incentiveController) external onlyOwner {
        incentiveController = IIncentiveController(_incentiveController);
        emit IncentiveControllerUpdated(_incentiveController);
    }

    // ─────────────────────────────────────────────────────────────
    //  Settlement-Logik  (HIER IMPLEMENTIEREN TEAMS)
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Rechnet einen Slot ab: matched Produzenten mit Konsumenten,
     *         transferiert Stablecoin entsprechend.
     */
    /// @dev Sweep-Matching statt Pool: Produzenten und Konsumenten werden je
    ///      absteigend nach Überschuss/Defizit sortiert, dann wird der groesste
    ///      Konsument der Reihe nach (groesster zuerst) direkt mit Produzenten
    ///      verrechnet, bis sein Defizit gedeckt ist - danach der naechste
    ///      Konsument, usw. Direkte Konsument->Produzent-Transfers (kein Pool
    ///      im Contract selbst): manche Stablecoins mit Compliance/Whitelisting
    ///      lassen Transfers an den Contract als Zwischenspeicher nicht zu.
    function settleSlot() external {
        uint256 slot = oracle.getCurrentSlot();
        require(slot > lastSettledSlot, "Slot already settled");

        uint256 n = households.length;
        require(n > 0, "No households registered");

        (int256[] memory netto, uint256 totalSurplusWh, uint256 totalDeficitWh) = _collectNetto(n);

        uint256 totalEnergyTraded = 0;
        uint256 totalPaid = 0;
        if (totalSurplusWh > 0 && totalDeficitWh > 0) {
            (totalEnergyTraded, totalPaid) = _buildListsAndMatch(netto, n, slot);
        }

        lastSettledSlot = slot;
        emit SlotSettled(slot, totalEnergyTraded, totalPaid);
    }

    /// @dev Baut Produzenten-/Konsumentenlisten und fuehrt den Sweep-Match aus -
    ///      ausgelagert aus settleSlot(), sonst "stack too deep" durch zu viele Locals.
    function _buildListsAndMatch(int256[] memory netto, uint256 n, uint256 slot)
        internal
        returns (uint256 totalEnergyTraded, uint256 totalPaid)
    {
        (address[] memory producers, uint256[] memory producerAmounts, uint256 producerCount) =
            _buildProducerList(netto, n);
        (address[] memory consumers, uint256[] memory consumerAmounts, uint256 consumerCount) =
            _buildConsumerList(netto, n);
        return _sweepMatch(
            producers, producerAmounts, producerCount,
            consumers, consumerAmounts, consumerCount,
            slot
        );
    }

    /// @dev Liest Meter-Daten + optionale Batterie-Entscheidung und berechnet
    ///      pro Haushalt den Nettowert sowie die Gesamtsummen Überschuss/Defizit.
    function _collectNetto(uint256 n)
        internal
        returns (int256[] memory netto, uint256 totalSurplusWh, uint256 totalDeficitWh)
    {
        netto = new int256[](n);

        for (uint256 i = 0; i < n; i++) {
            address household = households[i];
            IOracleStorage.MeterReading memory mr = oracle.getLatestMeterReading(household);
            int256 net = int256(mr.productionWh) - int256(mr.consumptionWh);

            if (address(batteryManager) != address(0) && batteryManager.isManaged(household)) {
                try batteryManager.decideAction(household)
                    returns (IBatteryManager.Action action, uint256 amountWh) {
                    if (action == IBatteryManager.Action.CHARGE) {
                        net -= int256(amountWh);
                    } else if (action == IBatteryManager.Action.DISCHARGE) {
                        net += int256(amountWh);
                    }
                } catch {
                    // Batterie-Call fehlgeschlagen -> ignorieren, Handel läuft mit ursprünglichem netto weiter
                }
            }

            netto[i] = net;
            if (net > 0) {
                totalSurplusWh += uint256(net);
            } else if (net < 0) {
                totalDeficitWh += uint256(-net);
            }
        }
    }

    /// @dev Baut die Liste der Produzenten (netto > 0) und sortiert sie absteigend
    ///      nach Überschuss (Insertion Sort - bei wenigen Haushalten vernachlässigbare Gaskosten).
    function _buildProducerList(int256[] memory netto, uint256 n)
        internal
        view
        returns (address[] memory addrs, uint256[] memory amounts, uint256 count)
    {
        addrs = new address[](n);
        amounts = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            if (netto[i] > 0) {
                addrs[count] = households[i];
                amounts[count] = uint256(netto[i]);
                count++;
            }
        }
        _sortDescending(addrs, amounts, count);
    }

    /// @dev Baut die Liste der Konsumenten (netto < 0) und sortiert sie absteigend nach Defizit.
    function _buildConsumerList(int256[] memory netto, uint256 n)
        internal
        view
        returns (address[] memory addrs, uint256[] memory amounts, uint256 count)
    {
        addrs = new address[](n);
        amounts = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            if (netto[i] < 0) {
                addrs[count] = households[i];
                amounts[count] = uint256(-netto[i]);
                count++;
            }
        }
        _sortDescending(addrs, amounts, count);
    }

    /// @dev Insertion Sort absteigend, addrs und amounts bleiben zueinander zugeordnet.
    function _sortDescending(address[] memory addrs, uint256[] memory amounts, uint256 count) internal pure {
        for (uint256 i = 1; i < count; i++) {
            uint256 amt = amounts[i];
            address addr = addrs[i];
            uint256 j = i;
            while (j > 0 && amounts[j - 1] < amt) {
                amounts[j] = amounts[j - 1];
                addrs[j] = addrs[j - 1];
                j--;
            }
            amounts[j] = amt;
            addrs[j] = addr;
        }
    }

    /// @dev Berechnet den Token-Betrag für einen Konsumenten inkl. optionalem Incentive-Multiplikator.
    function _computeTradeAmount(address consumer, uint256 energyWh) internal view returns (uint256) {
        uint256 pricePerKwh = energyPricePerKwh;
        if (address(incentiveController) != address(0)) {
            uint256 multiplier = incentiveController.getPriceMultiplier(consumer);
            pricePerKwh = (energyPricePerKwh * multiplier) / 1000;
        }
        return (energyWh * pricePerKwh) / 1000;
    }

    /// @dev Zwei-Zeiger-Sweep: groesster Produzent mit groesstem Konsument zuerst,
    ///      Direkttransfer Konsument->Produzent, bis eine Seite aufgebraucht ist,
    ///      dann naechster Eintrag auf dieser Seite. Kein Pooling im Contract.
    function _sweepMatch(
        address[] memory producers,
        uint256[] memory producerAmounts,
        uint256 producerCount,
        address[] memory consumers,
        uint256[] memory consumerAmounts,
        uint256 consumerCount,
        uint256 slot
    ) internal returns (uint256 totalEnergyTraded, uint256 totalPaid) {
        uint256 i = 0;
        uint256 j = 0;

        while (i < producerCount && j < consumerCount) {
            uint256 matchedWh = producerAmounts[i] < consumerAmounts[j] ? producerAmounts[i] : consumerAmounts[j];
            uint256 amount = _computeTradeAmount(consumers[j], matchedWh);

            try stablecoin.transferFrom(consumers[j], producers[i], amount) returns (bool success) {
                if (success) {
                    emit EnergyTraded(producers[i], consumers[j], matchedWh, amount, slot);
                    totalEnergyTraded += matchedWh;
                    totalPaid += amount;
                } else {
                    emit TradeFailed(producers[i], consumers[j], matchedWh, amount, slot);
                }
            } catch {
                emit TradeFailed(producers[i], consumers[j], matchedWh, amount, slot);
            }

            producerAmounts[i] -= matchedWh;
            consumerAmounts[j] -= matchedWh;
            if (producerAmounts[i] == 0) i++;
            if (consumerAmounts[j] == 0) j++;
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions (Hilfsfunktionen)
    // ─────────────────────────────────────────────────────────────

    function getHouseholdCount() external view returns (uint256) {
        return households.length;
    }

    function getAllHouseholds() external view returns (address[] memory) {
        return households;
    }

    /// @notice Helper: Berechnet den Token-Betrag für eine Energiemenge
    function calculateCost(uint256 energyWh) public view returns (uint256) {
        // Wh -> kWh -> Token (mit Decimals)
        return (energyWh * energyPricePerKwh) / 1000;
    }
}
