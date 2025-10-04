#!/bin/bash

# This script continuously calls the /moveCamera endpoint to rotate the camera
# around its focus point. It sends a small, constant yaw rotation in a loop.
#
# Press Ctrl+C to stop the script.

# The amount to rotate in each step, in radians.
# A smaller value results in a slower, smoother rotation.
ROTATION_AMOUNT=0.02

while true
do
  # Use curl to send a POST request with the JSON payload.
  # The -s flag silences progress output, and -o /dev/null discards the response body.
  curl -s -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    -d "{ \"yaw_rads\": ${ROTATION_AMOUNT} }" \
    http://localhost:4042/moveCamera

  # Pause for a short duration to control the speed of the rotation.
  # 0.016 seconds is roughly 60 frames per second.
  sleep 0.016
done
