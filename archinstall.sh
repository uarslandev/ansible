#!/usr/bin/env bash
set -euo pipefail

echo "=================================================="
echo "      Arch Linux Automated System Installer       "
echo "=================================================="

# --- 1. Interactive Inputs ---
lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep disk; echo ""
read -rp "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda): " DISK
[[ -b "$DISK" ]] || { echo "Error: $DISK is not a valid block device."; exit 1; }

read -rp "Enter Hostname [arch-system]: " HOSTNAME; HOSTNAME=${HOSTNAME:-arch-system}
read -rp "Enter Timezone [Europe/Berlin]: " TIMEZONE; TIMEZONE=${TIMEZONE:-Europe/Berlin}

read -rp "Enter Username: " USERNAME
[[ -n "$USERNAME" ]] || { echo "Error: Username cannot be empty."; exit 1; }

prompt_pass() {
    local prompt=$1 var_name=$2 confirm_var=$3 pass1 pass2
    while true; do
        read -rsp "Enter $prompt: " pass1; echo
        read -rsp "Confirm $prompt: " pass2; echo
        [[ "$pass1" == "$pass2" && -n "$pass1" ]] && { eval "$var_name=\"\$pass1\""; break; }
        echo "Error: Passwords do not match or were empty. Try again."
    done
}

prompt_pass "Root Password" ROOT_PASS ROOT_PASS_CONFIRM
prompt_pass "User Password ($USERNAME)" USER_PASS USER_PASS_CONFIRM

echo -e "\nSelect Root Filesystem Type:\n1) ZFS\n2) ext4\n3) btrfs"
read -rp "Choice [1-3] (Default: 1): " FS_CHOICE; FS_CHOICE=${FS_CHOICE:-1}

echo -e "\nSelect primary bootloader strategy:"
if [[ "$FS_CHOICE" == "1" ]]; then
    echo -e "1) ZFSBootMenu (Default)\n2) GRUB\n3) systemd-boot"
    read -rp "Choice [1-3] (Default: 1): " BOOTLOADER_CHOICE; BOOTLOADER_CHOICE=${BOOTLOADER_CHOICE:-1}
else
    echo -e "1) GRUB (Default)\n2) systemd-boot"
    read -rp "Choice [1-2] (Default: 1): " BL_CHOICE
    BOOTLOADER_CHOICE=$([[ "${BL_CHOICE:-1}" == "1" ]] && echo "2" || echo "3")
fi

read -rp "Are you dual-booting with Windows? (y/N): " DUAL_BOOT; DUAL_BOOT=${DUAL_BOOT,,}

ENABLE_ENC="n"; ZFS_PASS=""
if [[ "$FS_CHOICE" == "1" ]]; then
    read -rp "Enable Native ZFS Encryption? (y/N): " ENABLE_ENC; ENABLE_ENC=${ENABLE_ENC,,}
    [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]] && prompt_pass "ZFS Encryption Passphrase" ZFS_PASS ZFS_PASS_CONFIRM
fi

echo -e "\nRun Ansible after installation? (y/N): "
read -rp "" RUN_ANSIBLE; RUN_ANSIBLE=${RUN_ANSIBLE,,}
CUSTOM_PLAYBOOK=""
[[ "$RUN_ANSIBLE" =~ ^(y|yes)$ ]] && read -rp "Enter custom playbook filename (leave empty for auto-detect): " CUSTOM_PLAYBOOK

POOL_NAME="zroot"
EFI_MOUNT_POINT=$([[ "$FS_CHOICE" == "1" && "$BOOTLOADER_CHOICE" == "1" ]] && echo "/efi" || echo "/boot")

# Define boot parameters before entering the heredoc block
CMDLINE_FINAL=$([[ "$FS_CHOICE" == "1" ]] && echo "zfs=$POOL_NAME/ROOT/default rw zfs_import_policy=force" || echo "rw")

