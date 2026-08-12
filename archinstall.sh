#!/usr/bin/env bash

set -euo pipefail

# Visual formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Arch Linux ZFS Automated Installer ===${NC}\n"

# 1. Gather Inputs
lsblk -d -n -o NAME,SIZE,MODEL | grep -v "loop" | grep -v "sr"
echo ""
read -rp "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda): " TARGET_DISK

if [ ! -b "$TARGET_DISK" ]; then
    echo -e "${RED}Error: Device $TARGET_DISK does not exist.${NC}"
    exit 1
fi

echo -e "${RED}WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!${NC}"
read -rp "Type 'YES' to confirm disk wipe: " CONFIRM_WIPE
if [ "$CONFIRM_WIPE" != "YES" ]; then
    echo "Aborting."
    exit 1
fi

read -rp "Enter hostname [arch-zfs]: " HOSTNAME
HOSTNAME=${HOSTNAME:-arch-zfs}

read -rp "Enter username: " USERNAME
while [ -z "$USERNAME" ]; do
    read -rp "Username cannot be empty. Enter username: " USERNAME
done

read -rs -p "Enter user password: " USER_PASS
echo ""
read -rs -p "Confirm user password: " USER_PASS_CONFIRM
echo ""

if [ "$USER_PASS" != "$USER_PASS_CONFIRM" ]; then
    echo -e "${RED}Passwords do not match. Aborting.${NC}"
    exit 1
fi

read -rp "Enable ZFS Native Encryption? (y/N): " USE_ENCRYPTION
if [[ "$USE_ENCRYPTION" =~ ^[Yy]$ ]]; then
    ENCRYPT=true
    read -rs -p "Enter ZFS Encryption Passphrase: " ZFS_PASS
    echo ""
    read -rs -p "Confirm ZFS Encryption Passphrase: " ZFS_PASS_CONFIRM
    echo ""
    if [ "$ZFS_PASS" != "$ZFS_PASS_CONFIRM" ]; then
        echo -e "${RED}Passphrases do not match. Aborting.${NC}"
        exit 1
    fi
else
    ENCRYPT=false
fi

echo "Select Kernel:"
echo "1) linux-zen (Recommended)"
echo "2) linux"
echo "3) linux-lts"
read -rp "Choice [1-3]: " KERNEL_CHOICE

case $KERNEL_CHOICE in
    2) KERNEL_PKG="linux"; ZFS_PKG="zfs-linux" ;;
    3) KERNEL_PKG="linux-lts"; ZFS_PKG="zfs-linux-lts" ;;
    *) KERNEL_PKG="linux-zen"; ZFS_PKG="zfs-linux-zen" ;;
esac

POOL_NAME="zroot"

# 2. Disk Preparation
echo -e "\n${YELLOW}[1/6] Partitioning disk...${NC}"
sgdisk --zap-all "$TARGET_DISK"
partprobe "$TARGET_DISK"

# Create 1GB EFI Partition (1) and ZFS Partition (2)
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System Partition" "$TARGET_DISK"
sgdisk -n 2:0:0   -t 2:bf01 -c 2:"ZFS Partition" "$TARGET_DISK"

partprobe "$TARGET_DISK"
sleep 2

# Handle disk partition Naming (nvme0n1p1 vs sda1)
if [[ "$TARGET_DISK" =~ "nvme" ]] || [[ "$TARGET_DISK" =~ "mmcblk" ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ZFS_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ZFS_PART="${TARGET_DISK}2"
fi

echo -e "${YELLOW}[2/6] Formatting EFI partition...${NC}"
mkfs.vfat -F32 -n "EFI" "$EFI_PART"

# 3. ZFS Pool & Dataset Creation
echo -e "${YELLOW}[3/6] Creating ZFS Pool '$POOL_NAME'...${NC}"

ZPOOL_OPTS=(
    -o ashift=12
    -o autotrim=on
    -O acltype=posixacl
    -O xattr=sa
    -O dnodesize=auto
    -O normalization=formD
    -O canmount=off
    -O mountpoint=none
    -R /mnt
)

if [ "$ENCRYPT" = true ]; then
    ZPOOL_OPTS+=(
        -O encryption=on
        -O keyformat=passphrase
        -O keylocation=prompt
    )
    echo "$ZFS_PASS" | zpool create "${ZPOOL_OPTS[@]}" "$POOL_NAME" "$ZFS_PART"
else
    zpool create "${ZPOOL_OPTS[@]}" "$POOL_NAME" "$ZFS_PART"
fi

# Create ZFS Datasets for ZFS-BootMenu compatibility
echo -e "${YELLOW}Creating ZFS Datasets...${NC}"
zfs create -o canmount=off -o mountpoint=none "$POOL_NAME/ROOT"
zfs create -o mountpoint=/ -o canmount=noauto "$POOL_NAME/ROOT/default"
zfs create -o mountpoint=/home "$POOL_NAME/home"

# Set ZFS-BootMenu parameters
zfs set org.zfsbootmenu:commandline="rw quiet loglevel=3" "$POOL_NAME/ROOT"

# Mount filesystems
zfs mount "$POOL_NAME/ROOT/default"
zfs mount "$POOL_NAME/home"

mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# 4. Pacstrap Base System
echo -e "${YELLOW}[4/6] Installing Base Packages (pacstrap)...${NC}"
pacstrap /mnt base base-devel "$KERNEL_PKG" "$KERNEL_PKG-headers" "$ZFS_PKG" \
    firmware-linux git neovim sudo networkmanager efibootmgr curl gptfdisk

genfstab -U /mnt | grep -v "$POOL_NAME" >> /mnt/etc/fstab

# Copy host ZFS zpool cache
mkdir -p /mnt/etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# 5. Chroot Configuration Script
echo -e "${YELLOW}[5/6] Configuring System inside Chroot...${NC}"

cat <<CHROOT_SCRIPT > /mnt/setup-chroot.sh
#!/usr/bin/env bash
set -e

# Timezone & Locale
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Host File
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# User Creation
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Enable Services
systemctl enable NetworkManager
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs.target

# Install ZFS-BootMenu onto EFI partition
mkdir -p /boot/efi/EFI/zfs-bootmenu
curl -sSL "https://get.zfsbootmenu.org/efi" -o /boot/efi/EFI/zfs-bootmenu/zfs-bootmenu.EFI

# Configure EFI Boot Entry
efibootmgr --create \
  --disk "$TARGET_DISK" \
  --part 1 \
  --label "ZFS-BootMenu" \
  --loader '\EFI\zfs-bootmenu\zfs-bootmenu.EFI' \
  --unicode

CHROOT_SCRIPT

chmod +x /mnt/setup-chroot.sh
arch-chroot /mnt /setup-chroot.sh
rm /mnt/setup-chroot.sh

# 6. Unmount and Export
echo -e "${YELLOW}[6/6] Finishing up and exporting pool...${NC}"
umount /mnt/boot/efi
zfs unmount -a
zpool export "$POOL_NAME"

echo -e "${GREEN}=== Installation Complete! ===${NC}"
echo -e "You can now run: ${YELLOW}reboot${NC}"
