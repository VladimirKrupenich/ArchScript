#!/bin/bash

# Arch Linux installation script with settings for vkrupenich
# Logging entire installation to /root/arch_install.log
exec > >(tee -a /root/arch_install.log) 2>&1

echo "=== Starting Arch Linux installation ==="
date

# 1. Disk identification
echo "=== Disk identification ==="
SSD=$(lsblk -o PATH,MODEL | grep -i 'ssd' | awk '{print $1}' | head -n1)
HDD=$(lsblk -o PATH,MODEL | grep -i 'tosh' | awk '{print $1}' | head -n1)

[ -z "$SSD" ] && SSD="/dev/sda"  # fallback
[ -z "$HDD" ] && HDD="/dev/sdb"       # fallback

# 2. Pre-installation checks
[ "$(id -u)" -ne 0 ] && { echo -e "\033[1;31m[ERROR] Root privileges required\033[0m"; exit 1; }
ping -c 3 archlinux.org || { echo -e "\033[1;31m[ERROR] No internet connection\033[0m"; exit 1; }

if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "033[1;31m[ERROR] System not booted in UEFI mode!\033[0m"
    exit 1
fi

# Disk presence check
if [ ! -e "$SSD" ]; then
    echo -e "033[1;31m[ERROR] SSD $SSD not found!\033[0m"
    exit 1
fi

if [ ! -e "$HDD" ]; then
    echo -e "033[1;31m[ERROR] HDD $HDD not found!\033[0m"
    exit 1
fi

# Free space check
if [ $(df --output=avail -BG / | tail -1 | tr -d 'G') -lt 10 ]; then
    echo -e "033[1;31m[ERROR] Not enough free space for installation!\033[0m"
    exit 1
fi

# Data loss warning
echo "[WARNING] This script will erase all data on $SSD and $HDD!"
read -p "Continue installation? (y/N): " confirm
if [ "$confirm" != "y" ]; then
    echo "[INFO] Installation canceled"
    exit 1
fi

# 3. Disk setup
echo "=== Disk setup ==="

# Disk wiping
wipefs -a "$SSD"
wipefs -a "$HDD"

# SSD partitioning
echo "Partitioning SSD ($SSD)..."
parted -s "$SSD" mklabel gpt
parted -s "$SSD" mkpart "EFI" fat32 1MiB 512MiB
parted -s "$SSD" set 1 esp on
parted -s "$SSD" mkpart "root" btrfs 512MiB 100%

# HDD partitioning
echo "Partitioning HDD ($HDD)..."
parted -s "$HDD" mklabel gpt
parted -s "$HDD" mkpart "data" btrfs 1MiB 100%

# Filesystem creation
echo "Creating filesystems..."
mkfs.fat -F32 "${SSD}1"
mkfs.btrfs -f "${SSD}2"
mkfs.btrfs -f "${HDD}1"

# SSD mounting
echo "Mounting partitions..."
mount "${SSD}2" /mnt
mkdir -p /mnt/boot
mount "${SSD}1" /mnt/boot

# Btrfs subvolumes creation for SSD
echo "Creating Btrfs subvolumes on SSD..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@swap

umount /mnt

# Mounting with subvolumes
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@ "${SSD}2" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,swap,boot}
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@home "${SSD}2" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@snapshots "${SSD}2" /mnt/.snapshots
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@var_log "${SSD}2" /mnt/var/log
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@swap "${SSD}2" /mnt/swap
mount "${SSD}1" /mnt/boot

# HDD mounting
mkdir -p /mnt/mnt/data
mount "${HDD}1" /mnt/mnt/data

# 4. Swap setup
echo "=== Swap setup ==="
SWAP_SIZE="8G"  # Swap size

# Swap file creation (safe method)
dd if=/dev/zero of=/mnt/swap/swapfile bs=1M count=$((8*1024)) status=progress
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# 5. Base system installation
echo "=== Base system installation ==="

# Mirror update
pacman -Sy --noconfirm reflector
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Package installation
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs nano reflector

# 6. System configuration
echo "=== System configuration ==="

# Fstab generation
genfstab -U /mnt >> /mnt/etc/fstab

# Adding swap to fstab
echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# Chroot into installed system
arch-chroot /mnt /bin/bash <<EOF

# Timezone and time setup
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Localization
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Network configuration
echo "arch-pc" > /etc/hostname

