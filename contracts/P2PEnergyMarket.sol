// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IEnergyStablecoin.sol";
import "./interfaces/IOracleStorage.sol";
import "./interfaces/IBatteryManager.sol";
import "./interfaces/IIncentiveController.sol";

/// @dev OracleStorage.sol stellt zusätzlich getMeterAtSlot(household, slot) bereit
///      (siehe dortige Implementierung - public meterHistory-Mapping mit eigenem
///      Getter), das aber nicht Teil des vorgegebenen IOracleStorage-Interfaces
///      ist. Statt IOracleStorage.sol selbst zu verändern (das laut Vorgabe von
///      Teams unangetastet bleiben soll), ergänzen wir hier lokal ein minimales
///      Zusatz-Interface für genau diese eine, bereits existierende Funktion.
interface IOracleStorageHistory {
    function getMeterAtSlot(address household, uint256 slot)
        external
        view
        returns (IOracleStorage.MeterReading memory);
}

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

    /// @notice Schutz gegen Gas-Explosion / DoS: maximal so viele Slots werden
    ///         pro settleSlot()-Aufruf nachgeholt. Bei größerem Rückstand (z.B.
    ///         nach längerer Downtime) einfach mehrfach hintereinander aufrufen -
    ///         lastSettledSlot wandert dann schrittweise weiter, bis alles
    ///         nachgeholt ist.
    uint256 public constant MAX_SLOTS_PER_SETTLE = 50;

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
     * @notice Rechnet alle noch offenen Slots seit lastSettledSlot ab (inkl.
     *         verpasster/übersprungener Aufrufe), matched pro Slot Produzenten
     *         mit Konsumenten und transferiert Stablecoin entsprechend.
     *
     * @dev Catch-up-Logik: liest pro Slot über oracle.getMeterAtSlot() die zu
     *      GENAU DIESEM Slot gehörenden Meter-Werte (statt nur den zuletzt
     *      gemeldeten via getLatestMeterReading()). Dadurch geht kein Slot
     *      verloren, wenn settleSlot() nicht bei jedem Slot rechtzeitig
     *      aufgerufen wird - der nächste Aufruf holt lastSettledSlot+1 bis
     *      currentSlot vollständig nach (begrenzt durch MAX_SLOTS_PER_SETTLE
     *      pro Tx, siehe dort).
     *
     *      Bekannte Einschränkung: batteryManager.decideAction() und
     *      incentiveController.getPriceMultiplier() liefern immer die JETZIGE
     *      Live-Entscheidung/den Live-Preis, nicht rückwirkend die historische
     *      für einen vergangenen Slot (dafür gibt es in den vorgegebenen
     *      Interfaces keine Historie). Deshalb wird die Batterie-Anpassung nur
     *      für den aktuellsten (Live-)Slot angewendet; nachgeholte, vergangene
     *      Slots werden rein auf Basis der historischen Meter-Netto-Werte
     *      abgerechnet. Der Incentive-Preismultiplikator wird mangels
     *      Alternative für alle Slots eines Aufrufs mit dem aktuellen Wert
     *      angewendet.
     */
    /// @dev Bündelt die Zwischenergebnisse der Klassifizierung, damit settleSlot()
    ///      selbst nur wenige lokale Variablen braucht (sonst "Stack too deep").
    struct NetPosition {
        address[] producerAddr;
        uint256[] producerWh;
        uint256 producerCount;
        address[] consumerAddr;
        uint256[] consumerWh;
        uint256 consumerCount;
    }

    function settleSlot() external {
        uint256 liveSlot = oracle.getCurrentSlot();
        require(liveSlot > lastSettledSlot, "Slot already settled");
        require(households.length > 0, "No households registered");

        uint256 fromSlot = lastSettledSlot + 1;
        uint256 toSlot = liveSlot;
        if (toSlot - fromSlot + 1 > MAX_SLOTS_PER_SETTLE) {
            toSlot = fromSlot + MAX_SLOTS_PER_SETTLE - 1;
        }

        for (uint256 slot = fromSlot; slot <= toSlot; slot++) {
            _settleOneSlot(slot, slot == liveSlot);
        }

        lastSettledSlot = toSlot;
    }

    /// @dev Rechnet genau einen Slot ab (Klassifizierung -> Sortierung -> Matching).
    ///      isLiveSlot steuert, ob die Batterie-Anpassung angewendet wird (siehe
    ///      Einschränkung oben im NatSpec von settleSlot()).
    function _settleOneSlot(uint256 slot, bool isLiveSlot) internal {
        NetPosition memory pos = _classifyHouseholdsForSlot(slot, isLiveSlot);
        _sortProducersDesc(pos.producerAddr, pos.producerWh, pos.producerCount);

        (uint256 slotEnergyTraded, uint256 slotPaid) = _matchAndSettle(pos, slot);

        emit SlotSettled(slot, slotEnergyTraded, slotPaid);
    }

    /// @dev Schritt 1: pro Haushalt Netto FÜR DIESEN SLOT berechnen (aus der
    ///      Oracle-Historie, nicht aus dem zuletzt gemeldeten Wert) und in
    ///      Produzenten/Konsumenten trennen.
    function _classifyHouseholdsForSlot(uint256 slot, bool applyBattery)
        internal
        returns (NetPosition memory pos)
    {
        uint256 n = households.length;

        pos.producerAddr = new address[](n);
        pos.producerWh = new uint256[](n);
        pos.consumerAddr = new address[](n);
        pos.consumerWh = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address household = households[i];
            int256 netto = _nettoForHouseholdAtSlot(household, slot, applyBattery);

            if (netto > 0) {
                pos.producerAddr[pos.producerCount] = household;
                pos.producerWh[pos.producerCount] = uint256(netto);
                pos.producerCount++;
            } else if (netto < 0) {
                pos.consumerAddr[pos.consumerCount] = household;
                pos.consumerWh[pos.consumerCount] = uint256(-netto);
                pos.consumerCount++;
            }
        }
    }

    /// @dev Meter-Netto eines Haushalts FÜR EINEN BESTIMMTEN SLOT (aus der
    ///      Oracle-Historie), optional inkl. Batterie-Anpassung (Phase 2) -
    ///      Batterie nur, wenn applyBattery=true (siehe Einschränkung im
    ///      NatSpec von settleSlot()).
    function _nettoForHouseholdAtSlot(address household, uint256 slot, bool applyBattery)
        internal
        returns (int256 netto)
    {
        IOracleStorage.MeterReading memory reading =
            IOracleStorageHistory(address(oracle)).getMeterAtSlot(household, slot);
        netto = int256(reading.productionWh) - int256(reading.consumptionWh);

        if (applyBattery && address(batteryManager) != address(0) && batteryManager.isManaged(household)) {
            try batteryManager.decideAction(household) returns (
                IBatteryManager.Action action,
                uint256 amountWh
            ) {
                if (action == IBatteryManager.Action.CHARGE) {
                    netto -= int256(amountWh);
                } else if (action == IBatteryManager.Action.DISCHARGE) {
                    netto += int256(amountWh);
                }
            } catch {
                // Batterie-Call fehlgeschlagen -> netto bleibt unverändert
            }
        }
    }

    /// @dev Schritt 2: Produzenten absteigend nach Überschuss sortieren (größter zuerst).
    ///      Selection Sort - unproblematisch bei den hier üblichen kleinen Haushaltszahlen.
    function _sortProducersDesc(
        address[] memory addrs,
        uint256[] memory whs,
        uint256 count
    ) internal pure {
        for (uint256 i = 0; i < count; i++) {
            uint256 maxIdx = i;
            for (uint256 j = i + 1; j < count; j++) {
                if (whs[j] > whs[maxIdx]) {
                    maxIdx = j;
                }
            }
            if (maxIdx != i) {
                (whs[i], whs[maxIdx]) = (whs[maxIdx], whs[i]);
                (addrs[i], addrs[maxIdx]) = (addrs[maxIdx], addrs[i]);
            }
        }
    }

    /// @dev Schritt 3: Waterfall-Matching: Konsument A zahlt Produzent B, bis dessen
    ///      Überschuss "voll" (verbraucht) ist, dann geht's weiter zu C usw.
    function _matchAndSettle(NetPosition memory pos, uint256 slot)
        internal
        returns (uint256 totalEnergyTraded, uint256 totalPaid)
    {
        uint256 pIdx = 0; // Zeiger wandert nur vorwärts - über alle Konsumenten hinweg geteilt,
                           // damit ein Produzent, der schon "voll" ist, nicht erneut angefragt wird

        for (uint256 c = 0; c < pos.consumerCount; c++) {
            address consumer = pos.consumerAddr[c];
            uint256 remainingDebtWh = pos.consumerWh[c];
            uint256 pricePerKwh = _priceForConsumer(consumer);

            while (remainingDebtWh > 0 && pIdx < pos.producerCount) {
                if (pos.producerWh[pIdx] == 0) {
                    pIdx++;
                    continue;
                }

                (uint256 tradeWh, uint256 amount) = _settleTrade(
                    pos.producerAddr[pIdx],
                    consumer,
                    remainingDebtWh,
                    pos.producerWh[pIdx],
                    pricePerKwh,
                    slot
                );

                totalEnergyTraded += tradeWh;
                totalPaid += amount;
                remainingDebtWh -= tradeWh;
                pos.producerWh[pIdx] -= tradeWh;

                // Produzent "voll" (Überschuss aufgebraucht) -> weiter zum nächsten
                if (pos.producerWh[pIdx] == 0) {
                    pIdx++;
                }
            }
            // Falls remainingDebtWh > 0 hier: kein Produzent mehr übrig,
            // Rest-Defizit bleibt unbezahlt (z.B. Bezug vom öffentlichen Netz).
        }
    }

    /// @dev [Phase 3] Preis für einen Konsumenten, ggf. via IncentiveController angepasst.
    function _priceForConsumer(address consumer) internal view returns (uint256 pricePerKwh) {
        pricePerKwh = energyPricePerKwh;
        if (address(incentiveController) != address(0)) {
            uint256 multiplier = incentiveController.getPriceMultiplier(consumer);
            pricePerKwh = (energyPricePerKwh * multiplier) / 1000;
        }
    }

    /// @dev Führt einen einzelnen Teil-Trade aus: Betrag berechnen, Token transferieren, Event emitten.
    function _settleTrade(
        address producer,
        address consumer,
        uint256 remainingDebtWh,
        uint256 available,
        uint256 pricePerKwh,
        uint256 slot
    ) internal returns (uint256 tradeWh, uint256 amount) {
        tradeWh = remainingDebtWh < available ? remainingDebtWh : available;
        amount = (tradeWh * pricePerKwh) / 1000;

        if (amount > 0) {
            require(
                stablecoin.transferFrom(consumer, producer, amount),
                "Payment transfer failed"
            );
        }

        emit EnergyTraded(producer, consumer, tradeWh, amount, slot);
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
