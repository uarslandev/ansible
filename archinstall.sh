#!/usr/bin/env bash
set -euo pipefail

ANSIBLE_REPO="https://github.com/uarslandev/ansible.git"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

echo "======================================================================"
echo " ARCH + ENCRYPTED ZFS INSTALLER"
echo "======================================================================"

umount -R /mnt 2>/dev/null || true
zpool export -f zroot 2>/dev/null || true

lsblk
echo

read -rp "Target disk: " DISK
[[ -b "$DISK" ]] || { echo "Invalid disk."; exit 1; }

echo
echo "WARNING: $DISK WILL BE ERASED."
read -rp "Type YES to continue: " OK
[[ "$OK" == "YES" ]] || exit 1

pass() {
    local a b
    while :; do
        read -rsp "$1: " a; echo
        read -rsp "Confirm: " b; echo
        [[ -n "$a" && "$a" == "$b" ]] && { printf '%s' "$a"; return; }
        echo "Passwords do not match."
    done
}

ZFS_PASS=$(pass "ZFS passphrase")

read -rp "Username: " USER
USER_PASS=$(pass "Password for $USER")
ROOT_PASS=$(pass "Root password")

read -rp "Hostname [arch-zfs]: " HOST
HOST=${HOST:-arch-zfs}

# Partition disk
sgdisk --zap-all "$DISK"
partprobe "$DISK"

sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n 2:0:0   -t 2:bf00 -c 2:ZFS "$DISK"
partprobe "$DISK"
sleep 2

if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
    EFI="${DISK}p1"
    ZFS="${DISK}p2"
else
    EFI="${DISK}1"
    ZFS="${DISK}2"
fi

mkfs.vfat -F32 "$EFI"

ZFS_ID="/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$ZFS")"

# Encrypted ZFS pool
printf '%s\n' "$ZFS_PASS" | zpool create -f \
    -o ashift=12 \
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
    zroot "$ZFS_ID"

# Datasets
zfs create -o mountpoint=none zroot/data
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/default
zfs create -o mountpoint=/home zroot/data/home
zfs create -o mountpoint=/root zroot/data/home/root
zfs create -o mountpoint=/var -o canmount=off zroot/var
zfs create zroot/var/log
zfs create -o mountpoint=/var/log/journal zroot/var/log/journal
zfs create -o mountpoint=/var/lib -o canmount=off zroot/var/lib
zfs create zroot/var/lib/libvirt
zfs create zroot/var/lib/docker

zfs mount zroot/ROOT/default
zfs mount -a

mkdir -p /mnt/boot /mnt/etc/zfs
mount "$EFI" /mnt/boot

zpool set bootfs=zroot/ROOT/default zroot
zpool set cachefile=/mnt/etc/zfs/zpool.cache zroot

# Base system -- deliberately install ZFS before linux-lts
pacstrap -K /mnt \
    base base-devel dkms zfs-dkms zfs-utils \
    linux-firmware libunwind efibootmgr nano \
    networkmanager git ansible sudo

genfstab -U /mnt >> /mnt/etc/fstab

# Basic system configuration
arch-chroot /mnt systemd-firstboot \
    --hostname="$HOST" \
    --locale=en_US.UTF-8 \
    --timezone=UTC

echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen

echo "KEYMAP=us" > /mnt/etc/vconsole.conf

echo "root:$ROOT_PASS" | arch-chroot /mnt chpasswd

arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USER"
echo "$USER:$USER_PASS" | arch-chroot /mnt chpasswd

mkdir -p /mnt/etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
chmod 440 /mnt/etc/sudoers.d/wheel

# ZFS repository
cat >> /mnt/etc/pacman.conf <<'EOF'

[archzfs]
SigLevel = TrustAll Optional
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

# ZFS host ID
HOSTID=$(hostid)
arch-chroot /mnt zgenhostid "$HOSTID"

# ZFS initramfs configuration
cat > /mnt/etc/mkinitcpio.conf <<'EOF'
MODULES=(zfs)
HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block zfs filesystems)
EOF

# Kernel after ZFS hook is installed/configured
arch-chroot /mnt pacman -S --noconfirm linux-lts linux-lts-headers

# Make sure DKMS is built
arch-chroot /mnt dkms autoinstall

# Services
systemctl --root=/mnt enable \
    NetworkManager \
    zfs.target \
    zfs-import-cache \
    zfs-mount \
    zfs-import.target

# Initramfs
arch-chroot /mnt mkinitcpio -P

# Bootloader
arch-chroot /mnt bootctl install

cat > /mnt/boot/loader/loader.conf <<'EOF'
default arch-zfs.conf
timeout 3
editor no
EOF

cat > /mnt/boot/loader/entries/arch-zfs.conf <<EOF
title Arch Linux (ZFS Encrypted)
linux /vmlinuz-linux-lts
initrd /initramfs-linux-lts.img
options root=ZFS=zroot/ROOT/default rw spl.spl_hostid=0x${HOSTID}
EOF

# Ansible
arch-chroot /mnt sudo -u "$USER" \
    git clone "$ANSIBLE_REPO" "/home/$USER/ansible"

# Finish
umount /mnt/boot || true
zfs umount -a || true
zpool export zroot

echo
echo "======================================================================"
echo " INSTALL COMPLETE"
echo " Reboot and select 'Arch Linux (ZFS Encrypted)'"
echo "======================================================================"
