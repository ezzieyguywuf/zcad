import requests
import time
import csv
import threading
import math

# --- Configuration ---
BASE_URL = "http://127.0.0.1:4042"
CSV_FILE = "benchmark_results.csv"
MEMORY_LIMIT_GB = 7.5
MEMORY_LIMIT_BYTES = MEMORY_LIMIT_GB * 1024**3
ROTATION_SPEED_RADS = 0.05
STATS_SAMPLE_INTERVAL = 0.2 # Seconds
MAX_LINES = 10000000

# --- Globals for Threading ---
stop_event = threading.Event()
data_lock = threading.Lock()
total_lines_drawn = 0
last_bytes_uploaded = 0
results = []

class ServerError(Exception):
    """Custom exception for server-related errors."""
    pass

def camera_rotator():
    """Continuously rotates the camera in the background."""
    while not stop_event.is_set():
        try:
            requests.post(f"{BASE_URL}/moveCamera", json={"yaw_rads": ROTATION_SPEED_RADS}, timeout=0.5)
        except requests.RequestException:
            time.sleep(1) # Don't spam errors, just wait
        time.sleep(0.1)

def stats_collector():
    """Continuously samples stats from the server."""
    global last_bytes_uploaded
    while not stop_event.is_set():
        try:
            stats = get_stats()
            with data_lock:
                results.append({
                    "fps": stats["fps"],
                    "frametime_ms": stats["frametime_ms"],
                    "bytes_uploaded_to_gpu": stats["bytes_uploaded_to_gpu"],
                    "total_lines": total_lines_drawn
                })
                last_bytes_uploaded = stats["bytes_uploaded_to_gpu"]
        except ServerError as e:
            print(f"\nError in stats collector: {e}. Stopping benchmark.")
            stop_event.set()
            break
        time.sleep(STATS_SAMPLE_INTERVAL)

def line_adder():
    """Continuously adds lines to the server in batches."""
    global total_lines_drawn
    batch_size = 100
    for i in range(0, MAX_LINES, batch_size):
        if stop_event.is_set():
            break
        try:
            print(f"Adding lines {i + 1}-{i + batch_size}/{MAX_LINES}...", end='\r')
            
            lines_to_add = []
            for j in range(batch_size):
                points = generate_spiral_points(2, start_angle=0.1 * (i + j))
                lines_to_add.append({"p0": points[0], "p1": points[1]})

            add_lines(lines_to_add)
            zoom_to_fit()
            
            with data_lock:
                total_lines_drawn += batch_size
                current_mem_usage = last_bytes_uploaded
            
            if current_mem_usage >= MEMORY_LIMIT_BYTES:
                print(f"\nMemory usage ({current_mem_usage / 1024**3:.2f} GB) has reached the limit. Stopping.")
                stop_event.set()
                break
        except ServerError as e:
            print(f"\nError in line adder: {e}. Stopping benchmark.")
            stop_event.set()
            break

def get_stats():
    """Fetches and returns performance stats from the server. Raises ServerError on failure."""
    try:
        response = requests.get(f"{BASE_URL}/stats", timeout=1)
        response.raise_for_status()
        data = response.json()
        return {
            "fps": data.get("fps", 0),
            "frametime_ms": data.get("raw", {}).get("frametime_ms", 0),
            "bytes_uploaded_to_gpu": data.get("raw", {}).get("bytes_uploaded_to_gpu", 0),
        }
    except requests.RequestException as e:
        raise ServerError(f"Error getting stats: {e}") from e

def add_lines(lines):
    """Adds a list of lines to the world. Raises ServerError on failure."""
    try:
        response = requests.post(f"{BASE_URL}/lines", json=lines, timeout=2) # Longer timeout for adding lines
        response.raise_for_status()
    except requests.RequestException as e:
        raise ServerError(f"Error adding lines: {e}") from e

def generate_spiral_points(num_points, start_angle=0, a=100, b=50):
    """Generates points for a 3D spiral."""
    points = []
    for i in range(num_points):
        angle = start_angle + 0.1 * i
        x = int((a + b * angle) * math.cos(angle))
        y = int((a + b * angle) * math.sin(angle))
        z = int(b * angle)
        points.append((x, y, z))
    return points

def zoom_to_fit():
    """Calls the zoomToFit endpoint to adjust the camera. Raises ServerError on failure."""
    try:
        response = requests.post(f"{BASE_URL}/zoomToFit", timeout=2) # Longer timeout for zoom
        response.raise_for_status()
    except requests.RequestException as e:
        raise ServerError(f"Error zooming to fit: {e}") from e

def main():
    """Main function to run the benchmark."""
    # Check if server is up before starting
    try:
        requests.get(f"{BASE_URL}/stats", timeout=1).raise_for_status()
    except requests.RequestException as e:
        print(f"Error: Connection to {BASE_URL} failed. Is the server running? ({e})")
        return

    print("Starting benchmark threads...")
    rotation_thread = threading.Thread(target=camera_rotator, daemon=True)
    stats_thread = threading.Thread(target=stats_collector, daemon=True)
    line_thread = threading.Thread(target=line_adder)

    rotation_thread.start()
    stats_thread.start()
    line_thread.start()

    try:
        # The main thread will wait here until the line_adder thread is finished
        line_thread.join()
    except KeyboardInterrupt:
        print("\n--- Benchmark interrupted by user ---")
        stop_event.set()
    finally:
        # Ensure all threads are signaled to stop and have finished
        stop_event.set()
        line_thread.join() # Make sure it's joined if interrupted
        stats_thread.join(timeout=2)
        rotation_thread.join(timeout=2)
        
        print("\nBenchmark finished.")

        if results:
            print(f"Writing {len(results)} results to {CSV_FILE}...")
            with open(CSV_FILE, "w", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=results[0].keys())
                writer.writeheader()
                writer.writerows(results)
            print("Done.")
        else:
            print("No results to save.")

if __name__ == "__main__":
    main()
