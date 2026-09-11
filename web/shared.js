const RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";
const ZERO = "0x0000000000000000000000000000000000000000";

const ORACLE_ABI = [
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "registerHousehold", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "isHouseholdRegistered", "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "", "type": "address" }], "name": "authorizedOracles", "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "oracle", "type": "address" }], "name": "authorizeOracle", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "oracle", "type": "address" }], "name": "revokeOracle", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [], "name": "owner", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "getLatestMeterReading", "outputs": [{ "components": [{ "internalType": "uint256", "name": "consumptionWh", "type": "uint256" }, { "internalType": "uint256", "name": "productionWh", "type": "uint256" }, { "internalType": "uint256", "name": "timestamp", "type": "uint256" }], "internalType": "struct IOracleStorage.MeterReading", "name": "", "type": "tuple" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "getLatestBatteryState", "outputs": [{ "components": [{ "internalType": "uint256", "name": "socPercent", "type": "uint256" }, { "internalType": "uint256", "name": "capacityWh", "type": "uint256" }, { "internalType": "uint256", "name": "maxRateWh", "type": "uint256" }, { "internalType": "uint256", "name": "timestamp", "type": "uint256" }], "internalType": "struct IOracleStorage.BatteryState", "name": "", "type": "tuple" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "getCurrentSlot", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "startTimestamp", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "SLOT_DURATION", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    {
        "anonymous": false, "inputs": [
            { "indexed": true, "internalType": "address", "name": "household", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "slot", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "consumption", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "production", "type": "uint256" }
        ], "name": "MeterUpdated", "type": "event"
    },
    {
        "anonymous": false, "inputs": [
            { "indexed": true, "internalType": "address", "name": "household", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "slot", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "soc", "type": "uint256" }
        ], "name": "BatteryUpdated", "type": "event"
    }
];

// Added incentiveController to MARKET ABI
const MARKET_ABI = [
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "registerHousehold", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "unregisterHousehold", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "producer", "type": "address" }], "name": "registerProducer", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "producer", "type": "address" }], "name": "unregisterProducer", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "", "type": "address" }], "name": "isRegistered", "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "owner", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "getAllHouseholds", "outputs": [{ "internalType": "address[]", "name": "", "type": "address[]" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "getAllProducers", "outputs": [{ "internalType": "address[]", "name": "", "type": "address[]" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "stablecoin", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "batteryManager", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "incentiveController", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "lastSettledSlot", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "oracle", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "energyPricePerKwh", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "householdToProducerPrice", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "producerToHouseholdPrice", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "getHouseholdCount", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "settleSlot", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    {
        "anonymous": false, "inputs": [
            { "indexed": true, "internalType": "address", "name": "producer", "type": "address" },
            { "indexed": true, "internalType": "address", "name": "consumer", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "energyWh", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "amountPaid", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "slot", "type": "uint256" }
        ], "name": "EnergyTraded", "type": "event"
    },
    {
        "anonymous": false, "inputs": [
            { "indexed": true, "internalType": "uint256", "name": "slot", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "totalEnergyTraded", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "totalPaid", "type": "uint256" }
        ], "name": "SlotSettled", "type": "event"
    }
];

// Decision struct order must exactly match BatteryManager.sol: (action, amountWh, slot, timestamp).
const BATTERY_ABI = [
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "addHousehold", "outputs": [], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "", "type": "address" }], "name": "isManaged", "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "getManagedHouseholds", "outputs": [{ "internalType": "address[]", "name": "", "type": "address[]" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "owner", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "oracle", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "getLastDecision", "outputs": [{ "components": [{ "internalType": "enum IBatteryManager.Action", "name": "action", "type": "uint8" }, { "internalType": "uint256", "name": "amountWh", "type": "uint256" }, { "internalType": "uint256", "name": "slot", "type": "uint256" }, { "internalType": "uint256", "name": "timestamp", "type": "uint256" }], "internalType": "struct BatteryManager.Decision", "name": "", "type": "tuple" }], "stateMutability": "view", "type": "function" },
    {
        "anonymous": false, "inputs": [
            { "indexed": true, "internalType": "address", "name": "household", "type": "address" },
            { "indexed": false, "internalType": "enum IBatteryManager.Action", "name": "action", "type": "uint8" },
            { "indexed": false, "internalType": "uint256", "name": "amountWh", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "slot", "type": "uint256" },
            { "indexed": false, "internalType": "string", "name": "reason", "type": "string" }
        ], "name": "DecisionMade", "type": "event"
    }
];

