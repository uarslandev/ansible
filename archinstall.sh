#!/usr/bin/env bash
#
# Automated Arch Linux + Minimal Base + User Setup + Ansible Repo Setup
# (Standard EXT4 Partitioning - No ZFS)
#

set -euo pipefail

# --- HARDCODED CONFIGURATION ---
ANSIBLE_REPO="https://github.com/uarslandev/ansible.git"

# --- CHECK PRE-REQUISITES ---
if [[ $EUID -ne 0 ]]; then
   echo "[!] This script must be run as root." 
   exit 1
fi

echo "=== Automated Arch Linux + Ansible Installer ==="
lsblk
echo ""

# --- AUTOMATED PROMPTS ---
read -rp "Enter target disk device (e.g. /dev/nvme0n1 or /dev/sda): " TARGET_DISK

if [[ ! -b "$TARGET_DISK" ]]; then
    echo "[!] Invalid block device: $TARGET_DISK"
    exit 1
fi

echo ""
echo "[DANGER] Entire contents of $TARGET_DISK will be erased!"
read -rp "Type 'YES' to confirm disk wipe: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# User Account Setup
read -rp "Enter new username to create: " NEW_USER
read -rsp "Enter password for $NEW_USER: " USER_PASS
echo ""
read -rsp "Enter Root password: " ROOT_PASS
echo ""

read -rp "Enter Hostname [arch-box]: " HOST_NAME
HOST_NAME=${HOST_NAME:-arch-box}

# --- 1. PARTITIONING ---
echo "[+] Wiping and partitioning $TARGET_DISK..."
sgdisk --zap-all "$TARGET_DISK"
partprobe "$TARGET_DISK"

# Partition 1: EFI System Partition (1G, ef00)
# Partition 2: Root Partition (Remaining space, 8300)
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$TARGET_DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:ROOT "$TARGET_DISK"
partprobe "$TARGET_DISK"

if [[ "$TARGET_DISK" =~ "nvme" ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

echo "[+] Formatting partitions..."
mkfs.vfat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

# --- 2. MOUNT FILESYSTEMS ---
echo "[+] Mounting filesystems..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# --- 3. PACSTRAP MINIMAL SYSTEM + ANSIBLE ---
echo "[+] Installing minimal base system, Linux kernel, Ansible, Git, and Sudo..."
pacstrap /mnt base base-devel linux linux-firmware efibootmgr nano networkmanager git ansible sudo

genfstab -U /mnt >> /mnt/etc/fstab

# --- 4. CONFIGURATION IN CHROOT ---
echo "[+] Configuring system in chroot..."

cat <<CHROOT_SCRIPT | arch-chroot /mnt /bin/bash
set -euo pipefail

# Time & Locale
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "${HOST_NAME}" > /etc/hostname

# Set Root Password
echo "root:${ROOT_PASS}" | chpasswd

# Automated User Creation & Sudo Setup
useradd -m -G wheel -s /bin/bash "${NEW_USER}"
echo "${NEW_USER}:${USER_PASS}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Enable NetworkManager
systemctl enable NetworkManager

# Regenerate Initramfs
mkinitcpio -P

# Bootloader Setup (systemd-boot)
bootctl install

cat << 'EOF' > /boot/loader/loader.conf
default arch.conf
timeout 3
console-mode max
EOF

ROOT_UUID=\$(blkid -s UUID -o value "${ROOT_PART}")

cat << EOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=\${ROOT_UUID} rw
EOF

# Clone Ansible Repository into User's Home Directory
echo "[+] Cloning ${ANSIBLE_REPO} into /home/${NEW_USER}/ansible..."
sudo -u "${NEW_USER}" git clone "${ANSIBLE_REPO}" "/home/${NEW_USER}/ansible"

CHROOT_SCRIPT

# --- 5. CLEANUP ---
echo "[+] Unmounting filesystems..."
umount -R /mnt

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "Created user '${NEW_USER}' with full sudo access."
echo "Ansible repository cloned to '/home/${NEW_USER}/ansible'."
echo "You can now safely reboot!"
