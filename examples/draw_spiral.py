#!/usr/bin/env python3

import requests
import math

BASE_URL = "http://127.0.0.1:4042"
NUM_LINES = 10000

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

def draw_lines(lines):
    """Sends a request to the server to draw a list of lines."""
    try:
        response = requests.post(f"{BASE_URL}/lines", json=lines)
        response.raise_for_status()
        print(f"Successfully drew {len(lines)} lines.")
    except requests.exceptions.RequestException as e:
        print(f"Error drawing lines: {e}")

def main():
    """Draws a spiral with a large number of lines."""
    print(f"Generating and drawing a spiral with {NUM_LINES} lines...")

    lines_to_add = []
    points = generate_spiral_points(NUM_LINES + 1)
    for i in range(NUM_LINES):
        lines_to_add.append({"p0": points[i], "p1": points[i+1]})

    draw_lines(lines_to_add)

if __name__ == "__main__":
    main()
