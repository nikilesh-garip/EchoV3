// Global State
let isMonitoring = false;
let currentScreen = 'home';
let audioContext = null;
let mediaStream = null;
let recordingInterval = null;
let animationFrameId = null;
let pipelineBusy = false;
let guidanceRules = {};
// Set once the local session is restored/created (see Session gate below).
// Not real authentication: whatever is entered is accepted and nothing is
// transmitted. It exists so contacts/history/alerts scope to a stable id,
// and so displayName can appear in the message a contact actually receives.
let userId = "demo_panel_user";
let displayName = "Echo user";

// --- Toasts --------------------------------------------------------------
// Replaces bare alert()/console-only failures with a small, non-blocking,
// on-brand notification -- "something went wrong" should never feel like a
// browser popup in an app whose whole job is calm, trustworthy signaling.
const toastStack = document.getElementById('toast-stack');
const MAX_STACKED_TOASTS = 4;
function showToast(message, kind = 'info', timeoutMs = 4200) {
    // Built with DOM nodes + textContent, not innerHTML: some callers pass
    // through user-entered text (a contact's name), and a toast is exactly
    // the kind of thing that fires unattended (e.g. "<name> added") -- it
    // must never be able to inject markup/script.
    const dot = document.createElement('span');
    dot.className = 'dot';
    const text = document.createElement('span');
    text.textContent = message;
    const el = document.createElement('div');
    el.className = `toast ${kind}`;
    el.append(dot, text);
    toastStack.appendChild(el);
    // A burst of near-simultaneous failures (e.g. several demo clicks
    // during a backend outage) must not pile toasts up forever.
    while (toastStack.children.length > MAX_STACKED_TOASTS) {
        toastStack.firstElementChild.remove();
    }
    setTimeout(() => {
        el.classList.add('leaving');
        setTimeout(() => el.remove(), 200);
    }, timeoutMs);
}

// --- Risk-level helpers ---------------------------------------------------
const RISK_LEVELS = ["NORMAL", "SUSPICIOUS", "POSSIBLE_DANGER", "HIGH_RISK"];
function normalizeRiskLevel(level) {
    return RISK_LEVELS.includes(level) ? level : "NORMAL";
}
function applyRiskAttr(el, level) {
    if (el) el.setAttribute('data-risk', normalizeRiskLevel(level));
}

// --- Session gate -----------------------------------------------------
// Mirrors app/lib/services/session_service.dart's local sign-in: derive a
// stable user id from whatever identifier is entered, store it, and gate
// the dashboard behind it. Credentials never leave this browser.
const SESSION_KEY = "echo_web_session";

function slugifyIdentifier(identifier) {
    const cleaned = identifier.trim().toLowerCase();
    const slug = cleaned.replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
    return slug ? `echo_${slug}` : 'echo_user';
}

function nameFromIdentifier(identifier) {
    const local = identifier.split('@')[0];
    if (!local) return 'Echo user';
    return local
        .split(/[._\-\s]+/)
        .filter(Boolean)
        .map(w => w[0].toUpperCase() + w.slice(1))
        .join(' ') || 'Echo user';
}

function applySession(session) {
    userId = session.userId;
    displayName = session.displayName;
    document.getElementById('session-name').textContent = `Signed in as ${displayName}`;
    const overlay = document.getElementById('login-overlay');
    const shell = document.getElementById('app-shell');
    // Belt-and-suspenders: set inline style directly rather than relying only
    // on the `hidden` attribute + CSS specificity, so a stale cached
    // stylesheet can never leave both screens visible at once.
    overlay.style.display = 'none';
    overlay.setAttribute('hidden', '');
    shell.style.display = '';
    shell.removeAttribute('hidden');
    loadEscalationStatus();
    loadReadiness();
    detectAccurateLocation();
    initLocationCalibrator();
}

function restoreSession() {
    try {
        const raw = localStorage.getItem(SESSION_KEY);
        if (!raw) return false;
        const session = JSON.parse(raw);
        if (!session || !session.userId) return false;
        applySession(session);
        return true;
    } catch (e) {
        return false;
    }
}

document.getElementById('login-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const identifier = document.getElementById('login-identifier').value.trim();
    const nameInput = document.getElementById('login-name').value.trim();
    if (!identifier) return;
    const session = {
        userId: slugifyIdentifier(identifier),
        email: identifier,
        displayName: nameInput || nameFromIdentifier(identifier),
    };
    localStorage.setItem(SESSION_KEY, JSON.stringify(session));
    applySession(session);
});

document.getElementById('sign-out-btn').addEventListener('click', () => {
    localStorage.removeItem(SESSION_KEY);
    location.reload();
});

restoreSession();
detectAccurateLocation();
initLocationCalibrator();



// --- Emergency channel status (Telegram / voice call) --------------------
// Surfaced in the sidebar (tiny dots), Settings (full detail), and the
// Overview "who would be told" card -- so "did my keys actually take
// effect" never requires opening /docs.
let escalationStatus = null;

async function loadEscalationStatus() {
    try {
        const res = await fetch('/escalation/status');
        if (!res.ok) return;
        escalationStatus = await res.json();
        applyEscalationStatusUI();
    } catch (e) {
        console.error("Could not load escalation status:", e);
    }
}

function applyEscalationStatusUI() {
    if (!escalationStatus) return;
    const tgLive = !!escalationStatus.telegram_configured;
    const voiceLive = !!escalationStatus.voice_call_configured;

    const tgDot = document.getElementById('channel-mini-telegram-dot');
    const voiceDot = document.getElementById('channel-mini-voice-dot');
    if (tgDot) tgDot.className = 'dot ' + (tgLive ? 'live' : 'sim');
    if (voiceDot) voiceDot.className = 'dot ' + (voiceLive ? 'live' : 'sim');

    const tgPill = document.getElementById('settings-telegram-pill');
    const voicePill = document.getElementById('settings-voice-pill');
    if (tgPill) { tgPill.textContent = tgLive ? 'Live' : 'Simulated'; tgPill.className = 'chan-pill ' + (tgLive ? 'live' : 'sim'); }
    if (voicePill) { voicePill.textContent = voiceLive ? 'Live' : 'Simulated'; voicePill.className = 'chan-pill ' + (voiceLive ? 'live' : 'sim'); }

    const classesEl = document.getElementById('settings-escalation-classes');
    if (classesEl) classesEl.textContent = (escalationStatus.escalation_classes || []).join(', ') || '—';
    const cancelEl = document.getElementById('settings-cancel-window');
    if (cancelEl) cancelEl.textContent = `${escalationStatus.cancel_window_seconds ?? '—'}s`;
    const minRiskEl = document.getElementById('settings-min-risk');
    if (minRiskEl) minRiskEl.textContent = `${escalationStatus.min_risk_score ?? '—'} / 100`;
}

async function loadReadiness() {
    const card = document.getElementById('readiness-card');
    const body = document.getElementById('readiness-body');
    if (!card || !body) return;
    try {
        const res = await fetch(`/escalation/readiness/${encodeURIComponent(userId)}`);
        if (!res.ok) return;
        const data = await res.json();
        card.hidden = false;
        if (data.ready) {
            body.innerHTML = `<p class="muted">${data.contact_count} contact${data.contact_count === 1 ? '' : 's'} would be called <strong>and</strong> Telegram-messaged, with your location and the evidence clip.</p>`;
        } else {
            const items = (data.blockers || []).map(b => `<li>${b}</li>`).join('');
            body.innerHTML = `<ul class="chat-picker" style="display:grid; gap:6px; list-style:none; padding:10px;">${items || '<li>Not ready yet.</li>'}</ul>`;
        }
    } catch (e) {
        console.error("Could not load escalation readiness:", e);
    }
}

// --- Model profile (production vs demo) ---------------------------------
// Selects which classifier head /detect runs: 'real' (8 production classes)
// or 'demo' (adds firecracker, aliased to gunshot). Applies to BOTH the
// live microphone pipeline and the demo-lab wav-injection buttons -- there
// is one shared pipeline, not two.
const PROFILE_KEY = "echo_model_profile";
let modelProfile = localStorage.getItem(PROFILE_KEY) || "real";

function applyProfileUI() {
    const isDemo = modelProfile === "demo";
    document.getElementById('profile-real-btn').classList.toggle('active', !isDemo);
    document.getElementById('profile-demo-btn').classList.toggle('active', isDemo);
    const badge = document.getElementById('profile-badge');
    badge.textContent = isDemo ? "Demo" : "Production";
    badge.classList.toggle('demo', isDemo);
    document.getElementById('profile-note').hidden = !isDemo;
    const firecrackerBtn = document.querySelector('.wav-btn[data-sound="firecracker"]');
    if (firecrackerBtn) firecrackerBtn.hidden = !isDemo;
}

