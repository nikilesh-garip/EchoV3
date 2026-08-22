# CLAUDE.md — how to run Echo after a fresh clone

You (Claude) are being run by someone who just cloned this repo and wants the
project working. This file is the single source of truth for **getting it
running**. Follow it top to bottom. `LOCAL_SETUP.md` has more background;
`MODELS.md` explains the models; `docs/` has the design.

Platform assumed: **Windows + PowerShell** (the launch scripts are `.ps1`).
On macOS/Linux, run the equivalent commands by hand (noted where they differ).

---

## 0. What this project is

Echo = an acoustic hazard-detection safety app. Three parts:

| Part | Path | What it is | Needed to demo? |
|------|------|-----------|-----------------|
| **Backend** | `backend/` | FastAPI server: runs the model, risk scoring, and the emergency-contact escalation (Telegram + automated call). Also serves a browser dashboard at `/`. | **Yes — always start here.** |
| **Model** | `model/` | Training + eval for a YAMNet transfer-learning classifier. Produces the checkpoint the backend loads. | Only to (re)train. |
| **Mobile app** | `app/` | Flutter app (the intended product surface). Ships only `lib/` + `pubspec.yaml`. | Optional — needs the Flutter SDK; least-tested surface. |

The browser dashboard (`http://127.0.0.1:<port>`) is enough to demo the whole
pipeline without Flutter.

---

## 1. Prerequisites

- **Python 3.10+** on `PATH` (`py -3 --version` or `python --version`).
  Repo was last verified on **Python 3.13.12**.
- **Internet on first run** — the setup downloads pip packages and the pretrained
  YAMNet model (~17 MB).
- ~2 GB free disk (TensorFlow + a venv).
- Flutter SDK — **only** if you're asked to run the mobile app.

---

## 2. First-time setup (once per clone)

A fresh clone has **no trained model and no dataset** — `model/checkpoints/`,
`model/data/`, `backend/.env`, and `model/esc50_temp.zip` are all git-ignored.
`backend/main.py` calls `sys.exit(1)` on startup if the checkpoint is missing,
so this step is mandatory.

```powershell
# from the repo root (the folder with run_local.ps1)
.\run_local.ps1 -Setup
```

This creates `.venv\`, installs `requirements.txt`, generates synthetic training
data, builds `model/data/processed/metadata.csv`, and trains the classifier
head. **~10–15 minutes**, mostly the TensorFlow install and the one-time YAMNet
embedding pass.

macOS/Linux equivalent (no `.ps1`):

```bash
python -m venv .venv && . .venv/bin/activate
pip install -U pip && pip install -r requirements.txt
cd model
python generate_synthetic_data.py
python prepare_dataset.py
python train_yamnet.py
```

### 2a. Real accuracy vs. what a plain clone gives you

`prepare_dataset.py` only uses **real** ESC-50 audio if `model/esc50_temp.zip`
(≈645 MB) is present — **it does not download it** (the note in `LOCAL_SETUP.md`
that says "downloads automatically" is wrong). Without that zip, every class
falls back to **synthetic-only** audio: the backend still starts and the demo
still works, but the model is much weaker than the committed
`reports/evaluation_report.txt` (Macro F1 **0.95**), and
`GET /readiness` / `evaluate.py` will correctly report "not ready".

To reproduce the real 0.95 number:

1. Get `esc50_temp.zip` from the repo author, **or** download
   <https://github.com/karolpiczak/ESC-50/archive/master.zip>, rename it to
   `esc50_temp.zip`, and put it in `model/`.
2. Re-run `.\run_local.ps1 -Setup` (or `cd model; ..\.venv\Scripts\python.exe prepare_dataset.py; ..\.venv\Scripts\python.exe train_yamnet.py`).

If the author shipped `model/checkpoints/` and `model/data/` alongside the clone
(e.g. in a zip), you can **skip step 2 entirely** — just go to section 3.

### 2b. YAMNet download / a broken cache

`train_yamnet.py` and the backend both call `load_yamnet()`, which pulls
`google/yamnet/1` into a local cache:

- Windows: `%TEMP%\tfhub_modules\`
- Linux/macOS: `/tmp/tfhub_modules/`

If a download was interrupted, the cache can be left **corrupt** — a hash
folder containing `assets/` and `variables/` but **no `saved_model.pb`**. The
symptom is:

```
ValueError: Trying to load a model of incompatible/unknown type.
'...\tfhub_modules\<hash>' contains neither 'saved_model.pb' nor 'saved_model.pbtxt'.
```

and the backend then prints `CRITICAL ERROR loading model` and exits. **Fix:**
delete that hash folder and re-run — it re-downloads cleanly.

```powershell
Remove-Item -Recurse -Force "$env:TEMP\tfhub_modules\*"
```

---

## 3. Run the backend

```powershell
.\run_local.ps1 -Port 8011
```

- Default port is **8010**; use `-Port` if it's taken.
- First start takes 30–90 s (loading YAMNet + the head). Wait for
  `Uvicorn running on http://127.0.0.1:8011`.
- macOS/Linux: `cd backend && ../.venv/bin/python -m uvicorn main:app --port 8011`
  (must run from `backend/` — it mounts `./static`).

