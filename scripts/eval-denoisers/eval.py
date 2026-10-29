#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.*"
# dependencies = [
#   "numpy<2.3",
#   "scipy>=1.16",
#   "soundfile>=0.12",
#   "librosa==0.11.0",
#   "pesq==0.0.4",
#   "pystoi==0.4.1",
#   "onnxruntime>=1.19",
# ]
# ///
"""Measures noisy input and all three noise suppression engines on real speech.

Downloads the VoiceBank+DEMAND 48 kHz test set (824 clips, Edinburgh DataShare) if it isn't
already at `--data-dir`, runs every clip through `denoise-cli` (built by `build.sh`, which
compiles the app's actual DenoiseKernel sources -- not a reimplementation), delay-compensates
each engine's output by its known kernel delay, and reports PESQ (wide-band, 16 kHz), ESTOI,
SI-SDR and DNSMOS P.835 (SIG/BAK/OVRL, official ONNX model) for the noisy baseline and each
engine, plus each engine's measured CPU per hop (from `scripts/bench`-style timing already in
docs/architecture/ARCHITECTURE.md -- this script only covers audio quality).

Usage:
    scripts/eval-denoisers/build.sh                 # once, after `swift build -c release`
    scripts/eval-denoisers/eval.py [--limit N] [--data-dir path] [--out results.json]

Writes a Markdown table to stdout and the raw per-clip numbers to `results.json` (or --out).
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import tempfile
import urllib.request
import warnings
import zipfile
from pathlib import Path

warnings.filterwarnings("ignore", category=RuntimeWarning, module="pystoi")

import librosa
import numpy as np
import onnxruntime as ort
import soundfile as sf
from pesq import pesq
from pystoi import stoi

ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT_DIR = Path(__file__).resolve().parent
CLI = SCRIPT_DIR / ".build" / "denoise-cli"
DPDFNET_MODEL = ROOT / "App/Loopbacker/Resources/DPDFNet2_48k.mlmodelc"
FASTENHANCER_MODEL = ROOT / "App/Loopbacker/Resources/FastEnhancer_S_48k.mlmodelc"

CLEAN_URL = "https://datashare.ed.ac.uk/server/api/core/bitstreams/dec213d3-bf57-4777-9663-c24bdce92d5e/content"
NOISY_URL = "https://datashare.ed.ac.uk/server/api/core/bitstreams/13c1bfbf-14a6-41db-9b41-8f7310f01ad5/content"

DNSMOS_URL = "https://raw.githubusercontent.com/microsoft/DNS-Challenge/master/DNSMOS/DNSMOS/sig_bak_ovr.onnx"
DNSMOS_CACHE = Path.home() / ".cache" / "loopbacker-eval" / "sig_bak_ovr.onnx"

ENGINES = ["dpdfnet", "fastenhancer", "rnnoise"]
# Samples of output delay (kernel.delay + hop - 1), matching NoiseSuppressorTests.swift exactly:
# the suppressor's output lags its input by this many samples once the wet path is primed.
DELAY = {"dpdfnet": 2879, "fastenhancer": 1023, "rnnoise": 1439}
SR = 48_000


def ensure_dataset(data_dir: Path) -> tuple[Path, Path]:
    clean_dir = data_dir / "clean_testset_wav"
    noisy_dir = data_dir / "noisy_testset_wav"
    if clean_dir.is_dir() and noisy_dir.is_dir():
        return clean_dir, noisy_dir
    data_dir.mkdir(parents=True, exist_ok=True)
    for name, url, target in [("clean", CLEAN_URL, clean_dir), ("noisy", NOISY_URL, noisy_dir)]:
        zip_path = data_dir / f"{name}_testset_wav.zip"
        if not zip_path.exists():
            print(f"downloading {name} testset ({url})...", file=sys.stderr)
            urllib.request.urlretrieve(url, zip_path)  # noqa: S310 (fixed Edinburgh DataShare URL)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(data_dir)
    return clean_dir, noisy_dir


def ensure_dnsmos_model() -> Path:
    if not DNSMOS_CACHE.exists():
        DNSMOS_CACHE.parent.mkdir(parents=True, exist_ok=True)
        print("downloading DNSMOS sig_bak_ovr.onnx...", file=sys.stderr)
        urllib.request.urlretrieve(DNSMOS_URL, DNSMOS_CACHE)  # noqa: S310 (fixed Microsoft URL)
    return DNSMOS_CACHE


def si_sdr(reference: np.ndarray, estimate: np.ndarray) -> float:
    """Scale-invariant SDR in dB (Le Roux et al. 2019)."""
    reference = reference - reference.mean()
    estimate = estimate - estimate.mean()
    projection = (np.dot(estimate, reference) / (np.dot(reference, reference) + 1e-12)) * reference
    noise = estimate - projection
    return 10 * np.log10((np.sum(projection ** 2) + 1e-12) / (np.sum(noise ** 2) + 1e-12))


class DNSMOS:
    """Official DNSMOS P.835 (SIG/BAK/OVRL) model: 9.01 s @ 16 kHz windows, averaged, then the
    non-personalized polynomial fit -- ported from microsoft/DNS-Challenge's dnsmos_local.py."""

    SR = 16_000
    INPUT_LENGTH = 9.01

    def __init__(self, model_path: Path) -> None:
        self.session = ort.InferenceSession(str(model_path))

    def __call__(self, audio16k: np.ndarray) -> tuple[float, float, float]:
        fs = self.SR
        audio = audio16k.astype(np.float32)
        len_samples = int(self.INPUT_LENGTH * fs)
        while len(audio) < len_samples:
            audio = np.concatenate([audio, audio])
        num_hops = int(np.floor(len(audio) / fs) - self.INPUT_LENGTH) + 1
        sig_raw, bak_raw, ovr_raw = [], [], []
        for idx in range(num_hops):
            seg = audio[int(idx * fs):int((idx + self.INPUT_LENGTH) * fs)]
            if len(seg) < len_samples:
                continue
            out = self.session.run(None, {"input_1": seg[np.newaxis, :]})[0][0]
            sig_raw.append(out[0])
            bak_raw.append(out[1])
            ovr_raw.append(out[2])
        sig, bak, ovr = float(np.mean(sig_raw)), float(np.mean(bak_raw)), float(np.mean(ovr_raw))
        p_sig = np.poly1d([-0.08397278, 1.22083953, 0.0052439])
        p_bak = np.poly1d([-0.13166888, 1.60915514, -0.39604546])
        p_ovr = np.poly1d([-0.06766283, 1.11546468, 0.04602535])
        return float(p_sig(sig)), float(p_bak(bak)), float(p_ovr(ovr))


