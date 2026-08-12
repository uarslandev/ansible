#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Arch Linux + ZFS Native Encryption Installer
# ==============================================================================

COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_WARN="\033[1;33m"
COLOR_ERR="\033[1;31m"

log_info() { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $1"; }
log_warn() { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $1"; }
log_err()  { echo -e "${COLOR_ERR}[ERROR]${COLOR_RESET} $1"; }

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_err "This script must be run as root."
    exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    log_err "UEFI mode is required. Boot in UEFI mode and retry."
    exit 1
fi

if ! command -v zpool &>/dev/null; then
    log_err "ZFS utilities not detected. Ensure you are booted into an ArchZFS live ISO."
    exit 1
fi

# ------------------------------------------------------------------------------
# User Configuration Input
# ------------------------------------------------------------------------------
echo "=================================================================="
echo "                   Arch Linux ZFS Setup Wizard                    "
echo "=================================================================="

lsblk -d -n -o NAME,SIZE,MODEL | grep -v "^loop"

read -rp "Target disk device (e.g., /dev/nvme0n1 or /dev/sda): " TARGET_DISK
read -rp "Hostname: " HOSTNAME
read -rp "Username: " USERNAME
read -r -s -p "ZFS Pool Encryption Passphrase: " ZFS_PASSPHRASE
echo ""
read -r -s -p "Root & User Password: " USER_PASSWORD
echo ""
read -rp "Ansible Dotfiles/Config Git Repository URL (optional): " ANSIBLE_REPO

POOL_NAME="zroot"
MOUNT_POINT="/mnt"

# Detect NVMe naming scheme vs standard SCSI/SATA
if [[ "${TARGET_DISK}" =~ nvme ]]; then
    BOOT_PART="${TARGET_DISK}p1"
    ZFS_PART="${TARGET_DISK}p2"
else
    BOOT_PART="${TARGET_DISK}1"
    ZFS_PART="${TARGET_DISK}2"
fi

# ------------------------------------------------------------------------------
# [1/7] Partitioning Disk
# ------------------------------------------------------------------------------
log_info "[1/7] Partitioning disk ${TARGET_DISK}..."

sgdisk --zap-all "${TARGET_DISK}"
partprobe "${TARGET_DISK}"

# 1GB EFI Partition, remaining space for ZFS Pool
sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI-system" "${TARGET_DISK}"
sgdisk -n 2:0:0   -t 2:BF00 -c 2:"ZFS-storage" "${TARGET_DISK}"
partprobe "${TARGET_DISK}"

mkfs.vfat -F 32 -n "EFI" "${BOOT_PART}"

# ------------------------------------------------------------------------------
# [2/7] Creating ZFS Pool with Native Encryption
# ------------------------------------------------------------------------------
log_info "[2/7] Creating encrypted ZFS Pool '${POOL_NAME}'..."

echo -n "${ZFS_PASSPHRASE}" | zpool create -f -o ashift=12 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O encryption=on \
    -O keyformat=passphrase \
    -O keylocation=prompt \
    -O canmount=off \
    -O mountpoint=none \
    -R "${MOUNT_POINT}" \
    "${POOL_NAME}" "${ZFS_PART}"

# ------------------------------------------------------------------------------
# [3/7] Creating ZFS Datasets
# ------------------------------------------------------------------------------
log_info "[3/7] Setting up dataset hierarchy..."

# Root containers
zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/ROOT"
zfs create -o canmount=noauto -o mountpoint=/ "${POOL_NAME}/ROOT/default"
zfs mount "${POOL_NAME}/ROOT/default"

# Data containers
zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/DATA"
zfs create -o mountpoint=/home "${POOL_NAME}/DATA/home"
zfs create -o mountpoint=/root "${POOL_NAME}/DATA/home/root"

# System state containers
zfs create -o mountpoint=/var -o canmount=off "${POOL_NAME}/VAR"
zfs create -o mountpoint=/var/log "${POOL_NAME}/VAR/log"
zfs create -o com.sun:auto-snapshot=false -o mountpoint=/var/cache "${POOL_NAME}/VAR/cache"

# Mount EFI partition
mkdir -p "${MOUNT_POINT}/boot"
mount "${BOOT_PART}" "${MOUNT_POINT}/boot"

# Export and re-import pool to verify mount layout
zpool set bootfs="${POOL_NAME}/ROOT/default" "${POOL_NAME}"
zpool export "${POOL_NAME}"
echo -n "${ZFS_PASSPHRASE}" | zpool import -N -R "${MOUNT_POINT}" "${POOL_NAME}"
echo -n "${ZFS_PASSPHRASE}" | zfs load-key "${POOL_NAME}"
zfs mount "${POOL_NAME}/ROOT/default"
zfs mount -a

mkdir -p "${MOUNT_POINT}/boot"
mount "${BOOT_PART}" "${MOUNT_POINT}/boot"

# ------------------------------------------------------------------------------
# [4/4] Pacstrap Base Packages
# ------------------------------------------------------------------------------
log_info "[4/7] Installing base system via pacstrap..."

pacstrap -K "${MOUNT_POINT}" \
    base \
    base-devel \
    linux \
    linux-headers \
    linux-firmware \
    zfs-linux \
    git \
    ansible \
    sudo \
    neovim \
    networkmanager \
    efibootmgr \
    curl \
    jq

# Generate fstab (EFI partition only; ZFS manages dataset mounts)
genfstab -U "${MOUNT_POINT}" | grep -v "${POOL_NAME}" > "${MOUNT_POINT}/etc/fstab"

# Copy ZFS pool cache to installed environment
mkdir -p "${MOUNT_POINT}/etc/zfs"
zpool set cachefile=/etc/zfs/zpool.cache "${POOL_NAME}"
cp /etc/zfs/zpool.cache "${MOUNT_POINT}/etc/zfs/zpool.cache"

# ------------------------------------------------------------------------------
# [5/7] Configuring System
# ------------------------------------------------------------------------------
log_info "[5/7] Configuring base system parameters..."

# Resolve system details with explicit fallback parameters (prevents set -u crashes)
cpu_total="$(nproc 2>/dev/null || echo 2)"
latest_url=""

# Safely fetch latest mirror/repository metadata if needed
latest_url="$(curl -s https://archlinux.org/download/ | grep -oP 'https://[^\"]*archlinux-[0-9\.]*-x86_64\.iso' | head -n1 || echo "")"

if [[ -z "${latest_url:-}" ]]; then
    log_warn "Notice: latest_url was empty or unreachable. Proceeding with fallback configuration."
fi

log_info "Configuring build concurrency with cpu_total=${cpu_total:-1}..."

# Apply parallel compilation settings to makepkg.conf
sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j${cpu_total:-2}\"/" "${MOUNT_POINT}/etc/makepkg.conf"

# Generate locale & timezone inside target
chroot "${MOUNT_POINT}" /bin/bash -c "
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    hwclock --systohc
    echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
    locale-gen
    echo 'LANG=en_US.UTF-8' > /etc/locale.conf
    echo '${HOSTNAME}' > /etc/hostname
"

# Configure Host ID for ZFS stability
zfs_hostid="$(hostid)"
chroot "${MOUNT_POINT}" /bin/bash -c "zgenhostid ${zfs_hostid}"

# Create User and Set Passwords
chroot "${MOUNT_POINT}" /bin/bash -c "
    echo 'root:${USER_PASSWORD}' | chpasswd
    useradd -m -G wheel -s /bin/bash '${USERNAME}'
    echo '${USERNAME}:${USER_PASSWORD}' | chpasswd
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
"

# ------------------------------------------------------------------------------
# [6/7] Bootloader & Initramfs Setup
# ------------------------------------------------------------------------------
log_info "[6/7] Configuring initcpio and systemd-boot..."

# Configure HOOKS in /etc/mkinitcpio.conf for ZFS native encryption
chroot "${MOUNT_POINT}" /bin/bash -c "
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modprobed-db kms keyboard keymap consolefont block zfs filesystems fsck)/' /etc/mkinitcpio.conf
    mkinitcpio -P
"

# Install systemd-boot
chroot "${MOUNT_POINT}" /bin/bash -c "
    bootctl install
"

# Systemd-boot Loader entry configuration
cat <<EOF > "${MOUNT_POINT}/boot/loader/loader.conf"
default arch.conf
timeout 3
console-mode max
editor no
EOF

UUID_ZFS=$(blkid -s PARTUUID -o value "${ZFS_PART}")

cat <<EOF > "${MOUNT_POINT}/boot/loader/entries/arch.conf"
title   Arch Linux (ZFS)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options zfs=${POOL_NAME}/ROOT/default rw root=ZFS=${POOL_NAME}/ROOT/default rw zfs_import_dir=/dev/disk/by-partuuid/${UUID_ZFS}
EOF

# Enable core services inside target
chroot "${MOUNT_POINT}" /bin/bash -c "
    systemctl enable NetworkManager
    systemctl enable zfs-import-cache
    systemctl enable zfs-mount
    systemctl enable zfs-import.target
    systemctl enable zfs.target
"

# ------------------------------------------------------------------------------
# [7/7] Ansible Integration & Cleanup
# ------------------------------------------------------------------------------
log_info "[7/7] Executing post-installation tasks..."

if [[ -n "${ANSIBLE_REPO:-}" ]]; then
    log_info "Cloning Ansible configuration repository..."
    chroot "${MOUNT_POINT}" /bin/bash -c "
        git clone '${ANSIBLE_REPO}' '/home/${USERNAME}/.ansible-config'
        chown -R ${USERNAME}:${USERNAME} '/home/${USERNAME}/.ansible-config'
    "
    
    if [[ -f "${MOUNT_POINT}/home/${USERNAME}/.ansible-config/setup.yml" ]]; then
        log_info "Executing local Ansible playbook..."
        chroot "${MOUNT_POINT}" /bin/bash -c "
            su - '${USERNAME}' -c 'ansible-playbook ~/.ansible-config/setup.yml --connection=local'
        "
    fi
fi

log_info "Unmounting ZFS datasets and exporting pool..."
umount -R "${MOUNT_POINT}/boot" || true
zfs umount -a
zpool export "${POOL_NAME}"

log_info "Installation complete! You can now run 'reboot'."
