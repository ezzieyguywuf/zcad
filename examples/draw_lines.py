import requests
import math

BASE_URL = "http://127.0.0.1:4042"

def draw_lines(lines):
    """Sends a request to the server to draw a list of lines."""
    try:
        response = requests.post(f"{BASE_URL}/lines", json=lines)
        response.raise_for_status()
        print(f"Successfully drew {len(lines)} lines.")
    except requests.exceptions.RequestException as e:
        print(f"Error drawing lines: {e}")

def main():
    """Draws a few angled lines and a smooth curve."""
    # --- Draw a few longer lines at 45-degree angles ---
    print("Drawing angled lines...")
    angled_lines = [
        {"p0": (0, 1000, 0), "p1": (1000, 0, 0)},
        {"p0": (1000, 0, 0), "p1": (2000, 1000, 0)},
        {"p0": (-2000, 1000, 0), "p1": (-1000, 0, 0)},
        {"p0": (-1000, 0, 0), "p1": (0, 1000, 0)},
    ]
    draw_lines(angled_lines)


    # --- Sweep a bunch of shorter lines into a curve ---
    print("\nDrawing a curve...")
    num_segments = 50
    radius = 1500
    center_x, center_y = 0, -2000
    start_angle = math.pi / 4  # 45 degrees
    end_angle = 3 * math.pi / 4 # 135 degrees

    points = []
    for i in range(num_segments + 1):
        angle = start_angle + (end_angle - start_angle) * i / num_segments
        x = int(center_x + radius * math.cos(angle))
        y = int(center_y + radius * math.sin(angle))
        points.append((x, y, 0))

    curve_lines = []
    # Draw the line segments for the curve
    for i in range(num_segments):
        curve_lines.append({"p0": points[i], "p1": points[i+1]})
    draw_lines(curve_lines)

if __name__ == "__main__":
    main()
