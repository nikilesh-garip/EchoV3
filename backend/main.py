import os
import sys
import time
import uuid
import sqlite3
from contextlib import asynccontextmanager
from typing import List, Optional

import requests
from fastapi import FastAPI, HTTPException, Query, UploadFile, File, Form
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# Add parent directory to path so we can import model modules
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "model")))

from two_pass_detector import TwoPassDetector
from risk_scorer import RISK_CONFIG, RiskScorer
from safety_policy import decide_action
from model_readiness import assess_dataset_readiness
from audio_classes import MEDIA_CONTEXT_THRESHOLD
from model_profiles import DEMO_PROFILE_NAME, REAL_PROFILE_NAME, available_profiles, get_profile
from yamnet_features import load_yamnet

import emergency_routes
from db import DB_PATH, get_db, init_db
from geocode import reverse_geocode
import math
import urllib.parse


def _resolve_media_context(client_media_playback, client_context_source, acoustic_media_score):
    """Combines the user/platform-reported media_playback flag with the
    automatically-detected acoustic media-context signal (see
    audio_classes.MEDIA_CONTEXT_AUDIOSET_INDICES). The acoustic signal only
    ever adds evidence of playback -- it never overrides an explicit False,
    and it is tagged with its own, weaker context_source so safety_policy's
    context_reliability field stays honest about where the signal came from.
    """
    if client_media_playback:
        return True, client_context_source
    if acoustic_media_score >= MEDIA_CONTEXT_THRESHOLD:
        return True, "acoustic_signal"
    return False, client_context_source


DATA_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "model", "data"))

init_db()


@asynccontextmanager
async def _lifespan(app: FastAPI):
    emergency_routes.start_sweeper()
    yield


app = FastAPI(title="Echo Smart Emergency System API", version="2.0", lifespan=_lifespan)

# Initialize Detectors and Scorer (Fail fast on startup if the production
# checkpoint is missing or corrupt). The demo head is optional: a machine that
# never runs the presentation should still start.
REAL_PROFILE = get_profile(REAL_PROFILE_NAME)
DEMO_PROFILE = get_profile(DEMO_PROFILE_NAME)

if not REAL_PROFILE.checkpoint_exists:
    print("CRITICAL: Model checkpoint missing at: {}".format(REAL_PROFILE.checkpoint_path))
    sys.exit(1)

detectors = {}
try:
    # One frozen YAMNet backbone shared by both heads -- loading it twice would
    # cost ~30s and several hundred MB for identical weights.
    shared_yamnet = load_yamnet()
    detectors[REAL_PROFILE_NAME] = TwoPassDetector(profile=REAL_PROFILE, yamnet=shared_yamnet)
    print("Successfully loaded YAMNet transfer-learning classifier for inference!")
except Exception as e:
    print("CRITICAL ERROR loading model: {}".format(e))
    sys.exit(1)

if DEMO_PROFILE.checkpoint_exists:
    try:
        detectors[DEMO_PROFILE_NAME] = TwoPassDetector(profile=DEMO_PROFILE, yamnet=shared_yamnet)
        print("Demo profile head loaded (firecracker class available).")
    except Exception as e:
        # A broken demo head must never take down the production path.
        print("WARNING: demo head present but failed to load: {}".format(e))
else:
    print("Demo profile head not built yet (run prepare_demo_dataset.py + "
          "train_yamnet.py --profile demo).")

detector = detectors[REAL_PROFILE_NAME]  # backwards-compatible alias
scorer = RiskScorer()

app.include_router(emergency_routes.router)


# Pydantic Schemas
class EventCreate(BaseModel):
    user_id: str
    class_name: str
    primary_conf: float
    verification_conf: float
    risk_score: int
    risk_level: str

class EventResponse(BaseModel):
    id: int
    user_id: str
    timestamp: float
    class_name: str
    primary_conf: float
    verification_conf: float
    risk_score: int
    risk_level: str

class ContactCreate(BaseModel):
    user_id: str
    name: str
    phone: str
    relation: Optional[str] = None
    telegram_chat_id: Optional[str] = None
    priority: Optional[int] = 100
    notify_call: Optional[bool] = True
    notify_telegram: Optional[bool] = True

class ContactUpdate(BaseModel):
    name: Optional[str] = None
    phone: Optional[str] = None
    relation: Optional[str] = None
    telegram_chat_id: Optional[str] = None
    priority: Optional[int] = None
    notify_call: Optional[bool] = None
    notify_telegram: Optional[bool] = None

class ContactResponse(BaseModel):
    id: int
    user_id: str
    name: str
    phone: str
    relation: Optional[str] = None
    telegram_chat_id: Optional[str] = None
    priority: Optional[int] = 100
    notify_call: Optional[bool] = True
    notify_telegram: Optional[bool] = True


