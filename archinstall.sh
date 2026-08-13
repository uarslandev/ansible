#!/usr/bin/env bash
set -euo pipefail

echo "=================================================="
echo "    Arch Linux Automated System Installer         "
echo "=================================================="

# Helper function for password input with confirmation
prompt_pass() {
    local var="$1" prompt="$2" p1 p2
    while true; do
        read -rsp "$prompt: " p1; echo
        read -rsp "Confirm $prompt: " p2; echo
        if [[ "$p1" == "$p2" && -n "$p1" ]]; then
            eval "$var=\"\$p1\""
            break
        fi
        echo "Error: Passwords do not match or were empty. Try again."
    done
}

# --------------------------------------------------
# 1. Interactive Inputs
# --------------------------------------------------
lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep disk
echo ""
read -rp "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda): " DISK
[[ ! -b "$DISK" ]] && { echo "Error: $DISK is not a valid block device."; exit 1; }

read -rp "Enter Hostname [arch-system]: " HOSTNAME; HOSTNAME=${HOSTNAME:-arch-system}
read -rp "Enter Timezone [Europe/Berlin]: " TIMEZONE; TIMEZONE=${TIMEZONE:-Europe/Berlin}
read -rp "Enter Username: " USERNAME
[[ -z "$USERNAME" ]] && { echo "Error: Username cannot be empty."; exit 1; }

prompt_pass ROOT_PASS "Root Password"
prompt_pass USER_PASS "User Password ($USERNAME)"

echo -e "\nSelect Root Filesystem Type:\n1) ZFS\n2) ext4\n3) btrfs"
read -rp "Choice [1-3] (Default: 1): " FS_CHOICE; FS_CHOICE=${FS_CHOICE:-1}

echo ""
if [[ "$FS_CHOICE" == "1" ]]; then
    echo -e "Select primary bootloader:\n1) ZFSBootMenu\n2) GRUB\n3) systemd-boot"
    read -rp "Choice [1-3] (Default: 1): " BOOTLOADER_CHOICE; BOOTLOADER_CHOICE=${BOOTLOADER_CHOICE:-1}
else
    echo -e "Select primary bootloader:\n1) GRUB\n2) systemd-boot"
    read -rp "Choice [1-2] (Default: 1): " BL_C; BOOTLOADER_CHOICE=$([[ "$BL_C" == "1" ]] && echo "2" || echo "3")
fi

read -rp "Are you dual-booting with Windows? (y/N): " DUAL_BOOT; DUAL_BOOT=${DUAL_BOOT,,}

ENABLE_ENC="n"; ZFS_PASS=""
if [[ "$FS_CHOICE" == "1" ]]; then
    read -rp "Enable Native ZFS Encryption? (y/N): " ENABLE_ENC; ENABLE_ENC=${ENABLE_ENC,,}
    [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]] && prompt_pass ZFS_PASS "ZFS Encryption Passphrase"
fi

read -rp "Run Ansible after installation? (y/N): " RUN_ANSIBLE; RUN_ANSIBLE=${RUN_ANSIBLE,,}
CUSTOM_PLAYBOOK=""
[[ "$RUN_ANSIBLE" =~ ^(y|yes)$ ]] && read -rp "Enter playbook filename (leave empty for auto-detect): " CUSTOM_PLAYBOOK

POOL_NAME="zroot"
CMDLINE="rw"
[[ "$FS_CHOICE" == "1" ]] && CMDLINE="zfs=$POOL_NAME/ROOT/default rw"

echo "=================================================="
echo "Disk: $DISK | FS: $FS_CHOICE | Enc: $ENABLE_ENC | User: $USERNAME | Bootloader: $BOOTLOADER_CHOICE"
echo "=================================================="
read -rp "Are you sure you want to proceed? (type 'YES'): " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Installation aborted."; exit 0; }

# --------------------------------------------------
# 2. Disk Wipe & Partitioning
# --------------------------------------------------
echo "[1/7] Preparing disk partitions..."
swapoff -a || true
for part in $(lsblk -l -n -o NAME "$DISK" | tail -n +2); do umount -l "/dev/$part" 2>/dev/null || true; done

if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
    sgdisk -n 0:0:+512M -t 0:ef00 -c 0:"Arch-EFI" "$DISK" || true
    sgdisk -n 0:0:0     -t 0:8300 -c 0:"Arch-Root" "$DISK" || true
