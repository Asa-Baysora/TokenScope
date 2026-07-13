#!/bin/zsh
# Builds TokenScope.app (menu bar app, no Dock icon) next to this script.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=TokenScope.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TokenScope "$APP/Contents/MacOS/TokenScope"

if [[ ! -f Resources/AppIcon.icns ]]; then
    swift tools/make-icon.swift
    mkdir -p Resources
    iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
    rm -rf AppIcon.iconset
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TokenScope</string>
    <key>CFBundleDisplayName</key>
    <string>TokenScope</string>
    <key>CFBundleIdentifier</key>
    <string>com.tokenscope</string>
    <key>CFBundleExecutable</key>
    <string>TokenScope</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.2</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string></string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
