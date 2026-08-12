#!/usr/bin/env bash
set -euo pipefail

# Check if paru is already installed
if command -v paru >/dev/null 2>&1; then
  echo "paru is already installed."
  exit 0
fi

echo "Installing paru..."

# Try pacman first in case paru is available in configured repos
if pacman -Sy --noconfirm --needed paru 2>/dev/null; then
  echo "paru successfully installed via pacman."
  exit 0
fi

# Fallback: Build paru-bin from AUR
echo "paru not found in pacman repositories. Building paru-bin from AUR..."

# Ensure build dependencies (base-devel, git) are present
if [[ "${EUID}" -eq 0 ]]; then
  pacman -S --needed --noconfirm base-devel git
else
  sudo pacman -S --needed --noconfirm base-devel git
fi

BUILD_DIR=$(mktemp -d /tmp/paru-build.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

BUILD_USER="${SUDO_USER:-$(whoami)}"
if [[ "$BUILD_USER" == "root" ]]; then
  BUILD_USER=$(id -nu 1000 2>/dev/null || echo "")
fi

if [[ -z "$BUILD_USER" || "$BUILD_USER" == "root" ]]; then
  echo "Error: Cannot run makepkg as root. Please run as a non-root user or via sudo."
  exit 1
fi

chown -R "$BUILD_USER:" "$BUILD_DIR"

su - "$BUILD_USER" -c "
  set -euo pipefail
  git clone https://aur.archlinux.org/paru-bin.git '$BUILD_DIR/paru-bin'
  cd '$BUILD_DIR/paru-bin'
  makepkg -si --noconfirm
"

echo "paru installed successfully!"

