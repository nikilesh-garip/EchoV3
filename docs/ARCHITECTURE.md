# ECHO — Architecture (Master Context Pack, Part 2 of 5)

> Paste alongside PROJECT_BRIEF.md. This file is the technical contract between team members
> and between AI tools. If you (or an AI tool) want to change something here, that change goes
> through DECISIONS_LOG.md first, then this file gets updated, then everyone is told.

## Repo Structure (everyone builds inside this — no personal variants)

```
/echo                        <- repo root
  CLAUDE.md                  <- clone-and-run guide (auto-read by Claude Code)
  MODELS.md                  <- every model in the project, and what each is for
  LOCAL_SETUP.md             <- Windows setup walkthrough + honest caveats
  run_local.ps1              <- venv + deps + dataset + train (-Setup), then start the backend
  requirements.txt
  /docs
    PROJECT_BRIEF.md
    ARCHITECTURE.md          <- this file
    DECISIONS_LOG.md
    TIER_TABLE.md
    CODING_CONVENTIONS.md
    TEAM_ROLES.md
    YAMNET_MODEL.md          <- the current model, in detail (replaced the old TRANSFORMER_MODEL.md)
    SAFETY_IMPLEMENTATION_PLAN.md
  /model                     <- gitignored: data/, checkpoints/, esc50_temp.zip
    /data
      /processed             <- metadata.csv (provenance manifest) + per-class wav folders
      /synthetic             <- procedurally generated fallback clips
      /raw                   <- optional real datasets you drop in (UrbanSound8K, firecrackers)
    audio_classes.py         <- the 8-class taxonomy + demo taxonomy + YAMNet handle (single source of truth)
    yamnet_features.py       <- YAMNet load + mean/max-pool embedding + media-context score
    train_yamnet.py          <- trains the small classifier head (real or --profile demo)
    two_pass_detector.py     <- pass 1 / pass 2 inference over a profile
    model_profiles.py        <- the "real" and "demo" profile registry
    prepare_dataset.py       <- ingest ESC-50/UrbanSound8K + augment + write metadata.csv
    prepare_demo_dataset.py  <- production manifest + a firecracker class
    generate_synthetic_data.py
    risk_scorer.py           <- the weighted-sum risk engine (config dict + one function)
    safety_policy.py         <- rule-based decision states (never auto-dials services)
    data_manifest.py / model_readiness.py / evaluation_gates.py  <- provenance + release gates
    evaluate.py              <- confusion matrix, precision/recall/F1, FPR/FNR -> reports/
    export_tflite.py / export_openvino.py / benchmark_openvino.py
    test_*.py                <- pytest suite (no train.py/model.py/dataset.py anymore — see #8)
  /app                       <- Flutter app (ships lib/ + pubspec.yaml only; setup_app.ps1 generates android/ ios/)
    /lib
      main.dart
      /screens               <- login, dashboard, live_monitor, alert, history, contacts, settings, demo
      /services              <- api_service.dart, session_service.dart, motion_service.dart
      /widgets  /theme
  /backend                   <- FastAPI (run from this folder — it mounts ./static)
    main.py                  <- /detect, /events, /contacts, /nearby, Pydantic schemas, static mounts
    emergency.py             <- incident lifecycle + contact escalation
    emergency_routes.py      <- /incidents/*, /escalation/*, /telegram/chats
    notifiers.py             <- Telegram + Twilio voice (plain REST, simulation mode without creds)
    config.py  db.py  geocode.py
    .env.example             <- copy to .env to make Telegram/calls real
    /static                  <- browser dashboard (index.html, app.js, styles.css, guidance_rules.json)
    /evidence                <- gitignored: 5s incident clips, auto-purged by retention policy
    test_*.py
  /demo_assets
    demo_script.md           <- panel demo walkthrough (6 scenarios)
  /reports                   <- evaluation_report.txt, training_run_trace.md
```

## Model Architecture (YAMNet transfer learning — Tier 1, Person A's deep-dive)

**Input:** raw 16kHz mono waveform, 2-5s. See `docs/YAMNET_MODEL.md` for the full writeup and
`docs/DECISIONS_LOG.md` entry #8 for why this replaced the original from-scratch
CNN-Transformer.

**Architecture:**
```
Waveform (16kHz mono)
-> YAMNet (frozen, pretrained on ~2M AudioSet clips, TF-Hub "google/yamnet/1")
   -> per-frame 1024-d embeddings (0.96s windows, 0.48s hop) + 521-class AudioSet scores
-> mean-pool embeddings across frames, max-pool embeddings across frames, concatenate (2048-d)
-> BatchNorm -> Dense(256, L2) -> Dropout(0.3) -> Dense(8, softmax)
```
Only the final block is trained; YAMNet itself stays frozen. This trades from-scratch model
capacity for sample efficiency, which matters when real per-class audio ranges from zero to a
few hundred clips.

**Two-pass "verification" (replaces separate Model A/B):**
- Pass 1 ("Primary"): 2s window, threshold 0.5 to trigger Pass 2.
- Pass 2 ("Verification"): 5s window centered on the same event, threshold 0.7 for final
  hazard confirmation. Report both numbers on the alert screen exactly as originally specced.

**Automatic media-context signal:** each pass also reads YAMNet's own general AudioSet
predictions (Television, Music, Soundtrack music, Radio, etc.) as a weak, automatically
detected acoustic signal that a movie/TV/game is likely playing — feeding the same
`media_playback` context input as the manual toggle, at a distinct, lower-reliability tier
(`context_source="acoustic_signal"`). See `model/audio_classes.py` and
`model/safety_policy.py`. It only ever adds evidence; it never overrides an explicit `False`,
and conflicting evidence (sudden motion, a repeat hazard sequence) still forces an alert.

