#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Linux ]]; then
  echo 'This installer is for Linux. macOS uses the built-in Swift/Vision backend.' >&2
  exit 1
fi
PYTHON="${PYTHON:-python3}"
"$PYTHON" -c 'import sys; assert (3, 10) <= sys.version_info[:2] <= (3, 12), "Use Python 3.10–3.12 (PYTHON=python3.12)."'
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/blinkmonitor"
mkdir -p "$DATA_DIR/models"
"$PYTHON" -m venv "$DATA_DIR/venv"
"$DATA_DIR/venv/bin/python" -m pip install -r backend/linux/requirements.txt
MODEL="$DATA_DIR/models/face_landmarker.task"
if [[ ! -f "$MODEL" ]]; then
  curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
    'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task' \
    -o "$MODEL.download"
  mv "$MODEL.download" "$MODEL"
fi
echo '64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff  '"$MODEL" | sha256sum --check --status || {
  echo 'Face model checksum mismatch. Remove the model and rerun setup.' >&2
  exit 1
}
"$DATA_DIR/venv/bin/python" backend/linux/blink_backend.py --model "$MODEL" --check
echo 'Linux camera backend is ready. Run flutter run -d linux.'
