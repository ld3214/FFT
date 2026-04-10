"""
FFT 验证脚本
用定点运算模拟硬件 DIF FFT, 与硬件输出对比
"""
import numpy as np
import os

N = 1024
WIDTH = 16

# ---- 读取输入数据 (16-bit hex, 只有实部) ----
input_file = os.path.join("FFT", "FFT_input", "input_q1_15_v3.hex")
x = np.zeros(N, dtype=np.int64)
with open(input_file, "r") as f:
    for i in range(N):
        line = f.readline().strip()
        if line:
            val = int(line, 16)
            if val >= 0x8000:
                val -= 0x10000
            x[i] = val

print(f"Input x[0:10] = {x[:10]}")
print(f"Input sum = {np.sum(x)}")

# ---- 读取旋转因子 ----
tw_file = os.path.join("FFT", "FFT_input", "twiddle_q15.hex")
tw_re = np.zeros(N // 2, dtype=np.int64)
tw_im = np.zeros(N // 2, dtype=np.int64)
with open(tw_file, "r") as f:
    for i in range(N // 2):
        line = f.readline().strip()
        if line:
            val32 = int(line, 16)
            re_raw = (val32 >> 16) & 0xFFFF
            im_raw = val32 & 0xFFFF
            if re_raw >= 0x8000: re_raw -= 0x10000
            if im_raw >= 0x8000: im_raw -= 0x10000
            tw_re[i] = re_raw
            tw_im[i] = im_raw

print(f"W[0] = {tw_re[0]} + {tw_im[0]}j  (expect ~32767 + 0j)")
print(f"W[1] = {tw_re[1]} + {tw_im[1]}j  (expect ~32767 - 201j)")

# ---- 定点 DIF FFT (精确模拟硬件行为) ----
def asr(val, shift):
    """Arithmetic right shift (Python int, preserves sign)"""
    if val >= 0:
        return val >> shift
    else:
        return -((-val) >> shift) if ((-val) >> shift) << shift == -val else -((-val - 1) >> shift) - 1

def trunc16(val):
    """Truncate to signed 16-bit"""
    val = val & 0xFFFF
    if val >= 0x8000:
        val -= 0x10000
    return val

def fixed_butterfly(a_re, a_im, b_re, b_im):
    y0_re = asr(int(a_re) + int(b_re), 1)
    y0_im = asr(int(a_im) + int(b_im), 1)
    y1_re = asr(int(a_re) - int(b_re), 1)
    y1_im = asr(int(a_im) - int(b_im), 1)
    return y0_re, y0_im, y1_re, y1_im

def fixed_multiply(a_re, a_im, b_re, b_im):
    arbr = int(a_re) * int(b_re)
    arbi = int(a_re) * int(b_im)
    aibr = int(a_im) * int(b_re)
    aibi = int(a_im) * int(b_im)
    shift = WIDTH - 1  # 15
    sc_arbr = asr(arbr, shift)
    sc_arbi = asr(arbi, shift)
    sc_aibr = asr(aibr, shift)
    sc_aibi = asr(aibi, shift)
    m_re = trunc16(sc_arbr - sc_aibi)
    m_im = trunc16(sc_arbi + sc_aibr)
    return m_re, m_im

num_stages = int(np.log2(N))
re = x.copy()
im = np.zeros(N, dtype=np.int64)

print(f"\nRunning {N}-point fixed-point DIF FFT ({num_stages} stages) ...")

for stage in range(num_stages):
    s_inv = num_stages - 1 - stage
    dist = 1 << s_inv
    lower_mask = dist - 1

    new_re = re.copy()
    new_im = im.copy()

    for bf in range(N // 2):
        a_idx = ((bf & ~lower_mask) << 1) | (bf & lower_mask)
        b_idx = a_idx | dist
        w_idx = (bf & lower_mask) << stage

        y0_re, y0_im, y1_re, y1_im = fixed_butterfly(
            re[a_idx], im[a_idx], re[b_idx], im[b_idx])

        m_re, m_im = fixed_multiply(y1_re, y1_im, tw_re[w_idx], tw_im[w_idx])

        new_re[a_idx] = y0_re
        new_im[a_idx] = y0_im
        new_re[b_idx] = m_re
        new_im[b_idx] = m_im

    re = new_re
    im = new_im

# ---- 比特反转重排 ----
def bit_reverse(k, bits):
    result = 0
    for b in range(bits):
        if k & (1 << b):
            result |= 1 << (bits - 1 - b)
    return result

nat_re = np.zeros(N, dtype=np.int64)
nat_im = np.zeros(N, dtype=np.int64)
for i in range(N):
    j = bit_reverse(i, num_stages)
    nat_re[j] = re[i]
    nat_im[j] = im[i]

# ---- 输出参考结果 ----
print("\n===== 比特反转顺序 (对应 SRAM 地址顺序, 前 32) =====")
print(f"{'Addr':>5} {'Re':>8} {'Im':>8}  Hex(re,im)")
for i in range(32):
    re_hex = re[i] & 0xFFFF
    im_hex = im[i] & 0xFFFF
    print(f"  [{i:4d}] {re[i]:8d} {im[i]:8d}  {re_hex:04x}{im_hex:04x}")

print("\n===== 自然顺序 (比特反转后, 前 32) =====")
print(f"{'Bin':>5} {'Re':>8} {'Im':>8}  Hex(re,im)")
for i in range(32):
    re_hex = nat_re[i] & 0xFFFF
    im_hex = nat_im[i] & 0xFFFF
    print(f"X[{i:4d}] {nat_re[i]:8d} {nat_im[i]:8d}  {re_hex:04x}{im_hex:04x}")

# 保存比特反转顺序 (与硬件 SRAM 直接输出对比)
with open("fft_ref_bitrev.txt", "w") as f:
    for i in range(N):
        re_hex = re[i] & 0xFFFF
        im_hex = im[i] & 0xFFFF
        f.write(f"{re_hex:04x}{im_hex:04x}\n")
print("\nReference (bit-reversed) -> fft_ref_bitrev.txt")

# 保存自然顺序
with open("fft_ref_natural.txt", "w") as f:
    for i in range(N):
        re_hex = nat_re[i] & 0xFFFF
        im_hex = nat_im[i] & 0xFFFF
        f.write(f"{re_hex:04x}{im_hex:04x}\n")
print("Reference (natural)      -> fft_ref_natural.txt")
