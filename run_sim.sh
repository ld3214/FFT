#!/bin/bash
# ----------------------------------------------------------------
#  FFT simulation run script
#  Uses Icarus Verilog + behavioural SRAM models (sim/ directory)
# ----------------------------------------------------------------
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ_DIR"

echo "=== [1/4] Generating golden reference (fft_ref_bitrev.txt) ==="
# The Python script expects the file paths relative to the parent of FFT_input
# fft_verify.py reads from "FFT/FFT_input/..." so we fix the path
python3 -c "
import numpy as np, os
N, WIDTH = 1024, 16
x = np.zeros(N, dtype=np.int64)
with open('FFT_input/input_q1_15_v3.hex') as f:
    for i in range(N):
        line = f.readline().strip()
        if line:
            val = int(line, 16)
            if val >= 0x8000: val -= 0x10000
            x[i] = val

tw_re = np.zeros(N//2, dtype=np.int64)
tw_im = np.zeros(N//2, dtype=np.int64)
with open('FFT_input/twiddle_q15.hex') as f:
    for i in range(N//2):
        line = f.readline().strip()
        if line:
            v = int(line, 16)
            r = (v >> 16) & 0xFFFF
            j = v & 0xFFFF
            if r >= 0x8000: r -= 0x10000
            if j >= 0x8000: j -= 0x10000
            tw_re[i], tw_im[i] = r, j

def asr(val, s):
    if val >= 0: return val >> s
    else: return -((-val-1)>>s)-1

def trunc16(v):
    v = v & 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v

re, im = x.copy(), np.zeros(N, dtype=np.int64)
for stage in range(10):
    s_inv = 9 - stage; dist = 1 << s_inv; lm = dist - 1
    nr, ni = re.copy(), im.copy()
    for bf in range(N//2):
        a = ((bf & ~lm) << 1) | (bf & lm)
        b = a | dist
        w = (bf & lm) << stage
        y0r = asr(int(re[a])+int(re[b]),1)
        y0i = asr(int(im[a])+int(im[b]),1)
        y1r = asr(int(re[a])-int(re[b]),1)
        y1i = asr(int(im[a])-int(im[b]),1)
        sh = WIDTH-1
        mr = trunc16(asr(int(y1r)*int(tw_re[w]),sh) - asr(int(y1i)*int(tw_im[w]),sh))
        mi = trunc16(asr(int(y1r)*int(tw_im[w]),sh) + asr(int(y1i)*int(tw_re[w]),sh))
        nr[a],ni[a] = y0r,y0i
        nr[b],ni[b] = mr,mi
    re, im = nr, ni

with open('fft_ref_bitrev.txt','w') as f:
    for i in range(N):
        f.write(f'{re[i]&0xFFFF:04x}{im[i]&0xFFFF:04x}\n')
print('  -> fft_ref_bitrev.txt generated')
"

echo "=== [2/4] Compiling with Icarus Verilog ==="
iverilog -g2005 -o fft_tb.vvp \
    fft_tb.v \
    fft_top.v \
    fft_ctr.v \
    data_sram_system.v \
    sim/data_sram_wrapper.v \
    sim/tw_sram_wrapper.v \
    butterfly.v \
    mult.v

echo "=== [3/4] Running simulation ==="
vvp fft_tb.vvp

echo "=== [4/4] Done ==="
echo "  Output:  fft_output.txt"
echo "  Golden:  fft_ref_bitrev.txt"
echo "  VCD:     fft_tb.vcd"
