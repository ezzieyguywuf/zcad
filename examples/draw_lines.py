import requests
import math

BASE_URL = "http://127.0.0.1:4042"

def draw_line(p0, p1):
    """Sends a request to the server to draw a line."""
    try:
        params = {
            "p0": f"{p0[0]},{p0[1]},{p0[2]}",
            "p1": f"{p1[0]},{p1[1]},{p1[2]}"
        }
        response = requests.get(f"{BASE_URL}/lines", params=params)
        response.raise_for_status()
        print(f"Successfully drew line from {p0} to {p1}")
    except requests.exceptions.RequestException as e:
        print(f"Error drawing line from {p0} to {p1}: {e}")

def main():
    """Draws a few angled lines and a smooth curve."""
    # --- Draw a few longer lines at 45-degree angles ---
    print("Drawing angled lines...")
    # A V-shape
    draw_line((0, 1000, 0), (1000, 0, 0))
    draw_line((1000, 0, 0), (2000, 1000, 0))
    # A second, separate V-shape
    draw_line((-2000, 1000, 0), (-1000, 0, 0))
    draw_line((-1000, 0, 0), (0, 1000, 0))


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

    # Draw the line segments for the curve
    for i in range(num_segments):
        draw_line(points[i], points[i+1])

if __name__ == "__main__":
    main()