# Password setup (temporary, should be changed after installation)
echo "root:qwerty222" | chpasswd
useradd -m -G wheel -s /bin/bash vkrupenich
echo "vkrupenich:qwerty123" | chpasswd

# Sudo configuration
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# 7. Bootloader installation
echo "=== GRUB installation ==="
pacman -S --noconfirm grub efibootmgr amd-ucode intel-ucode
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 8. Graphical environment installation (Sway)
echo "=== Sway installation ==="
pacman -S --noconfirm --needed \
    sway waybar alacritty wofi light dunst grim slurp wl-clipboard swaybg swayidle swaylock \
    swayidle xorg-server-xwayland qt5-wayland glfw-wayland \
    noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation \
    pipewire pipewire-pulse wireplumber \
    networkmanager iwd

# Sway autostart for user
sudo -u vkrupenich mkdir -p /home/vkrupenich/.config/sway
sudo -u vkrupenich cat > /home/vkrupenich/.config/sway/config <<SWAYCONF
# Main Sway configuration
input * {
    xkb_layout "us,ru"
    xkb_options "grp:win_space_toggle"
	xkb_numlock enabled
	repeat_delay 250
	repeat_rate 20
}

bindsym Mod4+d exec wofi
bindsym Mod4+q kill
bindsym Mod4+r reload

# Pulse Audio controls
#bindsym XF86AudioRaiseVolume exec pactl set-sink-volume \$(pacmd list-sinks |awk '/* index:/{print \$3}') +5%
#bindsym XF86AudioLowerVolume exec pactl set-sink-volume \$(pacmd list-sinks |awk '/* index:/{print \$3}') -5%
#bindsym XF86AudioMute exec pactl set-sink-mute \$(pacmd list-sinks |awk '/* index:/{print \$3}') toggle

# Window specifics
#for_window [title="feh"] floating enable
#for_window [title="feh"] resize set 600 400

output * {
    bg ~/.config/sway/wallpaper.png fill
}

exec waybar
exec alacritty
SWAYCONF

# Default wallpaper setup
sudo -u vkrupenich curl -sLo /home/vkrupenich/.config/sway/wallpaper.png https://www.reddit.com/media?url=https%3A%2F%2Fi.redd.it%2Fglq653otf1na1.png

# Permissions setup
chown -R vkrupenich:vkrupenich /home/vkrupenich/.config

# Adding Sway autostart
sudo -u vkrupenich echo "if [ -z \$DISPLAY ] && [ \$(tty) = /dev/tty1 ]; then" >> /home/vkrupenich/.bash_profile
sudo -u vkrupenich echo "  exec sway" >> /home/vkrupenich/.bash_profile
sudo -u vkrupenich echo "fi" >> /home/vkrupenich/.bash_profile

# 9. NetworkManager setup
echo "=== NetworkManager configuration ==="
systemctl enable NetworkManager
systemctl enable iwd

# 10. Virtualization tools and Docker installation
echo "=== Virtualization tools installation ==="
pacman -S --noconfirm --needed qemu libvirt virt-manager docker docker-compose

systemctl enable libvirtd
systemctl enable virtlogd.socket
systemctl enable docker.socket

usermod -aG libvirt,kvm,docker vkrupenich

# Docker configuration for Btrfs
mkdir -p /etc/docker
echo '{"storage-driver": "btrfs"}' > /etc/docker/daemon.json

# 11. Additional utilities installation
echo "=== Additional packages installation ==="
pacman -S --noconfirm --needed \
    git curl wget rsync openssh \
    man-db man-pages texinfo \
    htop neofetch ncdu \
    firefox

# 12. Audio setup
echo "=== Audio configuration ==="
systemctl enable --now pipewire pipewire-pulse wireplumber

EOF

# Installation completion
echo "=== Installation completion ==="
umount -R /mnt
swapoff /mnt/swap/swapfile

# Copying logs to new system (if needed)
mkdir -p /mnt/var/log/install
cp /root/arch_install.log /mnt/var/log/install/

echo "Arch Linux installation completed successfully!"
echo "1. Reboot the system"
echo "2. Log in as vkrupenich"
echo "3. Immediately change passwords with 'passwd' for root and 'passwd vkrupenich'"
echo "4. Configure NetworkManager: 'nmtui'"
date