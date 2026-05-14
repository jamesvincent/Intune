#!/bin/bash

# Script to generate Teams background files and macOS PKG
# Run this script on a build/test macOS device to generate the source for Intune
# Deploy in bulk using Intune, specify User context for the App
# Detect using "uk.co.jamesvincent.teamsbackgrounds" and version "1.0"
# James Vincent - May 2026

set -e

read -p "Enter the path to your collection of backgrounds (.jpg format): " IMAGE_LOCATION
read -p "Enter a description for the images, for example SummerCampaign2026: " IMAGE_NAME

OUTPUT_PATH="${IMAGE_LOCATION}/Intune"
PAYLOAD_ROOT="${OUTPUT_PATH}/payload"
TARGET_PATH="$HOME/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/Backgrounds/Uploads"
PKG_IDENTIFIER="uk.co.jamesvincent.teamsbackgrounds"
PKG_VERSION="1.0"
PKG_NAME="TeamsBackgrounds-macOS.pkg"

if [ ! -d "$IMAGE_LOCATION" ]; then
    echo "Input path does not exist."
    exit 1
fi

JPG_COUNT=$(find "$IMAGE_LOCATION" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | wc -l)

if [ "$JPG_COUNT" -eq 0 ]; then
    echo "No JPG files found in $IMAGE_LOCATION."
    exit 1
fi

if [ ! -d "$OUTPUT_PATH" ]; then
    echo "Creating output path: $OUTPUT_PATH"
    mkdir -p "$OUTPUT_PATH"
fi

if [ ! -d "$PAYLOAD_ROOT" ]; then
    echo "Creating payload root: $PAYLOAD_ROOT"
    mkdir -p "$PAYLOAD_ROOT"
fi

if [ ! -d "$TARGET_PATH" ]; then
    echo "Creating target path: $TARGET_PATH"
    mkdir -p "$TARGET_PATH"
fi

echo "Creating Teams background images..."

find "$IMAGE_LOCATION" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | while read -r IMAGE; do
    GUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    BACKGROUND_NAME="${GUID}${IMAGE_NAME}.jpg"
    THUMB_NAME="${GUID}${IMAGE_NAME}_thumb.jpg"

    echo "Creating background: $BACKGROUND_NAME"
    sips -z 1080 1920 "$IMAGE" --out "${TARGET_PATH}/${BACKGROUND_NAME}" >/dev/null

    echo "Creating thumbnail: $THUMB_NAME"
    sips -z 158 220 "$IMAGE" --out "${TARGET_PATH}/${THUMB_NAME}" >/dev/null
done

echo "Creating marker file..."
cat > "${TARGET_PATH}/.teams-backgrounds-installed" <<EOF
Package: ${PKG_IDENTIFIER}
Version: ${PKG_VERSION}
Installed: $(date)
EOF

echo "Building PKG..."

pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$PKG_VERSION" \
  --install-location "/" \
  "${OUTPUT_PATH}/${PKG_NAME}"

echo "PKG created at:"
echo "${OUTPUT_PATH}/${PKG_NAME}"
