#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "    Arch Linux Automated System Installer         "
echo "=================================================="

# --------------------------------------------------
# 1. Interactive Inputs (All Prompts Upfront)
# --------------------------------------------------
lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep disk
echo ""
read -rp "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda): " DISK

if [[ ! -b "$DISK" ]]; then
    echo "Error: $DISK is not a valid block device."
    exit 1
fi

read -rp "Enter Hostname [arch-system]: " HOSTNAME
HOSTNAME=${HOSTNAME:-arch-system}

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

# Filesystem Selection
echo ""
echo "Select Root Filesystem Type:"
echo "1) ZFS (Advanced snapshots, pool management & Boot Environments)"
echo "2) ext4 (Standard Linux filesystem)"
echo "3) btrfs (Modern Linux filesystem with subvolumes)"
read -rp "Choice [1-3] (Default: 1): " FS_CHOICE
FS_CHOICE=${FS_CHOICE:-1}

# Bootloader Selection based on Filesystem
echo ""
if [[ "$FS_CHOICE" == "1" ]]; then
    echo "Select primary bootloader strategy:"
    echo "1) ZFSBootMenu (Recommended & Default for ZFS)"
    echo "2) GRUB"
    echo "3) systemd-boot"
    read -rp "Choice [1-3] (Default: 1): " BOOTLOADER_CHOICE
    BOOTLOADER_CHOICE=${BOOTLOADER_CHOICE:-1}
else
    echo "Select primary bootloader strategy:"
    echo "1) GRUB (Recommended for Dual-Boot & standard partitions)"
    echo "2) systemd-boot (Fast, minimal EFI manager)"
    read -rp "Choice [1-2] (Default: 1): " NON_ZFS_BL_CHOICE
    NON_ZFS_BL_CHOICE=${NON_ZFS_BL_CHOICE:-1}
    if [[ "$NON_ZFS_BL_CHOICE" == "1" ]]; then
        BOOTLOADER_CHOICE="2"
    else
        BOOTLOADER_CHOICE="3"
    fi
fi

# Dual Boot Check
read -rp "Are you dual-booting with an existing Windows installation? (y/N): " DUAL_BOOT
DUAL_BOOT=$(echo "$DUAL_BOOT" | tr '[:upper:]' '[:lower:]')

# Native ZFS Encryption Check (Only if ZFS is selected)
ENABLE_ENC="n"
ZFS_PASS=""
if [[ "$FS_CHOICE" == "1" ]]; then
    read -rp "Enable Native ZFS Encryption? (y/N): " ENABLE_ENC
    ENABLE_ENC=$(echo "$ENABLE_ENC" | tr '[:upper:]' '[:lower:]')

    if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
        while true; do
            read -rsp "Enter ZFS Encryption Passphrase: " ZFS_PASS; echo
            read -rsp "Confirm ZFS Encryption Passphrase: " ZFS_PASS_CONFIRM; echo
            if [[ "$ZFS_PASS" == "$ZFS_PASS_CONFIRM" && -n "$ZFS_PASS" ]]; then
                break
            fi
            echo "Error: ZFS Passphrases do not match or were empty. Please try again."
        done
    fi
fi

# Ansible Run Preference
echo ""
read -rp "Do you want to run Ansible to set up the machine right after installation? (y/N): " RUN_ANSIBLE
RUN_ANSIBLE=$(echo "$RUN_ANSIBLE" | tr '[:upper:]' '[:lower:]')

CUSTOM_PLAYBOOK=""
if [[ "$RUN_ANSIBLE" =~ ^(y|yes)$ ]]; then
    read -rp "Enter playbook filename if not default (leave empty for auto-detect local.yml/site.yml/main.yml): " CUSTOM_PLAYBOOK
fi

POOL_NAME="zroot"

# Kernel command line parameters
CMDLINE="rw quiet"
if [[ "$FS_CHOICE" == "1" ]]; then CMDLINE="zfs=$POOL_NAME/ROOT/default rw quiet"; fi

