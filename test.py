import pandas as pd
import matplotlib.pyplot as plt
import os

csv_file = "result_data.csv"

color_map = {
    'tt': 'green',
    'ff': 'red',
    'ss': 'blue',
    'fs': 'magenta',
    'sf': 'cyan'
}

def plot_charts():
    if not os.path.exists(csv_file):
        print(f"error")
        return

    # 1. read data
    try:
        df = pd.read_csv(csv_file)
    except Exception as e:
        print(f"error")
        return

    df = df.sort_values(by=['Corner', 'VDD(V)'])

    corners = df['Corner'].unique()

    # 图1: Delay vs VDD
    fig1, ax1 = plt.subplots(figsize=(8, 6))
    fig1.suptitle('NAND Gate Performance vs VDD across Corners', fontsize=16)

    for corner in corners:
        subset = df[df['Corner'] == corner]
        color = color_map.get(corner, 'black') 
        
        ax1.plot(subset['VDD(V)'], subset['Delay(ps)'], 
                 marker='o', linestyle='-', linewidth=2, markersize=6, 
                 label=corner.upper(), color=color)

    ax1.set_title('Propagation Delay vs VDD')
    ax1.set_xlabel('Supply Voltage (V)')
    ax1.set_ylabel('Delay (ps)')
    ax1.grid(True, linestyle='--', alpha=0.7)
    ax1.legend()

    plt.tight_layout()
    output_img1 = "simulation_delay.png"
    plt.savefig(output_img1, dpi=300)
    print(f"Image saved as: {output_img1}")

    # 图2: Power vs VDD 
    fig2, ax2 = plt.subplots(figsize=(8, 6))
    fig2.suptitle('NAND Gate Performance vs VDD across Corners', fontsize=16)

    for corner in corners:
        subset = df[df['Corner'] == corner]
        color = color_map.get(corner, 'black')
        
        ax2.plot(subset['VDD(V)'], subset['Power(uW)'], 
                 marker='s', linestyle='--', linewidth=2, markersize=6, 
                 label=corner.upper(), color=color)

    ax2.set_title('Leakage/Static Power vs VDD')
    ax2.set_xlabel('Supply Voltage (V)')
    ax2.set_ylabel('Power (uW)')
    ax2.grid(True, linestyle='--', alpha=0.7)
    ax2.legend()

    plt.tight_layout()
    output_img2 = "simulation_power.png"
    plt.savefig(output_img2, dpi=300)
    print(f"Image saved as: {output_img2}")

if __name__ == "__main__":
    plot_charts()