document.getElementById('profile-real-btn').addEventListener('click', () => {
    modelProfile = 'real';
    localStorage.setItem(PROFILE_KEY, modelProfile);
    applyProfileUI();
});
document.getElementById('profile-demo-btn').addEventListener('click', () => {
    modelProfile = 'demo';
    localStorage.setItem(PROFILE_KEY, modelProfile);
    applyProfileUI();
});
applyProfileUI();

// Dom Elements
const screens = document.querySelectorAll('.screen');
const navItems = document.querySelectorAll('.nav-item');
const topbarTitle = document.getElementById('topbar-title');
const startBtn = document.getElementById('start-monitoring-btn');
const systemStatusBadge = document.getElementById('system-status-badge');
const micStatusIndicator = document.getElementById('mic-status-indicator');
const micStatusText = document.getElementById('mic-status-text');
const canvas = document.getElementById('waveform-canvas');
const canvasCtx = canvas.getContext('2d');
const monClassBox = document.getElementById('mon-class-box');
const monRiskBox = document.getElementById('mon-risk-box');
const monClass = document.getElementById('mon-class');
const monRisk = document.getElementById('mon-risk');
const monRiskChip = document.getElementById('mon-risk-chip');
const monP1 = document.getElementById('mon-p1-val');
const monP2 = document.getElementById('mon-p2-val');
const monP1Bar = document.getElementById('mon-p1-bar');
const monP2Bar = document.getElementById('mon-p2-bar');
const pulseWrapper = document.getElementById('pulse-wrapper');
const lastEventDetails = document.getElementById('last-event-details');
const alertModal = document.getElementById('alert-modal');
const alertHeader = document.getElementById('alert-header');
const alertBox = document.getElementById('alert-box');
const alertTitle = document.getElementById('alert-title');
const alertRiskScore = document.getElementById('alert-risk-score');
const alertRiskLvl = document.getElementById('alert-risk-lvl');
const alertRiskRingFill = document.getElementById('alert-risk-ring-fill');
const alertP1 = document.getElementById('alert-p1');
const alertP2 = document.getElementById('alert-p2');
const alertGuidanceList = document.getElementById('alert-guidance-list');
const alertPlacesContainer = document.getElementById('alert-places-container');
const dismissAlertBtn = document.getElementById('dismiss-alert-btn');
const sensitivitySlider = document.getElementById('sensitivity-slider');
const sensitivityVal = document.getElementById('sensitivity-val');
const contactsContainer = document.getElementById('contacts-container');
const saveContactBtn = document.getElementById('save-contact-btn');
const contactNameInput = document.getElementById('contact-name');
const contactPhoneInput = document.getElementById('contact-phone');
const contactRelationInput = document.getElementById('contact-relation');
const contactTelegramInput = document.getElementById('contact-telegram');
const contactPriorityInput = document.getElementById('contact-priority');
const contactNotifyCall = document.getElementById('contact-notify-call');
const contactNotifyTelegram = document.getElementById('contact-notify-telegram');
const findChatsBtn = document.getElementById('find-chats-btn');
const chatPicker = document.getElementById('chat-picker');
const sendTestAlertBtn = document.getElementById('send-test-alert-btn');
const testAlertResult = document.getElementById('test-alert-result');
const historyContainer = document.getElementById('history-items-container');
const clearHistoryBtn = document.getElementById('clear-history-btn');
const micPermissionStatus = document.getElementById('mic-permission-status');
const locationPermissionStatus = document.getElementById('location-permission-status');
const downloadReportBtn = document.getElementById('download-report-btn');
let latestIncident = null;

// Load configurations
fetch('guidance_rules.json')
    .then(res => res.json())
    .then(data => {
        guidanceRules = data;
    })
    .catch(() => showToast("Could not load guidance text. Alerts will still work, without recommended-actions copy.", "error"));

// Update Status Time
function updateTime() {
    const now = new Date();
    document.getElementById('status-time').innerText = now.toTimeString().slice(0, 5);
}
setInterval(updateTime, 1000);
updateTime();

// Screen Navigation
const SCREEN_TITLES = { home: 'Overview', monitor: 'Live monitor', history: 'Event history', contacts: 'Trusted contacts', demo: 'Demo lab', settings: 'Settings' };
navItems.forEach(item => {
    item.addEventListener('click', () => {
        const targetScreen = item.getAttribute('data-screen');
        switchScreen(targetScreen);
    });
});

function switchScreen(screenId) {
    screens.forEach(s => s.classList.remove('active'));
    navItems.forEach(n => n.classList.remove('active'));

    document.getElementById(`screen-${screenId}`).classList.add('active');
    const matchingNav = document.querySelector(`.nav-item[data-screen="${screenId}"]`);
    if (matchingNav) matchingNav.classList.add('active');
    if (topbarTitle && SCREEN_TITLES[screenId]) topbarTitle.textContent = SCREEN_TITLES[screenId];

    currentScreen = screenId;

    if (screenId === 'history') {
        loadHistory();
    } else if (screenId === 'contacts') {
        loadContacts();
    } else if (screenId === 'home') {
        loadReadiness();
    }
}

function sensitivityThreshold() {
    // 1 is least sensitive (70% confidence); 9 is most sensitive (30%).
    return Number((0.75 - Number(sensitivitySlider.value) * 0.05).toFixed(2));
}

// Sensitivity control
sensitivitySlider.addEventListener('input', (e) => {
    const val = e.target.value;
    const threshold = sensitivityThreshold().toFixed(2);
    let label = `Medium (${threshold})`;
    if (val < 4) label = `Low (${threshold})`;
    else if (val > 7) label = `High (${threshold})`;
    sensitivityVal.innerText = label;
});

// START/STOP Microphone Monitoring
startBtn.addEventListener('click', () => {
    if (isMonitoring) {
        stopMonitoring();
    } else {
        startMonitoring();
    }
});

async function startMonitoring() {
    try {
        mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
        if ("Notification" in window && Notification.permission === "default") {
            Notification.requestPermission().catch(() => {});
        }
        isMonitoring = true;

        startBtn.innerText = "STOP MONITORING";
        startBtn.classList.add('listening');
        systemStatusBadge.innerText = "Active";
        systemStatusBadge.classList.add('active');
        micStatusIndicator.className = "signal-dot green";
        micStatusText.innerText = "Monitoring";
        micPermissionStatus.innerText = "Granted";

        setupVisualizer();
        startPipelineLoop();
        return true;
    } catch (err) {
        micPermissionStatus.innerText = "Denied or unavailable";
        showToast("Microphone permission was denied or the device is busy. Monitoring did not start.", "error");
        console.error(err);
        return false;
    }
}

async function logVerifiedEvent(data) {
    if (!data.verified) return;
    const response = await fetch("/events", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            user_id: userId,
            class_name: data.candidate,
            primary_conf: data.primary_confidence,
            verification_conf: data.verification_confidence,
            risk_score: data.risk_score,
            risk_level: data.risk_level
        })
    });
    if (!response.ok) throw new Error("Could not save the verified event.");
}

function notifyUrgentIncident(data) {
    if ("Notification" in window && Notification.permission === "granted") {
        new Notification("Echo: verified high-risk sound", {
            body: `${data.candidate} detected. Risk score ${data.risk_score}. Review guidance now.`
        });
    }
}

// --- Emergency contact escalation ---------------------------------------
// This is what actually calls/messages the saved contacts. `triggerAlertModal`
// creates a real incident (with the audio clip that triggered it) before
// showing the modal, then polls the incident until it dispatches or is
// cancelled -- the countdown ring, the escalation copy, and the per-contact
// per-channel result list are all driven off that same poll.
let escalationPollTimer = null;
let currentIncidentId = null;
let escalationTotalWindow = 12;

// --- Accurate Geolocation & Address Management -------------------------
const EXACT_LOCATION_KEY = "echo_exact_user_location";
let cachedLocation = null;
let currentAlertThreat = null;

