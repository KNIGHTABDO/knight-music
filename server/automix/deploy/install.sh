#!/usr/bin/env bash
# Installs/updates the AutoMix service on the Navidrome host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$HOME/automix"
mkdir -p "$ROOT/app" "$ROOT/data"
if [ ! -x "$ROOT/.venv/bin/python" ]; then
  uv venv -q --python 3.12 "$ROOT/.venv"
  uv pip install -q --python "$ROOT/.venv/bin/python" torch torchaudio --index-url https://download.pytorch.org/whl/cpu
  uv pip install -q --python "$ROOT/.venv/bin/python" "git+https://github.com/CPJKU/beat_this" librosa soundfile soxr numpy scipy
fi
rsync -a --delete "$HERE/automix/" "$ROOT/app/automix/"
sudo install -m 644 "$HERE/deploy/knight-automix.service" /etc/systemd/system/knight-automix.service
sudo systemctl daemon-reload
sudo systemctl enable --now knight-automix.service
sudo systemctl restart knight-automix.service
# Public (and tailnet) access next to Navidrome: https://<host>/automix/... -> 127.0.0.1:4534/automix/...
# `funnel` (not `serve`): a plain serve on 443 would switch the public Funnel off.
tailscale funnel --bg --https=443 --set-path /automix http://127.0.0.1:4534/automix >/dev/null
echo "AutoMix installed. Status: curl -s http://127.0.0.1:4534/automix/v1/health"
