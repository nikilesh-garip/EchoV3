import os
import glob
import hashlib
import shutil
import csv
import zipfile
import numpy as np
import soundfile as sf
import scipy.signal

from data_manifest import validate_manifest

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
ESC50_DIR_CANDIDATES = [
    os.path.join(BASE_DIR, "data", "ESC-50-master"),
    os.path.join(BASE_DIR, "..", "data", "ESC-50-master"),
    os.path.join(BASE_DIR, "esc50_temp_dir", "ESC-50-master"),
]
RAW_HAZARDS_DIR = os.path.join(BASE_DIR, "data", "raw_hazards")
DEMO_SOUNDS_DIR = os.path.join(BASE_DIR, "..", "backend", "static", "demo_sounds")
PROCESSED_DIR = os.path.join(BASE_DIR, "data", "processed")

ACTIVE_CLASSES = [
    "normal", "gunshot", "explosion", "scream", "glass_breaking",
    "fire_alarm", "siren", "shouting"
]

def find_or_extract_esc50():
    for d in ESC50_DIR_CANDIDATES:
        if os.path.exists(os.path.join(d, "meta", "esc50.csv")) and os.path.isdir(os.path.join(d, "audio")):
            return d

    # Look for zip archives
    zip_candidates = [
        os.path.join(BASE_DIR, "esc50_temp.zip"),
        os.path.join(BASE_DIR, "..", "ESC-50-master.zip"),
        os.path.join(BASE_DIR, "data", "ESC-50-master.zip"),
    ]
    for z in zip_candidates:
        if os.path.exists(z):
            extract_target = os.path.join(BASE_DIR, "data", "ESC-50-master")
            print(f"Extracting ESC-50 from {z} to {extract_target}...")
            os.makedirs(os.path.join(BASE_DIR, "data"), exist_ok=True)
            with zipfile.ZipFile(z, 'r') as zip_ref:
                zip_ref.extractall(os.path.join(BASE_DIR, "data"))
            if os.path.exists(os.path.join(extract_target, "meta", "esc50.csv")):
                return extract_target

    raise FileNotFoundError("Could not locate ESC-50 dataset. Please place ESC-50-master in model/data/.")


def load_mono_16k(path):
    data, sr = sf.read(path, dtype="float32")
    if data.ndim > 1:
        data = np.mean(data, axis=1)
    if sr != 16000:
        num_samples = int(len(data) * 16000 / sr)
        data = scipy.signal.resample(data, num_samples)
    return data.astype(np.float32)


def fast_augment(audio, bg_noise=None, rng=None):
    if rng is None:
        rng = np.random.default_rng()
    augmented = audio.copy()

    # 1. Pitch / Speed Perturbation (fast resampling: 0.88x to 1.14x)
    rate = rng.uniform(0.88, 1.14)
    num_samples = max(1600, int(len(augmented) / rate))
    augmented = scipy.signal.resample(augmented, num_samples)

    # 2. Add real ambient background noise at realistic SNR (6dB - 22dB)
    if bg_noise is not None and len(bg_noise) > 0:
        snr_db = rng.uniform(6.0, 22.0)
        snr = 10.0 ** (snr_db / 20.0)
        bg_chunk = bg_noise
        if len(bg_chunk) < len(augmented):
            repeats = int(np.ceil(len(augmented) / len(bg_chunk))) + 1
            bg_chunk = np.tile(bg_chunk, repeats)
        start = rng.integers(0, max(1, len(bg_chunk) - len(augmented)))
        bg_chunk = bg_chunk[start:start + len(augmented)]

        signal_rms = np.sqrt(np.mean(augmented ** 2)) + 1e-8
        bg_rms = np.sqrt(np.mean(bg_chunk ** 2)) + 1e-8
        augmented = augmented + (bg_chunk * (signal_rms / (bg_rms * snr)))

    # 3. Peak normalization
    max_val = np.max(np.abs(augmented))
    if max_val > 0:
        augmented = augmented / max_val * rng.uniform(0.75, 0.95)

    # 4. Standard length (between 2.0s and 4.5s)
    min_len = int(1.5 * 16000)
    target_len = int(rng.uniform(2.0, 4.5) * 16000)
    if len(augmented) > target_len:
        start = rng.integers(0, len(augmented) - target_len)
        augmented = augmented[start:start + target_len]
    elif len(augmented) < min_len:
        pad_len = 32000 - len(augmented)
        augmented = np.pad(augmented, (0, pad_len))

    return augmented.astype(np.float32)


