#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
resources_dir=$(cd -- "$(dirname -- "$0")" && pwd)
exec "$resources_dir/../MacOS/dns-switcher" --menu
