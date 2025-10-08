#!/bin/bash

SERVER=http://127.0.0.1
PORT=4042

V0="-1000,-1000,-1000"
V1="1000,-1000,-1000"
V2="1000,1000,-1000"
V3="-1000,1000,-1000"
V4="-1000,-1000,1000"
V5="1000,-1000,1000"
V6="1000,1000,1000"
V7="-1000,1000,1000"

function curl_server() {
  local path="$1"
  local data="$2"
  echo "Curling to ${SERVER}:${PORT}${path}"
  if [ -z "$data" ]; then
    curl -X GET "${SERVER}:${PORT}${path}" || ("curl error, exiting" && exit 1)
  else
    curl -X POST -H "Content-Type: application/json" -d "$data" "${SERVER}:${PORT}${path}" || ("curl error, exiting" && exit 1)
  fi
  # sleep 1
}

# First the wireframe
lines_payload='[
  {"p0":[-1000,-1000,-1000],"p1":[1000,-1000,-1000]},
  {"p0":[1000,-1000,-1000],"p1":[1000,1000,-1000]},
  {"p0":[1000,1000,-1000],"p1":[-1000,1000,-1000]},
  {"p0":[-1000,1000,-1000],"p1":[-1000,-1000,-1000]},
  {"p0":[-1000,-1000,1000],"p1":[1000,-1000,1000]},
  {"p0":[1000,-1000,1000],"p1":[1000,1000,1000]},
  {"p0":[1000,1000,1000],"p1":[-1000,1000,1000]},
  {"p0":[-1000,1000,1000],"p1":[-1000,-1000,1000]},
  {"p0":[-1000,-1000,-1000],"p1":[-1000,-1000,1000]},
  {"p0":[1000,-1000,-1000],"p1":[1000,-1000,1000]},
  {"p0":[1000,1000,-1000],"p1":[1000,1000,1000]},
  {"p0":[-1000,1000,-1000],"p1":[-1000,1000,1000]}
]'
curl_server "/lines" "$lines_payload"

# Now the faces
curl_server "/faces?p0=${V0}&p1=${V1}&p2=${V2}&p3=${V3}"
curl_server "/faces?p0=${V4}&p1=${V5}&p2=${V6}&p3=${V7}"
curl_server "/faces?p0=${V0}&p1=${V1}&p2=${V5}&p3=${V4}"
curl_server "/faces?p0=${V2}&p1=${V3}&p2=${V7}&p3=${V6}"
curl_server "/faces?p0=${V1}&p1=${V2}&p2=${V6}&p3=${V5}"
curl_server "/faces?p0=${V0}&p1=${V3}&p2=${V7}&p3=${V4}"

# Finally the vertices
curl_server "/vertices?p0=${V0}"
curl_server "/vertices?p0=${V1}"
curl_server "/vertices?p0=${V2}"
curl_server "/vertices?p0=${V3}"
curl_server "/vertices?p0=${V4}"
curl_server "/vertices?p0=${V5}"
curl_server "/vertices?p0=${V6}"
curl_server "/vertices?p0=${V7}"