const ERC20_ABI = [
    { "inputs": [{ "internalType": "address", "name": "account", "type": "address" }], "name": "balanceOf", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "decimals", "outputs": [{ "internalType": "uint8", "name": "", "type": "uint8" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "symbol", "outputs": [{ "internalType": "string", "name": "", "type": "string" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "spender", "type": "address" }, { "internalType": "uint256", "name": "amount", "type": "uint256" }], "name": "approve", "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }], "stateMutability": "nonpayable", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "owner", "type": "address" }, { "internalType": "address", "name": "spender", "type": "address" }], "name": "allowance", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    {
        "anonymous": false, "inputs": [
            { "indexed": true, "internalType": "address", "name": "from", "type": "address" },
            { "indexed": true, "internalType": "address", "name": "to", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "value", "type": "uint256" }
        ], "name": "Transfer", "type": "event"
    }
];

const INCENTIVE_ABI = [
    { "inputs": [], "name": "owner", "outputs": [{ "internalType": "address", "name": "", "type": "address" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "getReputationScore", "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }], "name": "getPriceMultiplier", "outputs": [{ "internalType": "uint256", "name": "multiplier", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }, { "internalType": "uint256", "name": "slot", "type": "uint256" }], "name": "getForecast", "outputs": [{ "components": [{ "internalType": "uint256", "name": "expectedConsumptionWh", "type": "uint256" }, { "internalType": "uint256", "name": "expectedProductionWh", "type": "uint256" }, { "internalType": "uint256", "name": "slot", "type": "uint256" }, { "internalType": "uint256", "name": "timestamp", "type": "uint256" }], "internalType": "struct IncentiveController.Forecast", "name": "", "type": "tuple" }], "stateMutability": "view", "type": "function" },
    { "inputs": [{ "internalType": "address", "name": "household", "type": "address" }, { "internalType": "uint256", "name": "slot", "type": "uint256" }], "name": "getActual", "outputs": [{ "components": [{ "internalType": "uint256", "name": "actualConsumptionWh", "type": "uint256" }, { "internalType": "uint256", "name": "actualProductionWh", "type": "uint256" }, { "internalType": "uint256", "name": "slot", "type": "uint256" }], "internalType": "struct IncentiveController.Actual", "name": "", "type": "tuple" }], "stateMutability": "view", "type": "function" },
    {
        "anonymous": false, "inputs": [
            { "indexed": true, "internalType": "address", "name": "household", "type": "address" },
            { "indexed": false, "internalType": "uint256", "name": "newScore", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "consumptionDeviation", "type": "uint256" },
            { "indexed": false, "internalType": "uint256", "name": "productionDeviation", "type": "uint256" }
        ], "name": "ScoreUpdated", "type": "event"
    }
];

const $ = id => document.getElementById(id);

// ─────────────────────────────────────────────────────────────
//  Chart hover tooltip — a single floating div reused by every SVG chart on
//  the page. Attach it to a hoverable element via attachChartTooltip(el, fn),
//  where fn returns the HTML to show (or null/"" to hide).
// ─────────────────────────────────────────────────────────────

function getChartTooltipEl() {
    let el = document.getElementById("chartTooltip");
    if (!el) {
        el = document.createElement("div");
        el.id = "chartTooltip";
        el.className = "chart-tooltip";
        document.body.appendChild(el);
    }
    return el;
}

function positionChartTooltip(evt) {
    const el = getChartTooltipEl();
    const pad = 14;
    let x = evt.clientX + pad, y = evt.clientY + pad;
    const rect = el.getBoundingClientRect();
    if (x + rect.width > window.innerWidth) x = evt.clientX - rect.width - pad;
    if (y + rect.height > window.innerHeight) y = evt.clientY - rect.height - pad;
    el.style.left = `${Math.max(0, x)}px`;
    el.style.top = `${Math.max(0, y)}px`;
}

function attachChartTooltip(el, contentFn) {
    el.addEventListener("mouseenter", (evt) => {
        const html = contentFn(evt);
        if (!html) return;
        const tip = getChartTooltipEl();
        tip.innerHTML = html;
        tip.style.display = "block";
        positionChartTooltip(evt);
    });
    el.addEventListener("mousemove", positionChartTooltip);
    el.addEventListener("mouseleave", () => { getChartTooltipEl().style.display = "none"; });
}

// Optional address -> friendly id map, loaded from the "Household labels"
// panel in the header. short() is used everywhere addresses are displayed
// (tables, chart titles, etc.), so overriding it here is enough to relabel
// the whole app in one place. copyAddress() always receives the real address
// directly (never the label), so copying is unaffected either way.
let householdLabels = {};
const short = a => {
    if (!a) return "-";
    const label = householdLabels[a.toLowerCase()];
    return label || (a.slice(0, 6) + "…" + a.slice(-4));
};

const HOUSEHOLD_LABELS_STORAGE_KEY = "energyTradingHouseholdLabels";

// Added incentive to global config
let cfg = { oracle: "", market: "", stablecoin: "", battery: "", incentive: "" };
let readWeb3, walletWeb3;
let account = null;

function readParamFromUrl(name) {
    try {
        const v = new URLSearchParams(window.location.search).get(name);
        return v ? v.trim() : null;
    } catch (e) { return null; }
}

function syncParamsToUrl(params) {
    try {
        const url = new URL(window.location.href);
        for (const [key, value] of Object.entries(params)) {
            if (value) url.searchParams.set(key, value);
            else url.searchParams.delete(key);
        }
        history.replaceState(null, "", url.toString());
    } catch (e) {
        console.warn("syncParamsToUrl failed:", e.message);
    }
}

function setupNav() {
    const navTargets = {
        navHome: "../index.html",
        navAdmin: "../admin/index.html",
        navSelfservice: "../selfservice/index.html",
        navTransactions: "../transactions/index.html",
        navOverview: "../overview/index.html"
    };
    for (const [id, path] of Object.entries(navTargets)) {
        const link = $(id);
        if (!link) continue;
        link.href = path + window.location.search;
        link.addEventListener("click", (e) => {
            e.preventDefault();
            window.location.href = path + window.location.search;
        });
        // header.html is shared across pages, so which link is "active" can't be
        // baked into it — derive it from the current page instead.
        if (window.location.pathname.endsWith(path.replace("..", ""))) {
            link.classList.add("active");
        }
    }
}

function toggleSettings(forceOpen) {
    const panels = document.querySelectorAll(".settings-panel");
    if (panels.length === 0) return;
    const btn = $("settingsToggle");
    const currentlyOpen = panels[0].style.display !== "none";
    const shouldOpen = forceOpen !== undefined ? forceOpen : !currentlyOpen;
    panels.forEach(p => { p.style.display = shouldOpen ? "block" : "none"; });
    if (btn) {
        btn.classList.toggle("active", shouldOpen);
        btn.setAttribute("aria-expanded", String(shouldOpen));
    }
}

// ─────────────────────────────────────────────────────────────
//  Household labels (optional address -> friendly id map)
// ─────────────────────────────────────────────────────────────

/// Accepts either a bare `[{ id, address, ... }, ...]` array or an object
/// with a "households" array (i.e. the config JSON as-is). `persist` writes
/// the raw text to localStorage so it survives navigation/reloads; pass
/// false when just re-applying already-persisted text on page load.
function applyHouseholdLabelsJson(jsonText, persist) {
    const statusEl = $("householdLabelsStatus");
    const text = (jsonText || "").trim();

    if (!text) {
        householdLabels = {};
        if (persist) { try { localStorage.removeItem(HOUSEHOLD_LABELS_STORAGE_KEY); } catch (e) {} }
        if (statusEl) statusEl.innerHTML = `<span class="muted">No labels set — showing raw addresses.</span>`;
        return true;
    }

    let parsed;
    try { parsed = JSON.parse(text); }
    catch (e) { if (statusEl) statusEl.innerHTML = `<span class="bad">Invalid JSON: ${e.message}</span>`; return false; }

    const list = Array.isArray(parsed) ? parsed : parsed.households;
    if (!Array.isArray(list)) {
        if (statusEl) statusEl.innerHTML = `<span class="bad">Expected an array, or an object with a "households" array.</span>`;
        return false;
    }

    const map = {};
    let count = 0, skipped = 0;
    for (const h of list) {
        if (!h || !h.address || !h.id) { skipped++; continue; }
        try {
            map[Web3.utils.toChecksumAddress(String(h.address).trim()).toLowerCase()] = String(h.id);
            count++;
        } catch (e) { skipped++; }
    }

    householdLabels = map;
    if (persist) { try { localStorage.setItem(HOUSEHOLD_LABELS_STORAGE_KEY, text); } catch (e) {} }
    if (statusEl) {
        statusEl.innerHTML = skipped > 0
            ? `<span class="ok">Loaded ${count} label(s).</span> <span class="muted">(${skipped} entr${skipped === 1 ? "y" : "ies"} skipped — missing/invalid address or id.)</span>`
            : `<span class="ok">Loaded ${count} label(s).</span>`;
    }
    return true;
}

/// Called by the Save button. Applying labels changes what short() returns,
/// but every page already has its data loaded and rendered with the old
/// labels baked into the DOM text — reloading is the simplest way to
/// guarantee every table/chart on the current page picks up the new labels
/// consistently, without each page needing its own re-render hook.
function saveHouseholdLabels() {
    const input = $("householdLabelsInput");
    if (applyHouseholdLabelsJson(input ? input.value : "", true)) {
        setTimeout(() => location.reload(), 400);
    }
}

function clearHouseholdLabels() {
    const input = $("householdLabelsInput");
    if (input) input.value = "";
    applyHouseholdLabelsJson("", true);
    setTimeout(() => location.reload(), 400);
}

/// Loads any previously-saved labels before the page's own data fetch/render
/// runs, so the very first paint already shows ids instead of raw addresses.
function loadHouseholdLabelsFromStorage() {
    let saved = "";
    try { saved = localStorage.getItem(HOUSEHOLD_LABELS_STORAGE_KEY) || ""; } catch (e) {}
    if ($("householdLabelsInput")) $("householdLabelsInput").value = saved;
    if (saved) applyHouseholdLabelsJson(saved, false);
}

function applyConfigToForm() {
    if ($("cfgOracle")) $("cfgOracle").value = cfg.oracle || "";
    if ($("cfgMarket")) $("cfgMarket").value = cfg.market || "";
    if ($("cfgStablecoin")) $("cfgStablecoin").value = cfg.stablecoin || "";
    if ($("cfgBattery")) $("cfgBattery").value = (cfg.battery && cfg.battery !== ZERO) ? cfg.battery : "";
    if ($("cfgIncentive")) $("cfgIncentive").value = (cfg.incentive && cfg.incentive !== ZERO) ? cfg.incentive : "";
}

async function loadConfig() {
    const marketRaw = $("cfgMarket").value.trim();
    let market;
    try { market = Web3.utils.toChecksumAddress(marketRaw); }
    catch (e) { if ($("cfgStatus")) $("cfgStatus").innerHTML = `<span class="bad">Invalid P2PEnergyMarket address.</span>`; return; }

    cfg.market = market;
    syncParamsToUrl({ market: cfg.market });
    if ($("missingParamsBanner")) $("missingParamsBanner").style.display = "none";
    if ($("cfgStatus")) $("cfgStatus").textContent = "Loading…";

    await fetchDerivedAddresses();
    applyConfigToForm();
    if (window._accounts && window._accounts.length > 0) {
        initWalletContracts(); // rebuild against the freshly loaded addresses
        await refreshWalletRoles();
    }

    // Dispatch an event so specific pages (like admin) know data is ready
    window.dispatchEvent(new Event('marketConfigLoaded'));
}

async function fetchDerivedAddresses() {
    const marketR = new readWeb3.eth.Contract(MARKET_ABI, cfg.market);
    // OracleStorage is a public immutable field on the market contract, so it
    // doesn't need to be entered separately — one address (market) is enough.
    try { cfg.oracle = await marketR.methods.oracle().call(); }
    catch (e) { cfg.oracle = ""; if ($("cfgStatus")) $("cfgStatus").innerHTML = `<span class="bad">Could not read oracle(): ${e.message}</span>`; return; }

    try { cfg.stablecoin = await marketR.methods.stablecoin().call(); }
    catch (e) { cfg.stablecoin = ""; if ($("cfgStatus")) $("cfgStatus").innerHTML = `<span class="bad">Could not read stablecoin(): ${e.message}</span>`; return; }

    try { cfg.battery = await marketR.methods.batteryManager().call(); } catch (e) { cfg.battery = ""; }
    try { cfg.incentive = await marketR.methods.incentiveController().call(); } catch (e) { cfg.incentive = ""; }

    if ($("cfgStatus")) $("cfgStatus").innerHTML = `<span class="ok">Loaded.</span>`;
}

async function connectWallet() {
    if (!window.ethereum) { alert("MetaMask not found. Please install it."); return; }
    try {
        const accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
        window._accounts = accounts;
        account = accounts[0];
        walletWeb3 = new Web3(window.ethereum);
        initWalletContracts();
        if ($("walletAddr")) $("walletAddr").innerHTML = `<span class="ok">${accounts.length} account(s) connected</span>`;
        await refreshWalletRoles();
    } catch (e) {
        console.error(e);
        if ($("walletStatus")) $("walletStatus").innerHTML = `<span class="bad">Connection failed: ${e.message}</span>`;
    }
}

if (window.ethereum) {
    window.ethereum.on("accountsChanged", async (accounts) => {
        window._accounts = accounts;
        account = accounts.length ? accounts[0] : null;
        if ($("walletAddr")) $("walletAddr").innerHTML = accounts.length
            ? `<span class="ok">${accounts.length} account(s) connected</span>`
            : "Not connected";
        if (accounts.length) await refreshWalletRoles();
        else { if ($("rolesTableWrap")) $("rolesTableWrap").innerHTML = ""; window._perAccountData = null; }
    });
}

function initWalletContracts() {
    window.oracleW = new walletWeb3.eth.Contract(ORACLE_ABI, cfg.oracle);
    window.marketW = new walletWeb3.eth.Contract(MARKET_ABI, cfg.market);
    window.batteryW = (cfg.battery && cfg.battery !== ZERO) ? new walletWeb3.eth.Contract(BATTERY_ABI, cfg.battery) : null;
    window.incentiveW = (cfg.incentive && cfg.incentive !== ZERO) ? new walletWeb3.eth.Contract(INCENTIVE_ABI, cfg.incentive) : null;
    window.stablecoinW = cfg.stablecoin ? new walletWeb3.eth.Contract(ERC20_ABI, cfg.stablecoin) : null;
}

async function refreshWalletRoles() {
    if (!window._accounts || window._accounts.length === 0) return;
    const oracleR = new readWeb3.eth.Contract(ORACLE_ABI, cfg.oracle);
    const marketR = new readWeb3.eth.Contract(MARKET_ABI, cfg.market);

    let oOwner = null, mOwner = null, bOwner = null;
    try { oOwner = await oracleR.methods.owner().call(); } catch (e) { }
    try { mOwner = await marketR.methods.owner().call(); } catch (e) { }
    if (cfg.battery && cfg.battery !== ZERO) {
        try {
            const batteryR = new readWeb3.eth.Contract(BATTERY_ABI, cfg.battery);
            bOwner = await batteryR.methods.owner().call();
        } catch (e) { }
    }

    const perAccount = await Promise.all(window._accounts.map(async (acct) => {
        let isOracleAuthorized = null;
        try { isOracleAuthorized = await oracleR.methods.authorizedOracles(acct).call(); } catch (e) { }
        return {
            address: acct,
            isOracleAuthorized,
            isOracleOwner: oOwner ? oOwner.toLowerCase() === acct.toLowerCase() : false,
            isMarketOwner: mOwner ? mOwner.toLowerCase() === acct.toLowerCase() : false,
            isBatteryOwner: bOwner ? bOwner.toLowerCase() === acct.toLowerCase() : false
        };
    }));

    window._perAccountData = perAccount;
    renderRolesTable(perAccount);
}

function renderRolesTable(rows) {
    if (!$("rolesTableWrap")) return;
    const cell = (v) => v === null ? '<span class="muted">?</span>' : (v ? '<span class="ok">✓</span>' : '<span class="muted">—</span>');
    const body = rows.map(r => `
    <tr>
      <td title="${r.address}">${short(r.address)}${r.address === account ? " ← active" : ""}</td>
      <td>${cell(r.isOracleOwner)}</td>
      <td>${cell(r.isOracleAuthorized)}</td>
      <td>${cell(r.isMarketOwner)}</td>
      <td>${cell(r.isBatteryOwner)}</td>
    </tr>`).join("");
    $("rolesTableWrap").innerHTML = `
    <table>
      <thead><tr><th>Account</th><th>Oracle owner</th><th>Oracle-authorized</th><th>Market owner</th><th>Battery owner</th></tr></thead>
      <tbody>${body}</tbody>
    </table>`;
}

function pickSigner(roleKey) {
    if (!window._perAccountData) return null;
    const row = window._perAccountData.find(r => r[roleKey] === true);
    return row ? row.address : null;
}

async function sendTx(methodCall, fromAccount) {
    let estimated;
    try {
        estimated = await methodCall.estimateGas({ from: fromAccount });
    } catch (e) {
        throw new Error(`Simulation failed (action would revert): ${e.message}`);
    }
    const gas = Math.min(Math.ceil(Number(estimated) * 1.3), 1000000);
    const sendOpts = { from: fromAccount, gas };
    try {
        sendOpts.nonce = await walletWeb3.eth.getTransactionCount(fromAccount, "pending");
    } catch (e) {
        console.warn("Could not fetch fresh nonce:", e.message);
    }
    return methodCall.send(sendOpts);
}

function log(elId, msg, cls) {
    const el = $(elId);
    if (!el) return;
    const line = document.createElement("div");
    if (cls) line.className = cls;
    line.textContent = msg;
    el.appendChild(line);
}

function copyAddress(addr, btn) {
    navigator.clipboard.writeText(addr).then(() => {
        const original = btn.textContent;
        btn.textContent = "✓";
        btn.classList.add("done");
        setTimeout(() => { btn.textContent = original; btn.classList.remove("done"); }, 1200);
    }).catch(() => { alert(addr); });
}

// Global initialization function - safe to call from all scripts
async function initGlobal() {
    setupNav();
    loadHouseholdLabelsFromStorage();
    readWeb3 = new Web3(new Web3.providers.HttpProvider(RPC_URL));

    cfg.market = readParamFromUrl("market") || "";
    applyConfigToForm();

    if (!cfg.market) {
        if ($("missingParamsBanner")) $("missingParamsBanner").style.display = "block";
        toggleSettings(true);
        return;
    }

    try {
        cfg.market = Web3.utils.toChecksumAddress(cfg.market);
    } catch (e) {
        if ($("cfgStatus")) $("cfgStatus").innerHTML = `<span class="bad">Invalid address in URL params.</span>`;
        return;
    }

    await fetchDerivedAddresses();
    applyConfigToForm();
    window.dispatchEvent(new Event('marketConfigLoaded'));
}