echo -e "\n=================================================="
echo "WARNING: Target Partitions on $DISK will be configured!"
echo "Filesystem: $(case $FS_CHOICE in 1) echo ZFS;; 2) echo ext4;; 3) echo btrfs;; esac)"
echo "Encryption: $([[ "$ENABLE_ENC" =~ ^(y|yes)$ ]] && echo 'ENABLED (Passphrase)' || echo 'DISABLED')"
echo "Username:   $USERNAME | Timezone: $TIMEZONE"
echo "Bootloader: $(case $BOOTLOADER_CHOICE in 1) echo ZFSBootMenu;; 2) echo GRUB;; 3) echo systemd-boot;; esac)"
echo "Dual-Boot:  $([[ "$DUAL_BOOT" =~ ^(y|yes)$ ]] && echo 'YES' || echo 'NO')"
echo "Run Ansible:$([[ "$RUN_ANSIBLE" =~ ^(y|yes)$ ]] && echo 'YES' || echo 'NO')"
echo "=================================================="
read -rp "Are you sure you want to proceed? (type 'YES'): " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Installation aborted."; exit 0; }

# --- 2. Partitioning & Preparation ---
echo "[1/7] Preparing disk partitions..."
swapoff -a || true
lsblk -l -n -o NAME "$DISK" | tail -n +2 | xargs -I {} umount -l "/dev/{}" 2>/dev/null || true

if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
    echo "Checking for failed/previous Arch Linux partitions..."
    
    # Locate partition numbers associated with Arch labels
    ARCH_EFI_NUM=$(sgdisk -p "$DISK" 2>/dev/null | awk '/Arch-EFI/ {print $1}')
    ARCH_ROOT_NUM=$(sgdisk -p "$DISK" 2>/dev/null | awk '/Arch-Root/ {print $1}')

    if [[ -n "$ARCH_EFI_NUM" || -n "$ARCH_ROOT_NUM" ]]; then
        echo "Found previous Arch installation attempt. Cleaning up failed partitions..."
        [[ -n "$ARCH_EFI_NUM" ]] && sgdisk -d "$ARCH_EFI_NUM" "$DISK"
        [[ -n "$ARCH_ROOT_NUM" ]] && sgdisk -d "$ARCH_ROOT_NUM" "$DISK"
        partprobe "$DISK"; udevadm settle; sleep 2
    fi

    echo "Creating new Arch Linux partitions in free space..."
    sgdisk -n 0:0:+1024M -t 0:ef00 -c 0:"Arch-EFI" "$DISK"
    sgdisk -n 0:0:0     -t 0:8300 -c 0:"Arch-Root" "$DISK"
else
    # Full disk wipe for single-OS Arch installations
    blkdiscard -f "$DISK" 2>/dev/null || true
    zpool labelclear -f "$DISK" 2>/dev/null || true
    wipefs --all --force "$DISK" && sgdisk --zap-all "$DISK"
    PART_TYPE=$([[ "$FS_CHOICE" == "1" ]] && echo "bf00" || echo "8300")
    sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI-system" "$DISK"
    sgdisk -n 2:0:0     -t 2:"$PART_TYPE" -c 2:"Arch-Root" "$DISK"
fi
partprobe "$DISK"; udevadm settle; sleep 2

# Dynamically identify created partitions by label or structure
if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
    EFI_DEV_NAME=$(lsblk -l -n -o NAME,LABEL "$DISK" | awk '/Arch-EFI/ {print $1}')
    ROOT_DEV_NAME=$(lsblk -l -n -o NAME,LABEL "$DISK" | awk '/Arch-Root/ {print $1}')
    EFI_PART="/dev/$EFI_DEV_NAME"
    ROOT_PART="/dev/$ROOT_DEV_NAME"
else
    P_SEP=$([[ "$DISK" =~ (nvme|mmcblk) ]] && echo "p" || echo "")
    EFI_PART="${DISK}${P_SEP}1"
    ROOT_PART="${DISK}${P_SEP}2"
fi

echo "[2/7] Formatting EFI partition ($EFI_PART)..."
mkfs.vfat -F32 "$EFI_PART"

