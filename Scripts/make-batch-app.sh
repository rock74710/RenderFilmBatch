#!/bin/bash
# 把獨立的批次執行檔組成可雙擊的 macOS App。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

cd "$ROOT"
swift build -c "$CONFIG" --product RenderFilmBatch
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/RenderFilmBatch.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RenderFilmBatch" "$APP/Contents/MacOS/RenderFilmBatch"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# 授權與第三方聲明跟著 App 走。
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
# 介面字串以中文為 key；其他語系放在 Localization/<target>/<lang>.lproj。
cp -R "$ROOT/Localization/RenderFilmBatch/"*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>RenderFilm Batch</string>
    <key>CFBundleDisplayName</key><string>RenderFilm Batch</string>
    <key>CFBundleIdentifier</key><string>com.renderfilm.batch</string>
    <key>CFBundleExecutable</key><string>RenderFilmBatch</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hant</string><string>en</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 簽名：設定 SIGN_IDENTITY 才簽；有設 NOTARY_PROFILE 再送公證。
# 例：SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=RF-notary ./Scripts/make-batch-app.sh
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        ZIP="$ROOT/build/RenderFilmBatch.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        spctl -a -vv "$APP"
    fi
else
    echo "未設定 SIGN_IDENTITY，略過簽名"
fi

echo "已產生 $APP"
