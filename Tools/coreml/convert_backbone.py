#!/usr/bin/env python3
"""Convert an ESM-2 backbone to a Core ML package for the Neural Engine.

    Tools/coreml/.venv/bin/python Tools/coreml/convert_backbone.py \
        --model esm2_t12_35M_UR50D

Writes:
    Models/<model>.mlpackage        the converted backbone
    Models/<model>.tokeniser.json   the alphabet, so Swift tokenises identically
    Models/<model>.reference.npz    PyTorch reference tensors for parity testing

Design notes that are load-bearing
----------------------------------

**Static shapes.** The Neural Engine will not accept a fully dynamic sequence
length, so the model declares `EnumeratedShapes` over a fixed set of token
counts. A sequence is padded up to the smallest bucket that fits, the padding is
masked, and the output is sliced back. Sequences beyond the largest bucket are
tiled by the Swift side with overlap.

**The padding branch must be baked in.** fair-esm computes
`padding_mask = tokens.eq(padding_idx)` and then does
`if not padding_mask.any(): padding_mask = None`. Under `torch.jit.trace` that
`.any()` collapses to a Python bool and the branch taken during tracing is the
only branch that survives. Tracing with an unpadded example therefore produces a
model that silently ignores padding for every real input, which does not error:
it just attends to pad tokens and returns subtly wrong embeddings for every
sequence shorter than its bucket. The example input here is deliberately padded
so the masked path is the one captured, and `validate_parity.py` checks a padded
sequence specifically.

**Precision.** fp16 throughout. The parity gate decides whether that is
acceptable, rather than the choice being assumed safe.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = ROOT / "Models"

# Must stay in lockstep with ShapeBucket in BoffinML. A bucket that exists in
# one and not the other fails at prediction time, on device.
BUCKETS = [128, 256, 384, 512, 768, 1024]
DEFAULT_BUCKET = 384


class TraceableRotaryEmbedding(nn.Module):
    """A rotary position embedding that survives tracing.

    fair-esm's `RotaryEmbedding` caches its cos and sin tables in Python
    attributes keyed on sequence length:

        if seq_len != self._seq_len_cached or ...:
            self._seq_len_cached = seq_len
            ... recompute ...

    Under `torch.jit.trace` that `if` is evaluated exactly once, so the tables
    become graph CONSTANTS sized for whichever length happened to be traced.
    With `EnumeratedShapes` that is fatal and silent: a 1024-token input would
    be rotated by tables built for 384 positions. `apply_rotary_pos_emb` slices
    with `cos[:, : x.shape[-2], :]`, which on a too-short table simply returns
    what is there, so the failure surfaces as a broadcast error at best and as
    quietly wrong embeddings at worst. It also makes the trace itself
    non-deterministic, which is what torch's own trace check flags.

    This version precomputes the tables once at the maximum bucket length and
    slices them per call. No Python branch, no cache, nothing for the tracer to
    freeze at the wrong size.
    """

    def __init__(self, dim: int, max_sequence_length: int):
        super().__init__()
        inv_freq = 1.0 / (10000 ** (torch.arange(0, dim, 2).float() / dim))
        positions = torch.arange(max_sequence_length).type_as(inv_freq)
        frequencies = torch.einsum("i,j->ij", positions, inv_freq)
        embedding = torch.cat((frequencies, frequencies), dim=-1)
        self.register_buffer("cos_table", embedding.cos()[None, :, :], persistent=False)
        self.register_buffer("sin_table", embedding.sin()[None, :, :], persistent=False)

    def forward(self, q: torch.Tensor, k: torch.Tensor):
        from esm.rotary_embedding import apply_rotary_pos_emb

        length = k.shape[-2]
        cos = self.cos_table[:, :length, :]
        sin = self.sin_table[:, :length, :]
        return apply_rotary_pos_emb(q, cos, sin), apply_rotary_pos_emb(k, cos, sin)


def make_traceable(model: nn.Module, max_sequence_length: int) -> int:
    """Replace every cached rotary embedding with the traceable one.

    Returns how many were replaced, which the caller asserts on: silently
    replacing zero of them would leave the original bug in place while the
    conversion appeared to succeed.
    """
    from esm.rotary_embedding import RotaryEmbedding

    replaced = 0
    for module in model.modules():
        for name, child in list(module.named_children()):
            if isinstance(child, RotaryEmbedding):
                dim = child.inv_freq.shape[0] * 2
                setattr(module, name, TraceableRotaryEmbedding(dim, max_sequence_length))
                replaced += 1
    return replaced


class ESMBackbone(nn.Module):
    """Expose exactly the two tensors the app fans out from.

    Invariant 1 of the build plan: one forward pass, four fan-outs. The hidden
    states drive order and boundaries, the logits drive fitness, and the pooled
    embedding (computed on the Swift side from the hidden states) drives family
    and homolog search. Returning both from one call is what makes that
    invariant real rather than aspirational.
    """

    def __init__(self, model: nn.Module, repr_layer: int):
        super().__init__()
        self.model = model
        self.repr_layer = repr_layer

    def forward(self, tokens: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        out = self.model(tokens, repr_layers=[self.repr_layer], return_contacts=False)
        return out["representations"][self.repr_layer], out["logits"]


def load_model(name: str):
    import esm

    loader = getattr(esm.pretrained, name)
    model, alphabet = loader()
    model.eval()
    for parameter in model.parameters():
        parameter.requires_grad_(False)
    return model, alphabet


def export_tokeniser(alphabet, path: Path) -> dict:
    """Write the alphabet so the Swift tokeniser cannot drift from it.

    A tokeniser mismatch does not crash: it produces confident, wrong
    embeddings, which is the worst failure mode available.
    """
    payload = {
        "tokens": list(alphabet.all_toks),
        "token_to_index": {token: index for index, token in enumerate(alphabet.all_toks)},
        "padding_index": alphabet.padding_idx,
        "cls_index": alphabet.cls_idx,
        "eos_index": alphabet.eos_idx,
        "mask_index": alphabet.mask_idx,
        "unknown_index": alphabet.unk_idx,
        "prepend_bos": alphabet.prepend_bos,
        "append_eos": alphabet.append_eos,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="esm2_t12_35M_UR50D")
    parser.add_argument(
        "--precision", default="fp16", choices=["fp16", "fp32"],
        help="fp16 is the shipping configuration; fp32 is for diagnosing parity failures.")
    args = parser.parse_args()

    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"loading {args.model} ...")
    model, alphabet = load_model(args.model)
    repr_layer = model.num_layers
    print(f"  layers {model.num_layers}, embed dim {model.embed_dim}, "
          f"vocab {len(alphabet.all_toks)}")

    tokeniser = export_tokeniser(alphabet, MODELS_DIR / f"{args.model}.tokeniser.json")
    print(f"  wrote tokeniser ({len(tokeniser['tokens'])} tokens)")

    replaced = make_traceable(model, max(BUCKETS))
    print(f"  replaced {replaced} cached rotary embeddings with traceable ones")
    if replaced == 0:
        raise SystemExit(
            "No RotaryEmbedding modules were found. fair-esm's internals have changed: "
            "verify that position embeddings are still traceable before trusting the "
            "converted model.")

    wrapper = ESMBackbone(model, repr_layer).eval()

    # A DELIBERATELY PADDED example. See the module docstring: tracing without
    # padding bakes in the no-mask branch and silently breaks every real input.
    padding_index = alphabet.padding_idx
    example = torch.full((1, DEFAULT_BUCKET), padding_index, dtype=torch.int64)
    example[0, 0] = alphabet.cls_idx
    real_residues = [alphabet.get_idx(c) for c in "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDK"]
    example[0, 1 : 1 + len(real_residues)] = torch.tensor(real_residues)
    example[0, 1 + len(real_residues)] = alphabet.eos_idx

    assert example.eq(padding_index).any(), "example must contain padding"

    print("tracing ...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)

    print("converting ...")
    enumerated = ct.EnumeratedShapes(
        shapes=[[1, bucket] for bucket in BUCKETS], default=[1, DEFAULT_BUCKET])

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens", shape=enumerated, dtype=np.int32)],
        outputs=[
            ct.TensorType(name="hidden_states", dtype=np.float16),
            ct.TensorType(name="logits", dtype=np.float16),
        ],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16
        if args.precision == "fp16"
        else ct.precision.FLOAT32,
        # Excluding the GPU deliberately. If an operation cannot run on the
        # Neural Engine it falls back to the CPU and the benchmark shows it,
        # rather than quietly landing on the GPU and looking fast while
        # defeating the entire premise of the app.
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.iOS18,
    )

    mlmodel.short_description = (
        f"ESM-2 {args.model} backbone. Outputs per-residue hidden states and "
        f"masked-token logits from one forward pass.")
    mlmodel.input_description["tokens"] = (
        f"Padded token ids, one of {BUCKETS} in length, padding id {padding_index}.")
    mlmodel.output_description["hidden_states"] = (
        f"Per-residue hidden states, ({{1}}, S, {model.embed_dim}).")
    mlmodel.output_description["logits"] = "Per-position vocabulary logits."

    package = MODELS_DIR / f"{args.model}.mlpackage"
    mlmodel.save(str(package))
    print(f"wrote {package.relative_to(ROOT)}")

    # Reference tensors for the parity gate, computed BEFORE conversion so they
    # are genuinely the PyTorch answer rather than a re-derivation of whatever
    # Core ML produced.
    print("computing reference tensors ...")
    references = {}
    with torch.no_grad():
        for bucket in (128, DEFAULT_BUCKET):
            tokens = torch.full((1, bucket), padding_index, dtype=torch.int64)
            tokens[0, 0] = alphabet.cls_idx
            residues = [alphabet.get_idx(c) for c in UBIQUITIN[: bucket - 2]]
            tokens[0, 1 : 1 + len(residues)] = torch.tensor(residues)
            tokens[0, 1 + len(residues)] = alphabet.eos_idx
            hidden, logits = wrapper(tokens)
            references[f"tokens_{bucket}"] = tokens.numpy().astype(np.int32)
            references[f"hidden_{bucket}"] = hidden.numpy().astype(np.float32)
            references[f"logits_{bucket}"] = logits.numpy().astype(np.float32)

    reference_path = MODELS_DIR / f"{args.model}.reference.npz"
    np.savez_compressed(reference_path, **references)
    print(f"wrote {reference_path.relative_to(ROOT)}")

    size_mb = sum(f.stat().st_size for f in package.rglob("*") if f.is_file()) / 1e6
    print(f"\npackage size: {size_mb:.1f} MB")
    return 0


UBIQUITIN = "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"


if __name__ == "__main__":
    raise SystemExit(main())
