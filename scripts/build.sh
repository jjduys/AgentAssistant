#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
xcrun swiftc Sources/BrandIcon.swift Tools/GenerateIcons.swift -o build/GenerateIcons
build/GenerateIcons build/AppIcon.iconset
/usr/bin/iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
cp build/AppIcon.png Resources/AppIcon.png
swift build -c release
APP="$PWD/build/AgentAssistant.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AgentAssistant "$APP/Contents/MacOS/AgentAssistant"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP"
print "Built: $APP"