Then open **`http://127.0.0.1:8011`**. Sign in with any email/password (it's a
local profile, not real auth — this is intentional and the UI says so).

### Smoke test (what "working" looks like)

- `GET /profiles` → JSON with `real` and `demo`, both `"loaded": true`.
- `GET /escalation/status` → `"simulation_mode": true` (no `.env` yet — fine).
- In the dashboard: **Demo lab → Gunshot** → a red alert with a risk score and
  a 12-second countdown.
- **Trusted contacts** → add yourself → **Send test alert** → per-channel
  results, each marked `simulated` (until section 5).

---

## 4. Run the tests (proves the build)

```powershell
cd backend; ..\.venv\Scripts\python.exe -m pytest -q     # ~30s, loads TF. Expect: 29 passed
cd ..\model; ..\.venv\Scripts\python.exe -m pytest -q    # ~35s. Expect: 32 passed
```

`cd model; ..\.venv\Scripts\python.exe evaluate.py` re-runs the held-out
evaluation and rewrites `reports/evaluation_report.txt`.

If `backend/` pytest crashes at collection with `INTERNALERROR ... SystemExit: 1`,
that's the corrupt-YAMNet-cache problem from **2b** — clear the cache and retry.

---

## 5. Optional: make Telegram + calls real

Everything works in **simulation mode** without this (messages/call scripts are
composed and logged, nothing is sent).

```powershell
cd backend
copy .env.example .env
notepad .env
```

- `TELEGRAM_BOT_TOKEN` — from `@BotFather`. Each contact must open the bot and
  press Start; then the app/dashboard can list their chat id.
- `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_FROM_NUMBER` — for the
  automated voice call.
- `ECHO_PUBLIC_BASE_URL` — a public URL for this backend (Twilio fetches the
  call script + clip from it). Use a tunnel in dev: `ngrok http 8011`.

Restart the backend after editing `.env`.

---

## 6. Optional: the Flutter mobile app

Needs the Flutter SDK. `app/` has no `android/`/`ios/` folders yet.

```powershell
cd app
.\setup_app.ps1                 # generates android/ + ios/, patches permissions
flutter run --dart-define=ECHO_API_URL=http://<your-lan-ip>:8011   # real phone, same Wi-Fi
flutter run                                                        # Android emulator (uses 10.0.2.2:8010)
```

This app has **never been built** in this repo and has no automated tests — a
first `flutter run` may surface SDK/toolchain issues (`flutter doctor`). The
accelerometer "sudden motion" detector has never run on a real device.

---

## 7. Known rough edges (not blockers — say so if asked)

- **`model/esc50_temp.zip` is git-ignored** → a plain clone trains on
  synthetic-only data and won't reach the committed 0.95 F1. See 2a.
- **Corrupt YAMNet cache** gives a cryptic error with no auto-recovery. See 2b.
- **`docs/` has drift**: `docs/ARCHITECTURE.md` "Repo Structure" lists deleted
  files and omits the escalation routes; `demo_assets/demo_script.md` describes
  old "Method B" numbered demo buttons; `DECISIONS_LOG.md` entries are not in
  numeric order (#6–#7 sit below #8–#11); `LOCAL_SETUP.md` wrongly says ESC-50
  auto-downloads. The **code** is the source of truth.
- **`model/export_openvino.py`** runs a bare `os.system("pip install openvino")`
  on ImportError — harmless (openvino is in `requirements.txt`) but it would
  install outside the venv if ever triggered. The committed OpenVINO IR under
  `model/checkpoints/openvino/` is **stale** (predates the last retrain);
  regenerate with `python export_openvino.py` if you need it.
- **`model/auto_dev_loop.py`** is orphan dev tooling (nothing references it; it
  `git add`s git-ignored paths). Not part of running the product.
- **Model accuracy is genuinely limited** on unseen live-mic audio
  (glass_breaking recall ~0.70; `gunshot`/`scream` are trained on synthetic
  audio only). This is disclosed, not hidden — `evaluation_gates.py` blocks any
  "real-world ready" claim.
- No `README.md` at the repo root (this file + `LOCAL_SETUP.md` + `MODELS.md`
  cover it).

---

## 8. One-glance command reference

```powershell
.\run_local.ps1 -Setup                 # first time: venv + deps + data + train (~10-15 min)
.\run_local.ps1 -Port 8011             # start the backend
#   -> http://127.0.0.1:8011  (dashboard)   |   /docs  (API)

cd backend; ..\.venv\Scripts\python.exe -m pytest -q     # 29 passed
cd model;   ..\.venv\Scripts\python.exe -m pytest -q     # 32 passed
cd model;   ..\.venv\Scripts\python.exe evaluate.py      # rewrites reports/evaluation_report.txt

Remove-Item -Recurse -Force "$env:TEMP\tfhub_modules\*"  # fix a corrupt YAMNet cache
```

Verified working end-to-end on 2026-09-06 (Windows 11, Python 3.13.12,
TensorFlow 2.21): both test suites green, backend serves, `/detect` +
`/incidents` escalation run correctly in simulation mode.
