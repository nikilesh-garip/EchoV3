# Echo — Models in this project

Plain-language answer to "what models are used, and what is each one for."
Nothing here is a black box; every model or scorer below is either a small,
inspectable file or a well-known public model.

---

## 1. The models, at a glance

| # | Name | Type | File / source | Role |
|---|------|------|---------------|------|
| 1 | **YAMNet** | Pretrained deep audio model (frozen) | `google/yamnet/1`, downloaded at runtime from TF-Hub / Kaggle Hub | Turns raw audio into a rich embedding + gives its own 521-class sound guesses |
| 2 | **Echo production head** | Small trained classifier (Keras) | `model/checkpoints/yamnet_head.keras` (~6.4 MB) | Classifies audio into the 8 hazard classes |
| 3 | **Echo demo head** | Small trained classifier (Keras) | `model/checkpoints/yamnet_head_demo.keras` (~6.4 MB) | Same 8 classes **+ `firecracker`**, for on-stage demos |
| 4 | **TFLite export** | Quantised combined graph | `model/checkpoints/echo_yamnet_model.tflite` (~3.8 MB) | Mobile / on-device inference (not yet wired into the Flutter app) |
| 5 | **OpenVINO IR export** | Combined graph in Intel IR format | `model/checkpoints/openvino/echo_yamnet_model.{xml,bin}` | Laptop-side (Intel iGPU) latency/size benchmarking only |
| 6 | **Risk scorer** | Transparent weighted-sum formula (no ML) | `model/risk_scorer.py` | Converts model confidences + context into a 0–100 risk score |
| 7 | **Safety policy** | Rule-based decision table (no ML) | `model/safety_policy.py` | Decides notify / review / urgent / log-only from the risk score |

