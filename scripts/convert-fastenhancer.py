#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.*"
# dependencies = [
#   "torch==2.7.0",
#   "coremltools==9.0",
#   "numpy<2.3",
#   "scipy>=1.16",
#   "librosa==0.11.0",
# ]
# ///
"""Convert aask1357's FastEnhancer-S 48 kHz streaming model to the Core ML bundle the app ships.

Reproduces App/Loopbacker/Resources/FastEnhancer_S_48k.mlmodelc from pinned upstream sources:

    scripts/convert-fastenhancer.py   # writes App/Loopbacker/Resources/FastEnhancer_S_48k.mlmodelc

FastEnhancer (MIT, https://github.com/aask1357/fastenhancer, paper arXiv:2509.21867) is a causal
spectral mask predictor: a strided-conv U-Net over frequency bins wrapped around an "RNNFormer"
bottleneck (one GRU per block, run independently per frequency bin, giving every bin its own
zero-lookahead temporal state, plus self-attention *across* frequency bins within the current
frame only -- so the whole stack is causal with no lookahead). One call consumes one STFT frame
(n_fft=1024, hop=512, Hann window, 513 complex bins) plus a flat recurrent state (the per-block
GRU hidden states concatenated) and returns the enhanced frame plus the next state, exactly like
DPDFNet's graph (see convert-dpdfnet.py) -- so it reuses the same BNNS Graph kernel shape in
Swift (Sources/Services/CompiledGraph.swift), just with FastEnhancer's own STFT window pair and
state layout (Sources/Services/FastEnhancerKernel.swift).

Three checkpoints ship at this hop size (10.67 ms): "t" (29K params), "b" (104K) and "s" (212K).
Authors' own VoiceBank+DEMAND-48k validation metrics (from each checkpoint's `metrics` dict):

    t: PESQ 2.73, STOI 0.937
    b: PESQ 2.92, STOI 0.944
    s: PESQ 2.98, STOI 0.947   <- shipped: best quality, and BNNS Graph still runs it in a small
                                  fraction of the ~1 ms/hop budget (see FastEnhancerKernel.swift).

Weights are converted fp32 end-to-end: unlike DPDFNet, this model is ~200K parameters (under
1 MB fp32), so there is no size reason to compress to fp16, and fp32 avoids re-deriving a
compression tolerance for a different architecture.
"""

from __future__ import annotations

import math
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from torch import nn

FASTENHANCER_REPO = "https://github.com/aask1357/fastenhancer"
FASTENHANCER_COMMIT = "85d98a689a85b956dec384f258b075859ca50263"
RELEASE_TAG = "ckpt-v1.0.0-48khz"
RELEASE_ASSET = "fastenhancer_s.zip"
CHECKPOINT_IN_ZIP = "00500.pth"
VARIANT = "s"

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "App/Loopbacker/Resources/FastEnhancer_S_48k.mlmodelc"

# s.yaml model_kwargs (configs/fastenhancer_48khz/s.yaml), pinned at FASTENHANCER_COMMIT.
MODEL_KWARGS = dict(
    channels=64,
    kernel_size=[8, 3, 3, 3],
    stride=4,
    rnnformer_kwargs=dict(
        num_blocks=3,
        channels=48,
        freq=48,
        num_heads=4,
        eps=1.0e-5,
        positional_embedding="train",
        attn_bias=False,
        post_act=False,
        pre_norm=False,
    ),
    pre_post_init="linear",
    n_fft=1024,
    hop_size=512,
    win_size=1024,
    window="hann",
    stft_normalized=False,
    mask=None,
    activation="SiLU",
    activation_kwargs=dict(inplace=True),
    input_compression=0.3,
    normalize_final_conv=True,
    weight_norm=True,
    resnet=False,
)


def checkout_upstream(workdir: Path) -> Path:
    src = workdir / "fastenhancer"
    subprocess.run(["git", "clone", "--quiet", FASTENHANCER_REPO, str(src)], check=True)
    subprocess.run(["git", "-C", str(src), "checkout", "--quiet", FASTENHANCER_COMMIT], check=True)
    return src


def download_checkpoint(workdir: Path) -> Path:
    zip_path = workdir / RELEASE_ASSET
    url = f"{FASTENHANCER_REPO}/releases/download/{RELEASE_TAG}/{RELEASE_ASSET}"
    urllib.request.urlretrieve(url, zip_path)  # noqa: S310 (fixed, pinned GitHub release URL)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extract(CHECKPOINT_IN_ZIP, workdir)
    return workdir / CHECKPOINT_IN_ZIP


def load_model(src: Path, checkpoint: Path) -> nn.Module:
    sys.path.insert(0, str(src))
    from models.fastenhancer.default.model import ONNXModel

    model = ONNXModel(**MODEL_KWARGS)
    ckpt = torch.load(checkpoint, map_location="cpu", weights_only=True)
    model.load_state_dict(ckpt["model"], strict=True)
    model.remove_weight_reparameterizations()
    model.eval()
    return model


class Wrapper(nn.Module):
    """Flattens the per-block GRU caches into one state vector, like DPDFNet's wrapper flattens
    its recurrent state: BNNS Graph arguments are plain float buffers, not a Python list."""

    def __init__(self, model: nn.Module, num_blocks: int, freq: int, channels: int) -> None:
        super().__init__()
        self.model = model
        self.num_blocks = num_blocks
        self.freq = freq
        self.channels = channels
        self.block_size = freq * channels

    def forward(self, spec: torch.Tensor, state_in: torch.Tensor):
        caches_in = [
            state_in[i * self.block_size:(i + 1) * self.block_size].view(1, self.freq, self.channels)
            for i in range(self.num_blocks)
        ]
        spec_e, *caches_out = self.model(spec, *caches_in)
        state_out = torch.cat([c.reshape(-1) for c in caches_out], dim=0)
        return spec_e, state_out


