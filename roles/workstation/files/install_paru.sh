#!/usr/bin/env bash
set -euo pipefail

if command -v paru >/dev/null 2>&1; then
  exit 0
fi

if [[ "${EUID}" -eq 0 ]]; then
  pacman -Sy --noconfirm --needed paru
else
  sudo pacman -Sy --noconfirm --needed paru
fi
