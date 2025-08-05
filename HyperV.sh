#!/bin/bash

# =========================================
# Arch Linux Minimal Installation for Hyper-V
# Features:
# - Legacy BIOS support (for Hyper-V Generation 1 VMs)
# - Automatic Sway launch
# - Hyper-V specific optimizations
# =========================================

# Configuration
TARGET_DISK="/dev/sda"
SWAP_SIZE="2G"        # Reduced swap for VM
USERNAME="penich"
TIMEZONE="Europe/Moscow"
HYPERV_VIDEO="hyperv" # Hyper-V video driver

# =========================================
# 1. PRE-INSTALLATION CHECKS
# =========================================

# Verify target disk exists
[ -b "$TARGET_DISK" ] || { echo "[ERROR] Disk $TARGET_DISK not found!"; exit 1; }

# Confirm destructive action
echo "========================================"
echo "WARNING: This will ERASE ALL DATA on $TARGET_DISK!"
echo "========================================"
read -p "Continue? (y/N) " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 1

# Check internet connection
ping -c 3 archlinux.org || { echo "[ERROR] No internet connection"; exit 1; }

# Update system clock
timedatectl set-ntp true || { echo "[ERROR] Time sync failed"; exit 1; }

# =========================================
# 2. DISK SETUP (BIOS/MBR for Hyper-V Gen1)
# =========================================

# Partitioning (MBR for BIOS - Hyper-V Generation 1)
echo "Creating partitions for Hyper-V (Legacy BIOS)..."
parted -s "$TARGET_DISK" mklabel msdos || exit 1
parted -s "$TARGET_DISK" mkpart primary linux-swap 1MiB "${SWAP_SIZE}MiB" || exit 1
parted -s "$TARGET_DISK" mkpart primary btrfs "${SWAP_SIZE}MiB" 100% || exit 1
parted -s "$TARGET_DISK" set 2 boot on || exit 1  # Boot flag for root partition

# Formatting
echo "Formatting partitions..."
mkswap "${TARGET_DISK}1" || exit 1
mkfs.btrfs -f "${TARGET_DISK}2" || exit 1
swapon "${TARGET_DISK}1" || exit 1

# Btrfs subvolumes
echo "Creating Btrfs subvolumes..."
mount "${TARGET_DISK}2" /mnt || exit 1
btrfs subvolume create /mnt/@ || exit 1
btrfs subvolume create /mnt/@home || exit 1
umount /mnt || exit 1

mount -o noatime,compress=zstd,space_cache=v2,subvol=@ "${TARGET_DISK}2" /mnt || exit 1
mkdir -p /mnt/home || exit 1
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "${TARGET_DISK}2" /mnt/home || exit 1

# =========================================
# 3. BASE SYSTEM INSTALLATION
# =========================================

echo "Installing base system..."
pacstrap /mnt base linux linux-firmware || exit 1
genfstab -U /mnt >> /mnt/etc/fstab || exit 1

# =========================================
# 4. CHROOT CONFIGURATION
# =========================================

arch-chroot /mnt /bin/bash <<EOF
# Localization and time
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "archlinux" > /etc/hostname

# Bootloader (GRUB for BIOS)
pacman -S --noconfirm grub || exit 1
grub-install --target=i386-pc "$TARGET_DISK" || exit 1
grub-mkconfig -o /boot/grub/grub.cfg || exit 1

# Network configuration
echo "Installing and configuring NetworkManager..."
pacman -S --noconfirm networkmanager || exit 1
systemctl enable NetworkManager || exit 1

# Hyper-V specific packages
echo "Installing Hyper-V integration services..."
pacman -S --noconfirm hyperv || exit 1
systemctl enable hv_fcopy_daemon
systemctl enable hv_kvp_daemon
systemctl enable hv_vss_daemon

# Graphical environment with Hyper-V optimizations
echo "Installing graphical environment..."
pacman -S --noconfirm \
    xorg-xwayland sway waybar foot \
    xf86-video-fbdev xf86-input-libinput \
    grim slurp wl-clipboard || exit 1

# Create user
useradd -m -G wheel -s /bin/bash $USERNAME || exit 1
echo "Set password for $USERNAME:"
while ! passwd $USERNAME; do echo "Try again"; done

echo "Set root password:"
while ! passwd; do echo "Try again"; done

# Sudo configuration
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Sway autostart
cat > /home/$USERNAME/.bash_profile <<EOL
if [[ -z \$WAYLAND_DISPLAY ]] && [[ \$(tty) = /dev/tty1 ]]; then
    exec sway
fi
EOL

# Basic Sway configuration for Hyper-V
mkdir -p /home/$USERNAME/.config/sway
cat > /home/$USERNAME/.config/sway/config <<EOL
# Basic settings
set \$mod Mod4
bindsym \$mod+Return exec foot
bindsym \$mod+Shift+q kill

# Waybar
bar {
    position top
    status_command waybar
}

# Hyper-V display settings
output * {
    mode 1280x720@60Hz
    bg ~/wallpaper.png fill
}
EOL

# Set wallpaper
curl -o /home/$USERNAME/wallpaper.png https://archlinux.org/wallpaper/ || exit 1
chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF

# =========================================
# 5. POST-INSTALLATION
# =========================================

echo "Installation complete!"
echo "User: $USERNAME"
echo "Password: set during installation"
echo "Graphical environment will start automatically"
echo "For Hyper-V Enhanced Session:"
echo "1. Shut down the VM"
echo "2. Run: Set-VM -VMName <YourVM> -EnhancedSessionTransportType HVSocket"
echo "3. Start the VM"
echo "To reboot now:"
echo "umount -R /mnt && reboot"