async function detectAccurateLocation(forceRefresh = false) {
    if (!forceRefresh && cachedLocation && cachedLocation.lat && cachedLocation.lng) {
        return cachedLocation;
    }

    // 0. Check User-Calibrated Location from localStorage first
    if (!forceRefresh) {
        try {
            const saved = localStorage.getItem(EXACT_LOCATION_KEY);
            if (saved) {
                const parsed = JSON.parse(saved);
                if (parsed.lat && parsed.lng) {
                    cachedLocation = parsed;
                    if (locationPermissionStatus) locationPermissionStatus.innerText = "Calibrated Spot";
                    updateLiveLocationBar(parsed);
                    return parsed;
                }
            }
        } catch (e) {}
    }

    // 1. Try Browser High-Accuracy Geolocation (GPS) with fresh fix
    const browserLoc = await new Promise((resolve) => {
        if (!navigator.geolocation) return resolve(null);
        navigator.geolocation.getCurrentPosition(
            (pos) => {
                if (locationPermissionStatus) locationPermissionStatus.innerText = "Active (GPS)";
                resolve({
                    lat: pos.coords.latitude,
                    lng: pos.coords.longitude,
                    accuracy: Math.round(pos.coords.accuracy || 15),
                    source: "gps"
                });
            },
            (err) => {
                console.warn("Browser GPS unavailable/denied:", err.message);
                resolve(null);
            },
            { enableHighAccuracy: true, timeout: 8000, maximumAge: 15000 }
        );
    });

    let loc = browserLoc;

    // 2. Fall back to IP-based Geolocation via backend proxy
    if (!loc) {
        try {
            const res = await fetch('/api/location/detect');
            if (res.ok) {
                const data = await res.json();
                if (data.latitude && data.longitude) {
                    loc = {
                        lat: data.latitude,
                        lng: data.longitude,
                        accuracy: 2500,
                        source: data.source || "ip",
                        address: data.label || (data.city ? `${data.city}, ${data.region || ''}, ${data.country || ''}` : null)
                    };
                    if (locationPermissionStatus) locationPermissionStatus.innerText = "Active (Network/IP)";
                }
            }
        } catch (e) {
            console.warn("IP Geolocation detection error:", e);
        }
    }

    // 3. Fallback default if completely offline / blocked
    if (!loc) {
        loc = {
            lat: 17.3850,
            lng: 78.4867,
            accuracy: 10000,
            source: "default",
            address: "Hyderabad, Telangana, India"
        };
        if (locationPermissionStatus) locationPermissionStatus.innerText = "Fallback (Hyderabad)";
    }

    // 4. Reverse Geocode address if needed
    if (!loc.address) {
        try {
            const revRes = await fetch(`/api/location/reverse?lat=${loc.lat}&lng=${loc.lng}`);
            if (revRes.ok) {
                const revData = await revRes.json();
                if (revData.label || revData.address) {
                    loc.address = revData.label || revData.address;
                }
            }
        } catch (e) {
            console.warn("Reverse geocoding error:", e);
        }
    }

    loc.maps_url = `https://www.google.com/maps?q=${loc.lat},${loc.lng}`;
    cachedLocation = loc;

    // Update live location bar on home screen
    updateLiveLocationBar(loc);

    return loc;
}

function updateLiveLocationBar(loc) {
    const bar = document.getElementById('live-location-bar');
    const text = document.getElementById('live-loc-text');
    const link = document.getElementById('live-loc-maps-link');
    if (!bar || !text) return;
    
    const displayAddr = loc.address || `${loc.lat.toFixed(4)}, ${loc.lng.toFixed(4)}`;
    text.textContent = displayAddr;
    if (link) {
        link.href = loc.maps_url || `https://www.google.com/maps?q=${loc.lat},${loc.lng}`;
        link.hidden = false;
        link.setAttribute('title', `Open Lat: ${loc.lat.toFixed(5)}, Lng: ${loc.lng.toFixed(5)} in Google Maps`);
    }
}

function initLocationCalibrator() {
    const modal = document.getElementById('location-modal');
    const closeBtn = document.getElementById('loc-modal-close');
    const openBtn = document.getElementById('open-calib-btn');
    const alertOpenBtn = document.getElementById('alert-open-calib-btn');
    
    const currAddr = document.getElementById('modal-curr-addr');
    const currCoords = document.getElementById('modal-curr-coords');
    const currMapLink = document.getElementById('modal-curr-map-link');
    
    const gpsBtn = document.getElementById('modal-gps-btn');
    const searchInput = document.getElementById('modal-search-input');
    const searchBtn = document.getElementById('modal-search-btn');
    const searchResult = document.getElementById('modal-search-result');
    const searchName = document.getElementById('modal-search-name');
    const searchCoords = document.getElementById('modal-search-coords');
    const searchConfirm = document.getElementById('modal-search-confirm');
    
    const coordsInput = document.getElementById('modal-coords-input');
    const coordsBtn = document.getElementById('modal-coords-btn');

    let pendingSearchPlace = null;

    function openModal() {
        if (!modal) return;
        const loc = cachedLocation || { lat: 17.3850, lng: 78.4867, address: 'Locating...' };
        if (currAddr) currAddr.textContent = loc.address || "Detected Area";
        if (currCoords) currCoords.textContent = `Lat: ${loc.lat.toFixed(6)}, Lng: ${loc.lng.toFixed(6)} (${loc.source || 'detected'})`;
        if (currMapLink) currMapLink.href = loc.maps_url || `https://www.google.com/maps?q=${loc.lat},${loc.lng}`;
        if (searchResult) searchResult.hidden = true;
        modal.hidden = false;
    }

    function closeModal() {
        if (modal) modal.hidden = true;
    }

    if (openBtn) openBtn.addEventListener('click', openModal);
    if (alertOpenBtn) alertOpenBtn.addEventListener('click', openModal);
    if (closeBtn) closeBtn.addEventListener('click', closeModal);
    if (modal) {
        modal.addEventListener('click', (e) => {
            if (e.target === modal) closeModal();
        });
    }

    // 1. High-precision device GPS
    if (gpsBtn) {
        gpsBtn.addEventListener('click', () => {
            gpsBtn.disabled = true;
            gpsBtn.textContent = "Acquiring GPS fix...";
            if (!navigator.geolocation) {
                showToast("Geolocation is not supported by your browser.", "error");
                gpsBtn.disabled = false;
                gpsBtn.textContent = "Get GPS Fix";
                return;
            }
            navigator.geolocation.getCurrentPosition(
                async (pos) => {
                    const lat = pos.coords.latitude;
                    const lng = pos.coords.longitude;
                    const accuracy = Math.round(pos.coords.accuracy || 10);
                    showToast(`GPS fix acquired (±${accuracy}m)!`, "success");
                    
                    let address = null;
                    try {
                        const revRes = await fetch(`/api/location/reverse?lat=${lat}&lng=${lng}`);
                        if (revRes.ok) {
                            const revData = await revRes.json();
                            address = revData.label || revData.address;
                        }
                    } catch (e) {}

                    const newLoc = {
                        lat,
                        lng,
                        accuracy,
                        source: "gps_calibrated",
                        address: address || `Lat: ${lat.toFixed(5)}, Lng: ${lng.toFixed(5)}`,
                        maps_url: `https://www.google.com/maps?q=${lat},${lng}`
                    };

                    localStorage.setItem(EXACT_LOCATION_KEY, JSON.stringify(newLoc));
                    cachedLocation = newLoc;
                    updateLiveLocationBar(newLoc);
                    if (locationPermissionStatus) locationPermissionStatus.innerText = `Active (GPS ±${accuracy}m)`;

                    refreshAlertLocationAndPlaces(newLoc);

                    gpsBtn.disabled = false;
                    gpsBtn.textContent = "Get GPS Fix";
                    closeModal();
                },
                (err) => {
                    console.error("GPS error:", err);
                    showToast(`Could not obtain GPS fix: ${err.message}. Try searching your colony/landmark below.`, "error");
                    gpsBtn.disabled = false;
                    gpsBtn.textContent = "Get GPS Fix";
                },
                { enableHighAccuracy: true, timeout: 12000, maximumAge: 0 }
            );
        });
    }

    // 2. Search Area / Colony / Address
    if (searchBtn && searchInput) {
        const doSearch = async () => {
            const query = searchInput.value.trim();
            if (!query) return;
            searchBtn.disabled = true;
            searchBtn.textContent = "Searching...";
            try {
                const res = await fetch(`/api/location/search?query=${encodeURIComponent(query)}`);
                if (!res.ok) throw new Error("Location not found");
                const data = await res.json();
                pendingSearchPlace = data;
                if (searchName) searchName.textContent = data.display_name;
                if (searchCoords) searchCoords.textContent = `Lat: ${data.latitude.toFixed(6)}, Lng: ${data.longitude.toFixed(6)}`;
                if (searchResult) searchResult.hidden = false;
            } catch (err) {
                showToast("Could not resolve location. Try another landmark or enter coordinates directly.", "error");
                if (searchResult) searchResult.hidden = true;
            } finally {
                searchBtn.disabled = false;
                searchBtn.textContent = "Search";
            }
        };

        searchBtn.addEventListener('click', doSearch);
        searchInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                doSearch();
            }
        });
    }

    if (searchConfirm) {
        searchConfirm.addEventListener('click', () => {
            if (!pendingSearchPlace) return;
            const newLoc = {
                lat: pendingSearchPlace.latitude,
                lng: pendingSearchPlace.longitude,
                accuracy: 50,
                source: "user_searched",
                address: pendingSearchPlace.display_name.split(",").slice(0, 3).join(","),
                maps_url: pendingSearchPlace.google_maps_url || `https://www.google.com/maps?q=${pendingSearchPlace.latitude},${pendingSearchPlace.longitude}`
            };
            localStorage.setItem(EXACT_LOCATION_KEY, JSON.stringify(newLoc));
            cachedLocation = newLoc;
            updateLiveLocationBar(newLoc);
            showToast(`Location set: ${newLoc.address}`, "success");
            refreshAlertLocationAndPlaces(newLoc);
            closeModal();
        });
    }

    // 3. Raw coordinates input
    if (coordsBtn && coordsInput) {
        coordsBtn.addEventListener('click', async () => {
            const raw = coordsInput.value.trim();
            if (!raw) return;
            coordsBtn.disabled = true;
            coordsBtn.textContent = "Applying...";
            try {
                const res = await fetch(`/api/location/search?query=${encodeURIComponent(raw)}`);
                if (!res.ok) throw new Error("Invalid coordinates");
                const data = await res.json();
                const newLoc = {
                    lat: data.latitude,
                    lng: data.longitude,
                    accuracy: 25,
                    source: "user_coordinates",
                    address: data.display_name.split(",").slice(0, 3).join(","),
                    maps_url: data.google_maps_url || `https://www.google.com/maps?q=${data.latitude},${data.longitude}`
                };
                localStorage.setItem(EXACT_LOCATION_KEY, JSON.stringify(newLoc));
                cachedLocation = newLoc;
                updateLiveLocationBar(newLoc);
                showToast(`Coordinates calibrated: ${newLoc.lat.toFixed(5)}, ${newLoc.lng.toFixed(5)}`, "success");
                refreshAlertLocationAndPlaces(newLoc);
                closeModal();
            } catch (e) {
                showToast("Invalid coordinates. Please enter in 'latitude, longitude' format.", "error");
            } finally {
                coordsBtn.disabled = false;
                coordsBtn.textContent = "Apply";
            }
        });
    }
}