def _get_detector(profile_name):
    try:
        profile = get_profile(profile_name)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error))
    if profile.name not in detectors:
        raise HTTPException(
            status_code=503,
            detail=(
                "Model profile '{}' is not loaded on this backend. Build it with "
                "`python prepare_demo_dataset.py` then "
                "`python train_yamnet.py --profile {}`.".format(profile.name, profile.name)
            ),
        )
    return detectors[profile.name], profile


@app.get("/profiles")
def list_profiles():
    """Which classifier heads this backend can serve, and which are loaded."""
    profiles = available_profiles()
    for entry in profiles:
        entry["loaded"] = entry["name"] in detectors
    return {"active_default": REAL_PROFILE_NAME, "profiles": profiles}


@app.post("/detect")
async def detect_audio(
    file: UploadFile = File(...),
    duration: float = Form(..., description="Duration of the audio clip in seconds"),
    media_playback: bool = Form(False, description="Whether media is playing on device"),
    sudden_motion: bool = Form(False, description="Whether sudden motion is active"),
    primary_candidate: Optional[str] = Form(None, description="Candidate retained from pass 1"),
    primary_confidence: Optional[float] = Form(None, description="Confidence retained from pass 1"),
    sensitivity_threshold: float = Form(0.50, description="Pass 1 candidate threshold"),
    user_id: str = Form("anonymous", description="Monitoring session identifier"),
    context_source: str = Form("browser_manual", description="Origin of playback context"),
    profile: str = Form(REAL_PROFILE_NAME, description="Classifier head: real or demo"),
):
    """
    Performs real-time two-pass detection and risk scoring on an uploaded audio clip.
    If duration is ~2.0s, performs Pass 1 (Primary).
    If duration is ~5.0s, performs Pass 2 (Verification).

    ``profile`` selects the classifier head. The demo head adds a
    ``firecracker`` class that is aliased to ``gunshot`` for risk scoring and
    escalation; responses always carry both ``candidate`` (the resolved class
    the rest of the system acts on) and ``raw_candidate`` (what the head
    actually predicted), so a demo detection is never mistaken for a real one.
    """
    active_detector, active_profile = _get_detector(profile)

    if not 0.30 <= sensitivity_threshold <= 0.70:
        raise HTTPException(status_code=422, detail="Sensitivity threshold must be between 0.30 and 0.70.")
    if primary_candidate is not None and primary_candidate not in active_profile.class_mapping:
        raise HTTPException(
            status_code=422,
            detail="Pass 2 candidate must be a class of the '{}' profile.".format(active_profile.name),
        )
    if primary_candidate is not None and primary_candidate != "normal" and \
            active_profile.resolve_class(primary_candidate) not in RISK_CONFIG["hazard_classes"]:
        raise HTTPException(status_code=422, detail="Pass 2 candidate must be a supported hazard class.")
    if primary_confidence is not None and not 0.0 <= primary_confidence <= 1.0:
        raise HTTPException(status_code=422, detail="Pass 1 confidence must be between 0 and 1.")
    if context_source not in {"browser_manual", "platform_signal"}:
        raise HTTPException(status_code=422, detail="Invalid context source.")

    temp_path = None
    try:
        # Read uploaded file bytes
        file_bytes = await file.read()

        # Save temp file to read with soundfile
        os.makedirs("temp", exist_ok=True)
        # uuid4, not time.time(): concurrent requests can land in the same
        # fractional second and silently clobber each other's temp file.
        temp_path = "temp/{}_chunk.wav".format(uuid.uuid4().hex)
        with open(temp_path, "wb") as f:
            f.write(file_bytes)

        import soundfile as sf
        audio_data, sr = sf.read(temp_path)
    except Exception as e:
        raise HTTPException(status_code=400, detail="Failed to process uploaded audio: {}".format(e))
    finally:
        # Prevent temporary file leaks by ensuring cleanup on failure
        if temp_path and os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except Exception:
                pass

    profile_meta = {
        "profile": active_profile.name,
        "profile_banner": active_profile.banner,
    }

    try:
        if duration <= 3.0:
            # Run Pass 1
            has_candidate, candidate, confidence, acoustic_media_score = active_detector.run_pass_1(
                audio_data, sr, sensitivity_threshold
            )
            resolved = active_detector.resolve_class(candidate)
            effective_media_playback, effective_context_source = _resolve_media_context(
                media_playback, context_source, acoustic_media_score
            )

            # Immediate verification for genuinely single-shot, urgent events only
            # (gunshot, explosion). glass_breaking was removed from this list (see
            # docs/DECISIONS_LOG.md #10): it is not in URGENT_HAZARDS and does not
            # skip the cancel window or emergency handoff, so it should not skip a
            # real second listen either -- reusing one 2-second confidence value as
            # both "primary" and "verification" let a single ambiguous transient
            # (a click, a clatter) read as independently double-confirmed when it
            # was only ever heard once.
            if has_candidate and resolved in ["gunshot", "explosion"]:
                risk_score, risk_level = scorer.calculate_risk(
                    primary_conf=confidence,
                    verification_conf=confidence,
                    media_playback=effective_media_playback,
                    sudden_motion=sudden_motion,
                    current_class=resolved,
                    context_id=user_id
                )
                repeats = scorer.get_repeated_impulse_count(user_id)
                decision = decide_action(
                    verified=True, class_name=resolved, risk_score=risk_score,
                    media_playback=effective_media_playback, sudden_motion=sudden_motion,
                    repeat_count=repeats, context_source=effective_context_source,
                )
                return {
                    "pass": 1,
                    "has_candidate": True,
                    "candidate": resolved,
                    "raw_candidate": candidate,
                    "alias_applied": resolved != candidate,
                    "confidence": confidence,
                    "immediate_verification": True,
                    "verified": True,
                    "primary_confidence": confidence,
                    "verification_confidence": confidence,
                    "risk_score": risk_score,
                    "risk_level": risk_level,
                    "should_alert": decision.should_notify,
                    "media_suppressed": decision.state == "LIKELY_PLAYBACK_REVIEW",
                    "acoustic_media_score": acoustic_media_score,
                    "acoustic_media_detected": effective_context_source == "acoustic_signal",
                    "decision": decision.to_dict(),
                    **profile_meta,
                }

            return {
                "pass": 1,
                "has_candidate": has_candidate,
                "candidate": resolved,
                "raw_candidate": candidate,
                "alias_applied": resolved != candidate,
                "confidence": confidence,
                "immediate_verification": False,
                "acoustic_media_score": acoustic_media_score,
                **profile_meta,
            }
        else:
            # Run Pass 2 (Requires candidate parameter to be verified).
            # Pass 1 always looks at a real 2-second window; slicing a fixed 2/5 fraction
            # silently shrank the window for clips that were not exactly 5s long.
            # A live second pass must verify the candidate produced by the preceding
            # two-second recording, not silently re-classify unrelated audio.
            if primary_candidate is not None and primary_confidence is not None:
                has_candidate = primary_candidate != "normal"
                candidate = primary_candidate
                p1_conf = primary_confidence
                p1_acoustic_media_score = 0.0
            else:
                pass_1_samples = min(len(audio_data), int(2.0 * sr))
                has_candidate, candidate, p1_conf, p1_acoustic_media_score = active_detector.run_pass_1(
                    audio_data[:pass_1_samples], sr, sensitivity_threshold
                )

            if not has_candidate:
                effective_media_playback, effective_context_source = _resolve_media_context(
                    media_playback, context_source, p1_acoustic_media_score
                )
                return {
                    "pass": 2,
                    "verified": False,
                    "candidate": "normal",
                    "raw_candidate": "normal",
                    "alias_applied": False,
                    "confidence": p1_conf,
                    "primary_confidence": p1_conf,
                    "verification_confidence": 0.0,
                    "risk_score": 0,
                    "risk_level": "NORMAL",
                    "acoustic_media_score": p1_acoustic_media_score,
                    "acoustic_media_detected": effective_context_source == "acoustic_signal",
                    "decision": decide_action(
                        verified=False, class_name="normal", risk_score=0,
                        media_playback=effective_media_playback, sudden_motion=sudden_motion,
                        repeat_count=0, context_source=effective_context_source,
                    ).to_dict(),
                    **profile_meta,
                }

            verified, p2_conf, p2_acoustic_media_score = active_detector.run_pass_2(
                audio_data, sr, candidate
            )
            resolved = active_detector.resolve_class(candidate)
            acoustic_media_score = max(p1_acoustic_media_score, p2_acoustic_media_score)
            effective_media_playback, effective_context_source = _resolve_media_context(
                media_playback, context_source, acoustic_media_score
            )

            # Calculate Risk Score
            risk_score, risk_level = scorer.calculate_risk(
                primary_conf=p1_conf,
                verification_conf=p2_conf if verified else 0.0,
                media_playback=effective_media_playback,
                sudden_motion=sudden_motion,
                current_class=resolved if verified else "normal",
                context_id=user_id
            )

            repeats = scorer.get_repeated_impulse_count(user_id)
            decision = decide_action(
                verified=verified, class_name=resolved, risk_score=risk_score,
                media_playback=effective_media_playback, sudden_motion=sudden_motion,
                repeat_count=repeats, context_source=effective_context_source,
            )
            return {
                "pass": 2,
                "verified": verified,
                "candidate": resolved,
                "raw_candidate": candidate,
                "alias_applied": resolved != candidate,
                "primary_confidence": p1_conf,
                "verification_confidence": p2_conf,
                "risk_score": risk_score,
                "risk_level": risk_level,
                "should_alert": decision.should_notify,
                "media_suppressed": decision.state == "LIKELY_PLAYBACK_REVIEW",
                "acoustic_media_score": acoustic_media_score,
                "acoustic_media_detected": effective_context_source == "acoustic_signal",
                "decision": decision.to_dict(),
                **profile_meta,
            }

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail="Inference error: {}".format(e))


