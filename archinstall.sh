echo "[+] Configuring system in chroot..."
HOSTID_VAL=$(hostid)

# 1. Base system & User configuration using systemd-firstboot and native tools
arch-chroot /mnt systemd-firstboot --hostname="${HOST_NAME}" --locale="en_US.UTF-8" --timezone="UTC"
echo "root:${ROOT_PASS}" | arch-chroot /mnt chpasswd
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "${NEW_USER}"
echo "${NEW_USER}:${USER_PASS}" | arch-chroot /mnt chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel

# 2. Add ArchZFS repo & install packages
cat << 'EOF' >> /mnt/etc/pacman.conf

[archzfs]
SigLevel = TrustAll Optional
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

arch-chroot /mnt pacman -Sy --noconfirm zfs-dkms zfs-utils
arch-chroot /mnt zgenhostid "${HOSTID_VAL}"

# 3. Enable services & configure initcpio
arch-chroot /mnt systemctl enable NetworkManager zfs.target zfs-import-cache zfs-mount zfs-import.target

sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect modprobes block zfs filesystems)/' /mnt/etc/mkinitcpio.conf
sed -i 's/^MODULES=.*/MODULES=(zfs)/' /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux-lts

# 4. Install systemd-boot
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

# 5. Clone Ansible repository
arch-chroot /mnt sudo -u "${NEW_USER}" git clone "${ANSIBLE_REPO}" "/home/${NEW_USER}/ansible"
