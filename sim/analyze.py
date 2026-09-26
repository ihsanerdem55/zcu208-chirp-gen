#!/usr/bin/env python3
"""Check the RTL capture against a bit-exact Python model and plot the results.

Run after the testbench (from the sim/ folder):  python3 analyze.py
Outputs: pass/fail lines on stdout and out/sim_results.png
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from gen_sincos_mem import table  # noqa: E402

LANES = 4
FS_BB = 737.28e6
QW = np.array(table(), dtype=np.int64)
M48 = (1 << 48) - 1

# ------------------------------------------------------------------ model
def sincos(p14):
    """Same folding as sincos_qw_rom.sv. Returns (cos, sin)."""
    i = p14 & 0xFFF
    def look(q):
        a = np.where(q & 1, 0xFFF - i, i)
        v = QW[a]
        return np.where(q & 2, -v, v)
    q = (p14 >> 12) & 3
    return look((q + 1) & 3), look(q)

def scale(x, amp):
    return (x * amp + 16384) >> 15

def model_pulse(f_start, k_rate, phase0, amp, nsamp, n0=0):
    n = np.arange(n0, n0 + nsamp, dtype=object)
    F0 = (f_start << 16)
    K = (k_rate << 8)
    P0 = (phase0 << 16)
    phi = np.array([(P0 + F0 * k + K * (k * (k - 1) // 2)) & M48 for k in n], dtype=np.int64)
    c, s = sincos(phi >> 34)
    return scale(c, amp), scale(s, amp)

# --------------------------------------------------------------- capture
def s16(v):
    v = v & 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def load(fname, interleaved=False):
    I, Q, T = [], [], []
    for line in open(fname):
        h, t = line.split()
        w = int(h, 16)
        for m in range(LANES):
            if interleaved:
                I.append(s16(w >> (32 * m))); Q.append(s16(w >> (32 * m + 16)))
            else:
                I.append(s16(w >> (16 * m))); Q.append(s16(w >> (16 * (m + LANES))))
            T.append(int(t))
    return np.array(I), np.array(Q), np.array(T)

def fword(f):
    return int(round(f / FS_BB * 2**32))

results = []
def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}: {name} {detail}")

# ------------------------------------------------ T1: CW, split packing
I, Q, _ = load("out/cw_split.txt")
fs_word = fword(10e6)
# CW phase runs freely since the parameter load: find the sample offset
ref_i, ref_q = model_pulse(fs_word, 0, 0, 0x7FFF, 20000)
n0 = next(k for k in range(0, 20000 - 64)
          if np.array_equal(ref_i[k:k + 64], I[:64]) and np.array_equal(ref_q[k:k + 64], Q[:64]))
mi, mq = model_pulse(fs_word, 0, 0, 0x7FFF, len(I), n0)
check("CW bit-exact vs model", np.array_equal(mi, I) and np.array_equal(mq, Q), f"({len(I)} samples)")

x = (I + 1j * Q) / 32768.0
N = len(x)
# 4-term Blackman-Harris window (-92 dB sidelobes): the tone is not bin-centred
nn = np.arange(N)
win = (0.35875 - 0.48829*np.cos(2*np.pi*nn/(N-1)) + 0.14128*np.cos(4*np.pi*nn/(N-1))
       - 0.01168*np.cos(6*np.pi*nn/(N-1)))
X = np.fft.fftshift(np.fft.fft(x * win)) / np.sum(win)
f_axis = np.fft.fftshift(np.fft.fftfreq(N, 1 / FS_BB))
P = 20 * np.log10(np.abs(X) + 1e-15)
kpk = np.argmax(P)
mask = np.abs(np.arange(N) - kpk) > 12         # exclude the main lobe
sfdr = P[kpk] - P[mask].max()
f_peak = f_axis[kpk]
check("CW tone frequency", abs(f_peak - 10e6) < FS_BB / N, f"(peak at {f_peak/1e6:.3f} MHz)")
check("CW SFDR > 75 dBc", sfdr > 75, f"(SFDR = {sfdr:.1f} dBc)")
image = P[np.argmin(np.abs(f_axis + 10e6))] - P[kpk]
check("CW image (-10 MHz) < -75 dBc", image < -75, f"({image:.1f} dBc)")

# -------------------------------------------- T2: pulsed chirp, split
Ic, Qc, Tc = load("out/chirp_split.txt")
PW, PRI = 368, 500
Ns = PW * LANES
bw = 400e6
k_rate = int(round((bw / FS_BB * 2**32) / Ns * 256))
rise = np.flatnonzero((Tc[1:] == 1) & (Tc[:-1] == 0)) + 1
st = rise[0]
mi, mq = model_pulse(fword(-200e6), k_rate, 0, 0x7FFF, Ns)
check("chirp pulse bit-exact vs model", np.array_equal(mi, Ic[st:st + Ns]) and np.array_equal(mq, Qc[st:st + Ns]),
      f"({Ns} samples)")
gate_len = np.sum(Tc[st:st + PRI * LANES])
check("pulse width", gate_len == Ns, f"({gate_len} samples = {gate_len/FS_BB*1e6:.3f} us)")
check("PRI", len(rise) < 2 or rise[1] - rise[0] == PRI * LANES,
      f"({(rise[1]-rise[0]) if len(rise) > 1 else 'n/a'} samples)")
off = Ic[st + Ns:st + PRI * LANES]
check("zero output between pulses", np.all(off == 0) and np.all(Qc[st + Ns:st + PRI * LANES] == 0))

# instantaneous frequency vs ideal line
z = Ic[st:st + Ns] + 1j * Qc[st:st + Ns]
finst = np.angle(z[1:] * np.conj(z[:-1])) / (2 * np.pi) * FS_BB
t = np.arange(1, Ns) / FS_BB
# phi[n] - phi[n-1] = F0 + K*(n-1)  ->  exact frequency of each sample-to-sample step
f_ideal = (fword(-200e6) + (k_rate / 256) * np.arange(0, Ns - 1)) * FS_BB / 2**32
ferr = finst - f_ideal
# the estimator sees the 14-bit phase quantisation (+-1/16384 cycle per sample => ~+-45 kHz)
check("chirp inst. frequency error", np.max(np.abs(ferr)) < 100e3 and abs(np.mean(ferr)) < 1e3,
      f"(max {np.max(np.abs(ferr))/1e3:.1f} kHz, mean {np.mean(ferr):.1f} Hz)")
slope = (k_rate / 256) * FS_BB**2 / 2**32
print(f"INFO: chirp slope {slope/1e12:.4f} MHz/us, sweep {slope*Ns/FS_BB/1e6:.2f} MHz in {Ns/FS_BB*1e6:.3f} us")

# --------------------------------- T3: interleaved packing + I/Q swap
Ii, Qi, _ = load("out/cw_ilv_swap.txt", interleaved=True)
xi = Ii + 1j * Qi
Xi = np.fft.fftshift(np.fft.fft(xi * np.blackman(len(xi))))
fi = np.fft.fftshift(np.fft.fftfreq(len(xi), 1 / FS_BB))
fpk = fi[np.argmax(np.abs(Xi))]
# T3 keeps FSTART = -200 MHz from T2; swapping I/Q mirrors it to +200 MHz
check("interleaved packing + I/Q swap mirrors -200 MHz to +200 MHz", abs(fpk - 200e6) < FS_BB / len(xi),
      f"(peak at {fpk/1e6:.3f} MHz)")

# ------------------------------------------------------------- plots
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(3, 1, figsize=(10, 11))
    ax[0].plot(f_axis / 1e6, P - P[kpk], lw=0.8)
    ax[0].set_title(f"CW +10 MHz, full scale: SFDR {sfdr:.1f} dBc (baseband, before DAC)")
    ax[0].set_xlabel("Baseband frequency (MHz)"); ax[0].set_ylabel("dBc"); ax[0].set_ylim(-140, 5)
    ax[0].grid(alpha=0.3)
    tt = np.arange(len(Ic)) / FS_BB * 1e6
    ax[1].plot(tt, Ic, lw=0.5, label="I"); ax[1].plot(tt, Qc, lw=0.5, label="Q", alpha=0.7)
    ax[1].plot(tt, Tc * 36000, "k", lw=1, label="trig_out")
    ax[1].set_title("Pulsed LFM: PW 2.0 us, PRI 2.71 us, -200 to +200 MHz")
    ax[1].set_xlabel("Time (us)"); ax[1].legend(loc="upper right"); ax[1].grid(alpha=0.3)
    ax[2].plot(t * 1e6, finst / 1e6, lw=0.8, label="RTL instantaneous frequency")
    ax[2].plot(t * 1e6, f_ideal / 1e6, "--", lw=1, label="ideal")
    ax[2].set_xlabel("Time from pulse start (us)"); ax[2].set_ylabel("MHz (baseband)")
    ax[2].set_title("Chirp frequency vs time (add the NCO frequency for RF)")
    ax[2].legend(); ax[2].grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig("out/sim_results.png", dpi=110)
    print("INFO: wrote out/sim_results.png")
except ImportError:
    pass

print(f"SUMMARY: {sum(results)}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)
