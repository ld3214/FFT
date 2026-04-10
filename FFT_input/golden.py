import os

# ==========================================
# 基础定点与 Hex 转换函数
# ==========================================
def hex_to_int16(hex_str):
    """将16位16进制字符串转换为有符号整数"""
    val = int(hex_str, 16)
    if val >= 0x8000:
        val -= 0x10000
    return val

def int16_to_hex(val):
    """将有符号整数转换为16位16进制字符串"""
    val = val & 0xFFFF
    return f"{val:04X}"

def read_twiddles(filename):
    """
    读取旋转因子文件。
    根据提供的片段 (如 7FFF0000)，假定格式为 32-bit: [高16位 实部][低16位 虚部]
    """
    tw_r, tw_i = [], []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            r_hex = line[0:4]
            i_hex = line[4:8]
            tw_r.append(hex_to_int16(r_hex))
            tw_i.append(hex_to_int16(i_hex))
    return tw_r, tw_i

def read_input(filename):
    """读取 Q15 输入数据"""
    data = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            data.append(hex_to_int16(line))
    return data

def bit_reverse(val, n_bits):
    """位反转函数"""
    res = 0
    for _ in range(n_bits):
        res = (res << 1) | (val & 1)
        val >>= 1
    return res

# ==========================================
# 核心算术：模拟 DSP 行为
# ==========================================
def q15_complex_mul(dr, di, tr, ti):
    """
    Q15 复数乘法
    数学公式: (dr + j*di) * (tr + j*ti)
    硬件实现通常是先进行全精度乘法，相加减后再移位。
    """
    prod_r = (dr * tr) - (di * ti)
    prod_i = (dr * ti) + (di * tr)
    
    # 算术右移 15 位 (模拟 Verilog 的 '>>> 15')
    # 注意：如果你的 RTL 加了 1<<14 进行四舍五入(Rounding)，请改为:
    # res_r = (prod_r + 16384) >> 15
    res_r = prod_r >> 15
    res_i = prod_i >> 15
    
    # 防止极端情况溢出，钳位在 16-bit signed 范围内
    res_r = max(-32768, min(32767, res_r))
    res_i = max(-32768, min(32767, res_i))
    
    return res_r, res_i

def radix2_dit_fft_bittrue(x_r, x_i, tw_r, tw_i, n_points=1024):
    """
    标准的 Radix-2 时间抽取 (DIT) FFT
    完全定点化，每级包含 >> 1 以防溢出
    """
    n_bits = 10 # log2(1024)
    
    # 1. 位反转 (Bit-reversal)
    X_r = [0] * n_points
    X_i = [0] * n_points
    for i in range(n_points):
        rev_i = bit_reverse(i, n_bits)
        X_r[rev_i] = x_r[i]
        X_i[rev_i] = x_i[i]
        
    # 2. 蝶形运算 (10 个 Stage)
    # m 代表当前级参与一次完整蝶形的点数跨度 (2, 4, 8 ... 1024)
    for stage in range(1, n_bits + 1):
        m = 1 << stage
        half_m = m >> 1
        # stride 控制旋转因子的步进。N=1024时，第一级stride=512，最后一级stride=1
        stride = n_points // m 
        
        for k in range(0, n_points, m):
            for j in range(half_m):
                # 获取旋转因子
                tw_idx = j * stride
                t_r = tw_r[tw_idx]
                t_i = tw_i[tw_idx]
                
                # 读取蝶形下半支路的数据
                bot_r = X_r[k + j + half_m]
                bot_i = X_i[k + j + half_m]
                
                # 蝶形上半支路的数据
                top_r = X_r[k + j]
                top_i = X_i[k + j]
                
                # 复数乘法: bot * twiddle
                mul_r, mul_i = q15_complex_mul(bot_r, bot_i, t_r, t_i)
                
                # 蝶形加减法与缩放 (Divide by 2) 防止溢出
                # 如果硬件采用了进位四舍五入，应改为 (A + B + 1) >> 1
                new_top_r = (top_r + mul_r) >> 1
                new_top_i = (top_i + mul_i) >> 1
                new_bot_r = (top_r - mul_r) >> 1
                new_bot_i = (top_i - mul_i) >> 1
                
                # 写回
                X_r[k + j] = new_top_r
                X_i[k + j] = new_top_i
                X_r[k + j + half_m] = new_bot_r
                X_i[k + j + half_m] = new_bot_i
                
    return X_r, X_i

# ==========================================
# 主程序
# ==========================================
def main():
    input_file = 'input_q1_15_v3.hex'
    twiddle_file = 'twiddle_q15.hex'
    
    if not os.path.exists(input_file) or not os.path.exists(twiddle_file):
        print("错误: 找不到输入文件或旋转因子文件。请确保都在同一目录下。")
        return

    # 1. 解析 Twiddle (只提取前 512 个点即可，对应 W_1024^0 到 W_1024^511)
    tw_r, tw_i = read_twiddles(twiddle_file)
    
    # 2. 解析 Input
    raw_data = read_input(input_file)
    x_r = [0] * 1024
    x_i = [0] * 1024
    
    if len(raw_data) >= 2048:
        print("解析为交错复数输入 (Real, Imag, Real, Imag...)")
        x_r = raw_data[0:2048:2]
        x_i = raw_data[1:2048:2]
    else:
        print(f"解析为纯实数输入，共 {len(raw_data)} 点")
        for i in range(min(1024, len(raw_data))):
            x_r[i] = raw_data[i]

    # 3. 运行 Bit-true FFT
    out_r, out_i = radix2_dit_fft_bittrue(x_r, x_i, tw_r, tw_i, 1024)

    # 4. 生成对比报告
    output_file = 'bittrue_fft_output.txt'
    with open(output_file, 'w') as f:
        f.write("Index | Bit-true Hex Real | Bit-true Hex Imag | Int Real | Int Imag\n")
        f.write("-" * 75 + "\n")
        for i in range(1024):
            hex_r = int16_to_hex(out_r[i])
            hex_i = int16_to_hex(out_i[i])
            f.write(f"{i:4d}  | {hex_r}             | {hex_i}             | {out_r[i]:6d}   | {out_i[i]:6d}\n")

    print(f"Bit-true Golden Model 生成完毕！结果已保存至: {output_file}")
    print("你可以直接用 bittrue_fft_output.txt 中的 Hex 列去对比 Verilog $writememh 的输出结果。")

if __name__ == "__main__":
    main()