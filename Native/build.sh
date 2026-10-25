#!/bin/zsh
set -eu
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release
APP="$PWD/build/jipass.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/jipass "$APP/Contents/MacOS/jipass"
DATA="$(cd .. && pwd)/data"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>jipass</string>
<key>CFBundleDisplayName</key><string>jipass</string>
<key>CFBundleIdentifier</key><string>com.dustalexw.jipass</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>jipass</string>
<key>CFBundleIconFile</key><string>jipass</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
plutil -insert JipassDataPath -string "$DATA" "$APP/Contents/Info.plist"
cp Assets/jipass.icns "$APP/Contents/Resources/jipass.icns"
codesign --force --deep --sign - "$APP"
if [[ "${1:-}" == "open" ]]; then open "$APP"; fi
print "Built: $APP"
