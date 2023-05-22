#!/bin/bash
# Artix Linux Install Script

# CONFIG
# --------------------------------------------------------------------
drive=/dev/sda
boot=${drive}1
swap=${drive}2
root=${drive}3
home=${drive}4

boot_size=300M
root_size=50G

user=blake
user_groups=wheel,video,audio
locale=en_GB
timezone=Europe/London
hostname=artix

# FUNCTIONS
# --------------------------------------------------------------------
confirm(){
    local input=""
    while true; do
        read -p "$1 (y/n): " -r input
        case $input in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "Wrong input! Press to continue..."; read -rn 1 ;;
        esac
    done
}

ram(){
    ram_kB=$(awk 'FNR==1 {print $2}' /proc/meminfo)
    ram_gb=$(bc <<< "${ram_kB} / 1000^2")
    [ "${ram_gb}" -lt 1 ] && { echo "ERR: not enough ram"; return 1; }
    echo "${ram_gb}"
}

arch_support(){
    # download Arch mirrorlist
    url="https://github.com/archlinux/svntogit-packages\
/raw/packages/pacman-mirrorlist/trunk/mirrorlist"
    curl -L ${url} -o /mnt/etc/pacman.d/mirrorlist-arch

    # Uncomment local servers in Arch mirrorlist
    pacman --needed -S vim
    vim -s <(printf "/United Kingdom\nvip:s/^#//g\n:wq\n") \
        /mnt/etc/pacman.d/mirrorlist-arch

    # add mirror list & universe db to pacman
    echo "
# Arch
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[community]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch

[universe]
Server = https://universe.artixlinux.org/\$arch
Server = https://mirror1.artixlinux.org/universe/\$arch
Server = https://mirror.pascalpuffke.de/artix-universe/\$arch
Server = https://mirrors.qontinuum.space/artixlinux-universe/\$arch
Server = https://mirror1.cl.netactuate.com/artix/universe/\$arch
Server = https://ftp.crifo.org/artix-universe/\$arch
Server = https://artix.sakamoto.pl/universe/\$arch
" >> /mnt/etc/pacman.conf

    artix-chroot /mnt bash -c \
                 "pacman --noconfirm -Syy artix-archlinux-support"
}

# INSTALLATION
# --------------------------------------------------------------------
swapoff -a &> /dev/null
umount -R /mnt &> /dev/null
set -xe

# check online
ping -c 3 artixlinux.org > /dev/null \
    || { echo "ERR: no internet connection found"; exit; }

# ensure required packages
pacman --needed --noconfirm -Sy bc vim

# confirm before installing
[[ -z $swap_size ]] && swap_size="$(bc <<< "sqrt($(ram)) * 4")G"

echo \
    "Drive: ${drive}
    BOOT Partition: ${boot}, Size: ${boot_size}
    SWAP Partition: ${swap}, Size: ${swap_size}
    ROOT Partition: ${root}, Size: ${root_size}
    HOME Partition: ${home}"

echo "!!! CAUTION: all data from ${drive} will be erased !!!"
confirm "Are you sure you want to continue?" || exit

wipefs -a "${drive}"

# partition drive
boot_type=L
[ -d /sys/firmware/efi/efivars/ ] && boot_type=U
printf ",%s,%s\n,%s,S\n,%s,L\n,+,H\n" \
        "${boot_size}" "${boot_type}" "${swap_size}" "${root_size}" \
        | sfdisk -qf -X gpt ${drive}

# enable swap partition
mkswap -L SWAP ${swap}
swapon ${swap}

# enable root & home partition
mkfs.ext4 -L ROOT ${root}
mkfs.ext4 -L HOME ${home}
mount ${root} /mnt
mkdir /mnt/home /mnt/boot
mount ${home} /mnt/home

# enable boot partition
if [ -d /sys/firmware/efi/efivars/ ]; then
    mkfs.fat -n BOOT -F 32 ${boot}
    mkdir /mnt/boot/efi
    mount ${boot} /mnt/boot/efi
else
    mkfs.ext4 -L BOOT ${boot}
    mount ${boot} /mnt/boot
fi

# install packages
basestrap /mnt base base-devel runit elogind-runit
basestrap /mnt linux linux-firmware
basestrap /mnt grub efibootmgr os-prober
basestrap /mnt \
          iwd-runit dhcpcd-runit openntpd-runit \
          cronie-runit openssh-runit ufw-runit \
          git vim nano man-db man-pages

# set swappiness
[ -d /mnt/etc/sysctl.d/ ] || mkdir -p /mnt/etc/sysctl.d/
echo vm.swappiness=10 > /mnt/etc/sysctl.d/99-swappiness.conf

# enablin services
services="elogind iwd dhcpcd openntpd cronie openssh ufw"
for service in ${services}; do
    artix-chroot /mnt bash -c \
      "ln -sf /etc/runit/sv/${service} /etc/runit/runsvdir/default/"
done

# set file-system table
fstabgen -U /mnt >> /mnt/etc/fstab

# set systemwide settings
echo "${locale}.UTF-8 UTF-8
${locale} ISO-8859-1" >> /mnt/etc/locale.gen

echo "LANG=${locale}.UTF-8
export LC_COLLATE=C" > /mnt/etc/locale.conf

artix-chroot /mnt bash -c 'locale-gen'

# set timezone
artix-chroot /mnt bash -c "ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime"
artix-chroot /mnt bash -c "hwclock -w"

# set hostname
echo ${hostname} > /mnt/etc/hostname

# set root password
echo "Set ROOT password:"
artix-chroot /mnt bash -c 'passwd'

# add new user
artix-chroot /mnt bash -c "useradd -mG ${user_groups} ${user}"

# set user privileges
echo "
Cmnd_Alias STAT = /usr/bin/sv status,/usr/bin/ufw status
Cmnd_Alias PACMAN = /usr/bin/checkupdates
Cmnd_Alias REBOOT = /sbin/halt,/sbin/reboot
Defaults pwfeedback
%wheel ALL=(ALL) ALL
${user} ALL=(ALL) NOPASSWD: PACMAN,REBOOT,STAT
" >> /mnt/etc/sudoers

# set default editor (for visudo)
echo "export EDITOR=vim" >> /mnt/etc/profile

# set user password
echo "Set password for ${user}:"
artix-chroot /mnt bash -c "passwd ${user}"

# instal grub
if [ -d /sys/firmware/efi ]; then
    artix-chroot /mnt bash -c \
                 "grub-install
                 --target=x86_64-efi
                 --efi-directory=/boot/efi
                 --bootloader-id=grub"
else
    artix-chroot /mnt bash -c \
                 "grub-install --recheck ${drive}"
fi

artix-chroot /mnt bash -c "grub-mkconfig -o /boot/grub/grub.cfg"

# fix/hack to find boot on startup (EFI)
if [ -d /sys/firmware/efi ]; then
    cp -r /mnt/boot/efi/EFI/artix /mnt/boot/efi/EFI/boot
    mv /mnt/boot/efi/EFI/boot/grubx64.efi \
       /mnt/boot/efi/EFI/boot/bootx86.efi
fi

# OPTIONAL: install Arch support
confirm "Install Arch Linux support?" && arch_support

# Enable firewall
artix-chroot /mnt bash -c "ufw enable"

umount -R /mnt
swapoff -a
set +x
echo "Installation complete!"