async function getCurrentLocation() {
    return await detectAccurateLocation();
}

async function createIncidentAndEscalate(data, clipBlob) {
    const position = await getCurrentLocation();
    const formData = new FormData();
    formData.append("user_id", userId);
    formData.append("class_name", data.candidate);
    formData.append("raw_class", data.raw_candidate || data.candidate);
    formData.append("profile", data.profile || "real");
    formData.append("primary_conf", data.primary_confidence ?? 0);
    formData.append("verification_conf", data.verification_confidence ?? 0);
    formData.append("risk_score", data.risk_score ?? 0);
    formData.append("risk_level", data.risk_level ?? "NORMAL");
    formData.append("verified", "true");
    formData.append("user_label", displayName);
    if (position) {
        formData.append("latitude", position.lat);
        formData.append("longitude", position.lng);
        formData.append("accuracy_m", position.accuracy);
        // No place_label sent from here on purpose: the backend resolves a
        // real street-level address from lat/lng at dispatch time (see
        // backend/geocode.py) rather than us sending a placeholder string.
    }
    if (clipBlob) {
        formData.append("clip", clipBlob, "incident.wav");
    }
    const res = await fetch("/incidents", { method: "POST", body: formData });
    if (!res.ok) {
        if (res.status === 429) throw new Error("Too many alerts too quickly -- please wait a moment.");
        throw new Error(`Could not create incident (${res.status})`);
    }
    return res.json();
}

function renderEscalationAttempts(attempts, container) {
    container.innerHTML = "";
    if (!attempts.length) {
        container.innerHTML = "<li class='empty'>No contacts were attempted.</li>";
        return;
    }
    attempts.forEach(a => {
        // Built with DOM nodes + textContent, not a template-literal
        // innerHTML: contact_name and detail are stored copies of a
        // user-entered contact name and echo straight back from the
        // backend, so this must not be able to inject markup.
        const channelLabel = a.channel === 'voice_call' ? 'Automated call' : a.channel === 'telegram' ? 'Telegram' : a.channel;
        const strong = document.createElement('strong');
        strong.textContent = a.contact_name || 'Contact';
        const chan = document.createElement('div');
        chan.className = 'chan';
        chan.append(strong, document.createTextNode(' · ' + channelLabel));
        const detail = document.createElement('div');
        detail.className = 'detail';
        detail.textContent = a.detail || '';
        const info = document.createElement('div');
        info.append(chan, detail);
        const status = document.createElement('span');
        status.className = `esc-status ${a.status}`;
        status.textContent = a.status;
        const li = document.createElement('li');
        li.append(info, status);
        container.appendChild(li);
    });
}

function stopEscalationTimers() {
    if (escalationPollTimer) clearInterval(escalationPollTimer);
    escalationPollTimer = null;
}

function setCountdownRing(secondsLeft, totalSeconds) {
    const ring = document.getElementById('escalation-ring-fill');
    const circumference = 326.7; // 2 * pi * 52
    const pct = totalSeconds > 0 ? Math.max(0, Math.min(1, secondsLeft / totalSeconds)) : 0;
    if (ring) ring.style.strokeDashoffset = String(circumference * (1 - pct));
    const numberEl = document.getElementById('escalation-countdown');
    const inlineEl = document.getElementById('escalation-countdown-inline');
    const rounded = Math.max(0, Math.ceil(secondsLeft));
    if (numberEl) numberEl.textContent = rounded;
    if (inlineEl) inlineEl.textContent = rounded;
}

function showEscalationState(incident) {
    const pendingEl = document.getElementById('escalation-pending');
    const resultEl = document.getElementById('escalation-result');
    const noneEl = document.getElementById('escalation-none');
    const locationEl = document.getElementById('escalation-location');
    pendingEl.hidden = true;
    resultEl.hidden = true;
    noneEl.hidden = true;

    if (!incident) {
        noneEl.hidden = false;
        noneEl.querySelector('p').textContent = "Could not reach the backend to alert your contacts.";
        return;
    }

    if (incident.state === 'PENDING') {
        pendingEl.hidden = false;
        setCountdownRing(incident.seconds_to_dispatch || 0, escalationTotalWindow);
        return;
    }
    if (incident.state === 'SUPPRESSED') {
        noneEl.hidden = false;
        noneEl.querySelector('p').textContent = incident.gate_reason || "This detection did not meet the escalation policy.";
        return;
    }
    if (incident.state === 'NO_CONTACTS') {
        noneEl.hidden = false;
        noneEl.querySelector('p').textContent = "No emergency contact is saved — nobody could be alerted. Add one on the Trusted contacts tab.";
        return;
    }
    if (incident.state === 'CANCELLED') {
        noneEl.hidden = false;
        noneEl.querySelector('p').textContent = "Alert cancelled — nobody was called or messaged.";
        return;
    }
    // DISPATCHED (or DISPATCHING mid-flight)
    resultEl.hidden = false;
    if (incident.place_label) {
        locationEl.hidden = false;
        locationEl.textContent = `Location sent: ${incident.place_label}`;
    } else {
        locationEl.hidden = true;
    }
    renderEscalationAttempts(incident.attempts || [], document.getElementById('escalation-attempts-list'));
}

let escalationPollFailures = 0;
const MAX_POLL_FAILURES = 5;

