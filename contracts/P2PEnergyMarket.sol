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
    function getMeterAtSlot(
        address household,
        uint256 slot
    ) external view returns (IOracleStorage.MeterReading memory);
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

    address[] public producers;
    mapping(address => bool) public isRegisteredProducer;

    /// @notice Energiepreis in Token-Einheiten pro kWh (6 Decimals).
    /// @dev Beispiel: 100_000 = 0.10 Token / kWh
    uint256 public energyPricePerKwh = 100_000;

    /// @notice Preis (Token-Einheiten pro kWh, 6 Decimals), den ein Haushalt für an
    ///         einen Producer verkaufte Energie erhält (z.B. Feed-in-/Rückkauftarif).
    uint256 public householdToProducerPrice = 100_000;

    /// @notice Preis (Token-Einheiten pro kWh, 6 Decimals), den ein Haushalt für von
    ///         einem Producer bezogene Energie zahlt (z.B. Netzbezug/Import-Tarif).
    uint256 public producerToHouseholdPrice = 100_000;

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
    event HouseholdUnregistered(address indexed household);
    event ProducerRegistered(address indexed producer);
    event ProducerUnregistered(address indexed producer);
    event EnergyTraded(
        address indexed producer,
        address indexed consumer,
        uint256 energyWh,
        uint256 amountPaid,
        uint256 slot
    );
    event SlotSettled(
        uint256 indexed slot,
        uint256 totalEnergyTraded,
        uint256 totalPaid,
        bool batteryEligible
    );
    event PriceUpdated(uint256 newPricePerKwh);
    event HouseholdToProducerPriceUpdated(uint256 newPrice);
    event ProducerToHouseholdPriceUpdated(uint256 newPrice);
    event BatteryManagerUpdated(address indexed batteryManager);
    event IncentiveControllerUpdated(address indexed incentiveController);

    /// @notice Emitted whenever a battery action was actually folded into a
    ///         household's netto for a given slot. If a household shows as
    ///         "Discharging" in a UI but no such event was emitted for the
    ///         slot in question, that discharge was NOT credited against
    ///         that household's bill for that slot (see BatteryActionFailed
    ///         and SlotSettled.batteryEligible for why).
    event BatteryActionApplied(
        address indexed household,
        uint256 indexed slot,
        IBatteryManager.Action action,
        uint256 amountWh
    );

    /// @notice Emitted when batteryManager.decideAction() reverted for a
    ///         household during settlement. Previously this failure was
    ///         swallowed silently (empty catch block) and netto was left
    ///         unchanged with no trace anywhere on-chain - meaning a
    ///         household could show as actively discharging in the battery
    ///         contract while still being billed as if it had no battery
    ///         at all, with no way to tell the two cases apart.
    event BatteryActionFailed(address indexed household, uint256 indexed slot);

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

    /// @notice Entfernt einen Haushalt wieder aus dem Marktplatz.
    /// @dev Betrifft nur die Registrierung hier in P2PEnergyMarket - die Registrierung
    ///      im OracleStorage-Contract bleibt unberührt (separate Zuständigkeit).
    function unregisterHousehold(address household) external onlyOwner {
        require(isRegistered[household], "Not registered");
        isRegistered[household] = false;
        _removeFromArray(households, household);
        emit HouseholdUnregistered(household);
    }

    /// @notice Registriert einen Producer (z.B. Netz-/Utility-Backstop für Kauf
    ///         von Haushalts-Überschuss bzw. Verkauf bei Haushalts-Defizit).
    function registerProducer(address producer) external onlyOwner {
        require(!isRegisteredProducer[producer], "Already registered");
        producers.push(producer);
        isRegisteredProducer[producer] = true;
        emit ProducerRegistered(producer);
    }

    /// @notice Entfernt einen Producer wieder aus dem Marktplatz.
    function unregisterProducer(address producer) external onlyOwner {
        require(isRegisteredProducer[producer], "Not registered");
        isRegisteredProducer[producer] = false;
        _removeFromArray(producers, producer);
        emit ProducerUnregistered(producer);
    }

    /// @dev Entfernt `target` aus einem Storage-Array (swap-with-last + pop).
    ///      Reihenfolge der verbleibenden Einträge ist danach nicht mehr garantiert -
    ///      wie bisher schon bei households gibt es keine dokumentierte Ordnungsgarantie.
    function _removeFromArray(address[] storage arr, address target) internal {
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == target) {
                arr[i] = arr[len - 1];
                arr.pop();
                break;
            }
        }
    }

    function setEnergyPrice(uint256 newPricePerKwh) external onlyOwner {
        energyPricePerKwh = newPricePerKwh;
        emit PriceUpdated(newPricePerKwh);
    }

    /// @notice Setzt den Preis für Verkäufe Haushalt -> Producer (Feed-in/Rückkauf).
    function setHouseholdToProducerPrice(uint256 newPrice) external onlyOwner {
        householdToProducerPrice = newPrice;
        emit HouseholdToProducerPriceUpdated(newPrice);
    }

    /// @notice Setzt den Preis für Käufe Producer -> Haushalt (Netzbezug/Import).
    function setProducerToHouseholdPrice(uint256 newPrice) external onlyOwner {
        producerToHouseholdPrice = newPrice;
        emit ProducerToHouseholdPriceUpdated(newPrice);
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
    function setIncentiveController(
        address _incentiveController
    ) external onlyOwner {
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

        (uint256 slotEnergyTraded, uint256 slotPaid) = _matchAndSettle(
            pos,
            slot
        );

        emit SlotSettled(slot, slotEnergyTraded, slotPaid, isLiveSlot);
    }

    /// @dev Schritt 1: pro Haushalt Netto FÜR DIESEN SLOT berechnen (aus der
    ///      Oracle-Historie, nicht aus dem zuletzt gemeldeten Wert) und in
    ///      Produzenten/Konsumenten trennen.
    function _classifyHouseholdsForSlot(
        uint256 slot,
        bool applyBattery
    ) internal returns (NetPosition memory pos) {
        uint256 n = households.length;

        pos.producerAddr = new address[](n);
        pos.producerWh = new uint256[](n);
        pos.consumerAddr = new address[](n);
        pos.consumerWh = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address household = households[i];
            int256 netto = _nettoForHouseholdAtSlot(
                household,
                slot,
                applyBattery
            );

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
    function _nettoForHouseholdAtSlot(
        address household,
        uint256 slot,
        bool applyBattery
    ) internal returns (int256 netto) {
        IOracleStorage.MeterReading memory reading = IOracleStorageHistory(
            address(oracle)
        ).getMeterAtSlot(household, slot);
        netto = int256(reading.productionWh) - int256(reading.consumptionWh);

        if (
            applyBattery &&
            address(batteryManager) != address(0) &&
            batteryManager.isManaged(household)
        ) {
            try batteryManager.decideAction(household) returns (
                IBatteryManager.Action action,
                uint256 amountWh
            ) {
                if (action == IBatteryManager.Action.CHARGE) {
                    netto -= int256(amountWh);
                    emit BatteryActionApplied(household, slot, action, amountWh);
                } else if (action == IBatteryManager.Action.DISCHARGE) {
                    netto += int256(amountWh);
                    emit BatteryActionApplied(household, slot, action, amountWh);
                }
                // IDLE: no netto change, nothing to log.
            } catch {
                // Batterie-Call fehlgeschlagen -> netto bleibt unverändert,
                // aber JETZT SICHTBAR statt still verschluckt, damit ein
                // fehlgeschlagener Call nicht wie "Batterie hat nichts
                // beigetragen" aussieht.
                emit BatteryActionFailed(household, slot);
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
    function _matchAndSettle(
        NetPosition memory pos,
        uint256 slot
    ) internal returns (uint256 totalEnergyTraded, uint256 totalPaid) {
        uint256 pIdx = 0;
        address grid = producers.length > 0 ? producers[0] : address(0);

        for (uint256 c = 0; c < pos.consumerCount; c++) {
            uint256 remainingDebtWh = pos.consumerWh[c];

            while (remainingDebtWh > 0 && pIdx < pos.producerCount) {
                if (pos.producerWh[pIdx] == 0) {
                    pIdx++;
                    continue;
                }

                (uint256 tradeWh, uint256 amount) = _settleTrade(
                    pos.producerAddr[pIdx],
                    pos.consumerAddr[c], // Inlined
                    remainingDebtWh,
                    pos.producerWh[pIdx],
                    _priceForConsumer(pos.consumerAddr[c]), // Inlined
                    slot
                );

                totalEnergyTraded += tradeWh;
                totalPaid += amount;
                remainingDebtWh -= tradeWh;
                pos.producerWh[pIdx] -= tradeWh;
            }

            if (remainingDebtWh > 0 && grid != address(0)) {
                (uint256 tradeWh, uint256 amount) = _settleTrade(
                    grid,
                    pos.consumerAddr[c],
                    remainingDebtWh,
                    remainingDebtWh,
                    producerToHouseholdPrice,
                    slot
                );
                totalEnergyTraded += tradeWh;
                totalPaid += amount;
            }
        }

        if (grid != address(0)) {
            for (uint256 p = pIdx; p < pos.producerCount; p++) {
                if (pos.producerWh[p] > 0) {
                    (uint256 tradeWh, uint256 amount) = _settleTrade(
                        pos.producerAddr[p],
                        grid,
                        pos.producerWh[p],
                        pos.producerWh[p],
                        householdToProducerPrice,
                        slot
                    );
                    totalEnergyTraded += tradeWh;
                    totalPaid += amount;
                }
            }
        }
    }

    /// @dev [Phase 3] Preis für einen Konsumenten, ggf. via IncentiveController angepasst.
    function _priceForConsumer(
        address consumer
    ) internal view returns (uint256 pricePerKwh) {
        pricePerKwh = energyPricePerKwh;
        if (address(incentiveController) != address(0)) {
            uint256 multiplier = incentiveController.getPriceMultiplier(
                consumer
            );
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

    function getProducerCount() external view returns (uint256) {
        return producers.length;
    }

    /// @notice Anzahl der Slots, die aktuell auf eine Abrechnung warten.
    /// @dev WICHTIG für Batterie-/Incentive-Genauigkeit: Batterie-Anpassung
    ///      (siehe _nettoForHouseholdAtSlot) wird nur für slot == liveSlot
    ///      angewendet. Liefert diese Funktion 0 oder 1, wird der nächste
    ///      settleSlot()-Aufruf genau einen - den aktuellen - Slot
    ///      abrechnen, und die Batterie-Logik greift korrekt. Liefert sie
    ///      einen größeren Wert, hat sich ein Rückstand aufgebaut: der
    ///      nächste Aufruf rechnet mehrere Slots nach, aber nur der letzte
    ///      davon bekommt die Batterie-Anpassung - für alle älteren Slots
    ///      im Rückstand wird rein der rohe Meter-Netto-Wert abgerechnet,
    ///      unabhängig davon, was die Batterie in der Zwischenzeit gemacht
    ///      hat. Betreiber/Frontends sollten settleSlot() regelmäßig genug
    ///      aufrufen, um diesen Wert nahe 0/1 zu halten.
    function pendingSlotsBehind() external view returns (uint256) {
        uint256 liveSlot = oracle.getCurrentSlot();
        if (liveSlot <= lastSettledSlot) {
            return 0;
        }
        return liveSlot - lastSettledSlot;
    }

    function getAllProducers() external view returns (address[] memory) {
        return producers;
    }

    /// @notice Helper: Berechnet den Token-Betrag für eine Energiemenge
    function calculateCost(uint256 energyWh) public view returns (uint256) {
        // Wh -> kWh -> Token (mit Decimals)
        return (energyWh * energyPricePerKwh) / 1000;
    }
}
