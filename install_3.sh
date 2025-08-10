#!/bin/bash

exec > >(tee -a /root/arch_install.log) 2>&1

# 1. Disk identification and checks
echo "=== Disk identification and checks==="
SSD=$(lsblk -o PATH,MODEL | grep -i 'ssd' | awk '{print $1}' | head -n1)
HDD=$(lsblk -o PATH,MODEL | grep -i 'tosh' | awk '{print $1}' | head -n1)
[ -z "$SSD" ] && SSD="/dev/sda"  # fallback
[ -z "$HDD" ] && HDD="/dev/sdb"  # fallback

[ "$(id -u)" -ne 0 ] && { echo -e "[ERROR] Root privileges required"; exit 1; }
ping -c 2 archlinux.org || { echo -e "[ERROR] No internet connection"; exit 1; }

if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "[ERROR] System not booted in UEFI mode"
    exit 1
fi

if [ ! -e "$SSD" ]; then
    echo -e "[ERROR] SSD $SSD not found"
    exit 1
fi

if [ ! -e "$HDD" ]; then
    echo -e "[ERROR] HDD $HDD not found"
    exit 1
fi

echo "[WARNING] This script will erase all data on $SSD and $HDD!"
read -p "Continue? (y/N): " confirm
if [ "$confirm" != "y" ]; then
    echo "[INFO] Installation canceled"
    exit 1
fi

# 2. Disk setup
echo "=== Disk setup ==="
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
parted -s "$HDD" mkpart "hdd" btrfs 1MiB 100%

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
mkdir -p /mnt/{home,.snapshots,var/log,boot,mnt/hdd,swap}
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@home "${SSD}2" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@snapshots "${SSD}2" /mnt/.snapshots
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@var_log "${SSD}2" /mnt/var/log
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@swap "${SSD}2" /mnt/swap
mount "${SSD}1" /mnt/boot

# HDD mounting
mount "${HDD}1" /mnt/mnt/hdd

# 3. Swap setup
echo "=== Swap setup ==="
SWAP_SIZE="8G"
dd if=/dev/zero of=/mnt/swap/swapfile bs=1M count=$((8*1024)) status=progress
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# 4. Base system installation
echo "=== Base system installation ==="
pacman -Sy --noconfirm reflector
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs nano reflector

# 5. System configuration
echo "=== System configuration ==="
genfstab -U /mnt >> /mnt/etc/fstab
echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/Europe/Samara /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "arch" > /etc/hostname

echo "root:qwerty222" | chpasswd
useradd -m -G wheel -s /bin/bash vkrupenich
echo "vkrupenich:qwerty123" | chpasswd
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# 6. Bootloader installation
echo "=== GRUB installation ==="
pacman -S --noconfirm grub efibootmgr amd-ucode intel-ucode
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 7. Graphical environment installation
echo "=== WM installation ==="
pacman -S --noconfirm --needed alacritty xterm rofi firefox thunar feh picom
pacman -S --noconfirm --needed xorg-server xorg-xinit awesome lightdm lightdm-gtk-greeter xorg-xkbcomp xorg-setxkbmap
systemctl enable lightdm

echo "=== Install fonts... ==="
pacman -S --noconfirm --needed noto-fonts noto-fonts-cjk ttf-dejavu ttf-liberation

echo "=== Install NetworkManager... ==="
pacman -S --noconfirm --needed networkmanager iwd
systemctl enable NetworkManager
systemctl enable iwd

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<XKB_EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,ru"
    Option "XkbModel" "pc105"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
XKB_EOF

cat > /home/vkrupenich/.xinitrc <<XINIT_EOF
#!/bin/sh
setxkbmap -layout us,ru -option grp:alt_shift_toggle
exec awesome
XINIT_EOF

chown vkrupenich:vkrupenich /home/vkrupenich/.xinitrc
chmod +x /home/vkrupenich/.xinitrc

# Awesome autostart for user
sudo -u vkrupenich mkdir -p /home/vkrupenich/.config/awesome
cat > /home/vkrupenich/.config/awesome/rc.lua <<AWESOME_EOF
-- Base awesome config
awful = require("awful")
require("awful.autofocus")

-- Set wallpaper
--local wallpaper = "/usr/share/backgrounds/archlinux/arch-wallpaper.jpg"
--if awful.util.file_readable(wallpaper) then
--    gears.wallpaper.maximized(wallpaper, nil, true)
--end

-- Default modkey
modkey = "Mod4"

-- Key bindings
globalkeys = awful.util.table.join(
    awful.key({ modkey }, "Return", function () awful.util.spawn("terminal") end),
    -- Alt+Shift for keyboard layout switching
    awful.key({ "Mod1", "Shift" }, "Shift_L", function () 
        awful.util.spawn("setxkbmap -toggle") 
    end)
)

root.keys(globalkeys)
AWESOME_EOF

chown -R vkrupenich:vkrupenich /home/vkrupenich/.config

# 8. Virtualization tools and Docker installation
echo "=== Virtualization tools installation ==="
pacman -S --noconfirm --needed qemu libvirt virt-manager docker docker-compose

systemctl enable libvirtd
systemctl enable virtlogd.socket
systemctl enable docker.socket

usermod -aG libvirt,kvm,docker vkrupenich

# Docker configuration for Btrfs
mkdir -p /etc/docker
echo '{"storage-driver": "btrfs"}' > /etc/docker/daemon.json

# 9. Additional utilities installation
echo "=== Additional packages installation ==="
pacman -S --noconfirm --needed git curl wget rsync openssh man-db man-pages texinfo htop ncdu

# 10. Audio setup
echo "=== Audio configuration ==="
systemctl enable --now pipewire pipewire-pulse wireplumber

EOF

# Installation completion
echo "=== Installation completion ==="
umount -R /mnt
swapoff /mnt/swap/swapfile

echo "Coping log file..."
mkdir -p /mnt/var/log/install
cp /root/arch_install.log /mnt/var/log/install/

echo "Arch Linux installation completed"
echo "1. Reboot the system"
echo "2. Log in as vkrupenich"
echo "3. Change passwords with 'passwd' for root and 'passwd vkrupenich'"
date
