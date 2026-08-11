#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "    Arch Linux ZFS Automated Installer            "
echo "=================================================="

# --------------------------------------------------
# 1. Interactive Inputs
# --------------------------------------------------
lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep disk
echo ""
read -rp "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda): " DISK

if [[ ! -b "$DISK" ]]; then
    echo "Error: $DISK is not a valid block device."
    exit 1
fi

read -rp "Enter Hostname [arch-zfs]: " HOSTNAME
HOSTNAME=${HOSTNAME:-arch-zfs}

read -rp "Enter Username: " USERNAME
if [[ -z "$USERNAME" ]]; then
    echo "Error: Username cannot be empty."
    exit 1
fi

read -rsp "Enter Root Password: " ROOT_PASS; echo
read -rsp "Enter User Password ($USERNAME): " USER_PASS; echo

read -rp "Enable Native ZFS Encryption? (y/N): " ENABLE_ENC
ENABLE_ENC=$(echo "$ENABLE_ENC" | tr '[:upper:]' '[:lower:]')

ZFS_PASS=""
if [[ "$ENABLE_ENC" == "y" || "$ENABLE_ENC" == "yes" ]]; then
    read -rsp "Enter ZFS Encryption Passphrase: " ZFS_PASS; echo
    read -rsp "Confirm ZFS Encryption Passphrase: " ZFS_PASS_CONFIRM; echo
    if [[ "$ZFS_PASS" != "$ZFS_PASS_CONFIRM" ]]; then
        echo "Error: ZFS Passphrases do not match."
        exit 1
    fi
fi

POOL_NAME="zroot"

echo ""
echo "=================================================="
echo "WARNING: $DISK will be completely erased!"
echo "Target Pool: $POOL_NAME"
echo "Encryption:  $([[ "$ENABLE_ENC" =~ ^(y|yes)$ ]] && echo 'ENABLED' || echo 'DISABLED')"
echo "Username:    $USERNAME"
echo "Timezone:    Europe/Berlin"
echo "Git Repo:    https://github.com/uarslandev/ansible.git"
echo "=================================================="
read -rp "Are you sure you want to proceed? (type 'YES'): " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Installation aborted."
    exit 0
fi

# --------------------------------------------------
# 2. Disk Wipe & Partitioning
# --------------------------------------------------
echo "[1/7] Partitioning target disk..."
sgdisk --zap-all "$DISK"
partprobe "$DISK"
sleep 2

# Create EFI Partition (512M) and ZFS Partition (Remaining)
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI-system" "$DISK"
sgdisk -n 2:0:0     -t 2:bf00 -c 2:"ZFS-partition" "$DISK"

# Handle partition naming scheme (nvme0n1p1 vs sda1)
if [[ "$DISK" =~ "nvme" || "$DISK" =~ "mmcblk" ]]; then
    EFI_PART="${DISK}p1"
    ZFS_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ZFS_PART="${DISK}2"
fi

partprobe "$DISK"
sleep 2

echo "[2/7] Formatting EFI partition..."
mkfs.vfat -F32 "$EFI_PART"

# --------------------------------------------------
# 3. ZFS Pool & Datasets Setup
# --------------------------------------------------
echo "[3/7] Creating ZFS Pool..."
zgenhostid -f 0x00babaf1

POOL_OPTS=(
    -o ashift=12
    -o autotrim=on
    -O acltype=posixacl
    -O xattr=sa
    -O dnodesize=auto
    -O normalization=formD
    -O relatime=on
    -O canmount=off
    -O mountpoint=none
    -R /mnt
)

if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
    POOL_OPTS+=(
        -O encryption=aes-256-gcm
        -O keyformat=passphrase
        -O keylocation=prompt
    )
    echo "$ZFS_PASS" | zpool create "${POOL_OPTS[@]}" "$POOL_NAME" "$ZFS_PART"
else
    zpool create "${POOL_OPTS[@]}" "$POOL_NAME" "$ZFS_PART"
fi

echo "Creating ZFS Datasets..."
zfs create -o mountpoint=none "$POOL_NAME/ROOT"
zfs create -o mountpoint=/ "$POOL_NAME/ROOT/default"
zfs create -o mountpoint=/home "$POOL_NAME/home"

# Set bootfs property
zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"

# Export and re-import pool to verify mount state
zpool export "$POOL_NAME"
if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
    echo "$ZFS_PASS" | zpool import -N -R /mnt "$POOL_NAME"
    echo "$ZFS_PASS" | zfs load-key "$POOL_NAME"
    zfs mount "$POOL_NAME/ROOT/default"
    zfs mount "$POOL_NAME/home"
else
    zpool import -N -R /mnt "$POOL_NAME"
    zfs mount "$POOL_NAME/ROOT/default"
    zfs mount "$POOL_NAME/home"
fi

mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# --------------------------------------------------
# 4. Pacstrap Base System
# --------------------------------------------------
echo "[4/7] Installing base system and packages..."
pacstrap -K /mnt base linux linux-firmware zfs-linux sudo nano networkmanager grub efibootmgr git

genfstab -U /mnt >> /mnt/etc/fstab

# Copy hostid to target system
cp /etc/hostid /mnt/etc/hostid

# --------------------------------------------------
# 5. System Configuration inside Chroot
# --------------------------------------------------
echo "[5/7] Configuring system..."

cat <<CHROOT_SCRIPT | arch-chroot /mnt /bin/bash
set -euo pipefail

# Timezone & Locale
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Passwords & Users
echo "root:$ROOT_PASS" | chpasswd

useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd

# Enable wheel group in sudoers
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# Clone Ansible repository into user's home directory
echo "Cloning Ansible repository into /home/$USERNAME/ansible..."
git clone https://github.com/uarslandev/ansible.git "/home/$USERNAME/ansible"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/ansible"

# ZFS Services
systemctl enable NetworkManager
systemctl enable zfs-import-scan.service
systemctl enable zfs-mount.service
systemctl enable zfs-zed.service
systemctl enable zfs.target

# Initramfs Hooks for ZFS
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modprobed-db kms keyboard keymap consolefont block zfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader Setup (ZFSBootMenu)
mkdir -p /boot/EFI/zfsbootmenu
curl -sL "https://get.zfsbootmenu.org/latest.tar.gz" | tar -xz -C /tmp
EFISTUB=\$(find /tmp -name "zfsbootmenu-*.EFI" | head -n 1)

if [[ -f "\$EFISTUB" ]]; then
    cp "\$EFISTUB" /boot/EFI/zfsbootmenu/zfsbootmenu.efi
    efibootmgr --create --disk "$DISK" --part 1 --label "ZFSBootMenu" --loader "\\EFI\\zfsbootmenu\\zfsbootmenu.efi" --verbose
else
    echo "Falling back to GRUB with ZFS..."
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="zfs=$POOL_NAME\/ROOT\/default"/' /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
fi

CHROOT_SCRIPT

# --------------------------------------------------
# 6. Set Bootloader Pool Properties & Clean Up
# --------------------------------------------------
echo "[6/7] Setting command line boot arguments for ZFS..."
zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"
zfs set org.zfsbootmenu:commandline="rw" "$POOL_NAME/ROOT"

echo "[7/7] Unmounting partitions and exporting pool..."
umount /mnt/boot
zfs unmount -a
zpool export "$POOL_NAME"

echo "=================================================="
echo " Installation Complete! You can now reboot.      "
echo "=================================================="
