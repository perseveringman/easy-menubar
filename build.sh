#!/bin/bash
# Build locally. Public distribution must go through scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")"
UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        *) echo "Usage: $0 [--universal] [--install]" >&2; exit 2 ;;
    esac
done
APP="Bar.app"
STAGING="$(mktemp -d "$PWD/.bar-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Bar.app/Contents/MacOS" "$STAGING/Bar.app/Contents/Resources"
if $UNIVERSAL; then
    for arch in arm64 x86_64; do
        swift build -c release --arch "$arch" --scratch-path ".build/$arch" --disable-sandbox
        bin_dir="$(swift build -c release --arch "$arch" --scratch-path ".build/$arch" --show-bin-path)"
        cp "$bin_dir/Bar" "$STAGING/Bar-$arch"
    done
    lipo -create "$STAGING/Bar-arm64" "$STAGING/Bar-x86_64" -output "$STAGING/Bar.app/Contents/MacOS/Bar"
else
    swift build -c release --disable-sandbox
    bin_dir="$(swift build -c release --show-bin-path)"
    cp "$bin_dir/Bar" "$STAGING/Bar.app/Contents/MacOS/Bar"
fi
cp Resources/Info.plist "$STAGING/Bar.app/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGING/Bar.app/Contents/Resources/AppIcon.icns"
SIGN_IDENTITY="${BAR_CODESIGN_IDENTITY:-}"
SIGN_IDENTITY_FILE=".swiftpm/signing-identity"
if [[ -z "$SIGN_IDENTITY" && -s "$SIGN_IDENTITY_FILE" ]]; then
    SIGN_IDENTITY="$(cat "$SIGN_IDENTITY_FILE")"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    IDENTITIES=()
    while IFS= read -r identity; do
        [[ -n "$identity" ]] && IDENTITIES+=("$identity")
    done < <(security find-identity -v -p codesigning 2>/dev/null | awk '/^[[:space:]]*[0-9]+\)/ { print $2 }')
    if [[ ${#IDENTITIES[@]} -eq 1 ]]; then SIGN_IDENTITY="${IDENTITIES[0]}"; fi
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$STAGING/Bar.app"
else
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGING/Bar.app"
fi
codesign --verify --deep --strict "$STAGING/Bar.app"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    mkdir -p .swiftpm
    printf '%s\n' "$SIGN_IDENTITY" > "$SIGN_IDENTITY_FILE"
fi
rm -rf "$APP"
mv "$STAGING/Bar.app" "$APP"
if $INSTALL; then
    if pgrep -x Bar >/dev/null; then
        echo "Quit Bar before replacing /Applications/Bar.app." >&2; exit 1
    fi
    ditto "$APP" /Applications/Bar.app
    codesign --verify --deep --strict /Applications/Bar.app
    echo "installed: /Applications/Bar.app"
else
    echo "built: $PWD/$APP"
fi
echo "signing: $SIGN_IDENTITY"
