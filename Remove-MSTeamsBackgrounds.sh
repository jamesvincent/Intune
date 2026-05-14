#!/bin/bash

# Uninstall Teams custom backgrounds
# Removes Teams background files containing the supplied IMAGE_NAME text
# If DELETEALL is entered, all custom background files are removed
# Forgets package receipt: uk.co.jamesvincent.teamsbackgrounds
# James Vincent - May 2026

# Usage:
#   ./Remove-MSTeamsBackgrounds.sh SummerCampaign2026
#   ./Remove-MSTeamsBackgrounds.sh DELETEALL
#
# If no parameter is supplied, the script prompts interactively allowing for it to be used within Intune, and as a standalone.

set -e

IMAGE_NAME="${1:-}"

TARGET_PATH="$HOME/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/Backgrounds/Uploads"
PKG_IDENTIFIER="uk.co.jamesvincent.teamsbackgrounds"

if [ -z "$IMAGE_NAME" ]; then
    read -p "Enter the image description/name to remove, or DELETEALL to remove everything: " IMAGE_NAME
fi

if [ -z "$IMAGE_NAME" ]; then
    echo "IMAGE_NAME cannot be empty."
    exit 1
fi

if [ ! -d "$TARGET_PATH" ]; then
    echo "Target path does not exist:"
    echo "$TARGET_PATH"
else
    if [ "$IMAGE_NAME" = "DELETEALL" ]; then
        echo "DELETEALL specified. Removing all Teams background files..."

        find "$TARGET_PATH" -maxdepth 1 -type f \( \
            -iname "*.jpg" -o \
            -iname "*.jpeg" \
        \) -print -delete
    else
        echo "Removing Teams backgrounds containing: $IMAGE_NAME"

        find "$TARGET_PATH" -maxdepth 1 -type f \( \
            -iname "*${IMAGE_NAME}*.jpg" -o \
            -iname "*${IMAGE_NAME}*.jpeg" \
        \) -print -delete
    fi

    if [ -f "${TARGET_PATH}/.teams-backgrounds-installed" ]; then
        echo "Removing marker file..."
        rm -f "${TARGET_PATH}/.teams-backgrounds-installed"
    fi
fi

echo "Forgetting package receipt: $PKG_IDENTIFIER"

if pkgutil --pkgs | grep -qx "$PKG_IDENTIFIER"; then
    pkgutil --forget "$PKG_IDENTIFIER"
else
    echo "Package receipt not found. Nothing to forget."
fi

echo "Uninstall complete."
exit 0