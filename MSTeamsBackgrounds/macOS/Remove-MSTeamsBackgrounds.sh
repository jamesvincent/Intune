#!/bin/bash

# Uninstall Teams custom backgrounds
# Removes all Teams background files by default
# If -RemoveImages is passed with text, only matching files are removed
# Forgets package receipt: uk.co.jamesvincent.teamsbackgrounds
# James Vincent - May 2026

# Usage:
#   ./Remove-MSTeamsBackgrounds.sh
#   ./Remove-MSTeamsBackgrounds.sh -RemoveImages "SummerCampaign2026"

set -e

REMOVE_IMAGES=""

TARGET_PATH="$HOME/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/Backgrounds/Uploads"
PKG_IDENTIFIER="uk.co.jamesvincent.teamsbackgrounds"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -RemoveImages)
            REMOVE_IMAGES="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

if [ ! -d "$TARGET_PATH" ]; then
    echo "Target path does not exist:"
    echo "$TARGET_PATH"
else
    if [ -z "$REMOVE_IMAGES" ]; then
        echo "No -RemoveImages parameter supplied. Removing all Teams background files..."

        find "$TARGET_PATH" -maxdepth 1 -type f \( \
            -iname "*.jpg" -o \
            -iname "*.jpeg" \
        \) -print -delete
    else
        echo "Removing Teams background files containing: $REMOVE_IMAGES"

        find "$TARGET_PATH" -maxdepth 1 -type f \( \
            -iname "*${REMOVE_IMAGES}*.jpg" -o \
            -iname "*${REMOVE_IMAGES}*.jpeg" \
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
