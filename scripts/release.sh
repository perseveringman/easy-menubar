#!/bin/bash
# A stable release fails closed without Developer ID and Apple notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:---notarized}"
[[ "$MODE" == "--notarized" || "$MODE" == "--candidate" ]] || { echo "Usage: $0 [--notarized|--candidate]" >&2; exit 2; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ "$MODE" == "--notarized" ]]; then
    [[ "${BAR_CODESIGN_IDENTITY:-}" == "Developer ID Application:"* ]] || { echo "Set BAR_CODESIGN_IDENTITY to a Developer ID Application certificate." >&2; exit 1; }
    if [[ -n "${BAR_NOTARY_PROFILE:-}" ]]; then
        NOTARY_ARGS=(--keychain-profile "$BAR_NOTARY_PROFILE")
    else
        : "${BAR_NOTARY_KEY:?Set BAR_NOTARY_PROFILE or BAR_NOTARY_KEY}"
        : "${BAR_NOTARY_KEY_ID:?Set BAR_NOTARY_KEY_ID}"
        : "${BAR_NOTARY_ISSUER:?Set BAR_NOTARY_ISSUER}"
        NOTARY_ARGS=(--key "$BAR_NOTARY_KEY" --key-id "$BAR_NOTARY_KEY_ID" --issuer "$BAR_NOTARY_ISSUER")
    fi
fi
notarize() {
    local file="$1" report="$2"
    xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait --timeout 20m --output-format json > "$report"
    python3 - "$report" <<'JSON'
import json, sys
result = json.load(open(sys.argv[1]))
print("Apple notarization:", result.get("id"), result.get("status"))
if result.get("status") != "Accepted":
    raise SystemExit("Apple did not accept this submission; inspect the report before publishing.")
JSON
}
swift test --disable-sandbox
if [[ "$MODE" == "--candidate" ]]; then
    BAR_CODESIGN_IDENTITY=- ./build.sh --universal
    LABEL="Bar-$VERSION-universal-UNNOTARIZED"
else
    ./build.sh --universal
    LABEL="Bar-$VERSION-universal"
fi
mkdir -p dist
STAGE=$(mktemp -d "$PWD/.bar-release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto Bar.app "$STAGE/Bar.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.txt "$STAGE/安装说明.txt"
cp LICENSE "$STAGE/LICENSE.txt"
if [[ "$MODE" == "--notarized" ]]; then
    ditto -c -k --keepParent Bar.app "$STAGE/notary.zip"
    notarize "$STAGE/notary.zip" "dist/notary-app-$VERSION.json"
    xcrun stapler staple "$STAGE/Bar.app"
    xcrun stapler validate "$STAGE/Bar.app"
    syspolicy_check distribution "$STAGE/Bar.app"
    spctl --assess --type execute --verbose=2 "$STAGE/Bar.app"
    rm "$STAGE/notary.zip"
fi
ditto -c -k --keepParent "$STAGE/Bar.app" "dist/$LABEL.zip"
hdiutil create -volname "Bar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/$LABEL.dmg"
hdiutil verify "dist/$LABEL.dmg"
if [[ "$MODE" == "--notarized" ]]; then
    codesign --force --sign "$BAR_CODESIGN_IDENTITY" --timestamp "dist/$LABEL.dmg"
    notarize "dist/$LABEL.dmg" "dist/notary-dmg-$VERSION.json"
    xcrun stapler staple "dist/$LABEL.dmg"
    xcrun stapler validate "dist/$LABEL.dmg"
    codesign --verify --strict "dist/$LABEL.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "dist/$LABEL.dmg"
fi
(cd dist && shasum -a 256 "$LABEL.zip" "$LABEL.dmg" > "$LABEL-SHA256SUMS.txt")
echo "Artifacts: $PWD/dist/$LABEL.*"
if [[ "$MODE" == "--candidate" ]]; then
    echo "UNNOTARIZED candidate only. Do not publish as a stable release."
fi
