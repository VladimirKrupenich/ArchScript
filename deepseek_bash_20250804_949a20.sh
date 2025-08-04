#!/bin/bash
set -euo pipefail

### Проверки ###
[ "$(id -u)" -ne 0 ] && { echo -e "\033[1;31mТребуются права root\033[0m"; exit 1; }
ping -c 1 archlinux.org &>/dev/null || { echo -e "\033[1;31mНет подключения к интернету\033[0m"; exit 1; }
timedatectl set-ntp true

### Определение дисков ###
echo -e "\033[1;34mОбнаружение дисков:\033[0m"
lsblk -o NAME,SIZE,TYPE,MODEL
SSD=$(lsblk -dn -o NAME,ROTA | awk '$2==0 {print $1}' | head -1)
[ -z "$SSD" ] && SSD="/dev/sda"
HDD=$(lsblk -dn -o NAME,ROTA | awk '$2==1 {print $1}' | head -1)
[ -z "$HDD" ] && { echo -e "\033[1;33mHDD не найден, будет использован только SSD\033[0m"; }

echo -e "\n\033[1;32mКонфигурация дисков:\033[0m"
echo "SSD: ${SSD} (системный диск)"
[ -n "$HDD" ] && echo "HDD: ${HDD} (дополнительное хранилище)"

### Разметка SSD ###
echo -e "\n\033[1;34mРазметка SSD (${SSD})\033[0m"
parted -s "/dev/${SSD}" mklabel gpt
parted -s "/dev/${SSD}" mkpart primary fat32 1MiB 513MiB
parted -s "/dev/${SSD}" set 1 esp on
parted -s "/dev/${SSD}" mkpart primary 513MiB 100%

### Шифрование SSD ###
echo -e "\n\033[1;34mШифрование системного раздела\033[0m"
cryptsetup luksFormat -y -v "/dev/${SSD}p2"
cryptsetup open "/dev/${SSD}p2" cryptroot

### Файловая система на SSD ###
echo -e "\n\033[1;34mСоздание файловой системы Btrfs\033[0m"
mkfs.btrfs -f -L ARCH /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

# Создание подтомов
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
umount /mnt

# Монтирование SSD
mount -o noatime,compress=zstd,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot/efi,home,.snapshots,var/log}
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o noatime,compress=zstd,space_cache=v2,subvol=@var_log /dev/mapper/cryptroot /mnt/var/log
mkfs.fat -F32 -n EFI "/dev/${SSD}p1"
mount "/dev/${SSD}p1" /mnt/boot/efi

### Разметка HDD (если есть) ###
if [ -n "$HDD" ]; then
    echo -e "\n\033[1;34mНастройка HDD (${HDD})\033[0m"
    parted -s "/dev/${HDD}" mklabel gpt
    parted -s "/dev/${HDD}" mkpart primary 1MiB 100%
    mkfs.btrfs -f -L DATA "/dev/${HDD}p1"
    mkdir -p /mnt/mnt/data
    echo -e "\n# HDD раздел" >> /mnt/etc/fstab
    echo "UUID=$(blkid -s UUID -o value "/dev/${HDD}p1") /mnt/data btrfs rw,noatime,compress=zstd,space_cache=v2 0 0" >> /mnt/etc/fstab
fi

### Установка системы ###
echo -e "\n\033[1;34mУстановка базовой системы\033[0m"
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs cryptsetup lvm2
genfstab -U /mnt >> /mnt/etc/fstab

# Добавляем параметры для зашифрованного раздела
{
    echo -e "\n# Зашифрованный раздел"
    echo "/dev/${SSD}p2 /dev/mapper/cryptroot none luks,discard"
    echo -e "\n# Оптимизации Btrfs"
    echo "/dev/mapper/cryptroot / btrfs rw,noatime,compress=zstd,space_cache=v2,subvol=@ 0 0"
    echo "/dev/mapper/cryptroot /home btrfs rw,noatime,compress=zstd,space_cache=v2,subvol=@home 0 0"
    echo "/dev/mapper/cryptroot /.snapshots btrfs rw,noatime,compress=zstd,space_cache=v2,subvol=@snapshots 0 0"
    echo "/dev/mapper/cryptroot /var/log btrfs rw,noatime,compress=zstd,space_cache=v2,subvol=@var_log 0 0"
} >> /mnt/etc/fstab

### Настройка системы ###
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

### Базовая настройка ###
echo -e "\033[1;34mНастройка локализации и времени\033[0m"
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

### Ядро и загрузчик ###
echo -e "\033[1;34mНастройка ядра и загрузчика\033[0m"
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap modconf block encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

pacman -S --noconfirm grub efibootmgr
grub_cmd="GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$(blkid -s UUID -o value /dev/${SSD}p2):cryptroot root=/dev/mapper/cryptroot\""
echo "$grub_cmd" >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

### Пользователи ###
echo -e "\033[1;34mНастройка пользователей\033[0m"
echo "Установка пароля root:"
passwd
useradd -m -G wheel -s /bin/bash user
echo "Установка пароля user:"
passwd user
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

### Сеть ###
systemctl enable dhcpcd.service

### Графическое окружение ###
echo -e "\033[1;34mУстановка графического окружения\033[0m"
pacman -S --noconfirm xorg-server-xwayland sway waybar foot wofi light swaylock swayidle \
    grim slurp wl-clipboard noto-fonts noto-fonts-cjk noto-fonts-emoji \
    pipewire pipewire-alsa pipewire-pulse wireplumber

sudo -u user bash <<'USEREOF'
mkdir -p ~/.config/sway
cat > ~/.config/sway/config <<'SWAYCFG'
# Основные настройки
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

### Виртуализация ###
echo -e "\033[1;34mУстановка инструментов виртуализации\033[0m"
pacman -S --noconfirm qemu-full libvirt virt-manager dnsmasq iptables-nft edk2-ovmf bridge-utils
systemctl enable --now libvirtd
usermod -aG libvirt,kvm user
virsh net-autostart default
virsh net-start default

### Контейнеры ###
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

### Дополнительные пакеты ###
echo -e "\033[1;34mУстановка дополнительных пакетов\033[0m"
pacman -S --noconfirm firefox neovim git snapper
snapper --no-dbus -c root create-config /
snapper --no-dbus -c home create-config /home

### Настройка HDD (если есть) ###
if [ -n "${HDD}" ]; then
    mkdir -p /mnt/data
    chown user:user /mnt/data
fi
EOF

### Завершение ###
umount -R /mnt
cryptsetup close cryptroot
echo -e "\n\033[1;32mУстановка завершена!\033[0m"
echo -e "\n\033[1;33mИнструкции:\033[0m"
echo "1. При загрузке будет запрашиваться пароль для расшифровки SSD"
echo "2. После входа пользователя 'user' автоматически запустится Sway"
echo "3. Дополнительные диски:"
[ -n "$HDD" ] && echo "   - HDD смонтирован в /mnt/data (доступен для пользователя 'user')"
echo -e "\n\033[1;32mПерезагрузите систему командой: reboot\033[0m"