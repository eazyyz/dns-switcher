#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
host_arch=$(uname -m)
build_arch=$host_arch
run_tests=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tests) run_tests=true; shift ;;
        --arch)
            [[ $# -ge 2 ]] || { printf 'Missing architecture\n' >&2; exit 1; }
            build_arch=$2; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
done
[[ "$build_arch" == arm64 || "$build_arch" == x86_64 ]] || { printf 'Unsupported architecture\n' >&2; exit 1; }
[[ "$run_tests" == false || "$build_arch" == "$host_arch" ]] || { printf 'Tests must run on the host architecture\n' >&2; exit 1; }
build_dir=.build/macos
if [[ "$build_arch" != "$host_arch" ]]; then build_dir=".build/macos-$build_arch"; fi
mkdir -p "$build_dir"
# Use the selected toolchain's SDK.
developer_dir=$(/usr/bin/xcode-select -p)
sdk_path=${SDKROOT:-}
if [[ -z "$sdk_path" ]]; then
    if [[ -d "$developer_dir/SDKs/MacOSX.sdk" ]]; then
        sdk_path="$developer_dir/SDKs/MacOSX.sdk"
    else
        sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
    fi
fi
flags=(-sdk "$sdk_path" -target "$build_arch-apple-macosx12.0" -swift-version 5 -O)
if [[ "$run_tests" == true ]]; then flags+=(-enable-testing); fi
defaults_base64=$(/usr/bin/base64 < lists/dns-defaults.txt | /usr/bin/tr -d '\r\n')
cat > "$build_dir/DefaultDNSList.swift" <<EOF
import Foundation
enum DefaultDNSList {
    static let text = String(data: Data(base64Encoded: "$defaults_base64")!, encoding: .utf8)!
}
EOF
/usr/bin/xcrun swiftc "${flags[@]}" -parse-as-library -emit-library -static \
    -emit-module -module-name DNSSwitcherCore macos/Sources/DNSSwitcherCore/*.swift "$build_dir/DefaultDNSList.swift" \
    -o "$build_dir/libDNSSwitcherCore.a" -emit-module-path "$build_dir/DNSSwitcherCore.swiftmodule"
/usr/bin/xcrun swiftc "${flags[@]}" -I "$build_dir" -L "$build_dir" -lDNSSwitcherCore \
    macos/Sources/dns-switcher/main.swift -o "$build_dir/dns-switcher"
if [[ "$run_tests" == true ]]; then
    /usr/bin/xcrun swiftc "${flags[@]}" -I "$build_dir" -L "$build_dir" -lDNSSwitcherCore \
        tests/macos.swift -o "$build_dir/core-tests"
    "$build_dir/core-tests"
fi
