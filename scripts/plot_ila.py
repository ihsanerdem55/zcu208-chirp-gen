#!/usr/bin/env python3
"""Decode a full-rate Vivado ILA CSV capture into baseband I/Q plots.

Run: python scripts/plot_ila.py out/chirp.csv
Needs numpy and matplotlib. Input must contain probe0 (128-bit TDATA),
probe1 (pulse gate), probe2 (TVALID), probe3 (TREADY). Signal names are
auto-detected; use --data-column / --gate-column etc. for renamed probes.
"""
import argparse
import csv
import re
from pathlib import Path


def number(text, radix="HEX"):
    text = text.strip().replace("_", "")
    match = re.fullmatch(r"(?:\d+)?'([hHbBdD])([0-9a-fA-F+-]+)", text)
    if match:
        return int(match[2], {"h": 16, "b": 2, "d": 10}[match[1].lower()])
    if text.lower().startswith("0x"):
        return int(text, 16)
    key = radix.strip().upper()
    base = {"HEX": 16, "BIN": 2, "BINARY": 2, "UNSIGNED": 10,
            "SIGNED": 10, "DEC": 10, "DECIMAL": 10}.get(key)
    if base is None:
        raise ValueError(f"Unsupported radix {radix!r}")
    return int(text, base)


def signed16(word):
    word &= 65535
    return word - 65536 if word & 32768 else word


def read_capture(path, columns=None, interleaved=True):
    columns = columns or {}
    with open(path, newline="", encoding="utf-8-sig") as stream:
        rows = list(csv.reader(stream))
    if not rows:
        raise ValueError("Empty capture")
    headers = [c.strip() for c in rows[0]]
    indices = {}
    # The block design probes the chirp_gen_0/mon_* copies of the stream.
    for key, (signals, port) in {
        "data": (("m_axis_tdata", "mon_data"), 0), "gate": (("trig_out", "mon_gate"), 1),
        "valid": (("m_axis_tvalid", "mon_valid"), 2), "ready": (("m_axis_tready", "mon_ready"), 3),
    }.items():
        if columns.get(key):
            matches = [i for i, h in enumerate(headers) if h == columns[key]]
        else:
            matches = [i for i, h in enumerate(headers)
                       if any(s in h.lower() for s in signals)
                       or re.search(rf"(?:^|[/_.])probe{port}(?:$|\[)", h.lower())]
        if len(matches) != 1:
            raise ValueError(f"Cannot uniquely find {key} column; use --{key}-column. Columns: {headers}")
        indices[key] = matches[0]
    # Standard Vivado exports have a second row: Radix - HEX, ... HEX ...
    radices = ["HEX"] * len(headers)
    start = 1
    if len(rows) > 1 and rows[1] and rows[1][0].strip().lower().startswith("radix"):
        radices = rows[1]
        if len(radices) != len(headers):
            raise ValueError("Malformed radix row")
        start = 2
    samples = []
    gates = []
    for rownum, row in enumerate(rows[start:], start + 1):
        if not row or not any(c.strip() for c in row):
            continue
        if len(row) != len(headers):
            raise ValueError(f"Row {rownum}: incorrect column count")
        try:
            values = {key: number(row[i], radices[i]) for key, i in indices.items()}
        except ValueError as exc:
            raise ValueError(f"Row {rownum}: invalid/unknown sample value: {exc}") from exc
        if any(values[k] not in (0, 1) for k in ("gate", "valid", "ready")):
            raise ValueError(f"Row {rownum}: control probes must be one bit")
        # Do not drop rows: that would compress time and fabricate a frequency plot.
        if not values["ready"] or not values["valid"]:
            raise ValueError(f"Row {rownum}: DAC not streaming (TREADY/TVALID low); capture after startup")
        if not -(1 << 127) <= values["data"] < (1 << 128):
            raise ValueError(f"Row {rownum}: TDATA exceeds 128 bits")
        word = values["data"] & ((1 << 128) - 1)
        for lane in range(4):
            ibit = 32 * lane if interleaved else 16 * lane
            qbit = ibit + 16 if interleaved else 16 * (lane + 4)
            samples.append((signed16(word >> ibit), signed16(word >> qbit)))
            gates.append(values["gate"])
    if len(samples) < 8:
        raise ValueError("Need at least two fabric-clock samples")
    return samples, gates


def plot(samples, gates, output, fs_bb, title):
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    iq = np.asarray(samples)
    gate = np.asarray(gates, dtype=bool)
    z = iq[:, 0] + 1j * iq[:, 1]
    t = np.arange(len(z)) / fs_bb * 1e6
    active = gate & (np.abs(z) > 0)
    frequency = np.angle(z[1:] * np.conj(z[:-1])) * fs_bb / (2 * np.pi * 1e6)
    frequency[~(active[1:] & active[:-1])] = np.nan
    fig, axes = plt.subplots(3, 1, figsize=(11, 9))
    axes[0].plot(t, iq[:, 0], lw=0.6, label="I")
    axes[0].plot(t, iq[:, 1], lw=0.6, alpha=0.7, label="Q")
    axes[0].set_ylabel("Signed sample")
    axes[0].legend(loc="upper right")
    axes[1].plot(t, gate.astype(int), color="black")
    axes[1].set_ylabel("Pulse gate")
    axes[1].set_ylim(-0.1, 1.2)
    axes[2].plot(t[1:], frequency, lw=0.8)
    axes[2].set_ylabel("Baseband frequency (MHz)")
    axes[2].set_xlabel("Time in capture (us)")
    for ax in axes:
        ax.grid(alpha=0.25)
    fig.suptitle(title + "\nDigital I/Q before RFDC interpolation and NCO")
    fig.tight_layout()
    Path(output).parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, dpi=150)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fs-bb", type=float, default=737.28e6)
    parser.add_argument("--split", action="store_true", help="legacy RTL experiment packing only")
    for key in ("data", "gate", "valid", "ready"):
        parser.add_argument(f"--{key}-column")
    args = parser.parse_args()
    if not 0 < args.fs_bb < float("inf"):
        parser.error("--fs-bb must be positive and finite")
    try:
        samples, gates = read_capture(args.capture,
            {k: getattr(args, f"{k}_column") for k in ("data", "gate", "valid", "ready")},
            interleaved=not args.split)
        output = args.output or args.capture.with_suffix(".png")
        plot(samples, gates, output, args.fs_bb, "ILA capture: " + args.capture.name)
    except (ValueError, OSError) as exc:
        parser.error(str(exc))
    print(f"Wrote {output}: {len(samples)} complex samples at {args.fs_bb / 1e6:g} MSPS")


if __name__ == "__main__":
    main()