The **only** thing that classifies sound is model #1 feeding model #2 (or #3 in
demo mode). Everything after that (#6, #7) is deliberately hand-written, auditable
logic — see `docs/ARCHITECTURE.md`.

---

## 2. YAMNet (the backbone) — model #1

- **What it is:** Google's YAMNet, pretrained on ~2 million labelled AudioSet
  clips across 521 general sound categories. Used **frozen** — never retrained.
- **Where it comes from:** loaded by `tensorflow_hub` from the handle
  `https://tfhub.dev/google/yamnet/1` (defined in `model/audio_classes.py`).
  The first run **downloads ~17 MB** into a local cache:
  - Windows: `%TEMP%\tfhub_modules\`
  - Linux/macOS: `/tmp/tfhub_modules/`
- **What Echo uses it for — two separate signals:**
  1. **Embeddings.** Per-audio-frame 1024-d vectors. Echo mean-pools **and**
     max-pools them across frames and concatenates → one **2048-d** clip
     embedding. (Max-pool matters: a gunshot or glass-break is 1–2 loud frames
     among many near-silent ones; mean-pool alone washes it out.)
  2. **Acoustic media-context.** YAMNet's own AudioSet predictions for
     "Television", "Music", "Soundtrack music", "Radio", etc.
     (`MEDIA_CONTEXT_AUDIOSET_INDICES`). If those fire, Echo treats it as *weak*
     evidence that a TV/movie/game is playing — it can lower urgency but never
     silently drops a verified event.
- **Offline note:** if the machine has never downloaded YAMNet and has no
  internet, `train_yamnet.py` and the backend will both fail at
  `load_yamnet()`. See `CLAUDE.md` → "YAMNet download".

---

## 3. Echo production head — model #2

The **only** part of the classifier that is trained in this repo.

**Architecture** (`model/train_yamnet.py`, verified from the saved checkpoint):

```
Input:  2048-d  [YAMNet mean-pool | YAMNet max-pool]
  → BatchNormalization
  → Dense(256, relu, L2=1e-3)
  → Dropout(0.3)
  → Dense(8, softmax)
```

> Note: `docs/YAMNET_MODEL.md` still says `Dense(128)` — the checkpoint that
> ships is `Dense(256)` (the CLI default). Harmless doc drift; the code and the
> saved model agree on 256.

**The 8 classes** (`model/audio_classes.py`):
`normal, gunshot, explosion, scream, glass_breaking, fire_alarm, siren, shouting`

**How it's trained:**
- YAMNet embeddings for every clip in `model/data/processed/metadata.csv`
  (cached in `yamnet_embeddings_cache.npz`, keyed by a hash of the manifest so
  retraining the head skips re-embedding).
- Class-weighted (inverse-frequency) cross-entropy — `normal` outnumbers hazard
  classes ~15:1.
- Early stopping + checkpointing on **val_accuracy** (val_loss is too spiky at
  this dataset size).

**Two-pass use at inference** (`model/two_pass_detector.py`, `backend/main.py`):
- **Pass 1** — 2-second window, threshold 0.50 to raise a candidate.
- **Pass 2** — 5-second window, threshold 0.70 to verify it.
- Exception: `gunshot` and `explosion` (single-shot impulses that don't persist
  into a second recording) can confirm on Pass 1 alone — see
  `docs/DECISIONS_LOG.md` #7 and #10.

---

## 4. Echo demo head — model #3

Identical architecture, **9 outputs** (the 8 above **+ `firecracker`**).

- Trained on Diwali firecracker audio (real recordings if you drop them into
  `model/data/raw/firecrackers/`, else ESC-50 "fireworks", else synthetic).
- At inference the demo profile **aliases `firecracker → gunshot`**, so lighting
  a cracker near the mic drives the *entire* alert path (risk score, countdown,
  automated call, Telegram clip) on a sound that is safe and legal to produce
  on stage.
- Every record it produces keeps `raw_class = "firecracker"` and
  `profile = "demo"`, and every alert/message is stamped **DEMO** — nothing ever
  claims a real gunshot was heard.
- It is a **separate file** and never shares training data with the production
  head. Reason: the production model must keep treating a firecracker as
  *not* a gunshot. See `model/model_profiles.py`.

Select it per request (`profile=demo` on `/detect` and `/incidents`), in the
web dashboard's "Demo lab" tab, or in the Flutter app's Settings → Detection
model.

---

## 5. Exports — models #4 and #5 (derived, not separately trained)

Both are built by fusing **YAMNet + pooling + the trained head** into one graph
and converting that graph directly.

| Export | Script | Output | Purpose | Status |
|--------|--------|--------|---------|--------|
| TFLite | `model/export_tflite.py` | `checkpoints/echo_yamnet_model.tflite` | On-device mobile inference | ~3.8 MB, dynamic-range quantised, `SELECT_TF_OPS`. Verified to run real inference. **Not yet called by the Flutter app** — the app talks to the backend. |
| OpenVINO IR | `model/export_openvino.py` | `checkpoints/openvino/echo_yamnet_model.{xml,bin}` | Intel iGPU latency/size benchmarking (`benchmark_openvino.py`) | Present but **stale** — the committed `.bin` predates the last head retrain. Regenerate with `python export_openvino.py` if you need current numbers. |

Both export scripts run a numerical sanity check (exported graph must match the
reference `embed_waveform() + head` path within 1e-4) before writing the file.

---

## 6. Not models — the scorer and the policy

These are frequently mistaken for ML. They are not.

- **`model/risk_scorer.py`** — a documented weighted sum:
  `primary_conf ×0.35 + verification_conf ×0.35 − media_playback ×0.25
   + sudden_motion ×0.15 + repeated_impulse_count ×0.10 (capped)`, clamped to
  0–100, then bucketed (`NORMAL / SUSPICIOUS / POSSIBLE_DANGER / HIGH_RISK`).
  Keeps a short (10 s) rolling per-user event history so a
  gunshot→scream→shouting sequence escalates.
- **`model/safety_policy.py`** — a rule table mapping (verified, class,
  risk, context) → one of `MONITORING / LIKELY_PLAYBACK_REVIEW / REVIEW_NOW /
  URGENT_USER_ACTION / LOG_ONLY`. **Never** dispatches police/fire/ambulance;
  the `tel:112` handoff is always user-initiated.

---

## 7. Models deliberately NOT used

| Rejected | Why | Reference |
|----------|-----|-----------|
| AST / PANNs / BEATs / CLAP as a 2nd verification model | Need cloud inference (conflicts with the no-audio-upload rule); impractical to train in timeframe. Two passes of one model simulate "verification" instead. | `docs/DECISIONS_LOG.md` #2 |
| Whisper / full ASR | Heavy subsystem for a "supporting-evidence-only" signal. A 6-phrase keyword spotter is the Tier-2 plan (not yet built). | #3 |
| From-scratch CNN-Transformer (the original model) | Too little real per-class audio (0–740 clips) — overfits or won't generalise. Replaced end-to-end by the frozen-YAMNet + small-head approach. Old `model.py` / `dataset.py` / `train.py` were deleted. | #8 |

---

## 8. Training data (for context)

- **ESC-50** — real audio, ingested from `model/esc50_temp.zip` (645 MB,
  **git-ignored**, not in a fresh clone). Supplies real clips for
  `glass_breaking, siren, shouting` and *provisional* proxies for
  `explosion` (fireworks) and `fire_alarm` (clock alarm), plus real ambient
  `normal`.
- **UrbanSound8K** — optional, not auto-downloaded. The only realistic free
  source of real `gunshot` audio.
- **Synthetic fallback** — `model/generate_synthetic_data.py` procedurally makes
  ~150 clips/class so the pipeline always runs. `gunshot` and `scream` are
  **100 % synthetic** — there is no real source for them yet.
- **Augmentation** — `prepare_dataset.py` makes label-preserving variants
  (pitch/time/noise/gain/one echo) of the *real* ESC-50 clips, split
  source-disjointly so an augmented clip never straddles train/test.
- Provenance + split live in `model/data/processed/metadata.csv`; the split is a
  deterministic, hashed, source-disjoint 70/15/15.

---

## 9. Current measured accuracy (honest numbers)

Held-out, source-disjoint test set. Reproduce with `cd model && python evaluate.py`
(writes `reports/evaluation_report.txt`). Last run reproduced on 2026-09-06:

```
Accuracy         0.9510
Macro Precision  0.9640
Macro Recall     0.9450
Macro F1         0.9508

Per class (precision / recall):
  normal          0.93 / 0.96
  gunshot         1.00 / 1.00   (synthetic-only data)
  explosion       0.86 / 0.93
  scream          1.00 / 1.00   (synthetic-only data)
  glass_breaking  1.00 / 0.70
  fire_alarm      0.92 / 1.00
  siren           1.00 / 1.00
  shouting        1.00 / 0.96

release_ready: False
  blockers: explosion/fire_alarm/normal precision, explosion recall,
            normal-audio FP rate, playback-FP eval never run,
            gunshot & scream are synthetic-only.
```

`model/evaluation_gates.py` enforces these gates — the model **cannot** be
called "real-world ready" until they pass, and the code says so. This is the
number to reproduce; **it requires `model/esc50_temp.zip`** (see `CLAUDE.md` and
`docs/SAFETY_IMPLEMENTATION_PLAN.md`). A clone with synthetic-only data will
train and run, but score well below this.