async function pollIncident(incidentId) {
    try {
        const res = await fetch(`/incidents/${incidentId}`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const incident = await res.json();
        escalationPollFailures = 0;
        showEscalationState(incident);
        if (incident.state !== 'PENDING' && incident.state !== 'DISPATCHING') {
            stopEscalationTimers();
        }
    } catch (e) {
        console.error("Incident poll error:", e);
        // A silently-frozen countdown is worse than an honest error: the
        // real dispatch may already have happened server-side with no way
        // for this client to know. Stop spinning after a few misses instead
        // of polling a failing endpoint forever with the ring frozen at
        // whatever it last showed.
        escalationPollFailures += 1;
        if (escalationPollFailures >= MAX_POLL_FAILURES) {
            stopEscalationTimers();
            showToast(
                "Lost contact with the backend while tracking this alert -- check Event history "
                + "to see whether it actually dispatched.",
                "error", 8000
            );
        }
    }
}

// Set while a "Cancel"/"I'm safe" click lands before createIncidentAndEscalate
// has resolved (still waiting on geolocation, etc. -- there's no incident id
// yet to cancel). Without tracking this, the click was a silent no-op and
// the incident went on to arm and dispatch anyway, invisibly, behind a modal
// the user believed they'd already dismissed.
let escalationCancelRequested = false;

// Cancels a real incident and reports EXACTLY what happened -- the backend's
// /cancel can return 200 with cancelled:false (e.g. it already dispatched),
// and that must never be shown to the user as a success. Shared by the
// Cancel button, "I'm safe", and the race-recovery path in startEscalation
// below, so all three report identically instead of each getting its own
// (previously divergent, previously wrong) copy of this logic.
async function requestCancelIncident(incidentId, note) {
    try {
        const res = await fetch(`/incidents/${incidentId}/cancel`, {
            method: 'POST',
            body: new URLSearchParams({ user_id: userId, note })
        });
        const data = await res.json();
        if (data.cancelled) {
            showToast("Cancelled — nobody was called or messaged.", "success");
        } else {
            showToast(data.reason || "Could not cancel — it may already have dispatched.", "error");
        }
        return data.incident || null;
    } catch (e) {
        console.error("Cancel error:", e);
        showToast("Could not cancel — the request failed. Try again.", "error");
        return null;
    }
}

async function startEscalation(data, clipBlob) {
    currentIncidentId = null;
    escalationCancelRequested = false;
    showEscalationState({ state: 'PENDING', seconds_to_dispatch: 0 });
    try {
        const incident = await createIncidentAndEscalate(data, clipBlob);
        escalationTotalWindow = (escalationStatus && escalationStatus.cancel_window_seconds) || incident.seconds_to_dispatch || 12;

        if (escalationCancelRequested) {
            // The user already clicked Cancel/"I'm safe" while this incident
            // was still being created. Honor that now instead of silently
            // arming a countdown for something they already dismissed.
            currentIncidentId = incident.id;
            if (incident.escalation_armed) {
                const cancelled = await requestCancelIncident(incident.id, "Cancelled before the alert finished arming.");
                showEscalationState(cancelled || { state: 'CANCELLED' });
            } else {
                showEscalationState({ state: incident.state || 'CANCELLED' });
            }
            currentIncidentId = null;
            return;
        }

        currentIncidentId = incident.id;
        if (!incident.escalation_armed) {
            showEscalationState({ state: 'SUPPRESSED', gate_reason: incident.gate_reason });
            return;
        }
        showEscalationState(incident);
        stopEscalationTimers();
        escalationPollFailures = 0;
        escalationPollTimer = setInterval(() => pollIncident(incident.id), 1000);
    } catch (e) {
        console.error("Escalation error:", e);
        showToast(e.message || "Could not arm contact escalation.", "error");
        showEscalationState(null);
    }
}

document.getElementById('escalation-cancel-btn').addEventListener('click', async () => {
    if (!currentIncidentId) {
        escalationCancelRequested = true;
        showToast("Cancelling as soon as the alert finishes arming…", "info");
        return;
    }
    stopEscalationTimers();
    const incidentId = currentIncidentId;
    currentIncidentId = null;
    const cancelled = await requestCancelIncident(incidentId, "Marked safe by the user.");
    showEscalationState(cancelled || { state: 'CANCELLED' });
});

function downloadIncidentReport() {
    if (!latestIncident) return;
    const decision = latestIncident.decision || {};
    const report = [
        "ECHO INCIDENT REPORT", `Generated: ${new Date().toISOString()}`,
        `Detected sound: ${latestIncident.candidate}`,
        `Primary confidence: ${(latestIncident.primary_confidence * 100).toFixed(1)}%`,
        `Verification confidence: ${(latestIncident.verification_confidence * 100).toFixed(1)}%`,
        `Risk score: ${latestIncident.risk_score} (${latestIncident.risk_level})`,
        `Decision: ${decision.state || "NOT AVAILABLE"}`,
        `Rationale: ${decision.rationale || "No decision rationale available."}`,
        "Audio was not retained by Echo.",
        "This report is user-generated evidence, not a police report or emergency dispatch request."
    ].join("\n");
    const url = URL.createObjectURL(new Blob([report], { type: "text/plain" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `echo-incident-${Date.now()}.txt`;
    link.click();
    URL.revokeObjectURL(url);
}

downloadReportBtn.addEventListener("click", downloadIncidentReport);

function stopMonitoring() {
    isMonitoring = false;
    if (mediaStream) {
        mediaStream.getTracks().forEach(track => track.stop());
    }
    if (recordingInterval) clearInterval(recordingInterval);
    recordingInterval = null;
    pipelineBusy = false;
    if (animationFrameId) cancelAnimationFrame(animationFrameId);

    startBtn.innerText = "START MONITORING";
    startBtn.classList.remove('listening');
    systemStatusBadge.innerText = "Off";
    systemStatusBadge.classList.remove('active');
    micStatusIndicator.className = "signal-dot red";
    micStatusText.innerText = "Idle";

    // Clear Visualizer Canvas
    canvasCtx.clearRect(0, 0, canvas.width, canvas.height);
}

// Web Audio API Visualizer Setup
function setupVisualizer() {
    audioContext = new (window.AudioContext || window.webkitAudioContext)();
    const source = audioContext.createMediaStreamSource(mediaStream);
    const analyser = audioContext.createAnalyser();
    analyser.fftSize = 256;
    source.connect(analyser);

    const bufferLength = analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);

    function draw() {
        if (!isMonitoring) return;
        animationFrameId = requestAnimationFrame(draw);

        analyser.getByteFrequencyData(dataArray);
        canvasCtx.fillStyle = '#020617';
        canvasCtx.fillRect(0, 0, canvas.width, canvas.height);

        const barWidth = (canvas.width / bufferLength) * 1.5;
        let barHeight;
        let x = 0;

        for (let i = 0; i < bufferLength; i++) {
            barHeight = dataArray[i] / 2;
            canvasCtx.fillStyle = `rgb(13, ${148 + barHeight}, ${136 - barHeight})`;
            canvasCtx.fillRect(x, canvas.height - barHeight, barWidth - 2, barHeight);
            x += barWidth;
        }
    }

    draw();
}

// Pipeline Recording / Inference loop
let audioChunks = [];
let mediaRecorder = null;

function startPipelineLoop() {
    // Record a 2-second window every 2.5 seconds, never overlapping a verification.
    runPipelinePass1();
    recordingInterval = setInterval(() => {
        if (!isMonitoring || pipelineBusy) return;
        runPipelinePass1();
    }, 2500);
}

async function runPipelinePass1() {
    if (!mediaStream || pipelineBusy) return;
    pipelineBusy = true;
    let handedOffToVerification = false;

    // Set up brief 2-second recorder using Web Audio script processor to convert to WAV
    const recorderContext = new AudioContext({ sampleRate: 16000 });
    const source = recorderContext.createMediaStreamSource(mediaStream);
    const processor = recorderContext.createScriptProcessor(4096, 1, 1);

    let leftChannel = [];

    processor.onaudioprocess = (e) => {
        const left = e.inputBuffer.getChannelData(0);
        leftChannel.push(new Float32Array(left));
    };

    source.connect(processor);
    processor.connect(recorderContext.destination);

    // Stop recording after 2 seconds
    setTimeout(async () => {
        if (!isMonitoring) {
            pipelineBusy = false;
            return;
        }
        source.disconnect();
        processor.disconnect();
        await recorderContext.close();

        // Merge chunks
        let flattened = mergeBuffers(leftChannel);
        let wavBlob = bufferToWav(flattened, 16000);

        // Send to backend Pass 1
        const formData = new FormData();
        formData.append("file", wavBlob, "chunk_2s.wav");
        formData.append("duration", 2.0);
        formData.append("media_playback", document.getElementById('ctx-media').checked);
        formData.append("sudden_motion", document.getElementById('ctx-motion').checked);
        formData.append("sensitivity_threshold", sensitivityThreshold());
        formData.append("user_id", userId);
        formData.append("context_source", "browser_manual");
        formData.append("profile", modelProfile);

        try {
            const res = await fetch("/detect", { method: "POST", body: formData });
            if (!res.ok) throw new Error(`Detection failed (${res.status})`);
            const data = await res.json();

            if (data.has_candidate) {
                if (data.immediate_verification) {
                    updateUIForClass(
                        data.candidate,
                        data.primary_confidence,
                        data.verification_confidence,
                        data.risk_score,
                        data.risk_level
                    );

                    if (data.verified) {
                        await logVerifiedEvent(data);
                        handleVerifiedDetection(data, wavBlob);
                    }
                } else {
                    // Trigger Pass 2: Verify candidate over a 5s window
                    micStatusIndicator.className = "signal-dot orange";
                    micStatusText.innerText = "Verifying...";
                    handedOffToVerification = true;
                    runPipelinePass2(data.candidate, data.confidence);
                    return;
                }
            } else {
                updateUIForClass("normal", data.confidence, 0.0, 0, "NORMAL");
            }
        } catch (e) {
            console.error("Pass 1 Detection error:", e);
            showToast("Lost contact with the backend during monitoring. Retrying next cycle.", "error", 3000);
        } finally {
            if (!handedOffToVerification) pipelineBusy = false;
        }
    }, 2000);
}

async function runPipelinePass2(candidate, p1Conf) {
    if (!mediaStream) return;
    pipelineBusy = true;
    const recorderContext = new AudioContext({ sampleRate: 16000 });
    const source = recorderContext.createMediaStreamSource(mediaStream);
    const processor = recorderContext.createScriptProcessor(4096, 1, 1);

    let leftChannel = [];
    processor.onaudioprocess = (e) => {
        leftChannel.push(new Float32Array(e.inputBuffer.getChannelData(0)));
    };
    source.connect(processor);
    processor.connect(recorderContext.destination);

    // Record for 5 seconds for full verification
    setTimeout(async () => {
        if (!isMonitoring) {
            pipelineBusy = false;
            return;
        }
        source.disconnect();
        processor.disconnect();
        await recorderContext.close();

        let flattened = mergeBuffers(leftChannel);
        let wavBlob = bufferToWav(flattened, 16000);

        const mediaPlayback = document.getElementById('ctx-media').checked;
        const suddenMotion = document.getElementById('ctx-motion').checked;

        const formData = new FormData();
        formData.append("file", wavBlob, "chunk_5s.wav");
        formData.append("duration", 5.0);
        formData.append("media_playback", mediaPlayback);
        formData.append("sudden_motion", suddenMotion);
        formData.append("primary_candidate", candidate);
        formData.append("primary_confidence", p1Conf);
        formData.append("sensitivity_threshold", sensitivityThreshold());
        formData.append("user_id", userId);
        formData.append("context_source", "browser_manual");
        formData.append("profile", modelProfile);

        try {
            const res = await fetch("/detect", { method: "POST", body: formData });
            if (!res.ok) throw new Error(`Verification failed (${res.status})`);
            const data = await res.json();

            micStatusIndicator.className = "signal-dot green";
            micStatusText.innerText = "Monitoring";

            updateUIForClass(
                data.candidate,
                data.primary_confidence,
                data.verification_confidence,
                data.risk_score,
                data.risk_level
            );

            if (data.verified) {
                await logVerifiedEvent(data);
                handleVerifiedDetection(data, wavBlob);
            }
        } catch (e) {
            console.error("Pass 2 Verification error:", e);
            showToast("Verification pass failed to reach the backend.", "error", 3000);
        } finally {
            pipelineBusy = false;
        }
    }, 5000);
}

// WAV encoding helper logic
function mergeBuffers(channelBuffer) {
    let resultLen = 0;
    for (let i = 0; i < channelBuffer.length; i++) {
        resultLen += channelBuffer[i].length;
    }
    let result = new Float32Array(resultLen);
    let offset = 0;
    for (let i = 0; i < channelBuffer.length; i++) {
        result.set(channelBuffer[i], offset);
        offset += channelBuffer[i].length;
    }
    return result;
}

function bufferToWav(buffer, sampleRate) {
    let bufferLen = buffer.length;
    let writeBuffer = new ArrayBuffer(44 + bufferLen * 2);
    let view = new DataView(writeBuffer);

    // RIFF header
    writeString(view, 0, 'RIFF');
    view.setUint32(4, 36 + bufferLen * 2, true);
    writeString(view, 8, 'WAVE');
    writeString(view, 12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); // PCM Format
    view.setUint16(22, 1, true); // Mono
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 2, true); // Byte rate
    view.setUint16(32, 2, true); // Block align
    view.setUint16(34, 16, true); // Bits per sample
    writeString(view, 36, 'data');
    view.setUint32(40, bufferLen * 2, true);

    // Float to 16bit PCM conversion
    let offset = 44;
    for (let i = 0; i < buffer.length; i++, offset += 2) {
        let s = Math.max(-1, Math.min(1, buffer[i]));
        view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    }
    return new Blob([writeBuffer], { type: 'audio/wav' });
}

function writeString(view, offset, string) {
    for (let i = 0; i < string.length; i++) {
        view.setUint8(offset + i, string.charCodeAt(i));
    }
}

// Update Dashboard Stats UI
function updateUIForClass(cls, p1, p2, risk, level) {
    monClass.innerText = cls.toUpperCase();
    monRisk.innerText = risk;
    monP1.innerText = `${((p1 || 0) * 100).toFixed(1)}%`;
    monP2.innerText = p2 > 0 ? `${(p2 * 100).toFixed(1)}%` : "0.0%";
    if (monP1Bar) monP1Bar.style.width = `${Math.max(0, Math.min(100, (p1 || 0) * 100))}%`;
    if (monP2Bar) monP2Bar.style.width = `${Math.max(0, Math.min(100, (p2 || 0) * 100))}%`;

    const normalizedLevel = normalizeRiskLevel(level);
    applyRiskAttr(monClassBox, normalizedLevel);
    applyRiskAttr(monRiskBox, normalizedLevel);
    if (monRiskChip) monRiskChip.textContent = normalizedLevel.replace('_', ' ');
    if (pulseWrapper) pulseWrapper.className = 'pulse-wrapper risk-' + normalizedLevel.toLowerCase();

    if (cls !== "normal") {
        lastEventDetails.innerHTML = `
            <strong>${cls.toUpperCase()}</strong><br>
            Risk Score: ${risk} (${level})<br>
            Conf: P1=${(p1 * 100).toFixed(0)}%, P2=${(p2 * 100).toFixed(0)}%
        `;
    }
}

// A verified detection can be worth logging without being worth a full-screen
// alarm. Reserve the intrusive modal (guidance, nearby facilities, escalation
// countdown) for POSSIBLE_DANGER/HIGH_RISK -- a SUSPICIOUS-level "should_alert"
// (any verified hazard-class reading with risk >= 31, per safety_policy.py's
// REVIEW_NOW state) still gets surfaced, just as a toast and a quiet log
// entry instead of the same screen used for an actual emergency. Popping the
// full alert for every borderline, moderate-confidence read trains the user
// to distrust or dismiss it -- see docs/DECISIONS_LOG.md #10.
const FULL_ALERT_LEVELS = new Set(['POSSIBLE_DANGER', 'HIGH_RISK']);

function handleVerifiedDetection(data, clipBlob) {
    if (!data.should_alert) {
        if (data.media_suppressed) {
            lastEventDetails.innerText = "Verified sound recorded as likely media playback; no critical alert shown.";
        }
        return;
    }
    if (FULL_ALERT_LEVELS.has(normalizeRiskLevel(data.risk_level))) {
        triggerAlertModal(data, clipBlob);
        return;
    }
    const label = (data.candidate || 'sound').replace(/_/g, ' ');
    showToast(
        `Possible ${label} (${data.risk_score}/100, ${data.risk_level}) — logged, below the alert threshold.`,
        'info', 5000
    );
    lastEventDetails.innerHTML = `
        <strong>${(data.candidate || '').toUpperCase()}</strong><br>
        Risk Score: ${data.risk_score} (${data.risk_level}) — reviewed, not alarmed<br>
        Conf: P1=${((data.primary_confidence || 0) * 100).toFixed(0)}%, P2=${((data.verification_confidence || 0) * 100).toFixed(0)}%
    `;
}

// Trigger Alert View Overlay
async function triggerAlertModal(data, clipBlob) {
    if (alertModal.classList.contains('show')) {
        // A second detection landing while an alert is already open used to
        // start a competing startEscalation() call -- resetting
        // currentIncidentId out from under the first one, orphaning its
        // poll timer, and making Cancel able to cancel the wrong incident
        // while the real one dispatched unattended. One alert at a time:
        // this one is still logged (the caller already did that before
        // reaching here), just not opened as a second competing modal.
        showToast(
            `Another ${(data.candidate || 'sound').replace(/_/g, ' ')} detected `
            + `(${data.risk_score}/100) while an alert is already open.`,
            'info'
        );
        return;
    }
    latestIncident = data;
    notifyUrgentIncident(data);
    const normalizedLevel = normalizeRiskLevel(data.risk_level);
    applyRiskAttr(alertHeader, normalizedLevel);
    document.getElementById('alert-badge').textContent = normalizedLevel === 'HIGH_RISK' ? 'CRITICAL ALERT' : normalizedLevel === 'POSSIBLE_DANGER' ? 'ALERT' : 'REVIEW';
    alertTitle.innerText = guidanceRules[data.candidate]?.title || "Acoustic Threat Detected";
    const rawClassEl = document.getElementById('alert-raw-class');
    if (data.alias_applied && data.raw_candidate) {
        rawClassEl.hidden = false;
        rawClassEl.textContent = `Raw acoustic class: ${data.raw_candidate}${data.profile === 'demo' ? ' (demo profile)' : ''}`;
    } else {
        rawClassEl.hidden = true;
    }
    alertRiskScore.innerText = data.risk_score;
    alertRiskLvl.innerText = `(${data.risk_level})`;
    alertP1.innerText = `${(data.primary_confidence * 100).toFixed(0)}%`;
    alertP2.innerText = `${(data.verification_confidence * 100).toFixed(0)}%`;
    if (alertRiskRingFill) {
        const circumference = 169.6; // 2 * pi * 27
        const pct = Math.max(0, Math.min(100, data.risk_score || 0)) / 100;
        alertRiskRingFill.style.strokeDashoffset = String(circumference * (1 - pct));
    }

    // Arms the real countdown -> automated call + Telegram to saved contacts.
    startEscalation(data, clipBlob);

    // Guidance Rules display
    alertGuidanceList.innerHTML = "";
    const instructions = guidanceRules[data.candidate]?.instructions || [];
    instructions.forEach(step => {
        const li = document.createElement('li');
        li.innerText = step;
        alertGuidanceList.appendChild(li);
    });

    // Populate Accurate Incident Location in Alert Modal & Load Contextual Facilities
    currentAlertThreat = data.candidate;
    detectAccurateLocation().then(loc => {
        refreshAlertLocationAndPlaces(loc);
    }).catch(err => {
        console.error("Location resolution error:", err);
    });

    alertModal.classList.add('show');
}

function refreshAlertLocationAndPlaces(loc) {
    const alertLocAddress = document.getElementById('alert-loc-address');
    const alertLocCoords = document.getElementById('alert-loc-coords');
    const alertLocAccuracy = document.getElementById('alert-loc-accuracy');
    const alertLocMapsLink = document.getElementById('alert-loc-maps-link');

    if (alertLocAddress) alertLocAddress.textContent = loc.address || "Detected Incident Area";
    if (alertLocCoords) alertLocCoords.textContent = `Lat: ${loc.lat.toFixed(6)}, Lng: ${loc.lng.toFixed(6)}`;
    if (alertLocAccuracy) {
        alertLocAccuracy.textContent = (loc.source && loc.source.includes('gps'))
            ? `GPS (±${loc.accuracy}m)`
            : ((loc.source && (loc.source.includes('calibrated') || loc.source.includes('user'))) ? 'User Calibrated' : 'Network IP');
    }
    if (alertLocMapsLink) {
        alertLocMapsLink.href = loc.maps_url || `https://www.google.com/maps?q=${loc.lat},${loc.lng}`;
        alertLocMapsLink.title = `View coordinates ${loc.lat.toFixed(6)}, ${loc.lng.toFixed(6)} on Google Maps`;
    }

    if (currentAlertThreat) {
        loadAndRenderNearbyFacilities(loc, currentAlertThreat);
    }
}

async function loadAndRenderNearbyFacilities(loc, threatCandidate) {
    const placesSearchAllBtn = document.getElementById('places-search-all-btn');
    if (!alertPlacesContainer) return;

    const threatLabel = (threatCandidate || 'sound').replace(/_/g, ' ');
    alertPlacesContainer.innerHTML = `<div class='place-card' style='text-align:center; padding:16px; color:var(--muted);'>Finding nearest 3-4 emergency facilities for ${threatLabel}...</div>`;

    try {
        const res = await fetch(`/nearby?lat=${loc.lat}&lng=${loc.lng}&threat=${encodeURIComponent(threatCandidate)}&limit=4`);
        if (!res.ok) throw new Error(`Facilities lookup error (${res.status})`);
        const resData = await res.json();

        alertPlacesContainer.innerHTML = "";
        if (placesSearchAllBtn && resData.google_search_url) {
            placesSearchAllBtn.href = resData.google_search_url;
            placesSearchAllBtn.hidden = false;
            placesSearchAllBtn.textContent = `🔍 Search all in Google Maps`;
        }

        if (resData.results && resData.results.length > 0) {
            resData.results.forEach(place => {
                const card = document.createElement('div');
                card.className = 'place-card';

                // Top line: Category Badge + Name + Distance badge
                const topRow = document.createElement('div');
                topRow.className = 'place-card-top';

                const leftHead = document.createElement('div');
                leftHead.style.display = 'flex';
                leftHead.style.alignItems = 'center';
                leftHead.style.flexWrap = 'wrap';
                leftHead.style.gap = '6px';

                if (place.category) {
                    const catBadge = document.createElement('span');
                    catBadge.className = 'place-category-badge';
                    catBadge.textContent = `${place.icon || '🚨'} ${place.category}`;
                    leftHead.appendChild(catBadge);
                }

                const nameEl = document.createElement('span');
                nameEl.className = 'name';
                nameEl.textContent = place.name;
                leftHead.appendChild(nameEl);
                topRow.appendChild(leftHead);

                if (place.distance_km !== undefined && place.distance_km !== null) {
                    const distBadge = document.createElement('span');
                    distBadge.className = 'place-dist-badge';
                    distBadge.textContent = `${place.distance_km} km away`;
                    topRow.appendChild(distBadge);
                }
                card.appendChild(topRow);

                // Urgency note
                if (place.urgency) {
                    const urgEl = document.createElement('div');
                    urgEl.className = 'place-urgency-note';
                    urgEl.textContent = `⚡ ${place.urgency}`;
                    card.appendChild(urgEl);
                }

                // Address line
                const addrEl = document.createElement('div');
                addrEl.className = 'addr';
                addrEl.textContent = place.address || 'Location verified';
                card.appendChild(addrEl);

                // Action buttons: Directions & View on Map
                const actionsRow = document.createElement('div');
                actionsRow.className = 'place-card-actions';

                const dirBtn = document.createElement('a');
                dirBtn.className = 'place-btn place-dir-btn';
                dirBtn.href = place.directions_url || `https://www.google.com/maps/dir/?api=1&origin=${loc.lat},${loc.lng}&destination=${encodeURIComponent(place.name + ' ' + (place.address || ''))}`;
                dirBtn.target = '_blank';
                dirBtn.rel = 'noopener noreferrer';
                dirBtn.innerHTML = '🧭 Directions';
                actionsRow.appendChild(dirBtn);

                const mapBtn = document.createElement('a');
                mapBtn.className = 'place-btn place-map-btn';
                mapBtn.href = place.maps_url || `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(place.name + ' ' + (place.address || ''))}`;
                mapBtn.target = '_blank';
                mapBtn.rel = 'noopener noreferrer';
                mapBtn.innerHTML = '📍 View on Map';
                actionsRow.appendChild(mapBtn);

                card.appendChild(actionsRow);
                alertPlacesContainer.appendChild(card);
            });
        } else {
            const fallbackUrl = resData.google_search_url || `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(threatCandidate + ' emergency near me')}`;
            alertPlacesContainer.innerHTML = `
                <div class='place-card' style='text-align:center; padding:18px;'>
                    <p style='margin:0 0 10px; color:#cbd5e1;'>No direct facilities listed in immediate radius.</p>
                    <a class='place-btn place-dir-btn' href='${fallbackUrl}' target='_blank' rel='noopener noreferrer'>
                        🔍 Search emergency facilities on Google Maps
                    </a>
                </div>
            `;
        }
    } catch (err) {
        console.error("Nearby facilities error:", err);
        const fallbackUrl = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(threatCandidate + ' near ' + (loc.address || `${loc.lat},${loc.lng}`))}`;
        alertPlacesContainer.innerHTML = `
            <div class='place-card' style='text-align:center; padding:18px;'>
                <p style='margin:0 0 10px; color:#cbd5e1;'>Facility directory query failed.</p>
                <a class='place-btn place-dir-btn' href='${fallbackUrl}' target='_blank' rel='noopener noreferrer'>
                    🗺️ Find on Google Maps
                </a>
            </div>
        `;
    }
}



dismissAlertBtn.addEventListener('click', async () => {
    // "I'm safe" also cancels a still-pending escalation -- closing the modal
    // must not leave a countdown silently running in the background.
    stopEscalationTimers();
    if (currentIncidentId) {
        await requestCancelIncident(currentIncidentId, "Dismissed by the user.");
    } else {
        // Incident creation may still be in flight (waiting on geolocation,
        // etc.) -- there's no id yet to cancel. Same race as the Cancel
        // button: flag it so startEscalation cancels it the moment it does
        // get an id, instead of it arming and dispatching invisibly behind
        // a modal the user already closed.
        escalationCancelRequested = true;
    }
    currentIncidentId = null;
    alertModal.classList.remove('show');
});

// HISTORY PERSISTENCE
function loadHistory() {
    fetch(`/events/${userId}`)
        .then(res => res.json())
        .then(data => {
            historyContainer.innerHTML = "";
            if (data.length === 0) {
                historyContainer.innerHTML = "<div class='empty-state'>No events recorded.</div>";
                return;
            }
            data.forEach(item => {
                const date = new Date(item.timestamp * 1000).toLocaleString();
                const level = normalizeRiskLevel(item.risk_level);
                const card = document.createElement('div');
                card.className = 'history-card';
                card.setAttribute('data-risk', level);
                card.innerHTML = `
                    <div class="meta">
                        <strong>${item.class_name.toUpperCase()}</strong>
                        <span class="time-stamp">${date}</span>
                    </div>
                    <span class="risk-pill">${item.risk_score} · ${level.replace('_', ' ')}</span>
                `;
                historyContainer.appendChild(card);
            });
        })
        .catch(() => { historyContainer.innerHTML = "<div class='empty-state'>Could not load history.</div>"; });
}

clearHistoryBtn.addEventListener('click', async () => {
    historyContainer.innerHTML = "<div class='empty-state'>Clearing history...</div>";
    try {
        const response = await fetch(`/events/${userId}`, { method: 'DELETE' });
        if (!response.ok) throw new Error('Could not clear history');
        loadHistory();
        showToast("History cleared.", "success");
    } catch (error) {
        historyContainer.innerHTML = "<div class='empty-state'>Could not clear history. Please try again.</div>";
        showToast("Could not clear history.", "error");
    }
});

// EMERGENCY CONTACTS CRUD
function loadContacts() {
    fetch(`/contacts-detail/${userId}`)
        .then(res => res.ok ? res.json() : fetch(`/contacts/${userId}`).then(r => r.json()))
        .then(data => {
            contactsContainer.innerHTML = "";
            if (data.length === 0) {
                contactsContainer.innerHTML = "<div class='empty-state'>No trusted contacts added yet. Add one below, then send a test alert to confirm it works.</div>";
                return;
            }
            data.forEach(contact => {
                // Built with DOM nodes + textContent, not innerHTML: name/
                // relation/phone are user-entered text round-tripped from
                // the backend, and must not be able to inject markup.
                const callOn = contact.notify_call === undefined ? true : !!contact.notify_call;
                const tgOn = contact.notify_telegram === undefined ? true : !!contact.notify_telegram;

                const name = document.createElement('h4');
                name.textContent = contact.name + (contact.relation ? ` (${contact.relation})` : '');
                const phone = document.createElement('p');
                phone.textContent = contact.phone;
                const badgesRow = document.createElement('p');
                const callPill = document.createElement('span');
                callPill.className = callOn ? 'chan-pill live' : 'chan-pill';
                callPill.textContent = callOn ? 'Call' : 'Call off';
                const tgPill = document.createElement('span');
                tgPill.className = (tgOn && contact.telegram_chat_id) ? 'chan-pill live' : tgOn ? 'chan-pill sim' : 'chan-pill';
                tgPill.textContent = (tgOn && contact.telegram_chat_id) ? 'Telegram' : tgOn ? 'Telegram (no chat id)' : 'Telegram off';
                badgesRow.append(callPill, document.createTextNode(' '), tgPill);

                const info = document.createElement('div');
                info.className = 'info';
                info.append(name, phone, badgesRow);

                const deleteBtn = document.createElement('button');
                deleteBtn.className = 'delete-btn';
                deleteBtn.textContent = 'Delete';
                deleteBtn.addEventListener('click', () => deleteContact(contact.id));

                const card = document.createElement('div');
                card.className = 'contact-card';
                card.append(info, deleteBtn);
                contactsContainer.appendChild(card);
            });
        })
        .catch(() => { contactsContainer.innerHTML = "<div class='empty-state'>Could not load contacts.</div>"; });
}

saveContactBtn.addEventListener('click', () => {
    const name = contactNameInput.value.trim();
    const phone = contactPhoneInput.value.trim();
    const relation = contactRelationInput.value.trim();
    const telegramChatId = contactTelegramInput.value.trim();
    const priority = Number(contactPriorityInput.value) || 100;

    if (!name || !phone) {
        showToast("Enter a name and phone number.", "error");
        return;
    }

    fetch('/contacts', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            user_id: userId, name, phone, relation,
            telegram_chat_id: telegramChatId || null,
            priority,
            notify_call: contactNotifyCall.checked,
            notify_telegram: contactNotifyTelegram.checked,
        })
    })
    .then(res => { if (!res.ok) throw new Error(); return res.json(); })
    .then(() => {
        contactNameInput.value = "";
        contactPhoneInput.value = "";
        contactRelationInput.value = "";
        contactTelegramInput.value = "";
        contactPriorityInput.value = "100";
        contactNotifyCall.checked = true;
        contactNotifyTelegram.checked = true;
        chatPicker.hidden = true;
        loadContacts();
        loadReadiness();
        showToast(`${name} added to your safety network.`, "success");
    })
    .catch(() => showToast("Could not save that contact. Check the backend is running.", "error"));
});

function deleteContact(id) {
    fetch(`/contacts/${id}?user_id=${encodeURIComponent(userId)}`, { method: 'DELETE' })
        .then(res => {
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            loadContacts();
            loadReadiness();
            showToast("Contact removed.", "info");
        })
        .catch(() => showToast("Could not remove that contact.", "error"));
}

findChatsBtn.addEventListener('click', async () => {
    findChatsBtn.disabled = true;
    findChatsBtn.textContent = "Looking…";
    try {
        const res = await fetch('/telegram/chats');
        const data = await res.json();
        chatPicker.innerHTML = "";
        chatPicker.hidden = false;
        if (!data.configured) {
            chatPicker.innerHTML = "<div class='empty'>Telegram bot token isn't configured on the backend yet — paste TELEGRAM_BOT_TOKEN into backend/.env and restart.</div>";
        } else if (!data.chats || data.chats.length === 0) {
            chatPicker.innerHTML = `<div class="empty">${data.hint || "No chats yet — have your contact press Start on your bot, then try again."}</div>`;
        } else {
            data.chats.forEach(chat => {
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.textContent = `${chat.name}${chat.username ? ' (@' + chat.username + ')' : ''} — ${chat.chat_id}`;
                btn.addEventListener('click', () => {
                    contactTelegramInput.value = chat.chat_id;
                    chatPicker.hidden = true;
                });
                chatPicker.appendChild(btn);
            });
        }
    } catch (e) {
        showToast("Could not reach the backend to list Telegram chats.", "error");
    } finally {
        findChatsBtn.disabled = false;
        findChatsBtn.textContent = "Find chats that started my bot";
    }
});

sendTestAlertBtn.addEventListener('click', async () => {
    sendTestAlertBtn.disabled = true;
    sendTestAlertBtn.textContent = "Sending…";
    testAlertResult.innerHTML = "";
    try {
        const res = await fetch('/escalation/test', {
            method: 'POST',
            body: new URLSearchParams({ user_id: userId, user_label: displayName }),
        });
        if (res.status === 400) {
            showToast("Add a contact first — there's nobody to test-alert yet.", "error");
            return;
        }
        if (res.status === 429) {
            showToast("A test alert already went out in the last minute. Wait before sending another.", "error");
            return;
        }
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const incident = await res.json();
        const list = document.createElement('ul');
        list.className = 'escalation-attempts';
        renderEscalationAttempts(incident.attempts || [], list);
        testAlertResult.appendChild(list);
        showToast("Test alert sent — check the results below.", "success");
    } catch (e) {
        showToast("Test alert failed to reach the backend.", "error");
    } finally {
        sendTestAlertBtn.disabled = false;
        sendTestAlertBtn.textContent = "Send test alert to my contacts";
    }
});

// DEMO MODE DIRECT FILE INJECTION (Method B)
const demoWavButtons = document.querySelectorAll('.wav-btn');

demoWavButtons.forEach(btn => {
    btn.addEventListener('click', async () => {
        const soundClass = btn.getAttribute('data-sound');

        try {
            // Fetch authentic real WAV file for this sound class
            let res = await fetch(`/demo_sounds/${soundClass}.wav`);
            if (!res.ok) {
                res = await fetch(`/data/processed/${soundClass}/real_${soundClass}_000.wav`);
            }
            if (!res.ok) {
                throw new Error(`Could not find authentic audio file for '${soundClass}'.`);
            }

            const wavBlob = await res.blob();

            // Play audio natively in browser so the user can hear the demo
            const audioUrl = URL.createObjectURL(wavBlob);
            const audio = new Audio(audioUrl);
            audio.play().catch(e => console.warn("Audio playback failed (browser auto-play policy):", e));

            const mediaPlayback = document.getElementById('ctx-media').checked;
            const suddenMotion = document.getElementById('ctx-motion').checked;

            // Post direct into inference pipeline
            const formData = new FormData();
            formData.append("file", wavBlob, "inject.wav");
            formData.append("duration", 5.0); // Send 5s to run full pipeline
            formData.append("media_playback", mediaPlayback);
            formData.append("sudden_motion", suddenMotion);
            formData.append("sensitivity_threshold", sensitivityThreshold());
            formData.append("user_id", userId);
            formData.append("context_source", "browser_manual");
            formData.append("profile", modelProfile);

            // Switch screen to Monitor to show live changes
            switchScreen('monitor');
            monClass.innerText = "ANALYZING...";

            const detectRes = await fetch("/detect", { method: "POST", body: formData });
            if (!detectRes.ok) throw new Error(`Detection failed (${detectRes.status})`);
            const data = await detectRes.json();

            updateUIForClass(
                data.candidate,
                data.primary_confidence,
                data.verification_confidence,
                data.risk_score,
                data.risk_level
            );

            if (data.verified) {
                await logVerifiedEvent(data);
                setTimeout(() => handleVerifiedDetection(data, wavBlob), 800);
            }
        } catch (e) {
            showToast(`Sample injection failed: ${e.message}`, "error");
        }
    });
});

// Demo Mic mode trigger
const demoMicBtn = document.getElementById('demo-mic-btn');
let demoMicActive = false;

demoMicBtn.addEventListener('click', async () => {
    if (demoMicActive) {
        demoMicActive = false;
        demoMicBtn.innerText = "Start Live Demo Listening";
        demoMicBtn.classList.remove('active');
        stopMonitoring();
    } else {
        switchScreen('monitor');
        const started = await startMonitoring();
        if (started) {
            demoMicActive = true;
            demoMicBtn.innerText = "Listening... Click to Stop";
            demoMicBtn.classList.add('active');
        }
    }
});
