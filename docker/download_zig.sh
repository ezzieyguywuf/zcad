#!/bin/bash
set -euo pipefail

VERSION=$1
TARGET_DIR=$2
ZSF_PUBKEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

echo "==> Fetching tarball information for Zig $VERSION..."
JSON_PAYLOAD=$(curl -s https://ziglang.org/download/index.json)
TARBALL_PATH=$(echo "$JSON_PAYLOAD" | jq -r --arg VERSION_KEY "$VERSION" '.[$VERSION_KEY]."x86_64-linux".tarball')
TARBALL_FILENAME=$(basename "$TARBALL_PATH")

if [ -z "$TARBALL_FILENAME" ] || [ "$TARBALL_FILENAME" = "null" ]; then
  echo "Error: Could not parse Zig download path for $VERSION from index.json" >&2
  exit 1
fi
echo "Target tarball: $TARBALL_FILENAME"

echo "==> Fetching and shuffling community mirror list..."
# The grep ensures we skip any empty lines
MIRROR_LIST=$(curl -s https://ziglang.org/download/community-mirrors.txt | grep . | shuf)

DOWNLOAD_SUCCESS=false
for mirror in $MIRROR_LIST; do
  TARBALL_URL="$mirror/$TARBALL_FILENAME"
  MINISIG_URL="$TARBALL_URL.minisig"
  echo "--> Attempting download from mirror: $mirror"
  if wget -q -O zig.tar.xz "$TARBALL_URL" && wget -q -O zig.tar.xz.minisig "$MINISIG_URL"; then
    echo "Download complete. Verifying signature..."
    if minisign -Vm zig.tar.xz -P "$ZSF_PUBKEY"; then
      echo "Signature valid. Success!"
      DOWNLOAD_SUCCESS=true
      break
    else
      echo "!! Signature verification FAILED for download from $mirror"
    fi
  else
    echo "Download failed from $mirror"
  fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
  echo "--> All mirrors failed. Attempting fallback to ziglang.org..."
  TARBALL_URL="https://ziglang.org$TARBALL_PATH"
  MINISIG_URL="$TARBALL_URL.minisig"
  if wget -q -O zig.tar.xz "$TARBALL_URL" && wget -q -O zig.tar.xz.minisig "$MINISIG_URL"; then
    echo "Download complete. Verifying signature..."
    if minisign -Vm zig.tar.xz -P "$ZSF_PUBKEY"; then
      echo "Signature valid. Success!"
      DOWNLOAD_SUCCESS=true
    else
      echo "!! Signature verification FAILED for download from ziglang.org"
    fi
  else
    echo "Download failed from ziglang.org"
  fi
fi

if [ "$DOWNLOAD_SUCCESS" = false ]; then
  echo "Error: Failed to download and verify Zig from all available sources." >&2
  exit 1
fi

echo "==> Extracting and installing Zig to $TARGET_DIR..."
ZIG_DIR_NAME=${TARBALL_FILENAME%.tar.xz}
mkdir -p /tmp/zig_extract
tar -xf zig.tar.xz -C /tmp/zig_extract
mv /tmp/zig_extract/$ZIG_DIR_NAME "$TARGET_DIR"

echo "==> Cleaning up..."
rm zig.tar.xz zig.tar.xz.minisig
rm -rf /tmp/zig_extract

echo "Zig $VERSION installed in $TARGET_DIR"