echo ""
echo "=================================================="
echo "WARNING: Target Partitions on $DISK will be configured!"
echo "Filesystem:  $([[ "$FS_CHOICE" == "1" ]] && echo 'ZFS' || ([[ "$FS_CHOICE" == "2" ]] && echo 'ext4' || echo 'btrfs'))"
echo "Encryption:  $([[ "$ENABLE_ENC" =~ ^(y|yes)$ ]] && echo 'ENABLED (ZFS - single password boot via initramfs keyfile)' || echo 'DISABLED')"
echo "Kernels:     linux, linux-lts, linux-zen"
echo "Desktop:     KDE Plasma + SDDM"
echo "Username:    $USERNAME"
echo "Timezone:    $TIMEZONE"
echo "Bootloader:  $([[ "$BOOTLOADER_CHOICE" == "2" ]] && echo 'GRUB' || ([[ "$BOOTLOADER_CHOICE" == "3" ]] && echo 'systemd-boot' || echo 'ZFSBootMenu'))"
echo "Dual-Boot:   $([[ "$DUAL_BOOT" =~ ^(y|yes)$ ]] && echo 'YES (Preserving Windows)' || echo 'NO')"
echo "Run Ansible: $([[ "$RUN_ANSIBLE" =~ ^(y|yes)$ ]] && echo 'YES' || echo 'NO')"
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
for part in $(lsblk -l -n -o NAME "$DISK" 2>/dev/null | tail -n +2); do
    umount -l "/dev/$part" 2>/dev/null || true
done

PART_TYPE="8300"
if [[ "$FS_CHOICE" == "1" ]]; then PART_TYPE="bf00"; fi

if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
    echo "Dual-boot detected. Preserving existing Windows EFI / NTFS partitions."
    sgdisk -n 0:0:+512M -t 0:ef00 -c 0:"Arch-EFI" "$DISK"
    sgdisk -n 0:0:0     -t 0:"$PART_TYPE" -c 0:"Arch-Root" "$DISK"
    partprobe "$DISK"
    sleep 2

    EFI_PART=$(lsblk -no NAME,PARTLABEL "$DISK" | grep "Arch-EFI" | awk '{print "/dev/"$1}' | head -n 1)
    ROOT_PART=$(lsblk -no NAME,PARTLABEL "$DISK" | grep "Arch-Root" | awk '{print "/dev/"$1}' | head -n 1)
