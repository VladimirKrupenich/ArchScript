#!/bin/bash

# Скрипт установки Arch Linux с настройками для vkrupenich
# Логирование всей установки в файл /root/arch_install.log
exec > >(tee -a /root/arch_install.log) 2>&1

echo "=== Начало установки Arch Linux ==="
date

# 1. Определение дисков
echo "=== Определение дисков ==="
SSD=$(lsblk -o PATH,MODEL | grep -i 'ssd' | awk '{print $1}' | head -n1)
HDD=$(lsblk -o PATH,MODEL | grep -i 'sata' | awk '{print $1}' | head -n1)

[ -z "$SSD" ] && SSD="/dev/nvme0n1"  # fallback
[ -z "$HDD" ] && HDD="/dev/sda"       # fallback

# 2. Проверки перед установкой
echo "=== Проверка условий установки ==="

# Проверка подключения к интернету
if ! ping -c 3 archlinux.org &> /dev/null; then
    echo "Ошибка: Нет подключения к интернету!"
    exit 1
fi

# Проверка загрузки в UEFI режиме
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "Ошибка: Система не загружена в UEFI режиме!"
    exit 1
fi

# Проверка наличия дисков
if [ ! -e "$SSD" ]; then
    echo "Ошибка: SSD $SSD не найден!"
    exit 1
fi

if [ ! -e "$HDD" ]; then
    echo "Ошибка: HDD $HDD не найден!"
    exit 1
fi

# Проверка свободного места
if [ $(df --output=avail -BG / | tail -1 | tr -d 'G') -lt 10 ]; then
    echo "Ошибка: Недостаточно свободного места для установки!"
    exit 1
fi

# Предупреждение о стирании данных
echo "ВНИМАНИЕ: Этот скрипт сотрет все данные на $SSD и $HDD!"
read -p "Продолжить установку? (y/N): " confirm
if [ "$confirm" != "y" ]; then
    echo "Установка отменена."
    exit 1
fi

# 3. Настройка дисков
echo "=== Настройка дисков ==="

# Очистка дисков
wipefs -a "$SSD"
wipefs -a "$HDD"

# Разметка SSD
echo "Разметка SSD ($SSD)..."
parted -s "$SSD" mklabel gpt
parted -s "$SSD" mkpart "EFI" fat32 1MiB 512MiB
parted -s "$SSD" set 1 esp on
parted -s "$SSD" mkpart "root" btrfs 512MiB 100%

# Разметка HDD
echo "Разметка HDD ($HDD)..."
parted -s "$HDD" mklabel gpt
parted -s "$HDD" mkpart "data" btrfs 1MiB 100%

# Создание файловых систем
echo "Создание файловых систем..."
mkfs.fat -F32 "${SSD}1"
mkfs.btrfs -f "${SSD}2"
mkfs.btrfs -f "${HDD}1"

# Монтирование SSD
echo "Монтирование разделов..."
mount "${SSD}2" /mnt
mkdir -p /mnt/boot
mount "${SSD}1" /mnt/boot

# Создание подтомов Btrfs для SSD
echo "Создание подтомов Btrfs на SSD..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@swap

umount /mnt

# Монтирование с подтомами
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@ "${SSD}2" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,swap,boot}
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@home "${SSD}2" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@snapshots "${SSD}2" /mnt/.snapshots
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@var_log "${SSD}2" /mnt/var/log
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@swap "${SSD}2" /mnt/swap
mount "${SSD}1" /mnt/boot

# Монтирование HDD
mkdir -p /mnt/mnt/data
mount "${HDD}1" /mnt/mnt/data

# 4. Настройка swap
echo "=== Настройка swap ==="
SWAP_SIZE="8G"  # Размер swap

# Создание swap файла (безопасный метод)
dd if=/dev/zero of=/mnt/swap/swapfile bs=1M count=$((8*1024)) status=progress
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# 5. Установка базовой системы
echo "=== Установка базовой системы ==="

# Обновление зеркал
pacman -Sy --noconfirm reflector
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Установка пакетов
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs nano reflector

