#!/usr/bin/env bash
#
# Dual-Purpose Script:
#   1. Run on any existing Arch Linux host to build a custom ZFS Live ISO.
#   2. Run inside the resulting custom Live ISO to perform the automated Arch + Encrypted ZFS install.
#

set -euo pipefail

ANSIBLE_REPO="https://github.com/uarslandev/ansible.git"

# ==============================================================================
# MODE DETECTION
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
   echo "[!] This script must be run as root." 
   exit 1
fi

# If ZFS module is loaded (or can be loaded), run the Installer Phase
if modprobe zfs &>/dev/null; then
    MODE="INSTALL"
else
    MODE="BUILD_ISO"
fi

# ==============================================================================
# PHASE 1: BUILD CUSTOM ARCH ZFS LIVE ISO
# ==============================================================================
if [[ "$MODE" == "BUILD_ISO" ]]; then
    echo "======================================================================"
    echo " ZFS Module not found. Running in ISO BUILD MODE (archiso)."
    echo "======================================================================"

    # Install build dependencies on host
    echo "[+] Installing archiso and build tools on host..."
    pacman -Sy --needed --noconfirm archiso git curl

    WORK_DIR="/tmp/archlive-zfs"
    OUT_DIR="$HOME/zfs-iso-build"

    rm -rf "$WORK_DIR"
    mkdir -p "$OUT_DIR"

    echo "[+] Copying archiso releng profile..."
    cp -r /usr/share/archiso/configs/releng "$WORK_DIR"

    # Configure packages for ArchZFS + LTS Kernel
    echo "[+] Configuring packages in ISO profile..."
    sed -i '/^linux$/d' "$WORK_DIR/packages.x86_64"
    sed -i '/^broadcom-wl$/d' "$WORK_DIR/packages.x86_64"
    rm -f "$WORK_DIR/airootfs/etc/mkinitcpio.d/linux.preset" || true

    cat << 'EOF' >> "$WORK_DIR/packages.x86_64"
linux-lts
linux-lts-headers
libunwind
zfs-utils
zfs-dkms
git
ansible
sudo
EOF

    # Configure ArchZFS Repository in profile pacman.conf
    echo "[+] Adding ArchZFS repository to ISO pacman.conf..."
    cat << 'EOF' >> "$WORK_DIR/pacman.conf"

[archzfs]
SigLevel = TrustAll Optional
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

    # Configure ArchZFS Repository inside live airootfs
    mkdir -p "$WORK_DIR/airootfs/etc"
    cp "$WORK_DIR/pacman.conf" "$WORK_DIR/airootfs/etc/pacman.conf"

    # Import ArchZFS Keyring into live environment
    mkdir -p "$WORK_DIR/airootfs/usr/share/pacman/keyrings"
    curl -sLo "$WORK_DIR/airootfs/usr/share/pacman/keyrings/archzfs.gpg" \
        'https://github.com/archzfs/archzfs-keyring/raw/master/keyring/packager/archzfs/3A9917BF0DED5C13F69AC68FABEC0A1208037BE9/3A9917BF0DED5C13F69AC68FABEC0A1208037BE9.asc' || true
    echo "3A9917BF0DED5C13F69AC68FABEC0A1208037BE9:4:" > "$WORK_DIR/airootfs/usr/share/pacman/keyrings/archzfs-trusted"

    # Update bootloader entries to use linux-lts
    echo "[+] Updating bootloader configurations to linux-lts..."
    sed -i -E 's/(vmlinuz|initramfs)-linux/&-lts/g' "$WORK_DIR"/efiboot/loader/entries/*.conf "$WORK_DIR"/syslinux/*.cfg "$WORK_DIR"/grub/*.cfg 2>/dev/null || true

    # Embed THIS script into root's home folder on the ISO for instant installer execution
    mkdir -p "$WORK_DIR/airootfs/root"
    cp "$0" "$WORK_DIR/airootfs/root/setup.sh"
    chmod +x "$WORK_DIR/airootfs/root/setup.sh"

    # Increase live environment tmpfs cowspace for DKMS compilation
    sed -i 's/cow_spacesize=[^ ]*/cow_spacesize=4G/g' "$WORK_DIR"/efiboot/loader/entries/*.conf "$WORK_DIR"/syslinux/*.cfg "$WORK_DIR"/grub/*.cfg 2>/dev/null || true

    echo "[+] Building custom ArchZFS ISO (this may take a few minutes)..."
    mkarchiso -v -w "$WORK_DIR/tmp" -o "$OUT_DIR" "$WORK_DIR"

    echo ""
    echo "======================================================================"
    echo " SUCCESS! Your custom ISO has been generated in:"
    echo "   $OUT_DIR"
    echo ""
    echo " Burn the ISO to a USB stick, boot your target machine, and simply run:"
    echo "   ./setup.sh"
    echo "======================================================================"
    exit 0