else
    blkdiscard -f "$DISK" 2>/dev/null || true
    zpool labelclear -f "$DISK" 2>/dev/null || true
    dd if=/dev/zero of="$DISK" bs=1M count=100 status=none conv=fsync
    wipefs --all --force "$DISK"
    sgdisk --zap-all "$DISK"
    PART_TYPE=$([[ "$FS_CHOICE" == "1" ]] && echo "bf00" || echo "8300")
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI-system" "$DISK"
    sgdisk -n 2:0:0     -t 2:"$PART_TYPE" -c 2:"Arch-Root" "$DISK"
fi

partprobe "$DISK"; sleep 2
[[ "$DISK" =~ "nvme" || "$DISK" =~ "mmcblk" ]] && { EFI_PART="${DISK}p1"; ROOT_PART="${DISK}p2"; } || { EFI_PART="${DISK}1"; ROOT_PART="${DISK}2"; }

echo "[2/7] Formatting EFI partition..."
mkfs.vfat -F32 "$EFI_PART"

# --------------------------------------------------
# 3. Filesystem Setup
# --------------------------------------------------
echo "[3/7] Setting up root filesystem..."

if [[ "$FS_CHOICE" == "1" ]]; then
    zgenhostid -f 0x00babaf1
    POOL_OPTS=(-o ashift=12 -o autotrim=on -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=none -R /mnt)

    if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
        echo "$ZFS_PASS" | zpool create "${POOL_OPTS[@]}" -O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation=file:///dev/stdin "$POOL_NAME" "$ROOT_PART"
        zfs set keylocation=prompt "$POOL_NAME"
    else
        zpool create "${POOL_OPTS[@]}" "$POOL_NAME" "$ROOT_PART"
    fi

    zfs create -o mountpoint=none "$POOL_NAME/ROOT"
    zfs create -o mountpoint=/ "$POOL_NAME/ROOT/default"
    zfs create -o mountpoint=/home "$POOL_NAME/home"
    zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"
    zpool export "$POOL_NAME"

    if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
        zpool import -N -R /mnt "$POOL_NAME"
        echo "$ZFS_PASS" | zfs load-key -L prompt "$POOL_NAME"
    else
        zpool import -N -R /mnt "$POOL_NAME"
    fi
    zfs mount "$POOL_NAME/ROOT/default"
    zfs mount "$POOL_NAME/home"

elif [[ "$FS_CHOICE" == "2" ]]; then
    mkfs.ext4 -F "$ROOT_PART"; mount "$ROOT_PART" /mnt
elif [[ "$FS_CHOICE" == "3" ]]; then
    mkfs.btrfs -f "$ROOT_PART"; mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@; btrfs subvolume create /mnt/@home; umount /mnt
    mount -o compress=zstd,subvol=@ "$ROOT_PART" /mnt
    mkdir -p /mnt/home; mount -o compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
fi

EFI_MOUNT_POINT="/boot"
[[ "$FS_CHOICE" == "1" && "$BOOTLOADER_CHOICE" == "1" ]] && EFI_MOUNT_POINT="/efi"
mkdir -p "/mnt$EFI_MOUNT_POINT"
mount "$EFI_PART" "/mnt$EFI_MOUNT_POINT"

