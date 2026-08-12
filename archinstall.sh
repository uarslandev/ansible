#!/bin/bash
################################################################################
# Arch Linux on ZFS Installation Script
# Based on: https://timo.sh/blog/installing-arch-linux-on-zfs/
# 
# WARNING: This script will partition and format your disk!
# Make sure you have backed up all important data.
################################################################################

set -e  # Exit on any error

# ============================================================================
# CONFIGURATION - CUSTOMIZE THESE BEFORE RUNNING
# ============================================================================

# Hardware configuration
DISK="/dev/nvme0n1"              # Target disk (e.g., /dev/sda, /dev/nvme0n1)
KEYMAP="de-latin1"               # Keyboard layout (default: de-latin1)
CONSOLE_FONT="ter-132n"          # Console font

# ZFS Pool configuration
POOL_NAME="zroot"                # ZFS pool name
POOL_DATASET="rootfs"            # Root dataset name

# System configuration
HOSTNAME="myhostname"            # System hostname
TIMEZONE="Europe/Berlin"         # Timezone
LOCALE="en_US.UTF-8"             # System locale
LOCALE_GEN="en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8"               # Locales to generate
VCONSOLE_KEYMAP="de-latin1"      # Console keymap

# User configuration
USERNAME="archuser"              # Regular user to create
ENABLE_SUDO=true                 # Enable sudo for user

# Packages to install
BASE_PACKAGES="base base-devel linux linux-headers linux-firmware grub efibootmgr nano zsh openssh"
OPTIONAL_PACKAGES="gdm gnome"    # Set to empty string to skip desktop environment
ADDITIONAL_PACKAGES=""            # Add any extra packages here

# Desktop environment (optional)
INSTALL_DESKTOP=false            # Set to true to install GNOME with GDM
GDM_ENABLE=false                 # Enable GDM service (requires INSTALL_DESKTOP=true)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $1"
}

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

confirm_action() {
    local prompt="$1"
    local response
    
    while true; do
        read -p "$(log_warn "$prompt (yes/no): ")" response
        case "$response" in
            yes) return 0 ;;
            no)  return 1 ;;
            *)   echo "Please answer 'yes' or 'no'" ;;
        esac
    done
}

# ============================================================================
# PRE-INSTALLATION CHECKS
# ============================================================================

log_info "Starting Arch Linux + ZFS Installation Script"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if running in UEFI mode
if [ ! -d /sys/firmware/efi/efivars ]; then
    log_error "System is not booting in UEFI mode. This script requires UEFI."
    exit 1
fi

log_success "Running in UEFI mode"

# Check internet connection
if ! ping -c 1 archlinux.org &> /dev/null; then
    log_error "No internet connection detected. Please connect to the network first."
    exit 1
fi

log_success "Internet connection verified"

# Check if disk exists
if [ ! -b "$DISK" ]; then
    log_error "Disk $DISK not found."
    exit 1
fi

log_success "Disk $DISK found"

# Check if ZFS tools are available
if ! command -v zpool &> /dev/null; then
    log_info "ZFS tools not found. Installing from archzfs repository..."
    pacman -Sy --noconfirm archzfs-linux
    modprobe zfs
    log_success "ZFS tools installed"
else
    log_success "ZFS tools already available"
fi

echo ""
log_warn "ATTENTION: This script will partition and format $DISK"
log_warn "All data on $DISK will be PERMANENTLY DESTROYED!"
log_warn "Make absolutely sure you have selected the correct disk."
echo ""
echo "Disk information:"
lsblk "$DISK"
echo ""

if ! confirm_action "Do you want to continue with the installation?"; then
    log_error "Installation cancelled by user."
    exit 0
fi

# ============================================================================
# CONFIGURATION SUMMARY
# ============================================================================

echo ""
log_info "Installation Configuration:"
echo "  Disk:              $DISK"
echo "  Hostname:          $HOSTNAME"
echo "  Timezone:          $TIMEZONE"
echo "  Locale:            $LOCALE"
echo "  Username:          $USERNAME"
echo "  ZFS Pool:          $POOL_NAME"
echo "  ZFS Root Dataset:  $POOL_DATASET"
echo ""

if ! confirm_action "Is this configuration correct?"; then
    log_error "Installation cancelled by user."
    exit 0
fi

# ============================================================================
# KEYBOARD AND CONSOLE SETUP
# ============================================================================

