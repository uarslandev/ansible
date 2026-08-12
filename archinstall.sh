# 3. ZFS Pool & Dataset Creation
echo -e "${YELLOW}[3/6] Creating ZFS Pool '$POOL_NAME'...${NC}"

ZPOOL_OPTS=(
    -f
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

# Create ZFS Datasets for ZFS-BootMenu compatibility (-u prevents auto-mounting on creation)
echo -e "${YELLOW}Creating ZFS Datasets...${NC}"
zfs create -o canmount=off -o mountpoint=none "$POOL_NAME/ROOT"
zfs create -o mountpoint=/ -o canmount=noauto "$POOL_NAME/ROOT/default"
zfs create -u -o mountpoint=/home "$POOL_NAME/home"

# Set ZFS-BootMenu parameters & bootfs
zfs set org.zfsbootmenu:commandline="rw quiet loglevel=3" "$POOL_NAME/ROOT"
zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"

# Mount root filesystem FIRST, then child datasets
echo -e "${YELLOW}Mounting ZFS Datasets...${NC}"
zfs mount "$POOL_NAME/ROOT/default"
zfs mount "$POOL_NAME/home"

mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi
