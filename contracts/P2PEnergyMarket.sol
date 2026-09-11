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
            // FIX 1: Apply battery logic to ALL unsettled slots being processed, 
            // not just the live one.
            _settleOneSlot(slot, true); 
        }
        lastSettledSlot = toSlot;
    }

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
            // FIX 2: Removed the try/catch block. If the battery manager reverts, 
            // the transaction will now properly fail instead of silently overcharging the customer.
            (IBatteryManager.Action action, uint256 amountWh) = batteryManager.decideAction(household);
            
            if (action == IBatteryManager.Action.CHARGE) {
                netto -= int256(amountWh);
            } else if (action == IBatteryManager.Action.DISCHARGE) {
                netto += int256(amountWh);
            }
        }
    }