log_info "Setting keyboard layout and console font..."
loadkeys "$KEYMAP"
setfont "$CONSOLE_FONT"
log_success "Keyboard and console configured"

# ============================================================================
# DISK PARTITIONING
# ============================================================================

echo ""
log_info "Partitioning $DISK..."

# Determine partition scheme based on disk type
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmc"* ]]; then
    EFI_PART="${DISK}p1"
    ZFS_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ZFS_PART="${DISK}2"
fi

log_info "Wiping disk and creating new GPT partition table..."
parted -a opt "$DISK" <<EOF
mklabel gpt
mkpart primary 5MB% 512MB
mkpart primary 512MB 100%
set 1 boot on
set 1 esp on
quit
EOF

log_success "Partitions created successfully"
log_info "EFI partition: $EFI_PART"
log_info "ZFS partition: $ZFS_PART"

# ============================================================================
# ZFS POOL CREATION
# ============================================================================

echo ""
log_info "Creating ZFS pool '$POOL_NAME'..."

# Create the ZFS pool with recommended settings
zpool create \
  -o ashift=12 \
  -O acltype=posixacl -O canmount=off \
  -O dnodesize=auto -O normalization=formD \
  -O atime=off -O xattr=sa -O mountpoint=none \
  -R /mnt "$POOL_NAME" "$ZFS_PART"

log_success "ZFS pool created"

# ============================================================================
# ZFS DATASET CREATION
# ============================================================================

echo ""
log_info "Creating ZFS datasets..."

# Root dataset
zfs create -o canmount=noauto -o mountpoint=/ "$POOL_NAME/$POOL_DATASET"

# Set the root dataset as bootfs
zpool set bootfs="$POOL_NAME/$POOL_DATASET" "$POOL_NAME"

# Additional datasets for better snapshots
zfs create "$POOL_NAME/$POOL_DATASET/home"

log_success "ZFS datasets created"

# ============================================================================
# MOUNT ZFS DATASETS
# ============================================================================

echo ""
log_info "Mounting ZFS datasets..."

zfs mount "$POOL_NAME/$POOL_DATASET"

log_success "ZFS datasets mounted"

# ============================================================================
# ZFS POOL CACHE
# ============================================================================

echo ""
log_info "Creating ZFS pool cache..."

mkdir -p /mnt/etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

log_success "ZFS pool cache created"

# ============================================================================
# BOOT PARTITION SETUP
# ============================================================================

echo ""
log_info "Setting up EFI boot partition..."

mkfs.vfat -F 32 "$EFI_PART"
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

log_success "EFI partition formatted and mounted"

# ============================================================================
# GENERATE FSTAB
# ============================================================================

echo ""
log_info "Generating fstab..."

genfstab -U -p /mnt >> /mnt/etc/fstab

log_success "fstab generated"

# ============================================================================
# PACSTRAP - INSTALL BASE SYSTEM
# ============================================================================

echo ""
log_info "Installing base system packages..."
log_info "This may take several minutes..."

PACSTRAP_PACKAGES="$BASE_PACKAGES"

if [ "$INSTALL_DESKTOP" = true ]; then
    PACSTRAP_PACKAGES="$PACSTRAP_PACKAGES $OPTIONAL_PACKAGES"
fi

if [ -n "$ADDITIONAL_PACKAGES" ]; then
    PACSTRAP_PACKAGES="$PACSTRAP_PACKAGES $ADDITIONAL_PACKAGES"
fi

pacstrap /mnt $PACSTRAP_PACKAGES

log_success "Base system installed"

# ============================================================================
# CHROOT CONFIGURATION
# ============================================================================

echo ""
log_info "Entering chroot for system configuration..."

# Create a configuration script to run inside chroot
cat > /mnt/arch-zfs-chroot-config.sh << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

# Import parameters
POOL_NAME="$1"
POOL_DATASET="$2"
HOSTNAME="$3"
TIMEZONE="$4"
LOCALE="$5"
USERNAME="$6"
ENABLE_SUDO="$7"
GDM_ENABLE="$8"
VCONSOLE_KEYMAP="$9"
LOCALE_GEN="${10}"

# Setup ArchZFS repository
echo ""
echo "[INFO] Adding ArchZFS repository..."
echo -e '\n[archzfs]
Server = https://archzfs.com/$repo/x86_64' >> /etc/pacman.conf

