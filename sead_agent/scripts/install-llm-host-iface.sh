#!/bin/sh
# Installs and starts sead-llm-host.service, which provides the host-only
# address (10.123.0.1) that the SEAD agent's LLM tunnel binds to.
# Run with sudo. Safe to re-run.
set -eu

UNIT=sead-llm-host.service
SRC="$(cd "$(dirname "$0")" && pwd)/$UNIT"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script needs root: sudo $0" >&2
    exit 1
fi

install -m 0644 "$SRC" /etc/systemd/system/$UNIT
systemctl daemon-reload
systemctl enable --now $UNIT

echo
echo "seadllm0 is up:"
ip -br addr show seadllm0
echo
echo "Bind the model tunnel to it, e.g.:"
echo "  ssh -N -L 10.123.0.1:5040:130.239.57.100:8081 johan@berra.humlab.umu.se"
