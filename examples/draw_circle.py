#!/usr/bin/env python3

import math
import urllib.request
import urllib.parse

# --- Configuration ---
SERVER_URL = "http://127.0.0.1:4042"
RADIUS = 1200
SEGMENTS = 120
CENTER_X = 0
CENTER_Y = 0
CENTER_Z = 0
# -------------------

import json
import urllib.request

# --- Configuration ---
SERVER_URL = "http://127.0.0.1:4042"
RADIUS = 1200
SEGMENTS = 120
CENTER_X = 0
CENTER_Y = 0
CENTER_Z = 0
# -------------------

def draw_lines(lines):
    """Sends a request to the zcad server to draw a list of lines."""
    try:
        data = json.dumps(lines).encode('utf-8')
        req = urllib.request.Request(f"{SERVER_URL}/lines", data=data, headers={'Content-Type': 'application/json'}, method='POST')
        with urllib.request.urlopen(req) as response:
            response.read()
    except Exception as e:
        print(f"  Error connecting to server: {e}")
        exit(1)

def main():
    """Calculates points and draws a circle."""
    print(f"Generating and drawing a circle with {SEGMENTS} segments and radius {RADIUS}...")

    lines = []
    # Calculate the coordinates for the first point
    last_x = CENTER_X + RADIUS
    last_y = CENTER_Y

    # Loop through the segments to draw the circle
    for i in range(1, SEGMENTS + 1):
        angle = (i / SEGMENTS) * 2 * math.pi

        # Calculate the precise coordinates of the current point
        x_float = CENTER_X + RADIUS * math.cos(angle)
        y_float = CENTER_Y + RADIUS * math.sin(angle)

        # Round to the nearest integer for the server
        x = int(round(x_float))
        y = int(round(y_float))

        # Define the two points for the line segment
        p0 = (last_x, last_y, CENTER_Z)
        p1 = (x, y, CENTER_Z)

        # Add the line to the list
        if p0 != p1:
            lines.append({"p0": p0, "p1": p1})

        # Update the last point for the next iteration
        last_x = x
        last_y = y

    draw_lines(lines)

    print("\nCircle drawing complete.")

if __name__ == "__main__":
    main()
