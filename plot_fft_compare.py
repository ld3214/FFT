
import os
import numpy as np
import matplotlib.pyplot as plt


# 自动识别格式的读取函数
def read_complex_auto(filename):
    data = []
    is_fixed = None
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) == 2:
                try:
                    re = float(parts[0])
                    im = float(parts[1])
                    data.append(complex(re, im))
                    if is_fixed is None:
                        is_fixed = False
                    continue
                except ValueError:
                    pass
            if len(line) == 8 or len(line) == 4:
                if len(line) == 8:
                    re_hex = line[:4]
                    im_hex = line[4:]
                else:
                    re_hex = line[:4]
                    im_hex = '0000'
                re = int(re_hex, 16)
                im = int(im_hex, 16)
                if re >= 0x8000:
                    re -= 0x10000
                if im >= 0x8000:
                    im -= 0x10000
                # Q1.15缩放
                data.append(complex(re / 32768.0, im / 32768.0))
                if is_fixed is None:
                    is_fixed = True
    return np.array(data)


# 读取数据
file1 = 'fft_ref_natural.txt'
file2 = 'fft_ref_natural_fp32.txt'

data1 = read_complex_auto(file1)
data2 = read_complex_auto(file2)

# 计算幅度谱和相位谱
mag1 = np.abs(data1)
mag2 = np.abs(data2)
phase1 = np.angle(data1)
phase2 = np.angle(data2)


N = 1024
num_groups = len(mag1) // N
output_dir = 'output_plots'
os.makedirs(output_dir, exist_ok=True)

for i in range(num_groups):
    start = i * N
    end = (i + 1) * N
    # 幅度对比图
    plt.figure(figsize=(12,5))
    plt.plot(mag1[start:end], label='Fixed-point', color='b')
    plt.plot(mag2[start:end], label='FP32', color='r', alpha=0.7)
    plt.title(f'FFT Output Magnitude Spectrum (Group {i+1})')
    plt.xlabel('Bin')
    plt.ylabel('Magnitude')
    plt.legend()
    plt.grid(True)
    plt.tight_layout()
    mag_path = os.path.join(output_dir, f'magnitude_{i+1}.png')
    plt.savefig(mag_path)
    plt.close()

    # 相位对比图
    plt.figure(figsize=(12,5))
    plt.plot(phase1[start:end], label='Fixed-point', color='b')
    plt.plot(phase2[start:end], label='FP32', color='r', alpha=0.7)
    plt.title(f'FFT Output Phase Spectrum (Group {i+1})')
    plt.xlabel('Bin')
    plt.ylabel('Phase (radians)')
    plt.legend()
    plt.grid(True)
    plt.tight_layout()
    phase_path = os.path.join(output_dir, f'phase_{i+1}.png')
    plt.savefig(phase_path)
    plt.close()