fi

# ==============================================================================
# PHASE 2: ARCH LINUX + ENCRYPTED ZFS + ANSIBLE INSTALLER
# ==============================================================================
echo "======================================================================"
echo " ZFS Module Detected! Running in INSTALLATION MODE."
echo "======================================================================"

lsblk
echo ""

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

read -rsp "Enter ZFS Encryption Passphrase: " ZFS_PASSPHRASE
echo ""
read -rsp "Confirm ZFS Encryption Passphrase: " ZFS_PASSPHRASE_CONFIRM
echo ""
if [[ "$ZFS_PASSPHRASE" != "$ZFS_PASSPHRASE_CONFIRM" ]]; then
    echo "[!] Passphrases do not match."
    exit 1
fi

read -rp "Enter new username to create: " NEW_USER
read -rsp "Enter password for $NEW_USER: " USER_PASS
echo ""
read -rsp "Enter Root password: " ROOT_PASS
echo ""

read -rp "Enter Hostname [arch-zfs]: " HOST_NAME
HOST_NAME=${HOST_NAME:-arch-zfs}

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

echo "[+] Installing minimal base system, Ansible, git, and sudo..."
pacstrap /mnt base base-devel linux-lts linux-lts-headers firmware-linux libunwind efibootmgr nano networkmanager git ansible sudo

genfstab -U -p /mnt >> /mnt/etc/fstab

echo "[+] Configuring system in chroot..."
HOSTID_VAL=$(hostid)

cat <<CHROOT_SCRIPT | arch-chroot /mnt /bin/bash
set -euo pipefail

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "${HOST_NAME}" > /etc/hostname

echo "root:${ROOT_PASS}" | chpasswd
useradd -m -G wheel -s /bin/bash "${NEW_USER}"
echo "${NEW_USER}:${USER_PASS}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

cat << 'EOF' >> /etc/pacman.conf

[archzfs]
SigLevel = TrustAll Optional
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

pacman -Sy --noconfirm zfs-dkms zfs-utils

zgenhostid ${HOSTID_VAL}
systemctl enable NetworkManager
systemctl enable zfs.target
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target

sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect modprobes block zfs filesystems)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES=.*/MODULES=(zfs)/' /etc/mkinitcpio.conf
mkinitcpio -p linux-lts

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

echo "[+] Cloning ${ANSIBLE_REPO} into /home/${NEW_USER}/ansible..."
sudo -u "${NEW_USER}" git clone "${ANSIBLE_REPO}" "/home/${NEW_USER}/ansible"

CHROOT_SCRIPT

echo "[+] Unmounting and exporting zpools..."
umount /mnt/boot || true
zfs umount -a
zfs umount zroot/ROOT/default
zpool export zroot

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "Created user '${NEW_USER}' with full sudo access."
echo "Ansible repository cloned to '/home/${NEW_USER}/ansible'."
echo "You can now safely reboot!"