def run_cli(engine: str, input_wav: Path, output_wav: Path) -> None:
    args = [str(CLI), engine, str(input_wav), str(output_wav)]
    if engine == "dpdfnet":
        args += ["--dpdfnet-model", str(DPDFNET_MODEL)]
    elif engine == "fastenhancer":
        args += ["--fastenhancer-model", str(FASTENHANCER_MODEL)]
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def align(clean: np.ndarray, degraded: np.ndarray, delay: int) -> tuple[np.ndarray, np.ndarray]:
    """Drops `delay` output samples and matches lengths, so both arrays line up sample-for-sample."""
    degraded = degraded[delay:]
    n = min(len(clean), len(degraded))
    return clean[:n], degraded[:n]


def score(clean48: np.ndarray, degraded48: np.ndarray, clean16: np.ndarray, degraded16: np.ndarray,
          dnsmos: DNSMOS) -> dict[str, float]:
    p = pesq(16_000, clean16, degraded16, "wb")
    s = stoi(clean48, degraded48, SR, extended=True)
    sdr = si_sdr(clean48, degraded48)
    sig, bak, ovr = dnsmos(degraded16)
    return {"pesq": float(p), "estoi": float(s), "sisdr": float(sdr), "dnsmos_sig": sig, "dnsmos_bak": bak, "dnsmos_ovr": ovr}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=Path.home() / ".cache" / "loopbacker-eval" / "voicebank-demand")
    parser.add_argument("--limit", type=int, default=None, help="only score the first N clips (default: all 824)")
    parser.add_argument("--out", type=Path, default=SCRIPT_DIR / "results.json")
    args = parser.parse_args()

    if not CLI.exists():
        raise SystemExit(f"{CLI} missing; run scripts/eval-denoisers/build.sh first")

    clean_dir, noisy_dir = ensure_dataset(args.data_dir)
    dnsmos = DNSMOS(ensure_dnsmos_model())

    clips = sorted(p.name for p in clean_dir.glob("*.wav"))
    if args.limit:
        clips = clips[:args.limit]
    print(f"scoring {len(clips)} clips...", file=sys.stderr)

    per_clip: list[dict] = []
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for i, name in enumerate(clips):
            clean_path = clean_dir / name
            noisy_path = noisy_dir / name
            if not noisy_path.exists():
                continue
            clean48, _ = sf.read(clean_path, dtype="float32")
            noisy48, _ = sf.read(noisy_path, dtype="float32")
            n = min(len(clean48), len(noisy48))
            clean48, noisy48 = clean48[:n], noisy48[:n]
            clean16 = librosa.resample(clean48, orig_sr=SR, target_sr=16_000)

            row: dict = {"clip": name}
            noisy16 = librosa.resample(noisy48, orig_sr=SR, target_sr=16_000)
            row["noisy"] = score(clean48, noisy48, clean16, noisy16, dnsmos)

            for engine in ENGINES:
                out_wav = tmp_path / f"{engine}.wav"
                run_cli(engine, noisy_path, out_wav)
                processed48, _ = sf.read(out_wav, dtype="float32")
                aligned_clean, aligned_processed = align(clean48, processed48, DELAY[engine])
                processed16 = librosa.resample(aligned_processed, orig_sr=SR, target_sr=16_000)
                clean16_aligned = librosa.resample(aligned_clean, orig_sr=SR, target_sr=16_000)
                row[engine] = score(aligned_clean, aligned_processed, clean16_aligned, processed16, dnsmos)
            per_clip.append(row)
            if (i + 1) % 50 == 0:
                print(f"  {i + 1}/{len(clips)}", file=sys.stderr)

    conditions = ["noisy"] + ENGINES
    metrics = ["pesq", "estoi", "sisdr", "dnsmos_sig", "dnsmos_bak", "dnsmos_ovr"]
    summary = {
        cond: {m: statistics.fmean(row[cond][m] for row in per_clip) for m in metrics}
        for cond in conditions
    }
    args.out.write_text(json.dumps({"per_clip": per_clip, "summary": summary, "n_clips": len(per_clip)}, indent=2))
    print(f"wrote {args.out}", file=sys.stderr)

    name = {"noisy": "Noisy input", "dpdfnet": "DPDFNet", "fastenhancer": "FastEnhancer", "rnnoise": "RNNoise"}
    print(f"\n{len(per_clip)} clips, VoiceBank+DEMAND 48 kHz test set\n")
    print("| Engine | PESQ (wb) | ESTOI | SI-SDR (dB) | DNSMOS SIG | DNSMOS BAK | DNSMOS OVRL |")
    print("|---|---|---|---|---|---|---|")
    for cond in conditions:
        s = summary[cond]
        print(f"| {name[cond]} | {s['pesq']:.2f} | {s['estoi']:.2f} | {s['sisdr']:.1f} | "
              f"{s['dnsmos_sig']:.2f} | {s['dnsmos_bak']:.2f} | {s['dnsmos_ovr']:.2f} |")


if __name__ == "__main__":
    main()