# Single-passphrase setup: Generate keyfile and bind it to dataset
if [[ "$FS_CHOICE" == "1" && "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
    mkdir -p /mnt/etc/zfs
    dd if=/dev/urandom of=/mnt/etc/zfs/zroot.key bs=32 count=1 status=none
    chmod 600 /mnt/etc/zfs/zroot.key
    zfs change-key -o keyformat=raw -o keylocation=file:///etc/zfs/zroot.key "$POOL_NAME"
fi

# --------------------------------------------------
# 4. Pacstrap Base System
# --------------------------------------------------
echo "[4/7] Installing base system..."
PACMAN_PKGS=(base linux linux-firmware sudo nano networkmanager efibootmgr git ansible curl)
[[ "$FS_CHOICE" == "1" ]] && PACMAN_PKGS+=(zfs-linux)
[[ "$FS_CHOICE" == "3" ]] && PACMAN_PKGS+=(btrfs-progs)
[[ "$BOOTLOADER_CHOICE" == "2" || "$DUAL_BOOT" =~ ^(y|yes)$ ]] && PACMAN_PKGS+=(grub os-prober ntfs-3g)

pacstrap -K /mnt "${PACMAN_PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab
[[ "$FS_CHOICE" == "1" ]] && cp /etc/hostid /mnt/etc/hostid

# --------------------------------------------------
# 5. System Configuration inside Chroot
# --------------------------------------------------
echo "[5/7] Configuring system..."

cat <<CHROOT_SCRIPT | arch-chroot /mnt /bin/bash
set -euo pipefail

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

git clone https://github.com/uarslandev/ansible.git "/home/$USERNAME/ansible"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/ansible"

systemctl enable NetworkManager

if [[ "$FS_CHOICE" == "1" ]]; then
    systemctl enable zfs-import-scan.service zfs-mount.service zfs-zed.service zfs.target
    
    # Embed keyfile in initramfs image so systemd/initramfs unlocks ZFS without second prompt
    if [[ -f /etc/zfs/zroot.key ]]; then
        sed -i 's|^FILES=(.*)|FILES=(/etc/zfs/zroot.key)|' /etc/mkinitcpio.conf
    fi
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block zfs filesystems)/' /etc/mkinitcpio.conf
    mkinitcpio -P
else
    mkinitcpio -P
fi

if [[ "$BOOTLOADER_CHOICE" == "2" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
    [[ "$FS_CHOICE" == "1" ]] && sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="zfs=$POOL_NAME\/ROOT\/default rw"/' /etc/default/grub
    [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]] && echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
elif [[ "$BOOTLOADER_CHOICE" == "3" ]]; then
    bootctl install --esp-path=/boot
    cat <<LOADER > /boot/loader/loader.conf
default arch.conf
timeout 5
console-mode max
LOADER
    cat <<ENTRY > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options $CMDLINE
ENTRY
    [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]] && cat <<WINENTRY > /boot/loader/entries/windows.conf
title   Windows Boot Manager
efi     /EFI/Microsoft/Boot/bootmgfw.efi
WINENTRY
else
    mkdir -p /efi/EFI/zfsbootmenu /efi/EFI/BOOT
    curl -fsSL -L -o /efi/EFI/zfsbootmenu/zfsbootmenu.efi "https://get.zfsbootmenu.org/efi" || \
    curl -fsSL -L -o /efi/EFI/zfsbootmenu/zfsbootmenu.efi "https://github.com/zbm-dev/zfsbootmenu/releases/latest/download/zfsbootmenu-release-x86_64-v2.3.0.EFI"

    if [[ -s /efi/EFI/zfsbootmenu/zfsbootmenu.efi ]]; then
        cp /efi/EFI/zfsbootmenu/zfsbootmenu.efi /efi/EFI/BOOT/BOOTX64.EFI
        efibootmgr --create --disk "$DISK" --part 1 --label "ZFSBootMenu" --loader "\\EFI\\zfsbootmenu\\zfsbootmenu.efi" --verbose || true
    fi
fi
CHROOT_SCRIPT

# --------------------------------------------------
# 6. Set Bootloader Pool Properties (ZFS Only) & Run Ansible
# --------------------------------------------------
if [[ "$FS_CHOICE" == "1" ]]; then
    echo "[6/7] Setting pool boot properties..."
    zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"
    zpool set org.zfsbootmenu:timeout=10 "$POOL_NAME"
    zpool set org.zfsbootmenu:keysource="$POOL_NAME/ROOT" "$POOL_NAME"
    zfs set org.zfsbootmenu:commandline="rw" "$POOL_NAME/ROOT"
fi

if [[ "$RUN_ANSIBLE" =~ ^(y|yes)$ ]]; then
    echo "Running Ansible playbook..."
    PLAYBOOK=${CUSTOM_PLAYBOOK:-local.yml}
    arch-chroot /mnt /bin/bash -c "
        cd /home/$USERNAME/ansible
        pb=\$(find . -maxdepth 1 \( -name '$PLAYBOOK' -o -name 'site.yml' -o -name 'main.yml' \) | head -n1)
        if [[ -n \"\$pb\" ]]; then
            su - $USERNAME -c \"cd ~/ansible && ansible-playbook \$pb --connection=local\"
        else
            echo 'No playbook found. Skipping Ansible.'
        fi
    "
fi

# --------------------------------------------------
# 7. Clean Up & Unmount
# --------------------------------------------------
echo "[7/7] Unmounting partitions..."
umount "/mnt$EFI_MOUNT_POINT"
if [[ "$FS_CHOICE" == "1" ]]; then
    zfs unmount -a; zpool export "$POOL_NAME"
else
    umount -R /mnt
fi

echo "=================================================="
echo " Installation Complete! You can now reboot.       "
echo "=================================================="