# --- 3. Filesystem Setup ---
echo "[3/7] Setting up root filesystem..."
case "$FS_CHOICE" in
    1) # ZFS Setup
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
            echo "$ZFS_PASS" | zpool create "${POOL_OPTS[@]}" \
                -O encryption=aes-256-gcm \
                -O keyformat=passphrase \
                -O keylocation=prompt \
                "$POOL_NAME" "$ROOT_PART"
        else
            zpool create "${POOL_OPTS[@]}" "$POOL_NAME" "$ROOT_PART"
        fi

        zfs create -o mountpoint=none "$POOL_NAME/ROOT"
        zfs create -o mountpoint=/ "$POOL_NAME/ROOT/default"
        zfs create -o mountpoint=/home "$POOL_NAME/home"
        zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"
        
        zpool export "$POOL_NAME"
        zpool import -N -R /mnt "$POOL_NAME"

        if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
            echo "$ZFS_PASS" | zfs load-key "$POOL_NAME"
        fi

        zfs mount "$POOL_NAME/ROOT/default"
        zfs mount "$POOL_NAME/home"

        mkdir -p "/mnt$EFI_MOUNT_POINT"
        mount "$EFI_PART" "/mnt$EFI_MOUNT_POINT"
        ;;

    2) # ext4 Setup
        mkfs.ext4 -F "$ROOT_PART"
        mount "$ROOT_PART" /mnt
        mkdir -p "/mnt$EFI_MOUNT_POINT"
        mount "$EFI_PART" "/mnt$EFI_MOUNT_POINT"
        ;;

    3) # btrfs Setup
        mkfs.btrfs -f "$ROOT_PART"
        mount "$ROOT_PART" /mnt
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        umount /mnt
        mount -o compress=zstd,subvol=@ "$ROOT_PART" /mnt
        mkdir -p /mnt/home
        mount -o compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
        mkdir -p "/mnt$EFI_MOUNT_POINT"
        mount "$EFI_PART" "/mnt$EFI_MOUNT_POINT"
        ;;
esac

# --- 4. Base System Installation ---
echo "[4/7] Installing base system..."
PKGS=(base linux linux-firmware sudo nano networkmanager efibootmgr git ansible curl)
[[ "$FS_CHOICE" == "1" ]] && PKGS+=(zfs-linux)
[[ "$FS_CHOICE" == "3" ]] && PKGS+=(btrfs-progs)
[[ "$BOOTLOADER_CHOICE" == "2" || "$DUAL_BOOT" =~ ^(y|yes)$ ]] && PKGS+=(grub os-prober ntfs-3g)

pacstrap -K /mnt "${PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

if [[ "$FS_CHOICE" == "1" ]]; then
    zgenhostid -f -o /mnt/etc/hostid 0x00babaf1
fi

# Prepare Ansible directory from host if local site.yml exists
HOST_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]:-$0}" )" && pwd )"
mkdir -p "/mnt/home/$USERNAME/ansible"
if [[ -f "$HOST_SCRIPT_DIR/site.yml" ]]; then
    cp -a "$HOST_SCRIPT_DIR/." "/mnt/home/$USERNAME/ansible/"
fi

# --- 5. System Chroot Configuration ---
echo "[5/7] Configuring installed system..."
arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen
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
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-wheel && chmod 0440 /etc/sudoers.d/10-wheel

if [[ ! -f "/home/$USERNAME/ansible/site.yml" ]]; then
    git clone https://github.com/uarslandev/ansible.git "/home/$USERNAME/ansible"
fi
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

systemctl enable NetworkManager

if [[ "$FS_CHOICE" == "1" ]]; then
    systemctl enable zfs-import-scan zfs-mount zfs-zed zfs.target
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block zfs filesystems)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Bootloader Configuration
if [[ "$BOOTLOADER_CHOICE" == "2" ]]; then
    grub-install --target=x86_64-efi --efi-directory="$EFI_MOUNT_POINT" --bootloader-id=GRUB --removable
    [[ "$FS_CHOICE" == "1" ]] && sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="zfs=$POOL_NAME\/ROOT\/default rw zfs_import_policy=force"/' /etc/default/grub
    [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]] && echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
    grub-mkconfig -o "$EFI_MOUNT_POINT/grub/grub.cfg"