# Import ArchZFS GPG keys
echo "[INFO] Importing ArchZFS GPG keys..."
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76 || true
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76 || true

# Install ZFS DKMS
echo "[INFO] Installing ZFS DKMS module..."
pacman -Sy --noconfirm zfs-dkms

# Optional: Install Intel microcode
if grep -q "Intel" /proc/cpuinfo; then
    echo "[INFO] Installing Intel microcode..."
    pacman -S --noconfirm intel-ucode
fi

# Optional: Install NVIDIA drivers (comment out if not needed)
# echo "[INFO] Installing NVIDIA DKMS drivers..."
# pacman -S --noconfirm nvidia-dkms

# Configure mkinitcpio for ZFS
echo "[INFO] Configuring mkinitcpio..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap zfs filesystems)/' /etc/mkinitcpio.conf

# Generate initramfs
echo "[INFO] Generating initramfs..."
mkinitcpio -p linux

# Setup GRUB bootloader
echo "[INFO] Installing and configuring GRUB..."
mkdir -p /boot/grub
pacman -S --noconfirm grub efibootmgr

# Configure GRUB with ZFS root
sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"$/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 zfs=$POOL_NAME\/$POOL_DATASET\"/" /etc/default/grub

# Generate GRUB configuration
grub-mkconfig -o /boot/grub/grub.cfg

# Install GRUB to EFI
grub-install --target=x86_64-efi --efi-directory=/boot

# Enable ZFS services
echo "[INFO] Enabling ZFS services..."
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target

# Enable GDM if requested
if [ "$GDM_ENABLE" = "true" ]; then
    echo "[INFO] Enabling GDM..."
    systemctl enable gdm
fi

# Set timezone
echo "[INFO] Setting timezone to $TIMEZONE..."
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
hwclock --systohc

# Configure locales
echo "[INFO] Configuring locales..."
echo "$LOCALE_GEN" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Configure console keymap
echo "[INFO] Configuring console keymap..."
echo "KEYMAP=$VCONSOLE_KEYMAP" > /etc/vconsole.conf

# Set hostname
echo "[INFO] Setting hostname to $HOSTNAME..."
echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 $HOSTNAME" >> /etc/hosts

# Create user
if [ -n "$USERNAME" ]; then
    echo "[INFO] Creating user $USERNAME..."
    useradd -m -s /bin/bash "$USERNAME" || true
fi

# Setup sudo
if [ "$ENABLE_SUDO" = "true" ]; then
    echo "[INFO] Setting up sudo..."
    pacman -S --noconfirm sudo
    
    if [ -n "$USERNAME" ]; then
        usermod -aG wheel "$USERNAME"
    fi
    
    # Uncomment wheel group in sudoers
    sed -i 's/^# %wheel ALL=(ALL) ALL$/%wheel ALL=(ALL) ALL/' /etc/sudoers
fi

# Set root password
echo ""
echo "[INFO] Setting root password..."
passwd

# Set user password
if [ -n "$USERNAME" ]; then
    echo "[INFO] Setting password for user $USERNAME..."
    passwd "$USERNAME"
fi

echo ""
echo "[SUCCESS] Chroot configuration complete!"

CHROOT_SCRIPT

chmod +x /mnt/arch-zfs-chroot-config.sh

# Run chroot configuration
arch-chroot /mnt /arch-zfs-chroot-config.sh \
    "$POOL_NAME" \
    "$POOL_DATASET" \
    "$HOSTNAME" \
    "$TIMEZONE" \
    "$LOCALE" \
    "$USERNAME" \
    "$ENABLE_SUDO" \
    "$GDM_ENABLE" \
    "$VCONSOLE_KEYMAP" \
    "$LOCALE_GEN"

# Clean up chroot script
rm /mnt/arch-zfs-chroot-config.sh

log_success "Chroot configuration completed"

# ============================================================================
# FINALIZATION
# ============================================================================

echo ""
log_info "Finalizing installation..."

log_info "Unmounting filesystems..."
umount -R /mnt

log_info "Unmounting ZFS datasets..."
zfs umount -a

log_info "Exporting ZFS pool..."
zpool export -a

log_success "Installation complete!"
echo ""
log_info "You can now reboot into your new Arch Linux ZFS system."
log_info "Remove the installation media and the system will boot automatically."
echo ""

if confirm_action "Reboot now?"; then
    reboot
fi