def parity_frames(bins: int) -> list[np.ndarray]:
    """STFT frames of a voiced, gated harmonic signal in noise, framed as the app frames audio,
    plus random spectra: the recurrent state sees speech onsets, silence and extremes."""
    sr, win_len, hop = 48_000, 1024, 512
    rng = np.random.default_rng(0)
    t = np.arange(sr * 4) / sr
    f0 = 140 + 30 * np.sin(2 * np.pi * 0.7 * t)
    voice = sum(np.sin(2 * np.pi * k * np.cumsum(f0) / sr) / k for k in range(1, 20))
    audio = 0.1 * voice * (np.sin(2 * np.pi * 1.3 * t) > 0) + 0.03 * rng.standard_normal(len(t))
    window = np.hanning(win_len + 1)[:-1]  # torch.hann_window(..., periodic=True)
    frames = []
    cache = np.zeros(win_len - hop, dtype=np.float32)
    for start in range(0, len(audio) - hop, hop):
        chunk = audio[start:start + hop].astype(np.float32)
        frame = np.concatenate([cache, chunk])
        cache = frame[-(win_len - hop):]
        spec = np.fft.rfft(frame * window)
        frames.append(np.stack([spec.real, spec.imag], -1).astype(np.float32)[None, :, None, :])
    frames += [(rng.standard_normal((1, bins, 1, 2)) * 3).astype(np.float32) for _ in range(110)]
    return frames


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        src = checkout_upstream(workdir)
        checkpoint = download_checkpoint(workdir)

        model = load_model(src, checkpoint)
        num_blocks = MODEL_KWARGS["rnnformer_kwargs"]["num_blocks"]
        rf_freq = MODEL_KWARGS["rnnformer_kwargs"]["freq"]
        rf_channels = MODEL_KWARGS["rnnformer_kwargs"]["channels"]
        bins = MODEL_KWARGS["n_fft"] // 2 + 1
        state_size = num_blocks * rf_freq * rf_channels

        reference = Wrapper(load_model(src, checkpoint), num_blocks, rf_freq, rf_channels).eval()
        wrapper = Wrapper(model, num_blocks, rf_freq, rf_channels).eval()

        example = (torch.randn(1, bins, 1, 2), torch.zeros(state_size))
        with torch.no_grad():
            traced = torch.jit.trace(wrapper, example)

        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="spec", shape=(1, bins, 1, 2), dtype=np.float32),
                ct.TensorType(name="state_in", shape=(state_size,), dtype=np.float32),
            ],
            outputs=[
                ct.TensorType(name="spec_e", dtype=np.float32),
                ct.TensorType(name="state_out", dtype=np.float32),
            ],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT32,
            minimum_deployment_target=ct.target.macOS15,
        )
        mlmodel.author = "aask1357 FastEnhancer (MIT); Core ML conversion by scripts/convert-fastenhancer.py"
        mlmodel.license = "MIT"
        mlmodel.short_description = "Causal 48 kHz FastEnhancer-S speech enhancement, one 10.67 ms hop per call"
        meta = mlmodel.user_defined_metadata
        meta["sample_rate"] = "48000"
        meta["n_fft"] = str(MODEL_KWARGS["n_fft"])
        meta["window_length"] = str(MODEL_KWARGS["win_size"])
        meta["hop_length"] = str(MODEL_KWARGS["hop_size"])
        meta["state_size"] = str(state_size)
        meta["state_init"] = ""  # all-zero GRU hidden state; no running norm prefix to carry.
        meta["source_commit"] = FASTENHANCER_COMMIT
        meta["variant"] = VARIANT

        # Parity against the unmodified upstream model, carrying state frame to frame as the app
        # does.
        torch_state = torch.zeros(state_size)
        mlmodel_state = np.zeros(state_size, dtype=np.float32)
        signal = error = worst = 0.0
        frames = parity_frames(bins)
        for spec in frames:
            with torch.no_grad():
                ref, torch_state = reference(torch.from_numpy(spec), torch_state)
            ref = ref.numpy()

            out = mlmodel.predict({"spec": spec, "state_in": mlmodel_state})
            mlmodel_state = out["state_out"].astype(np.float32)
            signal += float((ref ** 2).sum())
            error += float(((ref - out["spec_e"]) ** 2).sum())
            worst = max(worst, float(np.abs(out["spec_e"] - ref).max()) / (float(np.abs(ref).max()) or 1.0))
        snr = 10 * math.log10(signal / max(error, 1e-30))
        print(f"Core ML vs upstream PyTorch over {len(frames)} frames: SNR {snr:.1f} dB, worst frame {worst:.2e}")
        if worst > 1e-3:
            raise SystemExit("Core ML output diverges from PyTorch")

        package = workdir / "FastEnhancer_S_48k.mlpackage"
        mlmodel.save(str(package))
        compiled = workdir / "compiled"
        compiled.mkdir()
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(compiled)], check=True,
                       stdout=subprocess.DEVNULL)
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        shutil.copytree(compiled / "FastEnhancer_S_48k.mlmodelc", OUTPUT)
        print(f"wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
