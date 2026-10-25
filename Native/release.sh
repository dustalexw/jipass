#!/bin/zsh
set -eu
cd "$(dirname "$0")"
./build.sh
STAGE="$PWD/build/release"
mkdir -p "$STAGE"
# A distributable app must not retain the development checkout's data path.
if [[ -d "$STAGE/jipass.app" ]]; then rm -rf "$STAGE/jipass.app"; fi
ditto build/jipass.app "$STAGE/jipass.app"
plutil -remove JipassDataPath "$STAGE/jipass.app/Contents/Info.plist"
strip -S "$STAGE/jipass.app/Contents/MacOS/jipass"
codesign --force --deep --sign - "$STAGE/jipass.app"
codesign --verify --deep --strict "$STAGE/jipass.app"
ARCH="$(uname -m)"
ZIP="$STAGE/jipass-2.0.0-macOS-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/jipass.app" "$ZIP"
(cd "$STAGE" && shasum -a 256 "${ZIP:t}" > SHA256SUMS.txt)
print "Release: $ZIP"