**Training:** TensorFlow/Keras. Class-weighted (inverse-frequency) cross-entropy — "normal"
outnumbers hazard classes roughly 15-to-1 in the current dataset.

**Export:** `export_tflite.py` builds one combined graph (YAMNet + pooling + head) and converts
it directly to a quantized `.tflite` (~3.8MB, verified to run real inference — not just "exports
without error"). `export_openvino.py` produces IR format for laptop-side latency/size
benchmarking (Person A's OpenVINO-on-Arc-iGPU story — this is the differentiator, don't skip
it). The committed OpenVINO IR under `model/checkpoints/openvino/` can lag a head retrain;
re-run `python export_openvino.py` for current numbers. Neither export is wired into the
Flutter app yet — the app calls the backend.

## Context/Risk Scorer (Tier 1, heuristic — Person C)

Weighted sum, NOT a black box. Documented formula lives in `model/risk_scorer.py` as a
config dict, e.g.:

```python
WEIGHTS = {
    "primary_confidence": 0.35,
    "verification_confidence": 0.35,
    "media_playback_active": -0.25,   # negative = reduces risk
    "sudden_motion_detected": 0.15,
    "repeated_impulse_count": 0.10,   # per repeat, capped
}
THRESHOLDS = {"NORMAL": 30, "SUSPICIOUS": 60, "POSSIBLE_DANGER": 80, "HIGH_RISK": 100}
```
Every number in this dict must be justifiable out loud in a viva. Don't let an AI tool bury
this logic inline somewhere else — it stays in one file, one function, one truth.

## Keyword Spotter (Tier 2 — simplified, cut first if behind schedule)

Small grammar-constrained recognizer (e.g., Vosk small model with a fixed phrase list) for:
"help me", "call the police", "leave me alone", "don't hurt me", "call an ambulance", "fire".
Output is a boolean-per-phrase signal fed into the risk scorer as supporting evidence only —
never a standalone trigger.

## Backend API Contract (FastAPI — Person B)

Detection
```
POST /detect                 -> two-pass inference on one uploaded clip (multipart).
                                duration<=3s runs Pass 1; >3s runs Pass 2. Form field
                                `profile=real|demo` selects the classifier head. Returns
                                candidate, raw_candidate, confidences, risk score/level,
                                the safety decision, and the acoustic media-context score.
                                The clip is read, classified, and discarded — never stored.
GET  /profiles               -> which classifier heads exist and which are loaded
GET  /readiness              -> local dataset composition + whether a real-world claim is supportable
```
Events & contacts
```
POST /events                 -> log a detection event (metadata only, never raw audio)
GET  /events/{user_id}       -> history for the HISTORY screen
DELETE /events/{user_id}     -> clear this user's detection history
POST   /contacts             -> add an emergency contact
GET    /contacts/{user_id}   -> list contacts (escalation order)
PATCH  /contacts/{id}?user_id -> edit routing (telegram chat id, priority, per-channel opt-out)
DELETE /contacts/{id}?user_id -> remove a contact
GET  /contacts-detail/{user_id} -> contacts incl. escalation columns (legacy /contacts kept unchanged)
```
Emergency escalation (see backend/emergency.py / emergency_routes.py, and DECISIONS_LOG #9/#11)
```
POST /incidents                        -> create an incident + arm the cancel countdown (multipart, 5s clip)
GET  /incidents/user/{user_id}         -> incident history with per-channel results
GET  /incidents/{id}                   -> live state (drives the cancel countdown)
POST /incidents/{id}/cancel            -> "I'm safe" — stop the escalation (user_id required)
POST /incidents/{id}/dispatch          -> "Alert them now" — skip the countdown
GET  /incidents/{id}/clip              -> the 5s evidence clip (Twilio + app)
GET  /incidents/{id}/twiml             -> TwiML the automated call speaks
GET  /escalation/status                -> which channels are configured (no secrets)
GET  /escalation/readiness/{user_id}   -> "if something happened now, who gets told"
POST /escalation/test                  -> clearly-labelled rehearsal alert to every contact (rate-limited)
GET  /telegram/chats                   -> chats that pressed Start on the bot, to bind a contact
```
Places / demo
```
GET  /nearby?lat&lng&type              -> OSM Overpass proxy (police/hospital/fire), labelled mock fallback
POST /demo/nearby-corroboration        -> Tier 3, mocked scripted nearby-device data
```
No endpoint accepts or stores raw continuous audio. Ever. A `/detect` clip is classified and
dropped; a `/incidents` 5-second evidence clip is retained only until the retention window
(`ECHO_CLIP_RETENTION_SECONDS`, default 7 days) purges it. This is a privacy hard-line, not a
style preference — see PROJECT_BRIEF.md.

## Mobile App Screens (per original spec, unchanged)

HOME, LIVE MONITOR, ALERT, HISTORY, CONTACTS, SETTINGS, DEMO MODE. See original spec sections
18/16/13 for exact layout — that part of the spec was fine, keep it as-is.

## Demo Mode Mechanics (Tier 1, critical for panel)

Prepared clips are served by the backend from the training data itself
(`/data/processed/<class>/<class>_esc50_000.wav`, falling back to
`/data/synthetic/<class>/<class>_000.wav`), not a separate `demo_assets/audio_clips`
folder. The "Demo lab" tab injects a clip directly into the real `/detect` pipeline —
same model, same risk scorer, same escalation — and only room acoustics are bypassed;
it also offers live-microphone monitoring. The classifier-head switch (production vs the
firecracker demo head) applies to both. Each pipeline stage is shown on the Monitor view.
See `demo_assets/demo_script.md` for the six panel scenarios.