else
    # Full disk wipe
    blkdiscard -f "$DISK" 2>/dev/null || true
    zpool labelclear -f "$DISK" 2>/dev/null || true
    dd if=/dev/zero of="$DISK" bs=1M count=100 status=none conv=fsync
    wipefs --all --force "$DISK"
    sgdisk --zap-all "$DISK"
    
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI-system" "$DISK"
    sgdisk -n 2:0:0     -t 2:"$PART_TYPE" -c 2:"Arch-Root" "$DISK"
    partprobe "$DISK"
    sleep 2

    if [[ "$DISK" =~ "nvme" || "$DISK" =~ "mmcblk" ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi
fi

if [[ -z "${EFI_PART:-}" || -z "${ROOT_PART:-}" ]]; then
    echo "Error: Could not determine partition nodes."
    exit 1
fi

echo "Selected EFI Partition:  $EFI_PART"
echo "Selected Root Partition: $ROOT_PART"

echo "[2/7] Formatting EFI partition..."
mkfs.vfat -F32 "$EFI_PART"

# --------------------------------------------------
# 3. Filesystem Setup
# --------------------------------------------------
echo "[3/7] Setting up root filesystem..."

if [[ "$FS_CHOICE" == "1" ]]; then
    # ZFS Setup
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
        echo "$ZFS_PASS" | zpool create "${POOL_OPTS[@]}" "$POOL_NAME" "$ROOT_PART"
    else
        zpool create "${POOL_OPTS[@]}" "$POOL_NAME" "$ROOT_PART"
    fi

    echo "Creating ZFS Datasets..."
    zfs create -o mountpoint=none "$POOL_NAME/ROOT"
    zfs create -o mountpoint=/ "$POOL_NAME/ROOT/default"
    zfs create -o mountpoint=/home "$POOL_NAME/home"

    zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"

    zpool export "$POOL_NAME"
    if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
        echo "$ZFS_PASS" | zpool import -N -R /mnt "$POOL_NAME"
        echo "$ZFS_PASS" | zfs load-key "$POOL_NAME"
        zfs mount "$POOL_NAME/ROOT/default"
        zfs mount "$POOL_NAME/home"

        # Create keyfile to avoid entering passphrase twice at boot
        echo "Creating initramfs ZFS decryption keyfile to prevent double passphrase prompts..."
        mkdir -p /mnt/etc/zfs
        dd if=/dev/urandom of=/mnt/etc/zfs/zroot.key bs=32 count=1 status=none
        chmod 600 /mnt/etc/zfs/zroot.key
        zfs set keylocation=file:///etc/zfs/zroot.key "$POOL_NAME"
    else
        zpool import -N -R /mnt "$POOL_NAME"
        zfs mount "$POOL_NAME/ROOT/default"
        zfs mount "$POOL_NAME/home"
    fi

elif [[ "$FS_CHOICE" == "2" ]]; then
    # ext4 Setup
    mkfs.ext4 -F "$ROOT_PART"
    mount "$ROOT_PART" /mnt

elif [[ "$FS_CHOICE" == "3" ]]; then
    # btrfs Setup
    mkfs.btrfs -f "$ROOT_PART"
    mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt
    mount -o compress=zstd,subvol=@ "$ROOT_PART" /mnt
    mkdir -p /mnt/home
    mount -o compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
fi

# For ZFSBootMenu, mount EFI to /efi so /boot stays inside ZFS root dataset
EFI_MOUNT_POINT="/boot"
if [[ "$FS_CHOICE" == "1" && "$BOOTLOADER_CHOICE" == "1" ]]; then
    EFI_MOUNT_POINT="/efi"
fi

mkdir -p "/mnt$EFI_MOUNT_POINT"
mount "$EFI_PART" "/mnt$EFI_MOUNT_POINT"

# --------------------------------------------------
# 4. Pacstrap Base System & Kernels
# --------------------------------------------------
echo "[4/7] Installing base system, kernels (linux, linux-lts, linux-zen), Wi-Fi firmware & KDE Plasma..."

# Ensure archzfs repository is present in host pacman.conf if ZFS selected
if [[ "$FS_CHOICE" == "1" ]]; then
    if ! grep -q "\[archzfs\]" /etc/pacman.conf; then
        echo "Adding archzfs repository to installer pacman configuration..."
        pacman-key --recv-keys DDF7DB8173967019 2>/dev/null || true
        pacman-key --lsign-key DDF7DB8173967019 2>/dev/null || true
        cat <<'PACMAN_ZFS' >> /etc/pacman.conf

[archzfs]
SigLevel = Optional TrustAll
Server = https://archzfs.com/$repo/$arch
Server = https://zfs.fanet.ft/archzfs/$repo/$arch
PACMAN_ZFS
        pacman -Sy --noconfirm 2>/dev/null || true
    fi
fi

PACMAN_PKGS=(
    base sudo nano git ansible curl efibootmgr dkms
    linux linux-headers
    linux-lts linux-lts-headers
    linux-zen linux-zen-headers
    linux-firmware sof-firmware wireless-regdb broadcom-wl-dkms intel-ucode amd-ucode
    networkmanager iwd wpa_supplicant
    plasma-meta sddm sddm-kcm plasma-nm plasma-pa kscreen powerdevil kde-cli-tools bluedevil
    konsole dolphin kate spectacle ark gwenview qt6-wayland xdg-desktop-portal-kde
)

if [[ "$FS_CHOICE" == "1" ]]; then
    PACMAN_PKGS+=(zfs-dkms zfs-utils)
elif [[ "$FS_CHOICE" == "3" ]]; then
    PACMAN_PKGS+=(btrfs-progs)
fi

if [[ "$BOOTLOADER_CHOICE" == "2" || "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
    PACMAN_PKGS+=(grub os-prober ntfs-3g)
fi

pacstrap -K /mnt "${PACMAN_PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

if [[ "$FS_CHOICE" == "1" ]]; then
    cp /etc/hostid /mnt/etc/hostid
fi

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

# Services
systemctl enable NetworkManager
systemctl enable sddm
systemctl set-default graphical.target

if [[ "$FS_CHOICE" == "1" ]]; then
    # Ensure archzfs repo in target system pacman.conf
    if ! grep -q "\[archzfs\]" /etc/pacman.conf; then
        cat <<'PACMAN_ZFS_TARGET' >> /etc/pacman.conf

[archzfs]
SigLevel = Optional TrustAll
Server = https://archzfs.com/\$repo/\$arch
Server = https://zfs.fanet.ft/archzfs/\$repo/\$arch
PACMAN_ZFS_TARGET
    fi

    systemctl enable zfs-import-scan.service
    systemctl enable zfs-mount.service
    systemctl enable zfs-zed.service
    systemctl enable zfs.target

    if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
        sed -i 's/^FILES=.*/FILES=(\/etc\/zfs\/zroot.key)/' /etc/mkinitcpio.conf
    fi
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block zfs filesystems)/' /etc/mkinitcpio.conf

    # Build DKMS modules for linux, linux-lts, linux-zen
    echo "Building ZFS & DKMS modules for all installed kernels..."
    dkms autoinstall || true

    mkinitcpio -P
else
    # Build DKMS modules for all installed kernels
    dkms autoinstall || true
    mkinitcpio -P
fi

# --------------------------------------------------
# Bootloader Setup Strategy
# --------------------------------------------------
if [[ "$BOOTLOADER_CHOICE" == "2" ]]; then
    echo "Configuring GRUB Bootloader..."
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
    
    if [[ "$FS_CHOICE" == "1" ]]; then
        sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="zfs=$POOL_NAME\/ROOT\/default rw quiet"/' /etc/default/grub
    fi

    if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
        echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
    fi
    grub-mkconfig -o /boot/grub/grub.cfg

elif [[ "$BOOTLOADER_CHOICE" == "3" ]]; then
    echo "Configuring systemd-boot..."
    bootctl install --esp-path=/boot

    cat <<LOADER > /boot/loader/loader.conf
default arch.conf
timeout 10
console-mode max
LOADER

    # Kernel entries for linux, linux-lts, and linux-zen
    cat <<ENTRY_STD > /boot/loader/entries/arch.conf
title   Arch Linux (Standard Kernel)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options $CMDLINE
ENTRY_STD

    cat <<ENTRY_LTS > /boot/loader/entries/arch-lts.conf
title   Arch Linux (LTS Kernel)
linux   /vmlinuz-linux-lts
initrd  /initramfs-linux-lts.img
options $CMDLINE
ENTRY_LTS

    cat <<ENTRY_ZEN > /boot/loader/entries/arch-zen.conf
title   Arch Linux (Zen Kernel)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options $CMDLINE
ENTRY_ZEN

    if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
        cat <<WINENTRY > /boot/loader/entries/windows.conf
title   Windows Boot Manager
efi     /EFI/Microsoft/Boot/bootmgfw.efi
WINENTRY
    fi

else
    echo "Configuring ZFSBootMenu..."
    mkdir -p /efi/EFI/zfsbootmenu /efi/EFI/BOOT

    # Fetch compiled release EFI executable from zbm-dev
    echo "Downloading ZFSBootMenu EFI stub..."
    curl -fsSL -L -o /efi/EFI/zfsbootmenu/zfsbootmenu.efi "https://get.zfsbootmenu.org/efi" || \
    curl -fsSL -L -o /efi/EFI/zfsbootmenu/zfsbootmenu.efi "https://github.com/zbm-dev/zfsbootmenu/releases/latest/download/zfsbootmenu-release-x86_64-v2.3.0.EFI"

    if [[ -s /efi/EFI/zfsbootmenu/zfsbootmenu.efi ]]; then
        cp /efi/EFI/zfsbootmenu/zfsbootmenu.efi /efi/EFI/BOOT/BOOTX64.EFI
        efibootmgr --create --disk "$DISK" --part 1 --label "ZFSBootMenu" --loader "\\EFI\\zfsbootmenu\\zfsbootmenu.efi" --verbose || true
    else
        echo "Error: Failed to fetch ZFSBootMenu EFI binary."
        exit 1
    fi
fi

CHROOT_SCRIPT

# --------------------------------------------------
# 6. Set Bootloader Pool Properties (ZFS Only) & Create Initial Snapshot
# --------------------------------------------------
if [[ "$FS_CHOICE" == "1" ]]; then
    echo "[6/7] Setting pool boot properties & creating initial snapshot..."
    zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"
    zpool set org.zfsbootmenu:timeout=10 "$POOL_NAME"
    zfs set org.zfsbootmenu:commandline="rw quiet" "$POOL_NAME/ROOT"

    # Take initial ZFS snapshot so snapshot boot selection is immediately active
    zfs snapshot "$POOL_NAME/ROOT/default@initial-installation" || true
fi

if [[ "$RUN_ANSIBLE" =~ ^(y|yes)$ ]]; then
    echo "Running Ansible playbook inside chroot..."
    
    if [[ -n "$CUSTOM_PLAYBOOK" ]]; then
        arch-chroot /mnt /bin/bash -c "su - $USERNAME -c 'cd ~/ansible && ansible-playbook $CUSTOM_PLAYBOOK --connection=local'"
    else
        arch-chroot /mnt /bin/bash -c "
            cd /home/$USERNAME/ansible
            if [[ -f local.yml ]]; then
                su - $USERNAME -c 'cd ~/ansible && ansible-playbook local.yml --connection=local'
            elif [[ -f site.yml ]]; then
                su - $USERNAME -c 'cd ~/ansible && ansible-playbook site.yml --connection=local'
            elif [[ -f main.yml ]]; then
                su - $USERNAME -c 'cd ~/ansible && ansible-playbook main.yml --connection=local'
            else
                echo 'No default playbook (local.yml, site.yml, main.yml) found. Skipping Ansible execution.'
            fi
        "
    fi
fi

# --------------------------------------------------
# 7. Clean Up & Unmount
# --------------------------------------------------
echo "[7/7] Unmounting partitions..."
umount "/mnt$EFI_MOUNT_POINT"
if [[ "$FS_CHOICE" == "1" ]]; then
    zfs unmount -a
    zpool export "$POOL_NAME"
else
    umount -R /mnt
fi

echo "=================================================="
echo " Installation Complete! You can now reboot.      "
echo "=================================================="