# 6. Настройка системы
echo "=== Настройка системы ==="

# Генерация fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Добавление swap в fstab
echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# Chroot в установленную систему
arch-chroot /mnt /bin/bash <<EOF

# Установка часового пояса и времени
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Локализация
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Настройка сети
echo "arch-pc" > /etc/hostname

# Настройка паролей (временные, должны быть изменены после установки)
echo "root:qwerty222" | chpasswd
useradd -m -G wheel -s /bin/bash vkrupenich
echo "vkrupenich:qwerty123" | chpasswd

# Настройка sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# 7. Установка загрузчика
echo "=== Установка GRUB ==="
pacman -S --noconfirm grub efibootmgr amd-ucode intel-ucode
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 8. Установка графической среды (Sway)
echo "=== Установка Sway ==="
pacman -S --noconfirm --needed \
    sway waybar foot wofi light dunst grim slurp wl-clipboard swaybg swayidle swaylock \
    xorg-server-xwayland qt5-wayland glfw-wayland \
    noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation \
    pipewire pipewire-pulse wireplumber \
    networkmanager iwd

# Автозапуск Sway для пользователя
sudo -u vkrupenich mkdir -p /home/vkrupenich/.config/sway
sudo -u vkrupenich cat > /home/vkrupenich/.config/sway/config <<SWAYCONF
# Основная конфигурация Sway
input * {
    xkb_layout "us,ru"
    xkb_options "grp:win_space_toggle"
}

output * {
    bg ~/.config/sway/wallpaper.png fill
}

exec waybar
exec foot
SWAYCONF

# Установка обоев по умолчанию
sudo -u vkrupenich curl -sLo /home/vkrupenich/.config/sway/wallpaper.png https://raw.githubusercontent.com/swaywm/sway/master/contrib/wallpapers/violet-mountain.png

# Настройка прав
chown -R vkrupenich:vkrupenich /home/vkrupenich/.config

# Добавление автозапуска Sway
sudo -u vkrupenich echo "if [ -z \$DISPLAY ] && [ \$(tty) = /dev/tty1 ]; then" >> /home/vkrupenich/.bash_profile
sudo -u vkrupenich echo "  exec sway" >> /home/vkrupenich/.bash_profile
sudo -u vkrupenich echo "fi" >> /home/vkrupenich/.bash_profile

# 9. Установка NetworkManager
echo "=== Настройка NetworkManager ==="
systemctl enable NetworkManager
systemctl enable iwd

# 10. Установка средств виртуализации и Docker
echo "=== Установка инструментов виртуализации ==="
pacman -S --noconfirm --needed qemu libvirt virt-manager docker docker-compose

systemctl enable libvirtd
systemctl enable virtlogd.socket
systemctl enable docker.socket

usermod -aG libvirt,kvm,docker vkrupenich

# Настройка Docker для использования Btrfs
mkdir -p /etc/docker
echo '{"storage-driver": "btrfs"}' > /etc/docker/daemon.json

# 11. Установка дополнительных утилит
echo "=== Установка дополнительных пакетов ==="
pacman -S --noconfirm --needed \
    git curl wget rsync openssh \
    man-db man-pages texinfo \
    htop neofetch ncdu \
    firefox

# 12. Настройка звука
echo "=== Настройка звука ==="
systemctl enable --now pipewire pipewire-pulse wireplumber

EOF

# Завершение установки
echo "=== Завершение установки ==="
umount -R /mnt
swapoff /mnt/swap/swapfile

# Копирование логов в новую систему (если нужно)
mkdir -p /mnt/var/log/install
cp /root/arch_install.log /mnt/var/log/install/

echo "Установка Arch Linux завершена успешно!"
echo "Пожалуйста:"
echo "1. Перезагрузите систему"
echo "2. Войдите под пользователем vkrupenich"
echo "3. Сразу смените пароли командой 'passwd' для root и 'passwd vkrupenich'"
echo "4. Настройте NetworkManager: 'nmtui'"
date