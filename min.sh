#!/bin/bash

# CONFIG
# ======================================================
# Drive
drive="/dev/DRIVE"
root="/dev/DRIVE1"
boot="/dev/DRIVE2"

# System
timezone=Europe/London
locale=en_GB
user=blake
user_groups=wheel,video,audio,input,seat
hostname=ArtixPC

# INSTALLATION
# ======================================================

# Ensure nothing mounted
umount -R /mnt &> /dev/null

# Init shell environment
set -e

# Checks
[[ "${drive}" == "/dev/DRIVE" ]] \
    && { echo "You forgot to set the DRIVE option!"; exit; }

echo "Checking for internet connection..."
ping -c 3 artixlinux.org 2>&1 /dev/null \
    || { echo "No internet connection found"; exit; }

# Enable ntpd to update time
dinitctl start ntpd

# Calculate SWAP size
pacman --needed --noconfirm -Sy bc
ram_kB=$(awk 'FNR==1 {print $2}' /proc/meminfo)
ram_gb=$(bc <<< "${ram_kB} / 1000^2")
[[ "${ram_gb}" -lt 1 ]] && { echo "Not enough ram for SWAP"; exit; }
[[ -z "${swap_size}" || "${swap_size}" == auto ]] \
    && swap_size="$(bc <<< "sqrt(${ram_gb}) * 4")G"

# Request confirmation
drive_bytes=$(blockdev --getsize64 "${drive}")
drive_size="$(bc <<< "${drive_bytes} / 1000000000")G"
echo "
================ CONFIRM INSTALLATION ================
DRIVE: ${drive} (size: ${drive_size})
ROOT: ${root}
BOOT: ${boot}
------------------------------------------------------
!!! CAUTION: ALL data from ${drive} will be erased !!!
------------------------------------------------------
Are you sure you want install?
"
unset input
read -rp "Type YES (in uppercase letters) to begin installation: " input
[[ "${input}" != "YES" ]] && exit

# Create partitions
wipefs -a "${drive}"
layout=',+,L\n'
[[ -d /sys/firmware/efi/efivars/ ]] && layout=",1G,U,*\n${layout}"
printf "%s" "$layout" | sfdisk -qf -X gpt ${drive}

# Make file-systems
[[ -d /sys/firmware/efi/efivars/ ]] && mkfs.fat -n BOOT -F 32 "${boot}"
mkfs.ext4 -qfL ROOT "$root"

# Mount
mount "${root}" /mnt && mkdir /mnt/boot
[[ -d /sys/firmware/efi/efivars/ ]] && mount "${boot}" /mnt/boot

# Make Swap
fallocate -l "$swap_size" /mnt/swapfile && chmod 600 /mnt/swapfile
mkswap /mnt/swapfile

# Get CPU type & install microcode
ucode=amd-ucode
[[ $(grep "vendor_id" /proc/cpuinfo) == *Intel* ]] && ucode=intel-ucode

# Sync packages
pacman -Syy

# Install base packages
basestrap /mnt base base-devel dinit seatd-dinit pam_rundir

# Install Linux & utilities
basestrap /mnt \
          linux-{firmware,headers} "${ucode}" \
          grub efibootmgr os-prober \
          git nano man-{db,man-pages} bc btop

# Install services
basestrap /mnt {iwd,openntpd,cronie,openssh,ufw}-dinit

# Enable DHCP client for iwd
printf "[General]\nEnableNetworkConfiguration=true" >> /mnt/etc/iwd/main.conf

# Enable services
services="ufw iwd openntpd cronie"
for service in $services; do
    artix-chroot /mnt bash -c "dinitctl enable $service"
done

# Generate file-system table
fstabgen -U /mnt >> /mnt/etc/fstab

# Set swappiness levels
mkdir -p /mnt/etc/sysctl.d/
echo vm.swappiness=10 > /mnt/etc/sysctl.d/99-swappiness.conf

# Set locale
printf "%s.UTF-8 UTF-8\n%s ISO-8859-1" "$locale" "$locale" >> /mnt/etc/locale.gen
printf "LANG=%s.UTF-8\nexport LC_COLLATE=C" "$locale" > /mnt/etc/locale.conf
artix-chroot /mnt bash -c "locale-gen"

# Set timezone
artix-chroot /mnt bash -c \
             "ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime && hwclock -w"

# Set default text editor
echo "export EDITOR=nano" >> /mnt/etc/profile

# Set hostname
echo "$hostname" > /mnt/etc/hostname

# Set root password
artix-chroot /mnt bash -c "echo root:artix | chpasswd"

# Add new user
artix-chroot /mnt bash -c "useradd -mG ${user_groups} ${user}"
artix-chroot /mnt bash -c "echo \"${user}:artix\" | chpasswd"

# Set user privileges
echo "
Cmnd_Alias STAT = /usr/bin/ufw status
Cmnd_Alias PACMAN = /usr/bin/checkupdates
Cmnd_Alias REBOOT = /bin/halt,/bin/reboot
Defaults pwfeedback
%wheel ALL=(ALL) ALL
${user} ALL=(ALL) NOPASSWD:PACMAN,REBOOT,STAT
" >> /mnt/etc/sudoers

# Add PACMAN download style
# Set MAKEFLAGS to match CPU threads for faster compiling
cp /etc/makepkg.conf /etc/makepkg.conf.bak
sed "s/#MAKEFLAGS=\".*\"/MAKEFLAGS=\"-j$(nproc)\"/" \
    -i /mnt/etc/makepkg.conf

# Configure GRUB
# install grub
grub_options="--target=i386-pc --recheck ${drive}"
[[ -d /sys/firmware/efi/efivars/ ]] \
    && grub_options="--target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB"

artix-chroot /mnt bash -c \
             "grub-install ${grub_options} && grub-mkconfig -o /boot/grub/grub.cfg"

# FINISH
umount -R /mnt
swapoff -a
set +x

echo "
======================================================================
                        Installation Finished
======================================================================
"
echo "You can now reboot and log into system"
echo "NOTE: AFTER reboot be sure to enable the firewall with 'ufw enable'"
