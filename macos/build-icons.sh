#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

iconset=.build/icons/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" macos/Resources/AppIcon.png \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    /usr/bin/sips -z "$pixels" "$pixels" macos/Resources/AppIcon.png \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o .build/icons/AppIcon.icns