@app.post("/events", response_model=EventResponse)
def log_event(event: EventCreate):
    with get_db() as conn:
        cursor = conn.cursor()
        timestamp = time.time()
        cursor.execute(
            "INSERT INTO events (user_id, timestamp, class_name, primary_conf, verification_conf, risk_score, risk_level) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (event.user_id, timestamp, event.class_name, event.primary_conf, event.verification_conf, event.risk_score, event.risk_level)
        )
        event_id = cursor.lastrowid
        conn.commit()

    return {
        "id": event_id,
        "user_id": event.user_id,
        "timestamp": timestamp,
        "class_name": event.class_name,
        "primary_conf": event.primary_conf,
        "verification_conf": event.verification_conf,
        "risk_score": event.risk_score,
        "risk_level": event.risk_level
    }

@app.get("/events/{user_id}", response_model=List[EventResponse])
def get_event_history(user_id: str):
    with get_db() as conn:
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM events WHERE user_id = ? ORDER BY timestamp DESC", (user_id,))
        rows = cursor.fetchall()

    return [dict(row) for row in rows]

@app.get("/readiness")
def get_readiness():
    """Report whether locally available data supports a real-world deployment claim."""
    return assess_dataset_readiness(DATA_PATH)

@app.delete("/events/{user_id}")
def clear_event_history(user_id: str):
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM events WHERE user_id = ?", (user_id,))
        conn.commit()
    return {"status": "success"}

