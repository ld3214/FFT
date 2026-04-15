"""
FFT 验证脚本
用定点运算模拟硬件 DIF FFT, 与硬件输出对比
"""
import numpy as np
import os

N = 1024
WIDTH = 16

# ---- 读取输入数据 (16-bit hex, 只有实部) ----
x = np.zeros(N, dtype=np.int64)

def read_input_file(input_file, offset=0):
    x = np.zeros(N, dtype=np.int64)
    with open(input_file, "r") as f:
        # 跳过offset行
        for _ in range(offset):
            f.readline()
        for i in range(N):
            line = f.readline().strip()
            if line:
                val = int(line, 16)
                if val >= 0x8000:
                    val -= 0x10000
                x[i] = val
    return x

# ---- 读取旋转因子 ----
tw_file = os.path.join("FFT_input", "twiddle_q15.hex")
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


def bit_reverse(k, bits):
    result = 0
    for b in range(bits):
        if k & (1 << b):
            result |= 1 << (bits - 1 - b)
    return result

def run_fft(x, tw_re, tw_im):
    num_stages = int(np.log2(N))
    re = x.copy()
    im = np.zeros(N, dtype=np.int64)

    # print(f"\nRunning {N}-point fixed-point DIF FFT ({num_stages} stages)...")

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

    nat_re = np.zeros(N, dtype=np.int64)
    nat_im = np.zeros(N, dtype=np.int64)
    for i in range(N):
        j = bit_reverse(i, num_stages)
        nat_re[j] = re[i]
        nat_im[j] = im[i]

    # 返回bitrev和natural顺序结果
    return re, im, nat_re, nat_im


if __name__ == "__main__":
    input_file = os.path.join("FFT_input", "input_q1_15_v3.hex")
    if not os.path.exists(input_file):
        print(f"[Error] {input_file} not found.")
    else:
        # 打开输出文件，准备追加写入
        bitrev_file = "fft_ref_bitrev.txt"
        nat_file = "fft_ref_natural.txt"
        with open(bitrev_file, "w") as f_bitrev, open(nat_file, "w") as f_nat:
            for batch_idx in range(10):
                x = read_input_file(input_file, offset=batch_idx*1024)
                print(f"\n[Batch {batch_idx}] Input x[0:10] = {x[:10]}")
                print(f"[Batch {batch_idx}] Input sum = {np.sum(x)}")
                re, im, nat_re, nat_im = run_fft(x, tw_re, tw_im)
                # 依次写入1024点
                for i in range(N):
                    re_hex = re[i] & 0xFFFF
                    im_hex = im[i] & 0xFFFF
                    f_bitrev.write(f"{re_hex:04x}{im_hex:04x}\n")
                for i in range(N):
                    re_hex = nat_re[i] & 0xFFFF
                    im_hex = nat_im[i] & 0xFFFF
                    f_nat.write(f"{re_hex:04x}{im_hex:04x}\n")
        print(f"\nReference (bit-reversed) -> {bitrev_file}")
        print(f"Reference (natural)      -> {nat_file}")
