#!/bin/bash

# Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен с правами root" 
   exit 1
fi

# Настройки
USERNAME="penich"
USER_PASSWORD="Qwerty123"
ROOT_PASSWORD="qwerty222"
TIMEZONE="Europe/Moscow"
LOCALE="en_US.UTF-8"
KEYMAP="us"
HOSTNAME="arch-hyperv"
SWAY_PACKAGES="sway waybar wofi alacritty brightnessctl grim slurp wl-clipboard"
BASE_PACKAGES="base base-devel linux linux-firmware networkmanager nano man-db man-pages texinfo grub efibootmgr dosfstools os-prober mtools"

# Разметка диска (предполагается /dev/sda)
parted --script /dev/sda mklabel gpt
parted --script /dev/sda mkpart primary fat32 1MiB 513MiB
parted --script /dev/sda set 1 esp on
parted --script /dev/sda mkpart primary ext4 513MiB 100%

# Форматирование разделов
mkfs.fat -F32 /dev/sda1
mkfs.ext4 /dev/sda2

# Монтирование разделов
mount /dev/sda2 /mnt
mkdir -p /mnt/boot/efi
mount /dev/sda1 /mnt/boot/efi

# Установка базовой системы
pacstrap /mnt $BASE_PACKAGES

# Генерация fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot и настройка системы
arch-chroot /mnt /bin/bash <<EOF
    # Установка времени
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    hwclock --systohc

    # Настройка локали
    sed -i "s/#$LOCALE/$LOCALE/" /etc/locale.gen
    locale-gen
    echo "LANG=$LOCALE" > /etc/locale.conf
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

    # Настройка сети
    echo "$HOSTNAME" > /etc/hostname
    systemctl enable NetworkManager

    # Пароль root
    echo "root:$ROOT_PASSWORD" | chpasswd

    # Создание пользователя
    useradd -m -G wheel -s /bin/bash $USERNAME
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    # Установка графического окружения
    pacman -S --noconfirm $SWAY_PACKAGES xorg-xwayland

    # Настройка автозапуска Sway при входе пользователя
    echo 'if [ -z \$DISPLAY ] && [ "\$(tty)" = "/dev/tty1" ]; then' >> /home/$USERNAME/.bash_profile
    echo '  exec sway > ~/.sway.log 2>&1' >> /home/$USERNAME/.bash_profile
    echo 'fi' >> /home/$USERNAME/.bash_profile
    chown $USERNAME:$USERNAME /home/$USERNAME/.bash_profile

    # Базовая конфигурация Sway
    mkdir -p /home/$USERNAME/.config/sway
    cat > /home/$USERNAME/.config/sway/config <<EOL
# Основные настройки
set \$mod Mod4
bindsym \$mod+Return exec alacritty
bindsym \$mod+d exec wofi --show drun
bindsym \$mod+Shift+q kill

# Окна
floating_modifier \$mod normal
default_border pixel 2
gaps inner 10

# Статус бар
bar {
    position top
    status_command while date +'%Y-%m-%d %H:%M:%S'; do sleep 1; done
}
EOL
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

    # Установка GRUB
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg

    # Дополнительные настройки для Hyper-V
    echo "Добавляем драйвера Hyper-V в initramfs"
    sed -i 's/^MODULES=()/MODULES=(hv_vmbus hv_storvsc hv_netvsc hv_balloon hv_utils)/' /etc/mkinitcpio.conf
    mkinitcpio -P
EOF

# Завершение
umount -R /mnt
echo "Установка завершена! Вы можете перезагрузить систему."