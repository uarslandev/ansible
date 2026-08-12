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

read -rp "Enter Timezone [Europe/Berlin]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Berlin}

read -rp "Enter Username: " USERNAME
if [[ -z "$USERNAME" ]]; then
    echo "Error: Username cannot be empty."
    exit 1
fi

# Password prompts with confirmation
while true; do
    read -rsp "Enter Root Password: " ROOT_PASS; echo
    read -rsp "Confirm Root Password: " ROOT_PASS_CONFIRM; echo
    if [[ "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" && -n "$ROOT_PASS" ]]; then
        break
    fi
    echo "Error: Root passwords do not match or were empty. Please try again."
done

while true; do
    read -rsp "Enter User Password ($USERNAME): " USER_PASS; echo
    read -rsp "Confirm User Password ($USERNAME): " USER_PASS_CONFIRM; echo
    if [[ "$USER_PASS" == "$USER_PASS_CONFIRM" && -n "$USER_PASS" ]]; then
        break
    fi
    echo "Error: User passwords do not match or were empty. Please try again."
done

# Bootloader Selection
echo ""
echo "Select primary bootloader strategy:"
echo "1) ZFSBootMenu (Recommended for pure ZFS & snapshots)"
echo "2) GRUB (Best for traditional Dual-Boot auto-detection via os-prober)"
echo "3) systemd-boot (Fast, minimal EFI boot manager)"
read -rp "Choice [1-3] (Default: 1): " BOOTLOADER_CHOICE
BOOTLOADER_CHOICE=${BOOTLOADER_CHOICE:-1}

# Dual Boot Check
read -rp "Are you dual-booting with an existing Windows installation? (y/N): " DUAL_BOOT
DUAL_BOOT=$(echo "$DUAL_BOOT" | tr '[:upper:]' '[:lower:]')

# Native ZFS Encryption Check
read -rp "Enable Native ZFS Encryption? (y/N): " ENABLE_ENC
ENABLE_ENC=$(echo "$ENABLE_ENC" | tr '[:upper:]' '[:lower:]')

ZFS_PASS=""
if [[ "$ENABLE_ENC" == "y" || "$ENABLE_ENC" == "yes" ]]; then
    while true; do
        read -rsp "Enter ZFS Encryption Passphrase: " ZFS_PASS; echo
        read -rsp "Confirm ZFS Encryption Passphrase: " ZFS_PASS_CONFIRM; echo
        if [[ "$ZFS_PASS" == "$ZFS_PASS_CONFIRM" && -n "$ZFS_PASS" ]]; then
            break
        fi
        echo "Error: ZFS Passphrases do not match or were empty. Please try again."
    done
fi

POOL_NAME="zroot"

echo ""
echo "=================================================="
echo "WARNING: Target ZFS Partition on $DISK will be configured!"
echo "Target Pool: $POOL_NAME"
echo "Encryption:  $([[ "$ENABLE_ENC" =~ ^(y|yes)$ ]] && echo 'ENABLED' || echo 'DISABLED')"
echo "Username:    $USERNAME"
echo "Timezone:    $TIMEZONE"
echo "Bootloader:  $([[ "$BOOTLOADER_CHOICE" == "2" ]] && echo 'GRUB' || ([[ "$BOOTLOADER_CHOICE" == "3" ]] && echo 'systemd-boot' || echo 'ZFSBootMenu'))"
echo "Dual-Boot:   $([[ "$DUAL_BOOT" =~ ^(y|yes)$ ]] && echo 'YES (Windows)' || echo 'NO')"
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
echo "[1/7] Preparing disk partitions..."

# Unmount active mounts/swap
swapoff -a || true
for part in $(lsblk -l -n -o NAME "$DISK" | tail -n +2); do
    umount -l "/dev/$part" 2>/dev/null || true
done

if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
    echo "Dual-boot detected. Preserving existing Windows EFI / NTFS partitions."
    # If keeping Windows, we don't wipe the disk entirely—instead, prompt for target ZFS partition or partition cleanly after Windows
    sgdisk -n 0:0:+512M -t 0:ef00 -c 0:"Arch-EFI" "$DISK" || true
    sgdisk -n 0:0:0     -t 0:bf00 -c 0:"ZFS-partition" "$DISK" || true
else
    # Full disk wipe
    blkdiscard -f "$DISK" 2>/dev/null || true
    zpool labelclear -f "$DISK" 2>/dev/null || true
    dd if=/dev/zero of="$DISK" bs=1M count=100 status=none conv=fsync
    wipefs --all --force "$DISK"
    sgdisk --zap-all "$DISK"
    
    # Create EFI Partition (512M) and ZFS Partition (Remaining space)
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI-system" "$DISK"
    sgdisk -n 2:0:0     -t 2:bf00 -c 2:"ZFS-partition" "$DISK"
