#!/bin/bash

# =========================================
# Arch Linux Minimal Installation (BIOS/Legacy)
# Features:
# - Поддержка Legacy BIOS (для виртуальных машин)
# - Автоматический запуск Sway
# - Оптимизировано для виртуальных машин
# =========================================

# Конфигурация
TARGET_DISK="/dev/sda"
SWAP_SIZE="2G"  # Уменьшенный swap для VM
USERNAME="penich"
TIMEZONE="Europe/Moscow"
VM_GRAPHICS="virtio"  # или "vbox" для VirtualBox

# =========================================
# 1. ПРЕДУСТАНОВОЧНЫЕ ПРОВЕРКИ
# =========================================

[ -b "$TARGET_DISK" ] || { echo "[ОШИБКА] Диск $TARGET_DISK не найден!"; exit 1; }

echo "========================================"
echo "ВНИМАНИЕ: Все данные на $TARGET_DISK будут удалены!"
echo "========================================"
read -p "Продолжить? (y/N) " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 1

# Проверка сети
ping -c 3 archlinux.org || { echo "[ОШИБКА] Нет интернета"; exit 1; }

timedatectl set-ntp true || { echo "[ОШИБКА] Ошибка синхронизации времени"; exit 1; }

# =========================================
# 2. НАСТРОЙКА ДИСКА (BIOS/MBR)
# =========================================

# Разметка диска (MBR для BIOS)
echo "Создание разделов для Legacy BIOS..."
parted -s "$TARGET_DISK" mklabel msdos || exit 1
parted -s "$TARGET_DISK" mkpart primary linux-swap 1MiB "${SWAP_SIZE}MiB" || exit 1
parted -s "$TARGET_DISK" mkpart primary btrfs "${SWAP_SIZE}MiB" 100% || exit 1
parted -s "$TARGET_DISK" set 2 boot on || exit 1  # Флаг boot для root раздела

# Форматирование
echo "Форматирование разделов..."
mkswap "${TARGET_DISK}1" || exit 1
mkfs.btrfs -f "${TARGET_DISK}2" || exit 1
swapon "${TARGET_DISK}1" || exit 1

# Подтома Btrfs
echo "Создание подтомов Btrfs..."
mount "${TARGET_DISK}2" /mnt || exit 1
btrfs subvolume create /mnt/@ || exit 1
btrfs subvolume create /mnt/@home || exit 1
umount /mnt || exit 1

mount -o noatime,compress=zstd,space_cache=v2,subvol=@ "${TARGET_DISK}2" /mnt || exit 1
mkdir -p /mnt/home || exit 1
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "${TARGET_DISK}2" /mnt/home || exit 1

# =========================================
# 3. УСТАНОВКА СИСТЕМЫ
# =========================================

echo "Установка базовой системы..."
pacstrap /mnt base linux linux-firmware || exit 1
genfstab -U /mnt >> /mnt/etc/fstab || exit 1

# =========================================
# 4. НАСТРОЙКА В CHROOT
# =========================================

arch-chroot /mnt /bin/bash <<EOF
# Локализация и время
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "archlinux" > /etc/hostname

# Загрузчик (GRUB для BIOS)
pacman -S --noconfirm grub || exit 1
grub-install --target=i386-pc "$TARGET_DISK" || exit 1
grub-mkconfig -o /boot/grub/grub.cfg || exit 1

# Сеть
systemctl enable NetworkManager

# Графическое окружение (оптимизировано для VM)
if [ "$VM_GRAPHICS" = "virtio" ]; then
    pacman -S --noconfirm \
        xorg-xwayland sway waybar foot \
        qemu-guest-agent virtio-video \
        xf86-video-qxl xf86-video-vesa || exit 1
    systemctl enable qemu-guest-agent
else  # VirtualBox
    pacman -S --noconfirm \
        xorg-xwayland sway waybar foot \
        virtualbox-guest-utils || exit 1
    systemctl enable vboxservice
fi

# Драйверы ввода для VM
pacman -S --noconfirm xf86-input-libinput || exit 1

# Создание пользователя
useradd -m -G wheel -s /bin/bash $USERNAME || exit 1
echo "Установка пароля для $USERNAME:"
while ! passwd $USERNAME; do echo "Попробуйте снова"; done

echo "Установка пароля root:"
while ! passwd; do echo "Попробуйте снова"; done

# Настройки sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Автологин в virtual console
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOL
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --noclear %I \$TERM
EOL

# Автозапуск Sway
cat > /home/$USERNAME/.bash_profile <<EOL
if [[ -z \$WAYLAND_DISPLAY ]] && [[ \$(tty) = /dev/tty1 ]]; then
    exec sway
fi
EOL

# Базовая конфигурация Sway
mkdir -p /home/$USERNAME/.config/sway
cat > /home/$USERNAME/.config/sway/config <<EOL
# Основные настройки
set \$mod Mod4
bindsym \$mod+Return exec foot
bindsym \$mod+Shift+q kill

# Панель Waybar
bar {
    position top
    status_command waybar
}

# Оптимизации для VM
output * {
    mode 1366x768@60Hz
    bg ~/wallpaper.png fill
}
EOL

# Установка обоев
curl -o /home/$USERNAME/wallpaper.png https://archlinux.org/wallpaper/ || exit 1
chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF

# =========================================
# 5. ЗАВЕРШЕНИЕ УСТАНОВКИ
# =========================================

echo "Установка завершена!"
echo "Пользователь: $USERNAME"
echo "Пароль: установлен вами во время установки"
echo "Графическое окружение будет автоматически запускаться"
echo "Для перезагрузки выполните:"
echo "umount -R /mnt && reboot"