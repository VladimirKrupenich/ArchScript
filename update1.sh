#!/bin/bash
set -euo pipefail

### Checks ###
[ "$(id -u)" -ne 0 ] && { echo -e "\033[1;31mRoot privileges required\033[0m"; exit 1; }
ping -c 1 archlinux.org &>/dev/null || { echo -e "\033[1;31mNo internet connection\033[0m"; exit 1; }
timedatectl set-ntp true

### Disk Detection ###
echo -e "\033[1;34mDetecting disks:\033[0m"
lsblk -o NAME,SIZE,TYPE,MODEL
SSD=$(lsblk -dn -o NAME,ROTA | awk '$2==0 {print $1}' | head -1)
[ -z "$SSD" ] && SSD="/dev/sda"
HDD=$(lsblk -dn -o NAME,ROTA | awk '$2==1 {print $1}' | head -1)
[ -z "$HDD" ] && { echo -e "\033[1;33mHDD not found, using SSD only\033[0m"; }

echo -e "\n\033[1;32mDisk configuration:\033[0m"
echo "SSD: ${SSD} (system disk)"
[ -n "$HDD" ] && echo "HDD: ${HDD} (additional storage)"

### SSD Partitioning (BIOS/MBR) ###
echo -e "\n\033[1;34mPartitioning SSD (${SSD})\033[0m"
parted -s "/dev/${SSD}" mklabel msdos
parted -s "/dev/${SSD}" mkpart primary ext4 1MiB 513MiB
parted -s "/dev/${SSD}" set 1 boot on
parted -s "/dev/${SSD}" mkpart primary 513MiB 100%

### SSD Filesystem ###
echo -e "\n\033[1;34mCreating filesystems\033[0m"
mkfs.ext4 -F "/dev/${SSD}1"
mkfs.btrfs -f -L ARCH "/dev/${SSD}2"
mount "/dev/${SSD}2" /mnt

# Creating subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
umount /mnt

# Mounting SSD
mount -o noatime,compress=zstd,space_cache=v2,subvol=@ "/dev/${SSD}2" /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount "/dev/${SSD}1" /mnt/boot
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "/dev/${SSD}2" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,subvol=@snapshots "/dev/${SSD}2" /mnt/.snapshots
mount -o noatime,compress=zstd,space_cache=v2,subvol=@var_log "/dev/${SSD}2" /mnt/var/log

### HDD Partitioning (if present) ###
if [ -n "$HDD" ]; then
    echo -e "\n\033[1;34mConfiguring HDD (${HDD})\033[0m"
    parted -s "/dev/${HDD}" mklabel msdos
    parted -s "/dev/${HDD}" mkpart primary 1MiB 100%
    mkfs.btrfs -f -L DATA "/dev/${HDD}1"
    mkdir -p /mnt/mnt/data
    echo -e "\n# HDD partition" >> /mnt/etc/fstab
    echo "UUID=$(blkid -s UUID -o value "/dev/${HDD}1") /mnt/data btrfs rw,noatime,compress=zstd,space_cache=v2 0 0" >> /mnt/etc/fstab
fi

### System Installation ###
echo -e "\n\033[1;34mInstalling base system\033[0m"
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs
genfstab -U /mnt >> /mnt/etc/fstab

# Btrfs optimizations
{
    echo -e "\n# Btrfs optimizations"
    echo "/dev/${SSD}2 / btrfs rw,noatime,compress=zstd,space_cache=v2,subvol=@ 0 0"
    echo "/dev/${SSD}2 /home btrfs rw,noatime,compress=zstd,space_cache=v2,subvol=@home 0 0"
    echo "/dev/${SSD}2 /.snapshots btrfs rw,noatime,compress=zstd,space_cache=v2,subvol=@snapshots 0 0"
    echo "/dev/${SSD}2 /var/log btrfs rw,noatime,compress=zstd,space_cache=v2,subvol=@var_log 0 0"
    echo "/dev/${SSD}1 /boot ext4 rw,relatime 0 2"
} >> /mnt/etc/fstab

### System Configuration ###
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

