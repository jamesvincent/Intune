#!/bin/bash

# Build macOS Teams Backgrounds Uninstaller PKG
# Creates a PKG that removes Teams custom background images for all local users
# For use with Microsoft Intune
# James Vincent - May 2026

set -e

PKG_BUILD_ROOT="$HOME/Downloads/MSTeamsBackgrounds-Uninstaller"
PAYLOAD_ROOT="${PKG_BUILD_ROOT}/payload"
SCRIPTS_ROOT="${PKG_BUILD_ROOT}/scripts"
POSTINSTALL_SCRIPT="${SCRIPTS_ROOT}/postinstall"

OUTPUT_PKG_NAME="Remove-MSTeamsBackgrounds.pkg"
OUTPUT_PKG_PATH="${PKG_BUILD_ROOT}/${OUTPUT_PKG_NAME}"

PKG_IDENTIFIER="uk.co.jamesvincent.teamsbackgrounds.uninstaller"
PKG_VERSION="1.0"

echo "Creating PKG build structure..."

rm -rf "$PKG_BUILD_ROOT"

mkdir -p "$PAYLOAD_ROOT"
mkdir -p "$SCRIPTS_ROOT"

echo "Creating postinstall script..."

cat > "$POSTINSTALL_SCRIPT" <<'EOF'
#!/bin/bash

# Uninstall Teams custom backgrounds via macOS PKG
# Removes Teams backgrounds for all local users
# James Vincent - May 2026

set -e

PKG_IDENTIFIER="uk.co.jamesvincent.teamsbackgrounds"

echo "Starting Teams custom background removal..."

find /Users -mindepth 1 -maxdepth 1 -type d | while read -r USER_HOME; do

    USERNAME=$(basename "$USER_HOME")

    if [[ "$USERNAME" == "Shared" ]]; then
        continue
    fi

    TARGET_PATH="${USER_HOME}/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/Backgrounds/Uploads"

    echo ""
    echo "Processing user: $USERNAME"

    if [ ! -d "$TARGET_PATH" ]; then
        echo "Teams background path not found."
        continue
    fi

    echo "Removing Teams background files from:"
    echo "$TARGET_PATH"

    find "$TARGET_PATH" -maxdepth 1 -type f \( \
        -iname "*.jpg" -o \
        -iname "*.jpeg" \
    \) -print -delete

    if [ -f "${TARGET_PATH}/.teams-backgrounds-installed" ]; then
        echo "Removing marker file..."
        rm -f "${TARGET_PATH}/.teams-backgrounds-installed"
    fi

done

echo ""
echo "Forgetting package receipt: $PKG_IDENTIFIER"

if pkgutil --pkgs | grep -qx "$PKG_IDENTIFIER"; then
    pkgutil --forget "$PKG_IDENTIFIER"
else
    echo "Package receipt not found."
fi

echo ""
echo "Teams custom background removal complete."

exit 0
EOF

chmod +x "$POSTINSTALL_SCRIPT"

echo "Building uninstall PKG..."

pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$SCRIPTS_ROOT" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$PKG_VERSION" \
  "$OUTPUT_PKG_PATH"

echo ""
echo "Uninstaller PKG created successfully:"
echo "$OUTPUT_PKG_PATH"
echo ""
echo "Ready for Intune deployment."
