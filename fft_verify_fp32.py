"""
FP32 浮点 FFT golden model
输入：FFT_input/input_fp32_v3.hex（每行为32位float，10240点）
旋转因子：FFT_input/twiddle_fp32.hex（每行为64位：re[31:0], im[31:0]，共512行）
输出：fft_ref_bitrev_fp32.txt, fft_ref_natural_fp32.txt
"""
import numpy as np
import os
import struct

N = 1024
BATCHES = 10

# ---- 读取输入数据（10240点，float32）----
def read_input_fp32(filename):
    x = np.zeros(N * BATCHES, dtype=np.float32)
    with open(filename, 'r') as f:
        for i in range(N * BATCHES):
            line = f.readline()
            if not line:
                break
            val = int(line.strip(), 16)
            x[i] = struct.unpack('!f', val.to_bytes(4, 'big'))[0]
    return x

# ---- 读取旋转因子（512行，每行re,im各float32）----
def read_twiddle_fp32(filename):
    tw_re = np.zeros(N // 2, dtype=np.float32)
    tw_im = np.zeros(N // 2, dtype=np.float32)
    with open(filename, 'r') as f:
        for i in range(N // 2):
            line = f.readline()
            if not line:
                break
            val = int(line.strip(), 16)
            re = (val >> 32) & 0xFFFFFFFF
            im = val & 0xFFFFFFFF
            tw_re[i] = struct.unpack('!f', re.to_bytes(4, 'big'))[0]
            tw_im[i] = struct.unpack('!f', im.to_bytes(4, 'big'))[0]
    return tw_re, tw_im

# ---- 比特反转 ----
def bit_reverse(k, bits):
    result = 0
    for b in range(bits):
        if k & (1 << b):
            result |= 1 << (bits - 1 - b)
    return result

# ---- 浮点DIF FFT ----
def run_fft_fp32(x, tw_re, tw_im):
    num_stages = int(np.log2(N))
    re = x.copy()
    im = np.zeros(N, dtype=np.float32)
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
            # butterfly
            y0_re = 0.5 * (re[a_idx] + re[b_idx])
            y0_im = 0.5 * (im[a_idx] + im[b_idx])
            y1_re = 0.5 * (re[a_idx] - re[b_idx])
            y1_im = 0.5 * (im[a_idx] - im[b_idx])
            # twiddle
            m_re = y1_re * tw_re[w_idx] - y1_im * tw_im[w_idx]
            m_im = y1_re * tw_im[w_idx] + y1_im * tw_re[w_idx]
            new_re[a_idx] = y0_re
            new_im[a_idx] = y0_im
            new_re[b_idx] = m_re
            new_im[b_idx] = m_im
        re = new_re
        im = new_im
    # 比特反转重排
    nat_re = np.zeros(N, dtype=np.float32)
    nat_im = np.zeros(N, dtype=np.float32)
    for i in range(N):
        j = bit_reverse(i, num_stages)
        nat_re[j] = re[i]
        nat_im[j] = im[i]
    return re, im, nat_re, nat_im

if __name__ == "__main__":
    input_file = os.path.join("FFT_input", "input_fp32_v3.hex")
    tw_file = os.path.join("FFT_input", "twiddle_fp32.hex")
    if not os.path.exists(input_file) or not os.path.exists(tw_file):
        print("[Error] input_fp32_v3.hex or twiddle_fp32.hex not found.")
        exit(1)
    x_all = read_input_fp32(input_file)
    tw_re, tw_im = read_twiddle_fp32(tw_file)
    bitrev_file = "fft_ref_bitrev_fp32.txt"
    nat_file = "fft_ref_natural_fp32.txt"
    with open(bitrev_file, "w") as f_bitrev, open(nat_file, "w") as f_nat:
        for batch_idx in range(BATCHES):
            x = x_all[batch_idx*N:(batch_idx+1)*N]
            re, im, nat_re, nat_im = run_fft_fp32(x, tw_re, tw_im)
            for i in range(N):
                f_bitrev.write(f"{re[i]:.8e} {im[i]:.8e}\n")
            for i in range(N):
                f_nat.write(f"{nat_re[i]:.8e} {nat_im[i]:.8e}\n")
    print(f"[Done] Output: {bitrev_file}, {nat_file}")
