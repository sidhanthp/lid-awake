#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build="$root/build"
app="$build/Lid Awake.app"
staging="$build/.Lid Awake.app.build.$$"
backup="$build/.Lid Awake.app.previous.$$"
contents="$staging/Contents"
resources="$contents/Resources"

cleanup() {
    /bin/rm -rf "$staging"
}
trap cleanup EXIT

/bin/mkdir -p "$resources" "$contents/MacOS"

monitor_hash=$(/usr/bin/shasum -a 256 "$root/Resources/power-monitor.sh" | /usr/bin/awk '{print $1}')
install_hash=$(/usr/bin/shasum -a 256 "$root/Resources/install-helper.sh" | /usr/bin/awk '{print $1}')
uninstall_hash=$(/usr/bin/shasum -a 256 "$root/Resources/uninstall-helper.sh" | /usr/bin/awk '{print $1}')

/usr/bin/sed \
    -e "s/@POWER_MONITOR_SHA256@/$monitor_hash/g" \
    -e "s/@INSTALL_HELPER_SHA256@/$install_hash/g" \
    -e "s/@UNINSTALL_HELPER_SHA256@/$uninstall_hash/g" \
    "$root/Sources/LidAwake.swift" > "$build/LidAwake.swift"

developer_dir=$(/usr/bin/xcode-select -p)
if [ "$developer_dir" = "/Library/Developer/CommandLineTools" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    developer_dir="/Applications/Xcode.app/Contents/Developer"
fi
sdk=$(/usr/bin/env DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx --show-sdk-path)
/usr/bin/env DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx swiftc \
    -O -target arm64-apple-macosx13.0 -sdk "$sdk" \
    -framework AppKit -framework CryptoKit \
    "$build/LidAwake.swift" -o "$contents/MacOS/LidAwake"

/bin/cp "$root/Resources/power-monitor.sh" "$resources/power-monitor.sh"
/bin/cp "$root/Resources/install-helper.sh" "$resources/install-helper.sh"
/bin/cp "$root/Resources/uninstall-helper.sh" "$resources/uninstall-helper.sh"
/bin/chmod 755 "$resources"/*.sh

/bin/cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LidAwake</string>
    <key>CFBundleIdentifier</key><string>app.lidawake.LidAwake</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Lid Awake</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$staging"
if [ -e "$app" ]; then
    /bin/mv "$app" "$backup"
fi
if /bin/mv "$staging" "$app"; then
    if [ -e "$backup" ]; then
        /bin/rm -rf "$backup"
    fi
else
    if [ -e "$backup" ]; then
        /bin/mv "$backup" "$app"
    fi
    exit 1
fi
echo "Built $app"
