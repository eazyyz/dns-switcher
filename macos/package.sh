#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

host_arch=$(uname -m)

mkdir -p dist .build
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/dns-switcher.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
app="$staging_dir/DNS Switcher.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for build_arch in arm64 x86_64; do
    ./macos/build.sh --arch "$build_arch"
    build_dir=.build/macos
    if [[ "$build_arch" != "$host_arch" ]]; then build_dir=".build/macos-$build_arch"; fi
    cp "$build_dir/dns-switcher" "$staging_dir/dns-switcher-$build_arch"
    cp "$build_dir/DNS-Switcher-Launcher" "$staging_dir/launcher-$build_arch"
done
/usr/bin/lipo -create "$staging_dir/dns-switcher-arm64" "$staging_dir/dns-switcher-x86_64" -output "$app/Contents/MacOS/dns-switcher"
/usr/bin/lipo -create "$staging_dir/launcher-arm64" "$staging_dir/launcher-x86_64" -output "$app/Contents/MacOS/DNS-Switcher-Launcher"
cp macos/Resources/Info.plist "$app/Contents/Info.plist"
cp macos/Resources/run.command "$app/Contents/Resources/run.command"
bash macos/build-icons.sh
cp .build/icons/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
chmod 755 "$app/Contents/MacOS/"* "$app/Contents/Resources/run.command"
# codesign rejects Finder metadata.
/usr/bin/xattr -cr "$app"

signing_identity=${DNS_SWITCHER_SIGNING_IDENTITY:--}
signing_flags=(--force --sign "$signing_identity")
if [[ "$signing_identity" != - ]]; then signing_flags+=(--options runtime --timestamp); fi
/usr/bin/codesign "${signing_flags[@]}" "$app/Contents/MacOS/dns-switcher"
/usr/bin/codesign "${signing_flags[@]}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$app" "$staging_dir/DNS-Switcher-macOS.zip"

if [[ -e 'dist/DNS Switcher.app' ]]; then rm -rf -- 'dist/DNS Switcher.app'; fi
mv "$app" 'dist/DNS Switcher.app'
# Finder/file providers can attach metadata when the bundle reaches its final folder.
/usr/bin/xattr -cr 'dist/DNS Switcher.app'
/usr/bin/codesign --verify --deep --strict 'dist/DNS Switcher.app'
mv -f "$staging_dir/DNS-Switcher-macOS.zip" dist/DNS-Switcher-macOS.zip
printf '\nReady: dist/DNS-Switcher-macOS.zip (Intel + Apple Silicon, macOS 12+)\n'
