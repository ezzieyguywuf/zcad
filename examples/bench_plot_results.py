import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

# --- Configuration ---
CSV_FILE = "benchmark_results.csv"
OUTPUT_IMAGE = "benchmark_plot.png"

def plot_results():
    """Reads benchmark data from CSV and generates insightful plots."""
    try:
        df = pd.read_csv(CSV_FILE)
    except FileNotFoundError:
        print(f"Error: The file '{CSV_FILE}' was not found.")
        return
    except pd.errors.EmptyDataError:
        print(f"Error: The file '{CSV_FILE}' is empty. No data to plot.")
        return

    if df.empty:
        print("The benchmark results are empty. No plot will be generated.")
        return

    # Create a figure with 3 subplots that share the same x-axis
    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(12, 18), sharex=True)
    fig.suptitle('zcad Benchmark Performance', fontsize=16)

    # --- Plot 1: FPS vs. Total Lines ---
    ax1.plot(df['total_lines'], df['fps'], marker='.', linestyle='none', color='g')
    ax1.set_ylabel('Frames Per Second (FPS)')
    ax1.set_title('FPS vs. Scene Complexity')
    ax1.grid(True, which='both', linestyle='--', linewidth=0.5)

    # --- Plot 2: GPU Memory vs. Total Lines ---
    # Convert bytes to Gigabytes for easier reading
    bytes_to_gb = 1 / (1024**3)
    ax2.plot(df['total_lines'], df['bytes_uploaded_to_gpu'] * bytes_to_gb, marker='.', linestyle='none', color='b')
    ax2.set_ylabel('GPU Memory Uploaded (GB)')
    ax2.set_title('Memory Usage vs. Scene Complexity')
    ax2.grid(True, which='both', linestyle='--', linewidth=0.5)
    ax2.yaxis.set_major_formatter(mticker.FormatStrFormatter('%.2f GB'))

    # --- Plot 3: Frametime vs. Total Lines ---
    ax3.plot(df['total_lines'], df['frametime_ms'], marker='.', linestyle='none', color='r')
    ax3.set_xlabel('Total Lines in Scene')
    ax3.set_ylabel('Frametime (ms)')
    ax3.set_title('Frametime vs. Scene Complexity')
    ax3.grid(True, which='both', linestyle='--', linewidth=0.5)
    ax3.xaxis.set_major_formatter(mticker.FuncFormatter(lambda x, p: format(int(x), ',')))


    # Improve layout and save the figure
    plt.tight_layout(rect=[0, 0.03, 1, 0.97]) # Adjust layout to make room for suptitle
    plt.savefig(OUTPUT_IMAGE)
    
    print(f"Plot saved to '{OUTPUT_IMAGE}'")
    # plt.show() # Uncomment to display the plot directly if a GUI is available

if __name__ == "__main__":
    plot_results()
