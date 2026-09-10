# ECHO — Decisions Log (Master Context Pack, Part 3 of 5)

> Append-only. Never delete an entry, even if reversed — add a new entry that supersedes it.
> Every AI-assisted session that changes an architectural/scope decision MUST result in a new
> entry here, written by the human who approved the change, same day. If it's not written down
> here, treat it as not decided — revert to what ARCHITECTURE.md/PROJECT_BRIEF.md already say.

Format per entry:
```
### #N — [short title]
Date:
Decided by:
What: (one line)
Why: (one line)
Affects: (which file(s) also needed updating)
```

---

### #1 — Session-based monitoring instead of 24/7 background
Date: Not recorded at the time (a foundational decision, predates entry #6 — mid-2026)
Decided by: team
What: Monitoring runs while app is foregrounded/active service, not persistent 24/7 OS-level.
Why: Android 13+ background mic restrictions + Doze mode make true 24/7 unreliable to build
in timeframe; output/UX unaffected (same ON/OFF toggle).
Affects: PROJECT_BRIEF.md, ARCHITECTURE.md

### #2 — Single CRNN, two-pass, instead of two separate model architectures
Date: Not recorded at the time (a foundational decision, predates entry #6 — mid-2026)
Decided by: team
What: Replaced AST/PANNs/CLAP "verification model" with the same CRNN run twice at different
window sizes/thresholds.
Why: Heavy transformer models need cloud inference, which conflicts with the no-continuous-
audio-upload privacy rule, and are impractical to train from scratch in timeframe.
Affects: ARCHITECTURE.md

### #3 — Keyword-spotter instead of full ASR
Date: Not recorded at the time (a foundational decision, predates entry #6 — mid-2026)
Decided by: team
What: Replaced Whisper/general ASR with a small grammar-constrained keyword spotter for ~6
fixed phrases.
Why: Full ASR is a separate heavy subsystem for a "supporting evidence only" signal; not
worth the engineering cost at this scope. Tier 2 — cut first if behind schedule.
Affects: ARCHITECTURE.md, PROJECT_BRIEF.md

### #4 — Nearby-device alerts fully simulated
Date: Not recorded at the time (a foundational decision, predates entry #6 — mid-2026)
Decided by: team
What: No real device-to-device networking; Demo Mode calls a mocked backend endpoint with
scripted "corroboration" data.
Why: Real implementation needs user density + background location infra not available at
prototype scale; explicitly Tier 3, disclosed in report.
Affects: ARCHITECTURE.md, TIER_TABLE.md

### #5 — Post-training quantization + OpenVINO instead of pruning/QAT
Date: Not recorded at the time (a foundational decision, predates entry #6 — mid-2026)
Decided by: team
What: Use TFLite post-training dynamic-range quantization for mobile export; OpenVINO IR
export for laptop-side (Intel Arc iGPU) latency/size benchmarking.
Why: Pruning/QAT requires specialized ML-systems expertise beyond scope/timeline; OpenVINO
benchmarking on team's actual Intel hardware is a stronger, more specific interview story
than generic TFLite-only claims.
Affects: ARCHITECTURE.md

---

<!-- Add new entries below this line as the project progresses. -->

> **Entry index (read in this order).** The bodies below are append-only and are
> **not** in numeric order — #6 and #7 were written up after #8–#11. This table is
> the chronological/numeric order:
>
> | # | Date | Title |
> |---|------|-------|
> | 1 | mid-2026 | Session-based monitoring instead of 24/7 background |
> | 2 | mid-2026 | Single model, two-pass, instead of two separate architectures |
> | 3 | mid-2026 | Keyword-spotter instead of full ASR |
> | 4 | mid-2026 | Nearby-device alerts fully simulated |
> | 5 | mid-2026 | Post-training quantization + OpenVINO instead of pruning/QAT |
> | 6 | 2026-07-24 | CNN-Transformer with spatial derivative features — **superseded by #8** |
> | 7 | 2026-07-24 | Immediate verification for transient hazard classes — **narrowed by #10** |
> | 8 | 2026-08-17 | Replaced from-scratch CNN-Transformer with a fine-tuned YAMNet head |
> | 9 | 2026-08-27 | Real-audio augmentation to close the macro-F1 gate; escalation location + rate limiting |
> | 10 | 2026-08-28 | Narrowed the transient-class fast path; gated the full alert screen by severity |
> | 11 | 2026-08-28 | Bug-hunt pass: cooldown/cancel correctness, a risk-history leak, XSS, dataset safety-net |

### #11 — Bug-hunt pass: cooldown/cancel correctness, a risk-history leak, XSS, dataset safety-net
Date: August 28, 2026
Decided by: team (AI-assisted), from a targeted review pass across backend/model/web/app.
What: A dozen-plus real, reproduced defects, not style cleanup. Grouped by where they live.

Backend (`backend/emergency.py`, `backend/emergency_routes.py`, `backend/notifiers.py`):
- `last_escalation_time()` keyed cooldown off `dispatched_at` with no `class_name` filter. Two
  consequences: (1) `/escalation/test`'s rehearsal incident (`class_name="normal"`) dispatches for
  real and was silently arming a real cooldown window afterward -- running a test alert could make
  a genuine emergency arriving within `cooldown_seconds` come back "Cooldown active" and never
  reach contacts. (2) Because only *completed* dispatches counted, two verified high-risk
  detections seconds apart (repeat gunfire, a burst of alarm sounds -- exactly the "firecracker
  night" scenario the module's own docstring names) could both pass the gate and both dispatch,
  since neither had a `dispatched_at` yet when the other checked. Fixed: now keys off `created_at`
  of any `PENDING`/`DISPATCHING`/`DISPATCHED` incident with `class_name != 'normal'` --
  cancelled/suppressed incidents don't count, so a correctly-cancelled false alarm never blocks a
  later real one.
- Unguarded DB writes after durable state changes (`purge_expired_clips()` inside
  `create_incident()`, per-contact `_record_attempt()` and the final `_set_state(...DISPATCHED)`
  inside `dispatch_incident()`) could turn a transient SQLite lock into an unhandled 500 or an
  incident permanently stuck in `DISPATCHING` with no retry path. Wrapped in try/except with
  logging; doesn't fully solve "stuck forever" in the worst case, judged proportionate to the
  actual (low) contention risk at this scale rather than building a retry subsystem.
- `_rate_log` (emergency_routes.py) and `RiskScorer.event_history` (model/risk_scorer.py, used via
  the module-level `scorer` singleton) both grow one entry per distinct `user_id` forever --
  `user_id` is unauthenticated and client-supplied, so both were an unbounded-memory vector open
  to anyone. Bounded with the same FIFO-eviction pattern `geocode.py`'s cache already used
  (`_RATE_LOG_MAX_KEYS` / `MAX_TRACKED_CONTEXTS = 2000`); `RiskScorer.prune_history` now also
  drops a context's key entirely once its history is empty instead of leaving `[]` behind.
- **`RiskScorer` never pruned stale history except as a side effect of a *new hazard* event** --
  `add_event()`/`prune_history()` only ran when `current_class` was itself hazardous, so a
  `"normal"` or unverified read (main.py passes `current_class="normal"` for those) read
  `get_repeated_impulse_count()` with no time filter applied. Reproduced: a context with a
  gunshot+scream pair from an hour earlier scored a fresh, unrelated NORMAL-level read as
  SUSPICIOUS. Fixed: `calculate_risk()` now prunes this context's history unconditionally, before
  the hazard check, every call.
- `TelegramNotifier.send_alert()` reported the coarse `status` as `"sent"` whenever the text
  message succeeded, even if the evidence clip and/or location pin explicitly failed to send --
  the sub-failure was only visible in the free-text `detail` string. `escalation_attempts.status`
  is the field callers/UIs treat as the pass/fail signal; the clip and location are what make the
  alert actionable, not the alarming text alone. Now downgrades to `"failed"` (reusing the
  existing status vocabulary, so no frontend changes needed) when either sub-send fails.
- `POST /incidents/{id}/cancel` accepted `user_id` as optional and only applied the ownership
  filter `if user_id is not None` -- simply omitting the field bypassed it entirely. Both real
  clients (web, app) already always send it; made it required server-side.

Model (`model/prepare_dataset.py`): the manifest's `source_clip_id` field was set to the
per-variant filename, not the shared origin id (`_origin_id(filename)`) already used to compute
the *split*. `data_manifest.py`'s leakage check groups rows by `(source_dataset, source_clip_id)`
and flags any group spanning more than one split -- with a unique id per row, that group size is
always 1, so the check could structurally never fire, for any data. Today's actual splits are
correct (verified empirically: 0 real leaks across 200 augmented-clip origin groups), but the
safety net meant to catch a *future* regression in `_origin_id()`'s regex was dead code. Fixed to
match `prepare_demo_dataset.py`'s already-correct pattern.

Web dashboard (`backend/static/app.js`):
- **Cancel could report success when it silently failed.** The backend's `/cancel` returns HTTP
  200 with `{"cancelled": false, "reason": "..."}` when an incident already dispatched -- the
  frontend never read either field and showed "Cancelled — nobody was called or messaged" on every
  response regardless. Extracted a shared `requestCancelIncident()` that actually checks
  `data.cancelled` and shows `data.reason` on failure.
- **Cancel / "I'm safe" could be complete no-ops.** `startEscalation()` awaits geolocation and the
  `/incidents` POST before `currentIncidentId` is set; clicking Cancel or "I'm safe" during that
  window did nothing (Cancel: silent `return`; "I'm safe": closed the modal without cancelling)
  while the incident went on to arm and dispatch invisibly behind the now-closed modal. Added an
  `escalationCancelRequested` flag: a click during that window is honored the instant the incident
  actually gets an id, by cancelling it immediately rather than showing it as armed.
- **Overlapping detections could corrupt escalation state.** A second detection landing while an
  alert modal was already open started a second, competing `startEscalation()` call, capable of
  overwriting `currentIncidentId` with the second (possibly inert) incident while the first's poll
  timer kept running orphaned -- Cancel could then cancel the wrong incident while the real one
  dispatched unattended. `triggerAlertModal()` now refuses to open a second alert while one is
  already showing.
- **Stored/reflected HTML injection** via `innerHTML`: a contact's `name`/`relation`/`phone` (user
  input, round-tripped from the backend) were interpolated directly into `innerHTML` in
  `loadContacts()`, `showToast()`, and `renderEscalationAttempts()`. Rebuilt all three with DOM
  nodes + `textContent` (the pattern `alertPlacesContainer` already used correctly for place
  names, just not applied to contact fields).
- `pollIncident()` silently gave up (`if (!res.ok) return;`) on any failed request, freezing the
  countdown ring/number at their last value forever with no error shown and no way to know whether
  the incident actually dispatched server-side in the meantime. Now stops after 5 consecutive
  failures and tells the user to check Event history instead of spinning silently.
- Smaller: `deleteContact()` didn't check `res.ok` before claiming success; the priority `<select>`
  wasn't reset after saving a contact (stuck at the last-chosen value for the next add); the
  countdown number wasn't clamped to `>= 0` the way the ring fraction already was; the toast stack
  had no cap (a burst of failures could pile toasts up off-screen forever) -- capped at 4 visible.

Flutter app:
- `demo_screen.dart` was missing a `mounted` check after `await _api.logEvent(...)` before the
  next `setState` -- the one gap in a file (and codebase) that otherwise guards every async gap
  consistently. Switching tabs mid-demo-clip threw `setState() called after dispose()`.
- `alert_screen.dart` could momentarily display "Location sent: Last known location" -- the exact
  fabricated-looking placeholder its own comment says can't happen -- during the `DISPATCHING`
  window after an incident is claimed but before the backend's reverse-geocode call has resolved
  and persisted a real address. Self-corrected within a poll cycle; now filtered out explicitly
  rather than displayed and waited-out.
- `motion_service.dart`'s `dispose()` didn't dispose its own `ValueNotifier<bool> detected`.
Affects: backend/emergency.py, backend/emergency_routes.py, backend/notifiers.py,
model/risk_scorer.py, model/prepare_dataset.py, backend/static/app.js, backend/test_emergency.py,
backend/test_notifiers.py (new), model/test_risk_scorer.py,
app/lib/screens/demo_screen.dart, app/lib/screens/alert_screen.dart,
app/lib/services/motion_service.dart.

### #10 — Narrowed the transient-class fast path; gated the full alert screen by severity
Date: August 28, 2026
Decided by: team (AI-assisted), in response to a live false positive: real laptop-mic room
audio was misclassified as glass_breaking at 80%/80% confidence and popped the full-screen
critical alert (risk 41, SUSPICIOUS) with "Nearby emergency facilities" and recommended actions.
What: Two related fixes, not one.
  1. Removed `glass_breaking` from `/detect`'s "immediate verification" bypass (entry #7's list
     was gunshot/explosion/glass_breaking; now just gunshot/explosion). That bypass reuses a
     single 2-second Pass 1 confidence value as *both* `primary_confidence` and
     `verification_confidence` -- correct for gunshot/explosion, which entry #7 chose this for
     because a real one-shot impulse does not persist into a second recording block, but
     glass_breaking is not in `URGENT_HAZARDS`, does not skip the cancel window or emergency
     handoff, and gets no safety benefit from skipping a genuine second listen -- it only lets
     one ambiguous transient (a click, a clatter, a real mic's own noise floor) look like two
     independent confirmations when it was heard once. glass_breaking now goes through the same
     real 5-second Pass 2 re-inference every other non-bypassed class already used. This also
     brings the code in line with demo_assets/demo_script.md's own Scenario 3 description, which
     already said "the model performs the two-pass verification" for glass breaking.
  2. The frontend (backend/static/app.js, app/lib/screens/live_monitor_screen.dart,
     app/lib/screens/demo_screen.dart) no longer shows the full alert screen for every
     `should_alert=true` response -- that fires for *any* verified reading with risk >= 31
     (safety_policy.py's REVIEW_NOW state), which includes low-confidence SUSPICIOUS reads. The
     full alert (guidance, nearby facilities, escalation countdown) is now reserved for
     POSSIBLE_DANGER/HIGH_RISK; a SUSPICIOUS-band `should_alert` is still surfaced -- a toast +
     logged history entry on the web, a SnackBar + logged entry in the app -- just not as a
     full-screen alarm. The backend's `should_notify` flag and REVIEW_NOW state are unchanged;
     this is purely how the client presents that signal. Live monitoring only -- the demo lab's
     curated clips normally land in POSSIBLE_DANGER/HIGH_RISK anyway, so this mainly changes
     behaviour for genuinely borderline model output, which is exactly when not dramatizing the
     result is the honest call.
Why: A model this size, trained on ESC-50-derived audio, will sometimes misfire on real-mic
ambient sound it has never heard the like of -- that is an honest, expected limitation (see
`reports/evaluation_report.txt`), not something a threshold tweak alone fixes. What IS fixable
today: don't let a single un-reconfirmed guess trigger a full alarm screen for a class that was
never urgent enough to skip other safety gates in the first place.
Affects: backend/main.py, backend/static/app.js, app/lib/screens/live_monitor_screen.dart,
app/lib/screens/demo_screen.dart, backend/test_backend.py.

### #9 — Real-audio augmentation to close the macro-F1 gate; escalation location + rate limiting
Date: August 27, 2026
Decided by: team (AI-assisted)
What: `prepare_dataset.py` now generates label-preserving augmented variants (pitch shift, time
stretch, additive noise, gain jitter, one early reflection) of every real ESC-50 recording for
explosion/glass_breaking/fire_alarm/siren/shouting, source-disjointly split so an augmented clip
always lands in the same split as its source recording -- never both train and test. Macro F1
went 0.85 -> 0.9508 (clears the 0.95 gate for the first time); `synthetic_generated` gunshot/
scream sample counts and generator realism were also increased, but those two classes remain
100% synthetic (no augmentation possible with zero real source clips). Fixed a real bug: three
scripts (`evaluate.py`, `export_tflite.py`, `export_openvino.py`) had been `ImportError`-broken
since the profile refactor (entry #8) and silently uncovered by the test suite -- both are now
fixed and covered by a live run, not just an import check. Also added: `backend/geocode.py`
(OSM Nominatim reverse geocoding for the escalation call/Telegram location line, no API key),
a per-user rate limit on `/escalation/test` (previously uncapped -- unlike `/incidents`, it
skipped `escalation_gate()`'s cooldown entirely), and a redesigned `backend/static/` dashboard
(risk-level color coding, an animated escalation countdown ring, toast notifications, a "send a
real test alert" button, and full per-contact Telegram/priority/channel-opt-out fields that were
previously Flutter-app-only). See `reports/evaluation_report.txt` for the exact remaining release
blockers -- explosion/fire_alarm/normal precision, explosion recall, and gunshot/scream's
synthetic-only status are all still honestly gated, not overridden.
Affects: model/prepare_dataset.py, model/generate_synthetic_data.py, model/evaluate.py,
model/export_tflite.py, model/export_openvino.py, backend/geocode.py (new), backend/emergency.py,
backend/notifiers.py, backend/emergency_routes.py, backend/static/, LOCAL_SETUP.md.

### #6 — CNN-Transformer with Spatial Derivative Features
Date: July 24, 2026
Decided by: team
What: Upgraded the sound classification model to a CNN-Transformer architecture and added spatial Mel-spectrogram derivatives (Sobel and Laplacian) as input features.
Why: Outperforms baseline CRNN in modeling long-term temporal dependencies in parallel, improving F1 score to 93.58% and accuracy to 96.59% while reducing noise sensitivity.
Affects: model/model.py, model/dataset.py, model/two_pass_detector.py, model/train.py, model/evaluate.py

### #7 — Immediate Verification for Transient Hazard Classes
Date: July 24, 2026
Decided by: team
What: Bypassed the 5-second Pass 2 recording delay for transient classes (gunshot, explosion, glass breaking), triggering instant emergency warnings on Pass 1.
Why: Gunshots and explosions are non-repeating impulses that do not persist into a subsequent recording block. Requiring a second recording block is unsafe for single-event threats.
Affects: backend/main.py, backend/static/app.js

### #8 — Replaced from-scratch CNN-Transformer with a fine-tuned YAMNet head
Date: August 17, 2026
Decided by: team (AI-assisted)
What: Deleted model.py (CNN-Transformer), dataset.py (log-mel + Sobel/Laplacian preprocessing),
and the from-scratch train.py. Replaced with model/train_yamnet.py: a frozen, pretrained
YAMNet backbone (TF-Hub) + a small trainable classifier head on mean+max-pooled embeddings.
Why: Real-audio coverage per class is thin (zero to ~740 clips) and a transformer trained from
zero on that little real data either overfits or fails to generalize. YAMNet was pretrained on
~2M AudioSet clips, so the head needs far fewer real examples to generalize well. This also
solves the CNN-Transformer's permanently-blocked TFLite export (ai-edge-torch has no build for
this Python version; the onnx-tf fallback is unmaintained/incompatible) since a Keras model
converts to TFLite/OpenVINO natively. Measured result on the same expanded real+labeled-
synthetic dataset: macro F1 0.82 (CNN-Transformer) -> 0.85 (YAMNet head) — a real improvement,
not release-ready either way (see reports/evaluation_report.txt, evaluation_gates.py).
Also added: an automatic "acoustic media-context" signal read from YAMNet's own general
AudioSet predictions (Television, Music, Soundtrack music, etc.), feeding the existing
media_playback/safety_policy pipeline as a new, weaker context_source tier
("acoustic_signal") alongside the pre-existing manual/platform_signal tiers — this is what
makes the "gunshot during a movie" scenario resolve automatically, not only via the manual
toggle. It never overrides an explicit signal and never silently drops a verified event.
Affects: model/ (new: audio_classes.py, yamnet_features.py, train_yamnet.py; rewritten:
two_pass_detector.py, evaluate.py, export_tflite.py, export_openvino.py, benchmark_openvino.py,
safety_policy.py; removed: model.py, dataset.py, train.py, generate_real_metadata.py,
ingest_real_datasets.py), backend/main.py, docs/ARCHITECTURE.md, docs/YAMNET_MODEL.md
(replaces docs/TRANSFORMER_MODEL.md), docs/TIER_TABLE.md, docs/PROJECT_BRIEF.md,
requirements.txt, app/lib/screens/settings_screen.dart, backend/static/index.html.

