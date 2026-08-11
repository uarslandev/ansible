#!/usr/bin/env bash
set -euo pipefail

ANSIBLE_REPO="https://github.com/uarslandev/ansible.git"

if [[ $EUID -ne 0 ]]; then
    echo "[!] Must run as root." && exit 1
fi

echo "======================================================================"
echo " ARCH LINUX + ENCRYPTED ZFS + ANSIBLE INSTALLER"
echo "======================================================================"

# Clean up any leftover mounts/pools from previous runs
umount -R /mnt 2>/dev/null || true
zpool export -f zroot 2>/dev/null || true

lsblk
echo ""

read -rp "Enter target disk device (e.g. /dev/nvme0n1 or /dev/sda): " TARGET_DISK
if [[ ! -b "$TARGET_DISK" ]]; then
    echo "[!] Invalid block device: $TARGET_DISK" && exit 1
fi

echo ""
echo "[DANGER] Entire contents of $TARGET_DISK will be erased!"
read -rp "Type 'YES' to confirm disk wipe: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted." && exit 1
fi

# Function for re-prompting passwords on mismatch & enforcing minimum length
get_pass() {
    local p1 p2 prompt="$1" min_len="${2:-8}"
    while true; do
        read -rsp "$prompt (min $min_len chars): " p1 && echo ""
        read -rsp "Confirm $prompt: " p2 && echo ""
        if [[ "${#p1}" -lt "$min_len" ]]; then
            echo "[!] Passphrase must be at least $min_len characters long. Try again." >&2
        elif [[ "$p1" == "$p2" ]]; then
            echo "$p1"
            return 0
        else
            echo "[!] Passwords do not match. Try again." >&2
        fi
    done
}

# Collect Passwords & Configuration (Enforcing min 12 chars for ZFS passphrase)
ZFS_PASSPHRASE=$(get_pass "ZFS Encryption Passphrase" 12)
read -rp "Enter new username to create: " NEW_USER
USER_PASS=$(get_pass "Password for $NEW_USER" 8)
ROOT_PASS=$(get_pass "Root Password" 8)
read -rp "Enter Hostname [arch-zfs]: " HOST_NAME
HOST_NAME=${HOST_NAME:-arch-zfs}

echo "[+] Partitioning $TARGET_DISK..."
sgdisk --zap-all "$TARGET_DISK" && partprobe "$TARGET_DISK"
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

echo "[+] Creating natively encrypted ZFS Pool 'zroot'..."
zpool create -f -o ashift=12 \
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
    zroot "$ZFS_PART_BY_ID" <<< "$ZFS_PASSPHRASE"

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

echo "[+] Bootstrapping system via pacstrap..."
pacstrap /mnt base base-devel linux-lts linux-lts-headers linux-firmware libunwind efibootmgr nano networkmanager git ansible sudo

genfstab -U -p /mnt >> /mnt/etc/fstab

echo "[+] Configuring system inside chroot..."
HOSTID_VAL=$(hostid)

# System Firstboot Configuration
arch-chroot /mnt systemd-firstboot --hostname="${HOST_NAME}" --locale="en_US.UTF-8" --timezone="UTC"
echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen && arch-chroot /mnt locale-gen
echo "root:${ROOT_PASS}" | arch-chroot /mnt chpasswd
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "${NEW_USER}"
echo "${NEW_USER}:${USER_PASS}" | arch-chroot /mnt chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel

# ArchZFS Repository Setup
cat << 'EOF' >> /mnt/etc/pacman.conf

[archzfs]
SigLevel = TrustAll Optional
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

arch-chroot /mnt pacman -Sy --noconfirm zfs-dkms zfs-utils
arch-chroot /mnt zgenhostid "${HOSTID_VAL}"
arch-chroot /mnt systemctl enable NetworkManager zfs.target zfs-import-cache zfs-mount zfs-import.target

# Mkinitcpio Setup
sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect modprobes block zfs filesystems)/' /mnt/etc/mkinitcpio.conf
sed -i 's/^MODULES=.*/MODULES=(zfs)/' /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux-lts

# Bootloader Configuration (systemd-boot with explicit HEREDOCs)
arch-chroot /mnt bootctl install

cat << 'EOF' > /mnt/boot/loader/loader.conf
default arch-zfs.conf
timeout 3
EOF

cat << EOF > /mnt/boot/loader/entries/arch-zfs.conf
title   Arch Linux (ZFS Encrypted)
linux   /vmlinuz-linux-lts
initrd  /initramfs-linux-lts.img
options root=ZFS=zroot/ROOT/default rw spl.spl_hostid=0x${HOSTID_VAL}
EOF

# Clone Ansible Repository
echo "[+] Cloning ${ANSIBLE_REPO} into /home/${NEW_USER}/ansible..."
arch-chroot /mnt sudo -u "${NEW_USER}" git clone "${ANSIBLE_REPO}" "/home/${NEW_USER}/ansible"

echo "[+] Unmounting and exporting zpools..."
umount /mnt/boot || true
zfs umount -a || true
zpool export zroot

echo ""
echo "======================================================================"
echo " INSTALLATION COMPLETE!"
echo " Re-enter reboot, select your drive, and type your ZFS passphrase."
echo "======================================================================"
