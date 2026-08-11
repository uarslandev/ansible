#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="srv-arch-ccc"
KEYMAP="it"
LOCALE_GEN="it_IT.UTF-8 UTF-8"
LOCALE_CONF="LANG=it_IT.UTF-8"
TIMEZONE="Europe/Rome"

if ! command -v pacstrap &>/dev/null; then
    echo "Error: Must be run from an Arch Linux Live ISO."
    exit 1
fi

# Set system clock
timedatectl set-ntp true

echo "--> Configuring ArchZFS Repository..."
cat <<'EOF' >> /etc/pacman.conf

[archzfs]
Server = https://archzfs.com/$repo/$arch
Server = https://mirror.sum7.eu/archlinux/archzfs/$repo/$arch
EOF

# Import and sign current ArchZFS Key
pacman-key --recv-keys F75D04B31D9C38A00E982D2D50E3EE70F939810E
pacman-key --lsign-key F75D04B31D9C38A00E982D2D50E3EE70F939810E
pacman -Sy --noconfirm

echo "=== Available Disks ==="
lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep "disk"
echo "---------------------------------------------------"

read -rp "Enter target disk device (e.g., /dev/nvme0n1 or /dev/sda): " DISK

if [[ ! -b "$DISK" ]]; then
    echo "Error: Block device $DISK does not exist."
    exit 1
fi

echo "WARNING: All data on $DISK will be permanently erased!"
read -rp "Type 'YES' to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

# Detect partition naming convention
if [[ "$DISK" =~ nvme|mmcblk ]]; then
    PART_EFI="${DISK}p1"
    PART_ZFS="${DISK}p2"
else
    PART_EFI="${DISK}1"
    PART_ZFS="${DISK}2"
fi

echo "--> Wiping and partitioning $DISK..."
zpool labelclear -f "$PART_ZFS" 2>/dev/null || true
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

# Partitioning: 1GB EFI, Rest for ZFS
sgdisk -n 1:1M:+1G -t 1:EF00 -c 1:"EFI System Partition" "$DISK"
sgdisk -n 2:0:0    -t 2:BF00 -c 2:"ZFS Pool" "$DISK"
partprobe "$DISK"
sleep 2

echo "--> Formatting EFI Partition..."
mkfs.vfat -F32 -n "EFI" "$PART_EFI"

echo "--> Creating Encrypted ZFS Pool (zroot)..."
zpool create -f -o ashift=12 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=none \
    -O encryption=on \
    -O keyformat=passphrase \
    -O keylocation=prompt \
    -R /mnt zroot "$PART_ZFS"

echo "--> Creating Root and Datasets..."
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/arch
zfs create -o mountpoint=/home zroot/home

# Configure ZFSBootMenu boot commandline
zfs set org.zfsbootmenu:commandline="rw quiet" zroot/ROOT/arch

# Export & re-import for clean layout
zpool export zroot
zpool import -N -R /mnt zroot
zfs load-key zroot
zfs mount zroot/ROOT/arch
zfs mount zroot/home

mkdir -p /mnt/boot/efi
mount "$PART_EFI" /mnt/boot/efi

echo "--> Bootstrapping System (pacstrap)..."
pacstrap -K /mnt base base-devel linux-lts linux-lts-headers linux-firmware \
    zfs-linux-lts intel-ucode amd-ucode networkmanager vim git zsh openssh efibootmgr

echo "--> Generating fstab..."
genfstab -U /mnt | grep -v "zroot" > /mnt/etc/fstab

# Copy ArchZFS repo config into target environment
cp /etc/pacman.conf /mnt/etc/pacman.conf

echo "--> Configuring OS inside Chroot..."
arch-chroot /mnt /bin/bash -e <<EOF
# Hostname & Timezone
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locales & Keymap
echo "$LOCALE_GEN" > /etc/locale.gen
locale-gen
echo "$LOCALE_CONF" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# ZFS Configuration & HostID
zgenhostid \$(hostid)
mkdir -p /etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache zroot

# Systemd ZFS Services
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import-scan NetworkManager sshd

# Adjust Initramfs HOOKS for ZFS
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modprobes zfs filesystems keyboard)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Set Root Password
echo "Set root password:"
passwd

# Install ZFSBootMenu to EFI
mkdir -p /boot/efi/EFI/zbm
curl -o /boot/efi/EFI/zbm/zfsbootmenu.EFI -sSL https://get.zfsbootmenu.org/efi
efibootmgr -c -d "$DISK" -p 1 -L "ZFSBootMenu" -l '\EFI\zbm\zfsbootmenu.EFI'
EOF

echo "--> Cleanup & Export..."
umount /mnt/boot/efi
zfs umount -a
zpool export zroot

echo "======================================================================="
echo "Installation complete! Reboot, select ZFSBootMenu, and enter passphrase."
echo "======================================================================="