@app.post("/contacts", response_model=ContactResponse)
def add_contact(contact: ContactCreate):
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "INSERT INTO contacts (user_id, name, phone, relation, telegram_chat_id, "
            "priority, notify_call, notify_telegram) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                contact.user_id, contact.name, contact.phone, contact.relation,
                contact.telegram_chat_id,
                100 if contact.priority is None else contact.priority,
                1 if contact.notify_call is None else int(contact.notify_call),
                1 if contact.notify_telegram is None else int(contact.notify_telegram),
            )
        )
        contact_id = cursor.lastrowid
        conn.commit()

    return {
        "id": contact_id,
        "user_id": contact.user_id,
        "name": contact.name,
        "phone": contact.phone,
        "relation": contact.relation,
        "telegram_chat_id": contact.telegram_chat_id,
        "priority": 100 if contact.priority is None else contact.priority,
        "notify_call": True if contact.notify_call is None else contact.notify_call,
        "notify_telegram": True if contact.notify_telegram is None else contact.notify_telegram,
    }

@app.get("/contacts/{user_id}", response_model=List[ContactResponse])
def get_contacts(user_id: str):
    with get_db() as conn:
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute(
            "SELECT * FROM contacts WHERE user_id = ? ORDER BY COALESCE(priority, 100), id",
            (user_id,),
        )
        rows = cursor.fetchall()

    contacts = []
    for row in rows:
        item = dict(row)
        item["notify_call"] = bool(item.get("notify_call", 1))
        item["notify_telegram"] = bool(item.get("notify_telegram", 1))
        contacts.append(item)
    return contacts

@app.patch("/contacts/{contact_id}", response_model=ContactResponse)
def update_contact(contact_id: int, update: ContactUpdate, user_id: str = Query(...)):
    """Edits escalation routing on an existing contact (Telegram chat id,
    priority, per-channel opt-outs) without forcing a delete-and-re-add."""
    fields = {}
    for key, value in update.model_dump(exclude_unset=True).items():
        if value is None:
            continue
        fields[key] = int(value) if key in {"notify_call", "notify_telegram"} else value
    if not fields:
        raise HTTPException(status_code=422, detail="No fields to update.")

    assignments = ", ".join("{} = ?".format(key) for key in fields)
    params = list(fields.values()) + [contact_id, user_id]
    with get_db() as conn:
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE contacts SET {} WHERE id = ? AND user_id = ?".format(assignments), params
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Contact not found.")
        conn.commit()
        cursor.execute("SELECT * FROM contacts WHERE id = ?", (contact_id,))
        row = dict(cursor.fetchone())

    row["notify_call"] = bool(row.get("notify_call", 1))
    row["notify_telegram"] = bool(row.get("notify_telegram", 1))
    return row

