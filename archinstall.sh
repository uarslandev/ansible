#!/usr/bin/env bash
#
# Automated Arch Linux + Encrypted ZFS + Automated User + Ansible Repo Setup
#

set -euo pipefail

# --- HARDCODED CONFIGURATION ---
ANSIBLE_REPO="https://github.com/uarslandev/ansible.git"

# --- CHECK PRE-REQUISITES ---
if [[ $EUID -ne 0 ]]; then
   echo "[!] This script must be run as root." 
   exit 1
fi

if ! modprobe zfs &>/dev/null; then
    echo "[!] ZFS kernel module not loaded. Make sure you are using a ZFS-enabled Arch ISO."
    exit 1
fi

echo "=== Arch Linux + Encrypted ZFS + Ansible Installer ==="
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

# ZFS Passphrase
read -rsp "Enter ZFS Encryption Passphrase: " ZFS_PASSPHRASE
echo ""
read -rsp "Confirm ZFS Encryption Passphrase: " ZFS_PASSPHRASE_CONFIRM
echo ""
if [[ "$ZFS_PASSPHRASE" != "$ZFS_PASSPHRASE_CONFIRM" ]]; then
    echo "[!] Passphrases do not match."
    exit 1
fi

# User Account Creation Setup
read -rp "Enter new username to create: " NEW_USER
read -rsp "Enter password for $NEW_USER: " USER_PASS
echo ""
read -rsp "Enter Root password: " ROOT_PASS
echo ""

read -rp "Enter Hostname [arch-zfs]: " HOST_NAME
HOST_NAME=${HOST_NAME:-arch-zfs}

# --- 1. PARTITIONING ---
echo "[+] Wiping and partitioning $TARGET_DISK..."
sgdisk --zap-all "$TARGET_DISK"
partprobe "$TARGET_DISK"

sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$TARGET_DISK"
sgdisk -n 2:0:0   -t 2:bf00 -c 2:ZFS "$TARGET_DISK"
partprobe "$TARGET_DISK"

if [[ "$TARGET_DISK" =~ "nvme" ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ZFS_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ZFS_PART="${TARGET_DISK}2"
fi

ZFS_PART_BY_ID="/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$ZFS_PART")"

echo "[+] Formatting EFI Partition..."
mkfs.vfat -F32 "$EFI_PART"

# --- 2. CREATE ZPOOL & DATASETS ---
echo "[+] Creating encrypted ZFS Pool 'zroot'..."
echo "$ZFS_PASSPHRASE" | zpool create -f -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O relatime=on \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=none \
    -O canmount=off \
    -O devices=off \
    -O compression=lz4 \
    -O encryption=aes-256-gcm \
    -O keyformat=passphrase \
    -O keylocation=prompt \
    -R /mnt \
    zroot "$ZFS_PART_BY_ID"

echo "[+] Creating datasets..."
zfs create -o mountpoint=none zroot/data
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/default
zfs create -o mountpoint=/home zroot/data/home
zfs create -o mountpoint=/root zroot/data/home/root

zfs create -o mountpoint=/var -o canmount=off zroot/var
zfs create zroot/var/log
zfs create -o mountpoint=/var/log/journal -o acltype=posixacl zroot/var/log/journal
zfs create -o mountpoint=/var/lib -o canmount=off zroot/var/lib
zfs create zroot/var/lib/libvirt
zfs create zroot/var/lib/docker

zfs mount zroot/ROOT/default
zfs mount -a

mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

zpool set bootfs=zroot/ROOT/default zroot
mkdir -p /mnt/etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache zroot
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# --- 3. PACSTRAP MINIMAL SYSTEM + ANSIBLE ---
echo "[+] Installing minimal base system, Ansible, git, and sudo..."
pacstrap /mnt base base-devel linux-lts linux-lts-headers firmware-linux libunwind efibootmgr nano networkmanager git ansible sudo

genfstab -U -p /mnt >> /mnt/etc/fstab

# --- 4. CONFIGURATION IN CHROOT ---
echo "[+] Configuring system in chroot..."
HOSTID_VAL=$(hostid)

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

# Configure ArchZFS Repo
cat << 'EOF' >> /etc/pacman.conf

[archzfs]
SigLevel = TrustAll Optional
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

pacman -Sy --noconfirm zfs-dkms zfs-utils

# Set HostID & Services
zgenhostid ${HOSTID_VAL}
systemctl enable NetworkManager
systemctl enable zfs.target
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target

# mkinitcpio Setup
sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect modprobes block zfs filesystems)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES=.*/MODULES=(zfs)/' /etc/mkinitcpio.conf
mkinitcpio -p linux-lts

# Bootloader Setup
bootctl install

cat << 'EOF' > /boot/loader/loader.conf
default arch-zfs.conf
timeout 3
console-mode max
EOF

cat << EOF > /boot/loader/entries/arch-zfs.conf
title   Arch Linux (ZFS Encrypted)
linux   /vmlinuz-linux-lts
initrd  /initramfs-linux-lts.img
options root=ZFS=zroot/ROOT/default rw spl.spl_hostid=0x${HOSTID_VAL}
EOF

# Clone Ansible Repository into User's Home Directory
echo "[+] Cloning ${ANSIBLE_REPO} into /home/${NEW_USER}/ansible..."
sudo -u "${NEW_USER}" git clone "${ANSIBLE_REPO}" "/home/${NEW_USER}/ansible"

CHROOT_SCRIPT

# --- 5. CLEANUP ---
echo "[+] Exporting zpools and unmounting..."
umount /mnt/boot || true
zfs umount -a
zfs umount zroot/ROOT/default
zpool export zroot

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "Created user '${NEW_USER}' with full sudo access."
echo "Ansible repository cloned to '/home/${NEW_USER}/ansible'."
echo "You can now safely reboot!"
