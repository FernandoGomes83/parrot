#!/bin/sh
# Build, sign, and install parrot locally.
#
# Signing with a stable local identity keeps the Accessibility grant across
# updates: TCC ties the permission to the code signature, so unsigned (ad-hoc)
# builds count as a brand-new program on every install and need the grant
# redone by hand. One-time identity setup lives in docs/architecture.md-adjacent
# lore: create a self-signed "parrot-dev" code-signing certificate in the login
# keychain and trust it, then this script never bothers you again.
set -eu

IDENTITY="${PARROT_SIGN_IDENTITY:-parrot-dev}"
DEST=/usr/local/bin/parrot
LABEL=com.digimata.parrot

cd "$(dirname "$0")/.."

if ! security find-identity -p codesigning -v | grep -q "$IDENTITY"; then
    echo "signing identity '$IDENTITY' not found in the keychain." >&2
    echo "create a self-signed code-signing certificate with that name" >&2
    echo "(or set PARROT_SIGN_IDENTITY) and try again." >&2
    exit 1
fi

echo "→ building release..."
sh scripts/build.sh

echo "→ signing with '$IDENTITY'..."
# The identifier must stay constant: TCC keys the Accessibility grant on
# identifier + signing certificate.
codesign --force --sign "$IDENTITY" --identifier "$LABEL" dist/parrot
codesign --verify --strict dist/parrot

echo "→ installing to $DEST (sudo)..."
BUILD_ID=$(shasum -a 256 dist/parrot | cut -c1-12)
RUNTIME_DIR="/usr/local/lib/parrot/dev-$BUILD_ID"
sudo mkdir -p "$RUNTIME_DIR"
sudo install -m 755 dist/parrot "$RUNTIME_DIR/parrot"
sudo install -m 644 dist/mlx.metallib "$RUNTIME_DIR/mlx.metallib"
LINK_DIR=$(mktemp -d)
trap 'rm -rf "$LINK_DIR"' EXIT
ln -s "$RUNTIME_DIR/parrot" "$LINK_DIR/parrot"
sudo mv -f "$LINK_DIR/parrot" "$DEST"

# Restart the LaunchAgent if one is installed; harmless otherwise.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "→ restarting LaunchAgent..."
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
fi

echo "✓ installed $("$DEST" --version 2>/dev/null || echo parrot)"
