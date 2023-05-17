#!/bin/bash
# Artix Linux Install Script
## Creates BOOT, SWAP, ROOT, HOME partitions on a UEFI or BIOS system

# CONFIG -------------------------------------------------------------
drive=/dev/nvme0n1
bootPart=${drive}p1
swapPart=${drive}p2
rootPart=${drive}p3
homePart=${drive}p4

user=blake
locale=en_GB
timezone=Europe/London
hostname=artix

# DRIVE SETUP --------------------------------------------------------
set -xe

# check online
ping -c 3 artixlinux.org > /dev/null \
    || (echo "ERR: no internet connection found"; exit)

# parition drive
printf ",512M,U\n,16G,S\n,64G,L\n,+,H\n" | sfdisk -qf -X gpt ${drive}

# format partitions
if [ -d /sys/firmware/efi ]; then
    mkfs.fat -n BOOT -F 32 ${bootPart}
  else
    mkfs.ext4 -L BOOT ${bootPart}
fi

mkfs.ext4 -L ROOT ${rootPart}
mkfs.ext4 -L HOME ${homePart}
mkswap -L SWAP ${swapPart}

# mount partitions
mount ${rootPart} /mnt
mkdir -p /mnt/boot/efi /mnt/home
mount ${bootPart} /mnt/boot/efi
mount ${homePart} /mnt/home
swapon ${swapPart}

# SYSTEM CONFIG
# ----------------------------------------------------------------------
# installing base packages...
basestrap /mnt base base-devel linux linux-firmware
basestrap -i /mnt elogind-runit iwd-runit dhcpcd-runit openntpd-runit
basestrap /mnt grub efibootmgr git vim man-db man-pages

# set swappiness
[ -d /mnt/etc/sysctl.d/ ] || mkdir -p /mnt/etc/sysctl.d/
echo vm.swappiness=10 > /mnt/etc/sysctl.d/99-swappiness.conf

# install useful services
basestrap /mnt cronie-runit openssh-runit ufw-runit

# enabling runit services...
services="iwd dhcpcd openntpd cronie openssh ufw"
for service in $services; do
    artix-chroot \
        /mnt sh -c "ln -sf /etc/runit/sv/${service} /etc/runit/runsvdir/default"
done

# enable firewall
artix-chroot /mnt bash -c "ufw enable"

# setting file-system table...
fstabgen -U /mnt >> /mnt/etc/fstab

# set systemwide settings
echo "${locale}.UTF-8 UTF-8
${locale} ISO-8859-1" >> /mnt/etc/locale.gen

echo "LANG=${locale}.UTF-8
export LC_COLLATE=C" > /mnt/etc/locale.conf
artix-chroot /mnt bash -c 'locale-gen'

# setting timezone...
artix-chroot /mnt bash -c "ln -s /usr/share/zoneinfo/${timezone} /etc/localtime"
artix-chroot /mnt bash -c "hwclock -w"

# adding hostname...
echo ${hostname} > /mnt/etc/hostname

# setting root password...
artix-chroot /mnt bash -c 'passwd'

# adding new user...
artix-chroot /mnt bash -c "useradd -mG wheel ${user}"
# set user privileges
echo "
Cmnd_Alias PACMAN = /usr/bin/pacman -Sy*
Cmnd_Alias REBOOT = /sbin/halt, /sbin/reboot
Defaults pwfeedback
%wheel ALL=(ALL) ALL
${user} ALL=(ALL) NOPASSWD: PACMAN, REBOOT
" >> /mnt/etc/sudoers

# set default editor (for visudo)
echo "export EDITOR=vim" >> /mnt/etc/profile

# setting user password...
artix-chroot /mnt bash -c "passwd ${user}"

# installing grub...
if [ -d /sys/firmware/efi ]; then
    installgrub="grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=grub"
  else
    installgrub="grub-install --recheck ${drive}"
fi

artix-chroot /mnt bash -c ${installgrub}
artix-chroot /mnt bash -c "grub-mkconfig -o /boot/grub/grub.cfg"

# fix/hack to find boot on startup
cp -r /mnt/boot/efi/EFI/artix /mnt/boot/efi/EFI/boot
mv /mnt/boot/efi/EFI/boot/grubx64.efi to /mnt/boot/efi/EFI/boot/bootx86.efi

# EXTRA
# ----------------------------------------------------------------------
# Enable Arch package Support
# get mirrorlist
curl -L "https://github.com/archlinux/svntogit-packages/raw/packages/pacman-mirrorlist/trunk/mirrorlist" \
     -o /mnt/etc/pacman.d/mirrorlist-arch

# Uncomment location in Arch mirrorlist
vim -s <(printf "/United Kingdom\nvip:s/^#//g\n:wq\n") \
    /mnt/etc/pacman.d/mirrorlist-arch

# add mirror list to pacman
echo "
# Arch
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[community]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch

[universe]
Server = https://universe.artixlinux.org/$arch
Server = https://mirror1.artixlinux.org/universe/$arch
Server = https://mirror.pascalpuffke.de/artix-universe/$arch
Server = https://mirrors.qontinuum.space/artixlinux-universe/$arch
Server = https://mirror1.cl.netactuate.com/artix/universe/$arch
Server = https://ftp.crifo.org/artix-universe/$arch
Server = https://artix.sakamoto.pl/universe/$arch
" >> /mnt/etc/pacman.conf

artix-chroot /mnt bash -c "pacman --noconfirm -Syy artix-archlinux-support"

# Add global vim bindings
echo "
\" Movement keys
map j <up>
map k <down>
map l <left>
map ; <right>
" >> /mnt/etc/vimrc

# ----------------------------------------------------------------------
umount -R /mnt
swapoff -a
set +x

echo "Installation complete!"