elif [[ "$BOOTLOADER_CHOICE" == "3" ]]; then
    bootctl install --esp-path="$EFI_MOUNT_POINT"
    echo -e "default arch.conf\ntimeout 5\nconsole-mode max" > "$EFI_MOUNT_POINT/loader/loader.conf"
    echo -e "title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions $CMDLINE_FINAL" > "$EFI_MOUNT_POINT/loader/entries/arch.conf"
    if [[ "$DUAL_BOOT" =~ ^(y|yes)$ ]]; then
        echo -e "title Windows Boot Manager\nefi /EFI/Microsoft/Boot/bootmgfw.efi" > "$EFI_MOUNT_POINT/loader/entries/windows.conf"
    fi

elif [[ "$BOOTLOADER_CHOICE" == "1" ]]; then
    mkdir -p /efi/EFI/zfsbootmenu /efi/EFI/BOOT
    curl -fsSL -L -o /efi/EFI/zfsbootmenu/zfsbootmenu.efi "https://get.zfsbootmenu.org/efi" || \
    curl -fsSL -L -o /efi/EFI/zfsbootmenu/zfsbootmenu.efi "https://github.com/zbm-dev/zfsbootmenu/releases/latest/download/zfsbootmenu-release-x86_64-v2.3.0.EFI"

    if [[ -s /efi/EFI/zfsbootmenu/zfsbootmenu.efi ]]; then
        cp /efi/EFI/zfsbootmenu/zfsbootmenu.efi /efi/EFI/BOOT/BOOTX64.EFI
        efibootmgr --create --disk "$DISK" --part 1 --label "ZFSBootMenu" --loader "\\EFI\\zfsbootmenu\\zfsbootmenu.efi" --verbose || true
    else
        echo "Error: Failed to fetch ZFSBootMenu EFI binary." && exit 1
    fi
fi
CHROOT

# --- 6. Final Settings & Ansible Run ---
if [[ "$FS_CHOICE" == "1" ]]; then
    echo "[6/7] Setting ZFS pool boot properties..."
    zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"
    zpool set org.zfsbootmenu:timeout=10 "$POOL_NAME"
    
    if [[ "$ENABLE_ENC" =~ ^(y|yes)$ ]]; then
        zpool set org.zfsbootmenu:keysource="$POOL_NAME" "$POOL_NAME"
    fi

    zfs set org.zfsbootmenu:commandline="rw zfs_import_policy=force" "$POOL_NAME/ROOT"
fi

if [[ "$RUN_ANSIBLE" =~ ^(y|yes)$ ]]; then
    echo "Running Ansible playbook..."
    arch-chroot /mnt /bin/bash -c "
        chown -R $USERNAME:$USERNAME /home/$USERNAME
        cd /home/$USERNAME/ansible
        PLAYBOOK='$CUSTOM_PLAYBOOK'
        if [[ -z \"\$PLAYBOOK\" ]]; then
            for f in local.yml site.yml main.yml; do
                [[ -f \"\$f\" ]] && { PLAYBOOK=\"\$f\"; break; }
            done
        fi
        if [[ -n \"\$PLAYBOOK\" ]]; then
            su - $USERNAME -c \"cd ~/ansible && ansible-playbook \$PLAYBOOK --connection=local -e 'ansible_become_pass=\\\"\\\"'\"
        else
            echo 'No valid playbook found. Skipping.'
        fi
    "
fi

# --- 7. Clean Up ---
echo "[7/7] Unmounting partitions..."
umount "/mnt$EFI_MOUNT_POINT" 2>/dev/null || true
if [[ "$FS_CHOICE" == "1" ]]; then
    zfs unmount -a 2>/dev/null || true
    zpool export "$POOL_NAME" 2>/dev/null || true
else
    umount -R /mnt 2>/dev/null || true
fi

echo "=================================================="
echo " Installation Complete! You can now reboot.       "
echo "=================================================="