@app.delete("/contacts/{contact_id}")
def delete_contact(contact_id: int, user_id: str = Query(...)):
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM contacts WHERE id = ? AND user_id = ?", (contact_id, user_id))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Contact not found.")
        conn.commit()

    return {"status": "success", "message": "Contact {} deleted".format(contact_id)}

def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calculates great-circle distance between two coordinates in kilometers."""
    r = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return round(r * c, 2)


@app.get("/api/location/detect")
def detect_user_location():
    """Detects client location via dynamic public IP geolocation without hardcoding coordinates."""
    # Provider 1: ip-api.com
    try:
        r = requests.get("http://ip-api.com/json/", timeout=4)
        if r.status_code == 200:
            d = r.json()
            if d.get("status") == "success" and d.get("lat") and d.get("lon"):
                lat = float(d["lat"])
                lng = float(d["lon"])
                city = d.get("city", "")
                region = d.get("regionName", "")
                country = d.get("country", "")
                label = f"{city}, {region}" if city and region else city or country or f"{lat:.4f}, {lng:.4f}"
                return {
                    "status": "success",
                    "source": "ip_geolocation",
                    "latitude": lat,
                    "longitude": lng,
                    "city": city,
                    "region": region,
                    "country": country,
                    "label": label,
                    "google_maps_url": f"https://www.google.com/maps?q={lat},{lng}"
                }
    except Exception:
        pass

    # Provider 2: freeipapi.com
    try:
        r = requests.get("https://freeipapi.com/api/json", timeout=4)
        if r.status_code == 200:
            d = r.json()
            if d.get("latitude") and d.get("longitude"):
                lat = float(d["latitude"])
                lng = float(d["longitude"])
                city = d.get("cityName", "")
                region = d.get("regionName", "")
                country = d.get("countryName", "")
                label = f"{city}, {region}" if city and region else city or country or f"{lat:.4f}, {lng:.4f}"
                return {
                    "status": "success",
                    "source": "ip_geolocation_p2",
                    "latitude": lat,
                    "longitude": lng,
                    "city": city,
                    "region": region,
                    "country": country,
                    "label": label,
                    "google_maps_url": f"https://www.google.com/maps?q={lat},{lng}"
                }
    except Exception:
        pass

    return {
        "status": "gps_or_calib_needed",
        "message": "Browser GPS or manual calibration required for live location."
    }


@app.get("/api/location/reverse")
def reverse_geocode_endpoint(
    lat: float = Query(..., description="Latitude"),
    lng: float = Query(..., description="Longitude")
):
    """Reverse geocodes coordinates into a human-friendly street/city address."""
    label = reverse_geocode(lat, lng)
    return {
        "status": "success" if label else "coordinates_only",
        "label": label or f"{lat:.4f}, {lng:.4f}",
        "latitude": lat,
        "longitude": lng,
        "google_maps_url": f"https://www.google.com/maps?q={lat},{lng}"
    }


@app.get("/api/location/search")
def search_location(query: str = Query(..., description="Address, landmark, or lat,lng coordinates")):
    """Searches and geocodes any query or coordinates into exact lat, lng, and formatted address."""
    clean_q = query.strip()
    # Check if query is raw lat, lng coordinates e.g. "17.510485, 78.470566"
    parts = [p.strip() for p in clean_q.split(",") if p.strip()]
    if len(parts) == 2:
        try:
            clat = float(parts[0])
            clng = float(parts[1])
            if -90 <= clat <= 90 and -180 <= clng <= 180:
                rev_label = reverse_geocode(clat, clng)
                return {
                    "status": "success",
                    "latitude": clat,
                    "longitude": clng,
                    "display_name": rev_label or f"Coordinates ({clat:.6f}, {clng:.6f})",
                    "google_maps_url": f"https://www.google.com/maps?q={clat},{clng}"
                }
        except ValueError:
            pass

    # Search via Nominatim forward geocoding
    headers = {"User-Agent": "EchoSafetyApp/2.0 (location search)"}
    url = f"https://nominatim.openstreetmap.org/search?q={urllib.parse.quote(clean_q)}&format=json&limit=1"
    try:
        r = requests.get(url, headers=headers, timeout=6)
        if r.status_code == 200:
            data = r.json()
            if data:
                res = data[0]
                plat = float(res["lat"])
                plon = float(res["lon"])
                return {
                    "status": "success",
                    "latitude": plat,
                    "longitude": plon,
                    "display_name": res.get("display_name", clean_q),
                    "google_maps_url": f"https://www.google.com/maps?q={plat},{plon}"
                }
    except Exception as e:
        logger.warning(f"Nominatim geocode failed: {e}")

    raise HTTPException(status_code=404, detail=f"Could not locate '{query}'. Try entering another nearby landmark or coordinates.")


MILITARY_EXCLUSIONS = {
    "army", "military", "armory", "armoury", "cantonment", "barracks",
    "ordnance", "defence", "defense", "drdo", "air force", "navy",
    "regiment", "battalion", "corps", "arsenal", "firing range", "ammunition"
}

def is_military_facility(name: str, address: str) -> bool:
    full_text = f"{name} {address}".lower()
    return any(term in full_text for term in MILITARY_EXCLUSIONS)


def fetch_category_places(lat: float, lng: float, query_kw: str, cat_name: str, icon: str, urgency: str, fallback_kw: Optional[str] = None, limit: int = 6):
    headers = {"User-Agent": "EchoSafetyApp/2.0 (emergency services lookup)"}
    places = []
    
    keywords_to_try = [query_kw, fallback_kw] if fallback_kw else [query_kw]

    for kw in keywords_to_try:
        if not kw:
            continue
        # Bounded dynamic search near the live coordinates
        for box_deg in [0.08, 0.16]:
            url = (
                f"https://nominatim.openstreetmap.org/search?"
                f"q={urllib.parse.quote(kw)}&format=json&"
                f"viewbox={lng - box_deg},{lat + box_deg},{lng + box_deg},{lat - box_deg}&bounded=1&limit={limit}"
            )
            try:
                r = requests.get(url, headers=headers, timeout=5)
                if r.status_code == 200:
                    for item in r.json():
                        raw_name = item.get("name") or (item.get("display_name", "").split(",")[0] if item.get("display_name") else "")
                        if not raw_name:
                            continue
                        try:
                            plat = float(item["lat"])
                            plon = float(item["lon"])
                        except (KeyError, ValueError, TypeError):
                            continue
                        display_parts = [p.strip() for p in item.get("display_name", "").split(",") if p.strip()]
                        addr = ", ".join(display_parts[1:4]) if len(display_parts) > 1 else f"Near {plat:.4f}, {plon:.4f}"
                        
                        # Exclude military bases, army armories, and defense establishments
                        if is_military_facility(raw_name, addr):
                            continue

                        dist = haversine_distance(lat, lng, plat, plon)
                        query_enc = urllib.parse.quote_plus(f"{raw_name} {addr}")
                        places.append({
                            "name": raw_name,
                            "latitude": plat,
                            "longitude": plon,
                            "address": addr,
                            "distance_km": dist,
                            "category": cat_name,
                            "icon": icon,
                            "urgency": urgency,
                            "maps_url": f"https://www.google.com/maps/search/?api=1&query={query_enc}",
                            "directions_url": f"https://www.google.com/maps/dir/?api=1&origin={lat},{lng}&destination={plat},{plon}"
                        })
                    if places:
                        break
            except Exception:
                pass
        if places:
            break

    # 2. Overpass fallback if Nominatim found nothing
    if not places:
        osm_tag = "amenity=police" if "police" in query_kw else ("amenity=fire_station" if "fire" in query_kw else "amenity=hospital")
        overpass_query = f"[out:json][timeout:5]; (nwr[{osm_tag}](around:9000, {lat}, {lng});); out center 6;"
        for srv in ["https://overpass-api.de/api/interpreter", "https://lz4.overpass-api.de/api/interpreter"]:
            try:
                resp = requests.post(srv, data={"data": overpass_query}, headers=headers, timeout=5)
                if resp.status_code == 200:
                    for el in resp.json().get("elements", []):
                        tags = el.get("tags", {})
                        name = tags.get("name")
                        if not name:
                            continue
                        c = el.get("center") or {}
                        plat = el.get("lat") or c.get("lat")
                        plon = el.get("lon") or c.get("lon")
                        if plat is None or plon is None:
                            continue
                        addr_parts = [tags.get("addr:street"), tags.get("addr:suburb"), tags.get("addr:city")]
                        addr_str = ", ".join([p for p in addr_parts if p]) or f"Near {plat:.4f}, {plon:.4f}"
                        
                        if is_military_facility(name, addr_str):
                            continue

                        dist = haversine_distance(lat, lng, float(plat), float(plon))
                        query_enc = urllib.parse.quote_plus(f"{name} {addr_str}")
                        places.append({
                            "name": name,
                            "latitude": float(plat),
                            "longitude": float(plon),
                            "address": addr_str,
                            "distance_km": dist,
                            "category": cat_name,
                            "icon": icon,
                            "urgency": urgency,
                            "maps_url": f"https://www.google.com/maps/search/?api=1&query={query_enc}",
                            "directions_url": f"https://www.google.com/maps/dir/?api=1&origin={lat},{lng}&destination={plat},{plon}"
                        })
                    if places:
                        break
            except Exception:
                continue

    # 3. For mental helpline, if no physical clinic was tagged within 10km, provide 24/7 crisis helpline
    if not places and "mental" in query_kw.lower():
        places.append({
            "name": "Tele-MANAS 24/7 Mental Health Helpline",
            "latitude": lat,
            "longitude": lng,
            "address": "National Tele-Mental Health Programme (Toll-free 14416 / 1800-891-4416)",
            "distance_km": 0.0,
            "category": "Mental Helpline",
            "icon": "🧠",
            "urgency": "24/7 Crisis & Psychological Support",
            "maps_url": f"https://www.google.com/maps/search/mental+health+clinic/@{lat},{lng},13z",
            "directions_url": f"https://www.google.com/maps/search/mental+health+hospital/@{lat},{lng},13z"
        })

    # Deduplicate within category
    seen = set()
    deduped = []
    for p in places:
        key = (p["name"].lower().strip(), round(p["latitude"], 3), round(p["longitude"], 3))
        if key not in seen:
            seen.add(key)
            deduped.append(p)
    deduped.sort(key=lambda x: x["distance_km"])
    return deduped


@app.get("/nearby")
def get_nearby_places(
    lat: float = Query(..., description="Latitude"),
    lng: float = Query(..., description="Longitude"),
    threat: Optional[str] = Query(None, description="Hazard sound type: gunshot, fire_alarm, explosion, glass_breaking, scream, shouting, siren"),
    place_type: Optional[str] = Query(None, alias="type", description="Legacy service type: hospital, police, fire"),
    limit: int = Query(4, description="Max total facilities to return (typically 3-4)")
):
    THREAT_CONFIGS = {
        "gunshot": [
            {"kw": "police station", "name": "Police Station", "icon": "🚔", "urgency": "Emergency Police Dispatch"},
            {"kw": "hospital", "name": "Hospital", "icon": "🏥", "urgency": "Emergency Trauma & Medical Care"},
            {"kw": "ambulance", "fallback_kw": "emergency room", "name": "Ambulance / Emergency Place", "icon": "🚑", "urgency": "Emergency Medical Transport"}
        ],
        "fire_alarm": [
            {"kw": "fire station", "name": "Fire Station", "icon": "🚒", "urgency": "Fire & Rescue Operations"},
            {"kw": "hospital", "name": "Hospital", "icon": "🏥", "urgency": "Burn Care & Medical Treatment"},
            {"kw": "ambulance", "fallback_kw": "emergency room", "name": "Ambulance / Emergency Place", "icon": "🚑", "urgency": "Emergency Medical Response"}
        ],
        "explosion": [
            {"kw": "fire station", "name": "Fire Station", "icon": "🚒", "urgency": "Fire & Blast Response"},
            {"kw": "hospital", "name": "Hospital", "icon": "🏥", "urgency": "Critical Medical Care"},
            {"kw": "police station", "name": "Police Station", "icon": "🚔", "urgency": "Police Evacuation & Safety"},
            {"kw": "ambulance", "fallback_kw": "emergency room", "name": "Ambulance / Emergency Place", "icon": "🚑", "urgency": "Emergency Medical Transport"}
        ],
        "glass_breaking": [
            {"kw": "police station", "name": "Police Station", "icon": "🚔", "urgency": "Local Police Station"},
            {"kw": "hospital", "name": "Hospital", "icon": "🏥", "urgency": "First Aid & Medical Care"},
            {"kw": "ambulance", "fallback_kw": "emergency room", "name": "Ambulance / Emergency Place", "icon": "🚑", "urgency": "Emergency Medical Response"}
        ],
        "scream": [
            {"kw": "police station", "name": "Police Station", "icon": "🚔", "urgency": "Emergency Police Response"},
            {"kw": "hospital", "name": "Hospital", "icon": "🏥", "urgency": "Immediate Medical Support"},
            {"kw": "mental health", "fallback_kw": "psychiatric hospital", "name": "Mental Helpline", "icon": "🧠", "urgency": "24/7 Crisis & Mental Helpline"}
        ],
        "shouting": [
            {"kw": "police station", "name": "Police Station", "icon": "🚔", "urgency": "Police Patrol & Intervention"},
            {"kw": "hospital", "name": "Hospital", "icon": "🏥", "urgency": "Medical Support"},
            {"kw": "mental health", "fallback_kw": "psychiatric hospital", "name": "Mental Helpline", "icon": "🧠", "urgency": "24/7 Crisis & Mental Helpline"}
        ],
        "siren": [
            {"kw": "police station", "name": "Police Station", "icon": "🚔", "urgency": "Police Station"},
            {"kw": "hospital", "name": "Hospital", "icon": "🏥", "urgency": "Hospital"},
            {"kw": "fire station", "name": "Fire Station", "icon": "🚒", "urgency": "Fire Station"},
            {"kw": "ambulance", "fallback_kw": "emergency room", "name": "Ambulance / Emergency Place", "icon": "🚑", "urgency": "Ambulance"}
        ]
    }

    # Determine required categories
    categories = None
    if threat and threat in THREAT_CONFIGS:
        categories = THREAT_CONFIGS[threat]
    elif place_type:
        legacy_map = {
            "hospital": [{"kw": "hospital", "name": "Hospital", "icon": "🏥", "urgency": "Emergency Medical"}],
            "police": [{"kw": "police station", "name": "Police Station", "icon": "🚔", "urgency": "Law Enforcement"}],
            "fire": [{"kw": "fire station", "name": "Fire Station", "icon": "🚒", "urgency": "Fire & Rescue"}]
        }
        categories = legacy_map.get(place_type, THREAT_CONFIGS["gunshot"])
    else:
        categories = THREAT_CONFIGS["gunshot"]

    # Gather candidate facilities per required category
    category_pools = {}
    for cat in categories:
        items = fetch_category_places(lat, lng, cat["kw"], cat["name"], cat["icon"], cat["urgency"], cat.get("fallback_kw"))
        category_pools[cat["name"]] = items


    # Select top 3-4 facilities ensuring at least 1 closest from each category
    selected = []
    seen_ids = set()

    # Step 1: Guarantee the #1 closest facility from each needed category
    for cat in categories:
        pool = category_pools.get(cat["name"], [])
        if pool:
            closest = pool[0]
            cid = (closest["name"].lower(), round(closest["latitude"], 3), round(closest["longitude"], 3))
            if cid not in seen_ids:
                seen_ids.add(cid)
                selected.append(closest)

    # Step 2: Pool all remaining candidates and sort strictly by distance
    remaining = []
    for cat in categories:
        for item in category_pools.get(cat["name"], []):
            cid = (item["name"].lower(), round(item["latitude"], 3), round(item["longitude"], 3))
            if cid not in seen_ids:
                remaining.append(item)
    remaining.sort(key=lambda x: x["distance_km"])

    # Step 3: Fill up to limit (3-4 facilities)
    for item in remaining:
        if len(selected) >= limit:
            break
        cid = (item["name"].lower(), round(item["latitude"], 3), round(item["longitude"], 3))
        if cid not in seen_ids:
            seen_ids.add(cid)
            selected.append(item)

    # Step 4: Final sort strictly by distance (closest first!)
    selected.sort(key=lambda x: x["distance_km"])

    # Build primary Google search URL for this threat
    search_terms = " + ".join([c["kw"] for c in categories])
    google_search_url = f"https://www.google.com/maps/search/{urllib.parse.quote_plus(search_terms)}/@{lat},{lng},14z"

    if selected:
        return {
            "status": "success",
            "threat": threat or "general",
            "results": selected,
            "count": len(selected),
            "google_search_url": google_search_url
        }

    # If completely remote/no POI returned, provide targeted Google Maps direct links
    fallback_results = []
    for cat in categories:
        q_enc = urllib.parse.quote_plus(f"{cat['kw']} near me")
        fallback_results.append({
            "name": f"Find Nearest {cat['name']} on Google Maps",
            "latitude": lat,
            "longitude": lng,
            "address": f"Live search pinned to your exact coordinates ({lat:.5f}, {lng:.5f})",
            "distance_km": 0.1,
            "category": cat["name"],
            "icon": cat["icon"],
            "urgency": cat["urgency"],
            "maps_url": f"https://www.google.com/maps/search/{q_enc}/@{lat},{lng},14z",
            "directions_url": f"https://www.google.com/maps/search/{q_enc}/@{lat},{lng},14z"
        })

    return {
        "status": "google_search_fallback",
        "threat": threat or "general",
        "results": fallback_results,
        "count": len(fallback_results),
        "google_search_url": google_search_url
    }


@app.post("/demo/nearby-corroboration")
def get_demo_corroboration(lat: float, lng: float, class_name: str):
    return {
        "simulated": True,
        "active_danger_zone": True if class_name in ["gunshot", "explosion"] else False,
        "corroborated_reports_count": 3,
        "time_window_minutes": 5,
        "alert_corroborated": True
    }

# Mount Data static directory
data_dir_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "model", "data"))
os.makedirs(data_dir_path, exist_ok=True)
app.mount("/data", StaticFiles(directory=data_dir_path), name="data")

# Mount Web Emulator static assets. This is a catch-all mount and must stay
# last: anything registered after it becomes unreachable.
os.makedirs("static", exist_ok=True)
app.mount("/", StaticFiles(directory="static", html=True), name="static")
