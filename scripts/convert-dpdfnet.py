#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.*"
# dependencies = [
#   "torch==2.7.0",
#   "coremltools==9.0",
#   "numpy<2.3",
#   "huggingface_hub>=0.30",
#   "scikit-learn<1.6",
#   "einops==0.8.1",
#   "scipy>=1.16",
#   "librosa==0.11.0",
# ]
# ///
"""Convert CEVA's DPDFNet2 48 kHz streaming model to the Core ML bundle the app ships.

Reproduces App/Loopbacker/Resources/DPDFNet2_48k.mlmodelc from pinned upstream sources:

    scripts/convert-dpdfnet.py            # writes App/Loopbacker/Resources/DPDFNet2_48k.mlmodelc

The model consumes one 20 ms STFT frame (481 bins, real/imag) plus a flat recurrent state and
returns the enhanced frame plus the next state. STFT/ISTFT and overlap-add live in Swift
(NoiseSuppressor.swift). The initial state is stored in the model's metadata so the app needs
no side files.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DPDFNET_REPO = "https://github.com/ceva-ip/DPDFNet"
DPDFNET_COMMIT = "9bd9844a227bb6aa57e55588d8d0e961fcff1c46"
HF_REPO = "Ceva-IP/DPDFNet"
HF_REVISION = "dd6818d00f50c836fed43a6243ebe49116de5964"
CHECKPOINT = "checkpoints/dpdfnet2_48khz_hr.pth"

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "App/Loopbacker/Resources/DPDFNet2_48k.mlmodelc"


def checkout_upstream(workdir: Path) -> Path:
    src = workdir / "DPDFNet"
    subprocess.run(["git", "clone", "--quiet", DPDFNET_REPO, str(src)], check=True)
    subprocess.run(["git", "-C", str(src), "checkout", "--quiet", DPDFNET_COMMIT], check=True)
    return src


def register_unsafe_chunk() -> None:
    """coremltools 9 has no converter for aten::unsafe_chunk (emitted by the traced GRU cells).
    It is aten::chunk without the aliasing guarantee, so lower it to a static split."""
    import math

    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs
    from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op

    @register_torch_op
    def unsafe_chunk(context, node):
        x, chunks, dim = _get_inputs(context, node, expected=3)
        axis = int(dim.val)
        total = x.shape[axis]
        size = math.ceil(total / int(chunks.val))
        sizes = [size] * (total // size) + ([total % size] if total % size else [])
        context.add(mb.split(x=x, split_sizes=sizes, axis=axis, name=node.name), torch_name=node.name)


def main() -> None:
    import coremltools as ct
    import numpy as np
    import torch
    from huggingface_hub import hf_hub_download

    register_unsafe_chunk()

    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        src = checkout_upstream(workdir)
        sys.path.insert(0, str(src))
        from onnx_model.dpdfnet_48khz_hr import DPDFNet48HR, correct_state_dict
        from onnx_model.layers import convert_grouped_linear_to_einsum

        # Same hyperparameters as upstream onnx_model/export_dpdfnet_48khz_hr_to_onnx.py.
        model = DPDFNet48HR(
            conv_kernel_inp=(3, 3),
            conv_ch=64,
            enc_gru_dim=256,
            erb_dec_gru_dim=256,
            df_dec_gru_dim=256,
            enc_lin_groups=32,
            lin_groups=16,
            upsample_conv_type="subpixel",
            group_linear_type="loop",
            point_wise_type="cnn",
            separable_first_conv=True,
            dprnn_num_blocks=2,
        )
        ckpt = hf_hub_download(HF_REPO, CHECKPOINT, revision=HF_REVISION)
        model.load_state_dict(correct_state_dict(torch.load(ckpt, map_location="cpu", weights_only=True)), strict=True)
        convert_grouped_linear_to_einsum(model)
        # Upstream registers the norm variance as torch.full(..., 40 ** 2), an int64 buffer.
        # PyTorch promotes it at sqrt; Core ML rejects sqrt on ints, so make it float up front.
        for module in model.modules():
            if isinstance(getattr(module, "var0", None), torch.Tensor):
                module.var0 = module.var0.float()
        model.eval()

        wnorm = float(model.wnorm)

        class Wrapper(torch.nn.Module):
            """Folds the STFT window normalisation in, matching the upstream ONNX wrapper."""

            def __init__(self) -> None:
                super().__init__()
                self.model = model

            def forward(self, spec: torch.Tensor, state_in: torch.Tensor):
                spec_e, state_out = self.model(spec * wnorm, state_in)
                return spec_e * (1.0 / wnorm), state_out

        wrapper = Wrapper().eval()
        state_size = model.state_size()
        bins = model.freq_bins
        init_state = model.initial_state(dtype=torch.float32)
        norm_size = model.erb_norm.state_size() + model.spec_norm.state_size()
        assert torch.count_nonzero(init_state[norm_size:]) == 0, "only the norm prefix may be non-zero"

        example = (torch.randn(1, 1, bins, 2), init_state.clone())
        with torch.no_grad():
            traced = torch.jit.trace(wrapper, example)

        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="spec", shape=(1, 1, bins, 2), dtype=np.float32),
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
        mlmodel.author = "CEVA DPDFNet (Apache-2.0); Core ML conversion by scripts/convert-dpdfnet.py"
        mlmodel.license = "Apache-2.0"
        mlmodel.short_description = "Causal 48 kHz DPDFNet2 speech enhancement, one 10 ms hop per call"
        meta = mlmodel.user_defined_metadata
        meta["sample_rate"] = "48000"
        meta["window_length"] = str(model.stft.win_len)
        meta["hop_length"] = str(model.stft.hop)
        meta["state_size"] = str(state_size)
        meta["state_init"] = ",".join(format(float(v), ".9g") for v in init_state[:norm_size].numpy())
        meta["source_commit"] = DPDFNET_COMMIT
        meta["weights_revision"] = HF_REVISION

        # Parity: run 300 consecutive frames through both, carrying state, as the app does.
        rng = np.random.default_rng(0)
        torch_state = init_state.clone()
        coreml_state = init_state.numpy().copy()
        worst = 0.0
        for _ in range(300):
            spec = (rng.standard_normal((1, 1, bins, 2)) * 3).astype(np.float32)
            with torch.no_grad():
                ref, torch_state = wrapper(torch.from_numpy(spec), torch_state)
            out = mlmodel.predict({"spec": spec, "state_in": coreml_state})
            coreml_state = out["state_out"].astype(np.float32)
            scale = float(np.abs(ref.numpy()).max()) or 1.0
            worst = max(worst, float(np.abs(out["spec_e"] - ref.numpy()).max()) / scale)
        print(f"max relative deviation vs PyTorch over 300 frames: {worst:.2e}")
        if worst > 1e-3:
            raise SystemExit("Core ML output diverges from PyTorch")

        package = workdir / "DPDFNet2_48k.mlpackage"
        mlmodel.save(str(package))
        compiled = workdir / "compiled"
        compiled.mkdir()
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(compiled)], check=True,
                       stdout=subprocess.DEVNULL)
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        shutil.copytree(compiled / "DPDFNet2_48k.mlmodelc", OUTPUT)
        print(f"wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
