#!/bin/bash
# Installs capture-streamd as a systemd user service. No root needed.
set -euo pipefail
cd "$(dirname "$0")"

python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' \
  || { echo "capture-streamd needs Python 3.11 or newer"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found; install it first (e.g. sudo apt install ffmpeg)"; exit 1; }

LIB=~/.local/lib/capture-stream
CONF=~/.config/capture-stream
UNIT=~/.config/systemd/user

mkdir -p "$LIB" "$CONF" "$UNIT"
install -m755 capture-streamd.py "$LIB/"
install -m644 capture-streamd.service "$UNIT/"
if [ ! -e "$CONF/config.toml" ]; then
  install -m644 config.example.toml "$CONF/config.toml"
  echo "Created $CONF/config.toml; edit it to match your capture card."
fi

systemctl --user daemon-reload
systemctl --user enable capture-streamd.service
systemctl --user restart capture-streamd.service
systemctl --user --no-pager status capture-streamd.service | head -5

if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
  echo
  echo "To keep it running when you're logged out, run once: sudo loginctl enable-linger $USER"
fi