### Basic Configuration ###
echo -e "\033[1;34mConfiguring localization and time\033[0m"
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc
sed -i '/^#en_US.UTF-8/s/^#//' /etc/locale.gen
sed -i '/^#ru_RU.UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "arch" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1    localhost
::1          localhost
127.0.1.1    arch.localdomain    arch
HOSTS

### Kernel and Bootloader (BIOS) ###
echo -e "\033[1;34mConfiguring kernel and bootloader\033[0m"
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap modconf block btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

pacman -S --noconfirm grub
grub-install --target=i386-pc "/dev/${SSD}"
grub-mkconfig -o /boot/grub/grub.cfg

### User Setup ###
echo -e "\033[1;34mSetting up users\033[0m"
(
  echo "Setting root password:"
  until passwd; do
    echo "Please try again"
  done
)

useradd -m -G wheel -s /bin/bash user
(
  echo "Setting password for user 'user':"
  until passwd user; do
    echo "Please try again"
  done
)

echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

### Network ###
systemctl enable dhcpcd.service

### Graphical Environment ###
echo -e "\033[1;34mInstalling graphical environment\033[0m"
pacman -S --noconfirm xorg-server-xwayland sway waybar foot wofi light swaylock swayidle \
    grim slurp wl-clipboard noto-fonts noto-fonts-cjk noto-fonts-emoji \
    pipewire pipewire-alsa pipewire-pulse wireplumber

sudo -u user bash <<'USEREOF'
mkdir -p ~/.config/sway
cat > ~/.config/sway/config <<'SWAYCFG'
# Basic settings
input * {
    xkb_layout "us,ru"
    xkb_options "grp:win_space_toggle"
}
output * {
    bg ~/Pictures/wallpaper.jpg fill
}
set \$mod Mod4
set \$menu wofi --show drun
bindsym \$mod+Return exec foot
bindsym \$mod+d exec \$menu
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+e exec swaynag -t warning -m 'Exit Sway?' -b 'Yes' 'swaymsg exit'
bindsym \$mod+Shift+c reload
bindsym \$mod+Shift+x exec systemctl poweroff
bindsym \$mod+Shift+r exec systemctl reboot
exec systemctl --user import-environment
exec_always dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK
exec_always /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec_always swayidle -w timeout 300 'swaylock -f' timeout 600 'systemctl suspend'
SWAYCFG

mkdir -p ~/Pictures
echo "if [[ -z \$DISPLAY && \$(tty) == /dev/tty1 ]]; then exec sway; fi" >> ~/.bash_profile
USEREOF

### Virtualization ###
echo -e "\033[1;34mInstalling virtualization tools\033[0m"
pacman -S --noconfirm qemu-full libvirt virt-manager dnsmasq iptables-nft bridge-utils
systemctl enable --now libvirtd
usermod -aG libvirt,kvm user
virsh net-autostart default
virsh net-start default

### Containers ###
pacman -S --noconfirm docker docker-compose podman podman-dnsname slirp4netns
systemctl enable --now docker
usermod -aG docker user

cat > /etc/docker/daemon.json <<'DOCKERCONF'
{
  "bip": "172.17.0.1/16",
  "default-address-pools": [
    {"base": "172.18.0.0/16", "size": 24}
  ]
}
DOCKERCONF

echo "user:100000:65536" >> /etc/subuid
echo "user:100000:65536" >> /etc/subgid

### Additional Packages ###
echo -e "\033[1;34mInstalling additional packages\033[0m"
pacman -S --noconfirm firefox neovim git snapper
snapper --no-dbus -c root create-config /
snapper --no-dbus -c home create-config /home

### HDD Setup (if present) ###
if [ -n "${HDD}" ]; then
    mkdir -p /mnt/data
    chown user:user /mnt/data
fi
EOF

### Completion ###
umount -R /mnt
echo -e "\n\033[1;32mInstallation complete!\033[0m"
echo -e "\n\033[1;33mInstructions:\033[0m"
echo "1. System will boot in BIOS mode"
echo "2. Sway will start automatically after user 'user' logs in"
echo "3. Additional disks:"
[ -n "$HDD" ] && echo "   - HDD mounted at /mnt/data (accessible to user 'user')"
echo -e "\n\033[1;32mReboot the system with: reboot\033[0m"