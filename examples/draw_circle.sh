#!/bin/bash

# This script sends HTTP requests to the zcad server to draw a circle
# approximated by a series of short lines, using Python for precise calculations.

SERVER="http://127.0.0.1:4042"
RADIUS=5
SEGMENTS=300
CENTER_X=0
CENTER_Y=0
CENTER_Z=0

echo "Generating and drawing a circle with $SEGMENTS segments and radius $RADIUS..."

python3 -c "
import math
import os
import json

# Circle parameters from environment variables
RADIUS = int(os.getenv('RADIUS', '100'))
SEGMENTS = int(os.getenv('SEGMENTS', '72'))
CENTER_X = int(os.getenv('CENTER_X', '0'))
CENTER_Y = int(os.getenv('CENTER_Y', '0'))
CENTER_Z = int(os.getenv('CENTER_Z', '0'))
SERVER = os.getenv('SERVER', 'http://127.0.0.1:4042')

lines = []
# Calculate the coordinates for the first point
last_x = CENTER_X + RADIUS
last_y = CENTER_Y

# Loop through the segments to generate curl commands
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

    if p0 != p1:
        lines.append({"p0": p0, "p1": p1})

    # Update the last point for the next iteration
    last_x = x
    last_y = y

# Construct and execute the curl command
json_payload = json.dumps(lines)
command = f"curl -s -X POST -H 'Content-Type: application/json' -d '{json_payload}' {SERVER}/lines"
os.system(command)

print('\nCircle drawing complete.')
"