fi

partprobe "$DISK"
sleep 2

# Handle partition naming scheme (nvme0n1p1 vs sda1)
if [[ "$DISK" =~ "nvme" || "$DISK" =~ "mmcblk" ]]; then
    EFI_PART="${DISK}p1"
    ZFS_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ZFS_PART="${DISK}2"
fi

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

# Export and re-import pool
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
PACMAN_PKGS=(base linux linux-firmware zfs-linux sudo nano networkmanager efibootmgr git ansible)

if [[ "$BOOTLOADER_CHOICE" == "2" || "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
    PACMAN_PKGS+=(grub os-prober ntfs-3g)
fi

pacstrap -K /mnt "${PACMAN_PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab
cp /etc/hostid /mnt/etc/hostid

# --------------------------------------------------
# 5. System Configuration inside Chroot
# --------------------------------------------------
echo "[5/7] Configuring system..."

cat <<CHROOT_SCRIPT | arch-chroot /mnt /bin/bash
set -euo pipefail

# Timezone & Locale
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

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
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block zfs filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --------------------------------------------------
# Bootloader Setup Strategy
# --------------------------------------------------
if [[ "$BOOTLOADER_CHOICE" == "2" ]]; then
    echo "Configuring GRUB Bootloader..."
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="zfs=$POOL_NAME\/ROOT\/default rw"/' /etc/default/grub

    if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
        echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
    fi
    grub-mkconfig -o /boot/grub/grub.cfg

elif [[ "$BOOTLOADER_CHOICE" == "3" ]]; then
    echo "Configuring systemd-boot..."
    bootctl install --esp-path=/boot

    cat <<LOADER > /boot/loader/loader.conf
default arch.conf
timeout 5
console-mode max
LOADER

    cat <<ENTRY > /boot/loader/entries/arch.conf
title   Arch Linux (ZFS)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options zfs=$POOL_NAME/ROOT/default rw
ENTRY

    if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
        cat <<WINENTRY > /boot/loader/entries/windows.conf
title   Windows Boot Manager
efi     /EFI/Microsoft/Boot/bootmgfw.efi
WINENTRY
    fi

else
    echo "Configuring ZFSBootMenu..."
    mkdir -p /boot/EFI/zfsbootmenu
    curl -sL "https://get.zfsbootmenu.org/latest.tar.gz" | tar -xz -C /tmp
    EFISTUB=\$(find /tmp -name "zfsbootmenu-*.EFI" | head -n 1)

    if [[ -f "\$EFISTUB" ]]; then
        cp "\$EFISTUB" /boot/EFI/zfsbootmenu/zfsbootmenu.efi
        efibootmgr --create --disk "$DISK" --part 1 --label "ZFSBootMenu" --loader "\\EFI\\zfsbootmenu\\zfsbootmenu.efi" --verbose
    fi
fi

CHROOT_SCRIPT

# --------------------------------------------------
# 6. Set Bootloader Pool Properties
# --------------------------------------------------
echo "[6/7] Setting pool boot properties..."
zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"
zpool set org.zfsbootmenu:timeout=10 "$POOL_NAME"
zfs set org.zfsbootmenu:commandline="rw" "$POOL_NAME/ROOT"

read -rp "Do you want to run Ansible to set up the machine now? (y/N): " RUN_ANSIBLE
RUN_ANSIBLE=$(echo "$RUN_ANSIBLE" | tr '[:upper:]' '[:lower:]')

if [[ "$RUN_ANSIBLE" == "y" || "$RUN_ANSIBLE" == "yes" ]]; then
    echo "Running Ansible playbook inside chroot..."
    arch-chroot /mnt /bin/bash -c "
        cd /home/$USERNAME/ansible
        if [[ -f local.yml ]]; then
            su - $USERNAME -c 'cd ~/ansible && ansible-playbook local.yml --connection=local'
        elif [[ -f site.yml ]]; then
            su - $USERNAME -c 'cd ~/ansible && ansible-playbook site.yml --connection=local'
        elif [[ -f main.yml ]]; then
            su - $USERNAME -c 'cd ~/ansible && ansible-playbook main.yml --connection=local'
        else
            echo 'Running interactive playbook selection:'
            ls -la /home/$USERNAME/ansible
            read -rp 'Enter playbook filename to run (e.g., playbook.yml): ' PB_NAME
            su - $USERNAME -c \"cd ~/ansible && ansible-playbook \$PB_NAME --connection=local\"
        fi
    "
fi

# --------------------------------------------------
# 7. Clean Up & Unmount
# --------------------------------------------------
echo "[7/7] Unmounting partitions and exporting pool..."
umount /mnt/boot
zfs unmount -a
zpool export "$POOL_NAME"

echo "=================================================="
echo " Installation Complete! You can now reboot.      "
echo "=================================================="
