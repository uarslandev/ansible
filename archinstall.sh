#!/usr/bin/env bash
set -euo pipefail

ANSIBLE_REPO="https://github.com/uarslandev/ansible.git"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

echo "======================================================================"
echo " ARCH + ENCRYPTED ZFS INSTALLER"
echo "======================================================================"
echo

umount -R /mnt 2>/dev/null || true
zpool export -f zroot 2>/dev/null || true

lsblk
echo

read -rp "Target disk: " DISK
[[ -b "$DISK" ]] || { echo "Invalid disk."; exit 1; }

echo
echo "WARNING: $DISK WILL BE COMPLETELY ERASED."
read -rp "Type YES to continue: " OK
[[ "$OK" == "YES" ]] || { echo "Aborted."; exit 1; }

echo
read -rp "Username: " USER
while [[ -z "$USER" ]]; do
    read -rp "Username: " USER
done

read -rsp "Password for $USER: " USER_PASS
echo
read -rsp "Confirm password: " USER_PASS2
echo
[[ "$USER_PASS" == "$USER_PASS2" && -n "$USER_PASS" ]] || {
    echo "Passwords do not match."
    exit 1
}

read -rsp "Root password: " ROOT_PASS
echo
read -rsp "Confirm root password: " ROOT_PASS2
echo
[[ "$ROOT_PASS" == "$ROOT_PASS2" && -n "$ROOT_PASS" ]] || {
    echo "Passwords do not match."
    exit 1
}

read -rp "Hostname [arch-zfs]: " HOST
HOST=${HOST:-arch-zfs}

# ---------------------------------------------------------------------------
# Partition
# ---------------------------------------------------------------------------

echo
echo "[+] Partitioning $DISK..."

sgdisk --zap-all "$DISK"
partprobe "$DISK"
sleep 2

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

# ---------------------------------------------------------------------------
# Encrypted ZFS pool
# ---------------------------------------------------------------------------

echo
echo "[+] Creating encrypted ZFS pool..."
echo "[+] ZFS will now ask for your encryption passphrase."
echo

zpool create -f \
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

# ---------------------------------------------------------------------------
# Datasets
# ---------------------------------------------------------------------------

echo "[+] Creating datasets..."

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

# ---------------------------------------------------------------------------
# Base system (Kernel included here to avoid broken DKMS hooks later)
# ---------------------------------------------------------------------------

echo "[+] Installing base system..."

pacstrap -K /mnt \
    base \
    base-devel \
    linux-lts \
    linux-lts-headers \
    linux-firmware \
    dkms \
    efibootmgr \
    nano \
    networkmanager \
    git \
    ansible \
    sudo

genfstab -U /mnt >> /mnt/etc/fstab

# ---------------------------------------------------------------------------
# System configuration
# ---------------------------------------------------------------------------

echo "[+] Configuring system..."

HOSTID=$(hostid)

arch-chroot /mnt systemd-firstboot \
    --hostname="$HOST" \
    --locale="en_US.UTF-8" \
    --timezone="UTC"

echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen

echo "KEYMAP=us" > /mnt/etc/vconsole.conf

echo "root:$ROOT_PASS" | arch-chroot /mnt chpasswd

arch-chroot /mnt useradd \
    -m \
    -G wheel \
    -s /bin/bash \
    "$USER"

echo "$USER:$USER_PASS" | arch-chroot /mnt chpasswd

mkdir -p /mnt/etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
chmod 440 /mnt/etc/sudoers.d/wheel

# ---------------------------------------------------------------------------
# ArchZFS Repo Keyring & ZFS Package Installation
# ---------------------------------------------------------------------------

echo "[+] Setting up ArchZFS keys and repository..."

# Import and sign the ArchZFS repository key inside chroot
arch-chroot /mnt pacman-key --recv-keys DDF7FD3B505E1FC14A4D35F6F38B5859362B6608
arch-chroot /mnt pacman-key --lsign-key DDF7FD3B505E1FC14A4D35F6F38B5859362B6608

cat >> /mnt/etc/pacman.conf <<'EOF'

[archzfs]
SigLevel = Required DatabaseOptional
Server = https://archzfs.com/$repo/$arch
Server = https://github.com/archzfs/archzfs/releases/download/$repo
EOF

arch-chroot /mnt pacman -Sy --noconfirm zfs-dkms zfs-utils

# Explicitly trigger DKMS compilation before building initramfs
echo "[+] Building ZFS kernel modules via DKMS..."
KERNEL_VER=$(arch-chroot /mnt pacman -Q linux-lts | awk '{print $2}' | cut -d'-' -f1)-lts
arch-chroot /mnt dkms autoinstall -k "$KERNEL_VER"

# ---------------------------------------------------------------------------
# ZFS configuration
# ---------------------------------------------------------------------------

echo "[+] Configuring ZFS..."

arch-chroot /mnt zgenhostid "$HOSTID"

cat > /mnt/etc/mkinitcpio.conf <<'EOF'
MODULES=(zfs)
HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block zfs filesystems)
EOF

# Copy the generated zpool.cache into target system root
cp /mnt/etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

systemctl --root=/mnt enable \
    NetworkManager \
    zfs.target \
    zfs-import-cache \
    zfs-mount \
    zfs-import.target

# ---------------------------------------------------------------------------
# Initramfs
# ---------------------------------------------------------------------------

echo "[+] Building initramfs..."

arch-chroot /mnt mkinitcpio -P

# ---------------------------------------------------------------------------
# systemd-boot
# ---------------------------------------------------------------------------

echo "[+] Installing systemd-boot..."

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

# ---------------------------------------------------------------------------
# Ansible
# ---------------------------------------------------------------------------

echo "[+] Cloning Ansible repository..."

arch-chroot /mnt sudo -u "$USER" \
    git clone "$ANSIBLE_REPO" "/home/$USER/ansible"

# ---------------------------------------------------------------------------
# Finish
# ---------------------------------------------------------------------------

echo "[+] Cleaning up..."

umount /mnt/boot || true
zfs umount -a || true
zpool export zroot

echo
echo "======================================================================"
echo " INSTALL COMPLETE"
echo "======================================================================"
echo
echo "Reboot and select:"
echo
echo "  Arch Linux (ZFS Encrypted)"
echo
echo "ZFS will prompt you for the encryption passphrase."
echo
echo "======================================================================"
