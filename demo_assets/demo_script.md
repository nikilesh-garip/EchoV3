# ECHO — Demo Script & Panel Presentation Guide

How to demonstrate the Echo prototype during panel evaluation, using the
browser dashboard (no Flutter SDK needed). Every scenario runs the **real**
`/detect` pipeline — same model, same risk scorer, same escalation logic —
against a prepared clip; only room acoustics are bypassed.

---

## Preparation

1. Start the backend from the repo root:
   ```powershell
   .\run_local.ps1 -Port 8011
   ```
   (First start takes 30–90 s while YAMNet loads. Wait for
   `Uvicorn running on http://127.0.0.1:8011`.)
2. Open **http://127.0.0.1:8011** in Chrome or Edge.
3. Sign in with **any** email + password. This is a local profile, not real
   authentication — the sign-in card says so. It scopes your contacts,
   history, and alerts to a stable id, and supplies the display name that goes
   into the message a contact receives.
4. Left nav: **Overview · Live monitor · Event history · Trusted contacts ·
   Demo lab · Settings**.

Emergency channels stay in **simulation mode** unless `backend/.env` is
configured (Telegram bot token / Twilio). In simulation mode the exact
message and call script are composed, shown, and logged — nothing is sent.
That is fine for the demo and is clearly labelled "SIMULATED" on screen.

---

## Where the demo controls are

- **Demo lab tab → "Prepared sound samples"** — one button per class
  (Gunshot, Distress scream, Glass break, Explosion, Fire alarm, Siren,
  Shouting, Background, and Firecracker when the demo head is active). Clicking
  one fetches that clip, plays it, injects it into `/detect`, and switches to
  the Monitor view so each pipeline stage is visible.
- **Demo lab tab → "Classifier head" switch** — Production (8 real classes) vs
  Demo (adds `firecracker`, aliased to `gunshot`). Applies to the live
  microphone too.
- **Overview tab → "Signals that shape risk"** — the manual **Media playback**
  and **Sudden motion** toggles.
- **Live monitor / Demo lab → "Start live demo listening"** — real microphone
  monitoring (browser will ask for mic permission; `http://127.0.0.1` counts
  as a secure context).

---

## Presentation Scenarios

### Scenario 1 — Isolated gunshot (acoustic hazard)
* **Action:** Demo lab → **Gunshot**.
* **Say:** *"We inject a prepared clip straight into the local pipeline.
  Gunshot and explosion are single-shot impulses that don't persist into a
  second recording, so Echo can raise provisional urgent guidance from Pass 1
  alone — it never claims the audio proves an emergency."*
* **Expect:** view switches to Monitor; class = gunshot, high confidence; a
  full alert with a risk score, recommended actions, and "Nearby police" (only
  shown when the places provider responds; any fallback is labelled).

### Scenario 2 — Distress scream
* **Action:** Dismiss the alert ("I'm safe"). Demo lab → **Distress scream**.
* **Say:** *"Pass 1 detects the scream signature; Pass 2 re-confirms it over a
  5-second window. The context scorer lands on POSSIBLE_DANGER and shows
  withdrawal guidance."*
* **Expect:** Monitor shows scream with high confidence; alert with scream
  guidance; both Pass 1 and Pass 2 numbers on screen.

### Scenario 3 — Glass breaking
* **Action:** Dismiss. Demo lab → **Glass break**.
* **Say:** *"Glass breaking is a suspicious environmental event, not an
  urgent-impulse class, so it always goes through the real two-pass
  verification — no Pass 1 shortcut. The scorer rates it SUSPICIOUS to
  POSSIBLE_DANGER."* (See DECISIONS_LOG #10.)
* **Expect:** a logged glass-breaking event with two-pass confidences; a
  full alert only if it lands in POSSIBLE_DANGER/HIGH_RISK, otherwise a toast
  + history entry.

### Scenario 4 — Normal environment (negative class)
* **Action:** Demo lab → **Background**.
* **Say:** *"Normal background audio. The YAMNet-based classifier outputs
  NORMAL and the monitor stays idle. This is a demo result, not a real-world
  accuracy claim — see reports/evaluation_report.txt for the honest numbers."*
* **Expect:** status stays NORMAL; no alert.

### Scenario 5 — Movie action scene (false-positive defence)
* **Action:** Overview → tick **Media playback**. Demo lab → **Gunshot**.
* **Say:** *"An action movie can trip acoustic gunshot detection. Media
  playback is a manual context signal in the browser prototype
  (`context_source=manual`); it lowers urgency only when no other danger
  signal conflicts. This is a review state, not a claim the sound is safe.
  Echo also reads YAMNet's own 'Television/Music' predictions as a weaker
  automatic version of the same signal."*
* **Expect:** the model still detects gunshot, but the risk score drops below
  the HIGH_RISK band (SUSPICIOUS/POSSIBLE_DANGER); no critical escalation
  sequence starts. Untick Media playback afterward.

### Scenario 6 — Multi-event threat sequence (temporal scorer)
* **Action:** Media playback and Sudden motion **off**. Demo lab → **Gunshot**
  (dismiss), → **Distress scream** (dismiss), → **Shouting**.
* **Say:** *"Echo keeps a short rolling event history. An isolated sound is
  concerning; several related hazards in quick succession indicate an active
  danger zone. The repeated-impulse count climbs and the risk score escalates
  across the three clicks even when individual confidences are only moderate."*
* **Expect:** the final event lands in **HIGH_RISK** from compound temporal
  scoring. (The rolling window is ~10 s, so click through without long pauses.)

---

## Optional — the outbound escalation (what actually reaches other people)

1. **Trusted contacts** → add a contact (your own phone / Telegram chat id is
   fine). "Send test alert to my contacts" confirms the pipeline: each channel
   reports `sent` / `simulated` / `failed` per contact.
2. Trigger Scenario 1 again. The alert now arms a **12-second countdown**
   before contacts are called and messaged with the 5-second clip and your
   location. **Cancel — I'm safe** stops it; **Alert now** skips the countdown.
3. In simulation mode the composed Telegram message and the automated-call
   script are shown verbatim, marked SIMULATED. Every message is hedged
   ("what sounded like", "may be in danger") and Echo never auto-dials 112.

## Optional — the firecracker demo head (safe on-stage trigger)

1. Demo lab → **Classifier head** → **Demo**.
2. A **Firecracker** button appears. Click it (or, with a real cracker,
   "Start live demo listening" and light one near the mic).
3. It is detected as its own `firecracker` class and aliased to `gunshot`, so
   the whole alert path runs — but every alert, log line, and message is
   stamped **DEMO** and keeps `raw_class = firecracker`. Nothing claims a real
   gunshot was heard. The production head is never trained on cracker audio.

---

## Honest caveats to state up front

- `gunshot` and `scream` are trained on **synthetic** audio only — no real
  recordings exist for them in this dataset yet.
- Held-out macro F1 is ~0.95 **with** the ESC-50-derived dataset; a plain
  clone without `model/esc50_temp.zip` trains synthetic-only and scores lower.
  `model/evaluation_gates.py` blocks any "real-world ready" claim regardless.
- `/nearby` uses the public OSM Overpass API and falls back to labelled mock
  coordinates when it is rate-limited.
