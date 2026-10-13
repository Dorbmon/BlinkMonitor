#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER="${FLUTTER:-flutter}"
"$FLUTTER" pub get
case "$(uname -s)" in
  Darwin)
    "$FLUTTER" build macos --release
    APP_PATH="$PWD/build/macos/Build/Products/Release/BlinkMonitor.app"
    echo "Built $APP_PATH"
    if [[ "${1:-}" == --open ]]; then open "$APP_PATH"; fi
    ;;
  Linux)
    "$FLUTTER" build linux --release
    echo 'Built the Linux bundle under build/linux/. Run scripts/setup-linux-backend.sh before tracking.'
    ;;
  *) echo 'BlinkMonitor supports macOS and Linux.' >&2; exit 1 ;;
esac