def prepare_dataset():
    print("=== Echo 100% Real-Audio Dataset Preparation ===")
    esc50_root = find_or_extract_esc50()
    esc50_audio_dir = os.path.join(esc50_root, "audio")
    esc50_csv_path = os.path.join(esc50_root, "meta", "esc50.csv")
    print(f"Using ESC-50 at: {esc50_root}")

    if os.path.exists(PROCESSED_DIR):
        for entry in os.listdir(PROCESSED_DIR):
            p = os.path.join(PROCESSED_DIR, entry)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
            else:
                try:
                    os.remove(p)
                except OSError:
                    pass
    os.makedirs(PROCESSED_DIR, exist_ok=True)
    for c in ACTIVE_CLASSES + ["firecracker"]:
        os.makedirs(os.path.join(PROCESSED_DIR, c), exist_ok=True)

    rng = np.random.default_rng(42)

    # 1. Load ESC-50 metadata
    esc50_rows = []
    with open(esc50_csv_path, 'r', encoding='utf-8') as f:
        for r in csv.DictReader(f):
            esc50_rows.append(r)

    # 2. Collect ambient noise pool for mixing
    ambient_categories = [
        "rain", "wind", "sea_waves", "water_drops", "insects", "chirping_birds",
        "crickets", "footsteps", "breathing", "pouring_water", "rooster", "hen",
        "cow", "sheep", "frog", "cat", "engine", "train", "airplane", "helicopter",
        "vacuum_cleaner", "washing_machine", "keyboard_typing", "mouse_click",
        "laughing", "coughing", "sneezing", "snoring", "brushing_teeth",
        "drinking_sipping", "toilet_flush", "door_wood_knock", "door_wood_creaks",
        "can_opening", "church_bells", "crow", "clock_tick"
    ]

    ambient_pool = []
    for r in esc50_rows:
        if r['category'] in ambient_categories:
            p = os.path.join(esc50_audio_dir, r['filename'])
            if os.path.exists(p):
                ambient_pool.append(load_mono_16k(p))
    print(f"Loaded {len(ambient_pool)} real ambient background recordings.")

    # 3. Process Normal (Background non-hazard class): 350 real clips
    print("\nProcessing 'normal' background non-hazard class...")
    normal_count = 0
    for r in esc50_rows:
        if r['category'] in ambient_categories:
            src = os.path.join(esc50_audio_dir, r['filename'])
            if os.path.exists(src):
                audio = load_mono_16k(src)
                out_path = os.path.join(PROCESSED_DIR, "normal", f"esc50_normal_{r['filename']}")
                sf.write(out_path, audio, 16000)
                normal_count += 1
                if normal_count >= 350:
                    break
    print(f"  - Wrote {normal_count} real normal/background files.")

    # Helper function to write originals + fast augmented variants
    def expand_class(class_name, seed_audios, target_count=120):
        print(f"\nProcessing '{class_name}' from {len(seed_audios)} real source clips...")
        if not seed_audios:
            raise ValueError(f"No seed recordings found for real class: {class_name}")

        count = 0
        for i, a in enumerate(seed_audios):
            out_p = os.path.join(PROCESSED_DIR, class_name, f"real_{class_name}_{i:03d}.wav")
            sf.write(out_p, a, 16000)
            count += 1

        var_idx = 0
        while count < target_count:
            base_audio = seed_audios[var_idx % len(seed_audios)]
            bg_noise = ambient_pool[rng.integers(0, len(ambient_pool))]
            aug_audio = fast_augment(base_audio, bg_noise, rng)
            out_p = os.path.join(PROCESSED_DIR, class_name, f"real_{class_name}_aug_{var_idx:03d}.wav")
            sf.write(out_p, aug_audio, 16000)
            count += 1
            var_idx += 1
        print(f"  - Total for '{class_name}': {count} real files.")

    # 4. Glass breaking (from ESC-50 glass_breaking category)
    glass_audios = [
        load_mono_16k(os.path.join(esc50_audio_dir, r['filename']))
        for r in esc50_rows if r['category'] == 'glass_breaking' and os.path.exists(os.path.join(esc50_audio_dir, r['filename']))
    ]
    expand_class("glass_breaking", glass_audios, target_count=120)

    # 5. Siren (from ESC-50 siren category)
    siren_audios = [
        load_mono_16k(os.path.join(esc50_audio_dir, r['filename']))
        for r in esc50_rows if r['category'] == 'siren' and os.path.exists(os.path.join(esc50_audio_dir, r['filename']))
    ]
    expand_class("siren", siren_audios, target_count=120)

    # 6. Fire alarm (from ESC-50 clock_alarm + raw_hazards fire_alarm_1.wav + demo_sounds fire_alarm.wav)
    alarm_audios = [
        load_mono_16k(os.path.join(esc50_audio_dir, r['filename']))
        for r in esc50_rows if r['category'] == 'clock_alarm' and os.path.exists(os.path.join(esc50_audio_dir, r['filename']))
    ]
    for fa_candidate in [
        os.path.join(RAW_HAZARDS_DIR, "fire_alarm_1.wav"),
        os.path.join(DEMO_SOUNDS_DIR, "fire_alarm.wav"),
    ]:
        if os.path.exists(fa_candidate):
            fa_data = load_mono_16k(fa_candidate)
            for s_idx in range(0, max(1, len(fa_data) - 32000), 32000):
                alarm_audios.append(fa_data[s_idx:s_idx + 48000])
    expand_class("fire_alarm", alarm_audios, target_count=120)

    # 7. Explosion (from ESC-50 fireworks + raw_hazards explosion_1.wav, explosion_2.wav + demo explosion.wav)
    exp_audios = [
        load_mono_16k(os.path.join(esc50_audio_dir, r['filename']))
        for r in esc50_rows if r['category'] == 'fireworks' and os.path.exists(os.path.join(esc50_audio_dir, r['filename']))
    ]
    for exp_candidate in [
        os.path.join(RAW_HAZARDS_DIR, "explosion_1.wav"),
        os.path.join(RAW_HAZARDS_DIR, "explosion_2.wav"),
        os.path.join(DEMO_SOUNDS_DIR, "explosion.wav"),
    ]:
        if os.path.exists(exp_candidate):
            exp_audios.append(load_mono_16k(exp_candidate))
    expand_class("explosion", exp_audios, target_count=120)

    # 8. Gunshot (from raw_hazards gunshot_1.wav + demo_sounds gunshot.wav)
    gs_audios = []
    for gs_candidate in [
        os.path.join(RAW_HAZARDS_DIR, "gunshot_1.wav"),
        os.path.join(DEMO_SOUNDS_DIR, "gunshot.wav"),
    ]:
        if os.path.exists(gs_candidate):
            gs_data = load_mono_16k(gs_candidate)
            gs_audios.append(gs_data)
            for offset in [4000, 8000, 12000]:
                if len(gs_data) > offset + 16000:
                    gs_audios.append(gs_data[offset:])
    expand_class("gunshot", gs_audios, target_count=120)

    # 9. Scream (from raw_hazards scream_1.wav, scream_2.wav + demo scream.wav)
    sc_audios = []
    for sc_candidate in [
        os.path.join(RAW_HAZARDS_DIR, "scream_1.wav"),
        os.path.join(RAW_HAZARDS_DIR, "scream_2.wav"),
        os.path.join(DEMO_SOUNDS_DIR, "scream.wav"),
    ]:
        if os.path.exists(sc_candidate):
            sc_audios.append(load_mono_16k(sc_candidate))
    expand_class("scream", sc_audios, target_count=120)

    # 10. Shouting (from raw_hazards shouting_1.wav + demo shouting.wav + ESC-50 crying_baby)
    sh_audios = [
        load_mono_16k(os.path.join(esc50_audio_dir, r['filename']))
        for r in esc50_rows if r['category'] == 'crying_baby' and os.path.exists(os.path.join(esc50_audio_dir, r['filename']))
    ]
    for sh_candidate in [
        os.path.join(RAW_HAZARDS_DIR, "shouting_1.wav"),
        os.path.join(DEMO_SOUNDS_DIR, "shouting.wav"),
    ]:
        if os.path.exists(sh_candidate):
            sh_data = load_mono_16k(sh_candidate)
            for s_idx in range(0, max(1, len(sh_data) - 32000), 48000):
                sh_audios.append(sh_data[s_idx:s_idx + 48000])
    expand_class("shouting", sh_audios, target_count=120)

    # 11. Firecracker (for demo profile)
    fc_audios = [
        load_mono_16k(os.path.join(esc50_audio_dir, r['filename']))
        for r in esc50_rows if r['category'] == 'fireworks' and os.path.exists(os.path.join(esc50_audio_dir, r['filename']))
    ]
    fc_demo = os.path.join(DEMO_SOUNDS_DIR, "firecracker.wav")
    if os.path.exists(fc_demo):
        fc_audios.append(load_mono_16k(fc_demo))
    for i, a in enumerate(fc_audios):
        out_p = os.path.join(PROCESSED_DIR, "firecracker", f"real_firecracker_{i:03d}.wav")
        sf.write(out_p, a, 16000)

    # 12. Build Metadata CSV
    print("\nBuilding metadata.csv...")
    def _assign_split(name):
        bucket = int(hashlib.md5(name.encode("utf-8")).hexdigest(), 16) % 100
        if bucket < 70:
            return "train"
        if bucket < 85:
            return "validation"
        return "test"

    records = []
    for c in ACTIVE_CLASSES:
        c_dir = os.path.join(PROCESSED_DIR, c)
        for wav in glob.glob(os.path.join(c_dir, "*.wav")):
            fn = os.path.basename(wav)
            records.append({
                "filepath": os.path.abspath(wav),
                "label": c,
                "source_dataset": "real_audio",
                "source_clip_id": fn,
                "split": _assign_split(fn)
            })

    out_csv = os.path.join(PROCESSED_DIR, "metadata.csv")
    with open(out_csv, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(
            f, fieldnames=["filepath", "label", "source_dataset", "source_clip_id", "split"]
        )
        writer.writeheader()
        writer.writerows(records)

    print(f"Compiled {len(records)} 100% REAL records into {out_csv}")
    from collections import Counter
    dist = Counter([r['label'] for r in records])
    for cls in ACTIVE_CLASSES:
        print(f"  - {cls:15s}: {dist[cls]} files")

    # Validate
    res = validate_manifest(out_csv)
    print(f"\nManifest validation: {'PASSED' if res['valid'] else 'FAILED'}")
    print(f"Split counts: {res['split_counts']}")
    if not res['valid']:
        raise RuntimeError(f"Manifest validation blockers: {res['blockers']}")


if __name__ == "__main__":
    prepare_dataset()
