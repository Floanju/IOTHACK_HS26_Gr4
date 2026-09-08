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
    /// @notice Konsument hat für den Slot in den Pool eingezahlt.
    event EnergyBought(address indexed consumer, uint256 energyWh, uint256 amountPaid, uint256 slot);
    /// @notice Produzent wurde für den Slot aus dem Pool ausbezahlt.
    event EnergySold(address indexed producer, uint256 energyWh, uint256 amountReceived, uint256 slot);
    /// @notice Auszahlung an Produzent fehlgeschlagen (z.B. Compliance-Sperre beim Stablecoin) -
    ///         restliche Haushalte werden trotzdem abgerechnet, Betrag bleibt im Contract.
    event PayoutFailed(address indexed producer, uint256 energyWh, uint256 amount, uint256 slot);
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
    /// @dev Pool-Ansatz statt paarweisem Matching: Konsumenten zahlen proportional
    ///      zu ihrem Anteil am gehandelten Defizit in den Contract ein, Produzenten
    ///      werden proportional zu ihrem Anteil am gehandelten Überschuss ausbezahlt.
    ///      Dadurch max. 1 Transfer pro Haushalt statt bis zu N×M Transfers.
    function settleSlot() external {
        uint256 slot = oracle.getCurrentSlot();
        require(slot > lastSettledSlot, "Slot already settled");

        uint256 n = households.length;
        require(n > 0, "No households registered");

        (int256[] memory netto, uint256 totalSurplusWh, uint256 totalDeficitWh) = _collectNetto(n);
        uint256 matchedEnergyWh = totalSurplusWh < totalDeficitWh ? totalSurplusWh : totalDeficitWh;

        uint256 totalPaid = 0;
        if (matchedEnergyWh > 0) {
            totalPaid = _settleConsumers(netto, n, matchedEnergyWh, totalDeficitWh, slot);
            _settleProducers(netto, n, matchedEnergyWh, totalSurplusWh, slot);
        }

        lastSettledSlot = slot;
        emit SlotSettled(slot, matchedEnergyWh, totalPaid);
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

    /// @dev Pass 1: Konsumenten zahlen proportional zu ihrem Defizit-Anteil in den Pool ein.
    function _settleConsumers(
        int256[] memory netto,
        uint256 n,
        uint256 matchedEnergyWh,
        uint256 totalDeficitWh,
        uint256 slot
    ) internal returns (uint256 totalPaid) {
        for (uint256 i = 0; i < n; i++) {
            if (netto[i] >= 0) continue;

            address consumer = households[i];
            uint256 deficitWh = uint256(-netto[i]);
            uint256 boughtWh = (deficitWh * matchedEnergyWh) / totalDeficitWh;
            if (boughtWh == 0) continue;

            uint256 pricePerKwh = energyPricePerKwh;
            if (address(incentiveController) != address(0)) {
                uint256 multiplier = incentiveController.getPriceMultiplier(consumer);
                pricePerKwh = (energyPricePerKwh * multiplier) / 1000;
            }
            uint256 amount = (boughtWh * pricePerKwh) / 1000;

            require(stablecoin.transferFrom(consumer, address(this), amount), "Payment failed");
            totalPaid += amount;
            emit EnergyBought(consumer, boughtWh, amount, slot);
        }
    }

    /// @dev Pass 2: Produzenten werden proportional zu ihrem Überschuss-Anteil aus dem Pool ausbezahlt.
    function _settleProducers(
        int256[] memory netto,
        uint256 n,
        uint256 matchedEnergyWh,
        uint256 totalSurplusWh,
        uint256 slot
    ) internal {
        for (uint256 i = 0; i < n; i++) {
            if (netto[i] <= 0) continue;

            address producer = households[i];
            uint256 surplusWh = uint256(netto[i]);
            uint256 soldWh = (surplusWh * matchedEnergyWh) / totalSurplusWh;
            if (soldWh == 0) continue;

            uint256 amount = calculateCost(soldWh);

            // try/catch statt require: ein Compliance-bedingter Fehlschlag bei einem
            // Produzenten (z.B. Stablecoin-Blacklist) soll nicht den ganzen Slot für
            // alle anderen Haushalte blockieren. Der Betrag bleibt im Contract stehen.
            try stablecoin.transfer(producer, amount) returns (bool success) {
                if (success) {
                    emit EnergySold(producer, soldWh, amount, slot);
                } else {
                    emit PayoutFailed(producer, soldWh, amount, slot);
                }
            } catch {
                emit PayoutFailed(producer, soldWh, amount, slot);
            }
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
