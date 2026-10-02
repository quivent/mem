#!/bin/zsh
# Build Mem.app and the memread helper next to this script.
#
#   ./build.sh                   build Mem.app and memread
#   ./build.sh --install         ...and copy Mem.app to ~/Applications
#   ./build.sh --install-helper  ...and install memread setuid root (asks for your password)
#   ./build.sh --package         ...and zip Mem.app + memread into dist/
set -e
cd "${0:A:h}"
version=1.0

rm -rf Mem.app
mkdir -p Mem.app/Contents/MacOS
swiftc -O -whole-module-optimization main.swift -o Mem.app/Contents/MacOS/Mem
cat > Mem.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mem</string>
  <key>CFBundleIdentifier</key><string>local.mem</string>
  <key>CFBundleExecutable</key><string>Mem</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
</dict></plist>
EOF
codesign --force --sign - Mem.app
cc -O2 -Wall -o memread memread.c
echo "built $(pwd)/Mem.app and memread"

case "$1" in
  --install)
    mkdir -p ~/Applications && rm -rf ~/Applications/Mem.app && cp -R Mem.app ~/Applications/
    echo "installed ~/Applications/Mem.app" ;;
  --install-helper)
    sudo mkdir -p /usr/local/libexec
    sudo install -o root -g wheel -m 4755 memread /usr/local/libexec/memread
    echo "installed /usr/local/libexec/memread (setuid root)" ;;
  --package)
    mkdir -p dist && rm -f dist/Mem-$version.zip
    ditto -c -k --norsrc --noextattr --keepParent Mem.app dist/Mem-$version.zip
    zip -qj dist/Mem-$version.zip memread
    echo "packaged dist/Mem-$version.zip" ;;
esac
