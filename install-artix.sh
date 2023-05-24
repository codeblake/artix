#!/bin/bash
# ==========================================================
# Artix Linux Installation with LUKS Root Encryption & BTRFS
# ==========================================================
# IMPORTANT! set drive and options in CONFIG before running!
#
# NOTE:
# - ROOT password is 'artix'
# - USER password is the same as the decryption password
#
# SYSTEM LAYOUT:
# ----------------------------------------------------------
# DEVICE                   LABEL   MOUNT            SIZE
# /dev/sda
# ├─/dev/sda1              BOOT    /boot              1G
# ├─/dev/sda2              SWAP    [SWAP]            16G
# └─/dev/sda3              LUKS                      MAX
#   └─/dev/mapper/root     ROOT
#     └─@                          /
#     └─@home                      /home
#     └─@snapshots                 /.snapshots
# ----------------------------------------------------------
#
# TODO LIST:
# - FIXME: BIOS installation not booting
# - TODO: add arch mirrors support option
#
# ==========================================================
#                         CONFIG
# ==========================================================
drive=/dev/DRIVE
boot="${drive}1"
swap="${drive}2"
root="${drive}3"

timezone=Europe/London
locale=en_GB
hostname=artix
user=blake
user_groups=wheel,video,audio

# ==========================================================
#                     INSTALLATION
# ==========================================================
# Ensure nothing mounted
swapoff -a &> /dev/null
cryptsetup close root &> /dev/null
umount -R /mnt &> /dev/null

# Init shell environment
set -e

# Checks
[[ "${drive}" == "/dev/DRIVE" ]] \
    && { echo "You forgot to set the DRIVE option!"; exit; }
echo "Checking for internet connection..."
ping -c 3 artixlinux.org &> /dev/null \
    || { echo "No internet connection found"; exit; }

# Read password
echo "Enter a password (it will be used for system & user login)"
while true; do
    read -sr -p "Password: " password
    printf "\n"
    read -sr -p "Confirm password: " password2
    printf "\n"
    [[ "${password}" == "${password2}" ]] && break
    echo "Incorrect password!";
    read -rp "Press ENTER to try again...";
done

# Use RAM size to calculate SWAP size
# Note: if swap_size was set, that value will be used instead
if [[ -z $swap_size ]]; then
    pacman --needed --noconfirm -Sy bc
    ram_kB=$(awk 'FNR==1 {print $2}' /proc/meminfo)
    ram_gb=$(bc <<< "${ram_kB} / 1000^2")
    swap_size="$(bc <<< "sqrt(${ram_gb})) * 4")G"
fi

# Check at least 1GB of swap
[ "${ram_gb}" -lt 1 ] && { echo "ERR: not enough ram for SWAP"; exit; }

# Set default boot size if unset
# Note: if boot_size was set, that value will be used instead
[[ -z $boot_size ]] && boot_size=512M

# Set boot type
boot_type="BIOS Boot"
[ -d /sys/firmware/efi/efivars/ ] && boot_type=U

# Request confirmation
echo "
================ CONFIRM INSTALLATION ================
Drive: ${drive}
BOOT Partition: ${boot}, Size: ${boot_size}
SWAP Partition: ${swap}, Size: ${swap_size}
ROOT Partition: ${root}, Size: MAX
------------------------------------------------------
!!! CAUTION: all data from ${drive} will be erased !!!
------------------------------------------------------
"
secho "Are you sure you want install?"
unset input
read -rp "Type YES (in uppercase letters) to begin installation: " input
[[ "${input}" != "YES" ]] && exit

# Create partitions
printf ',%s,"%s",*\n,%s,S\n,+,L\n' \
       "${boot_size}" "${boot_type}" "${swap_size}" \
    | sfdisk -qf -X gpt ${drive}

# Create encrypted drive
echo "${password}" | cryptsetup --type luks2 \
                                --label LUKS \
                                --cipher aes-xts-plain64 \
                                --hash sha512 \
                                --use-random \
                                luksFormat "${root}"

# Open encrypted drive
echo "${password}" | cryptsetup luksOpen ${root} root

# enable SWAP partition
mkswap -L SWAP ${swap}
swapon ${swap}

# Make BOOT filesystem
if [ -d /sys/firmware/efi/efivars/ ]; then
    mkfs.fat -n BOOT -F 32 ${boot}
else
    mkfs.ext4 -L BOOT ${boot}
fi

# Make BTRFS ROOT filesystem
mkfs.btrfs -L ROOT /dev/mapper/root

# Mount btrfs ROOT drive
mount /dev/mapper/root /mnt

# Create BTRFS subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

# Mount BTRFS subvolumes
umount /mnt
options="noatime,space_cache=v2,compress=zstd,ssd,discard=async"
mount -o "${options},subvol=@" /dev/mapper/root /mnt
mkdir /mnt/{boot,home,.snapshots}
mount -o "${options},subvol=@home" /dev/mapper/root /mnt/home
mount -o "${options},subvol=@snapshots" /dev/mapper/root /mnt/.snapshots
chmod 750 /mnt/.snapshots

# Mount boot partition.
mount ${boot} /mnt/boot

# Sync packages
pacman -Syy

# Get CPU type & install microcode
ucode=amd-ucode
[[ $(grep "vendor_id" /proc/cpuinfo) == *Intel* ]] && ucode=intel-ucode

# Install base packages
basestrap /mnt base base-devel runit elogind-runit
basestrap /mnt linux linux-firmware
basestrap /mnt \
          grub efibootmgr os-prober \
          btrfs-progs mkinitcpio-nfs-utils \
          git vim man-db man-pages ${ucode}
# Install services
basestrap /mnt \
          cryptsetup-runit glibc-runit device-mapper-runit \
          iwd-runit dhcpcd-runit openntpd-runit \
          cronie-runit openssh-runit ufw-runit
# Extra packages
basestrap /mnt runit-bash-completions

# Enable runit services
services="iwd dhcpcd openntpd cronie openssh ufw dmeventd"
for service in ${services}; do
    artix-chroot /mnt bash -c \
      "ln -sf /etc/runit/sv/${service} /etc/runit/runsvdir/default/"
done

# Generate file-system table
fstabgen -U /mnt >> /mnt/etc/fstab

# Set swappiness levels
[ -d /mnt/etc/sysctl.d/ ] || mkdir -p /mnt/etc/sysctl.d/
echo vm.swappiness=10 > /mnt/etc/sysctl.d/99-swappiness.conf

# SETUP SYSTEM
# Set locale
echo "${locale}.UTF-8 UTF-8
${locale} ISO-8859-1" >> /mnt/etc/locale.gen
echo "LANG=${locale}.UTF-8
export LC_COLLATE=C" > /mnt/etc/locale.conf
artix-chroot /mnt bash -c "locale-gen"

# Set timezone
artix-chroot /mnt bash -c \
             "ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime"
artix-chroot /mnt bash -c "hwclock -w"

# Set default text editor
echo "export EDITOR=vim" >> /mnt/etc/profile

# Set hostname
echo ${hostname} > /mnt/etc/hostname

# Set root password
artix-chroot /mnt bash -c "echo root:artix | chpasswd"

# add new user
artix-chroot /mnt bash -c "useradd -mG ${user_groups} ${user}"
artix-chroot /mnt bash -c "echo \"${user}:${password}\" | chpasswd"

# set user privileges
echo "
Cmnd_Alias STAT = /usr/bin/sv status,/usr/bin/ufw status
Cmnd_Alias PACMAN = /usr/bin/checkupdates
Cmnd_Alias REBOOT = /sbin/halt,/sbin/reboot
Defaults pwfeedback
%wheel ALL=(ALL) ALL
${user} ALL=(ALL) NOPASSWD: PACMAN,REBOOT,STAT
" >> /mnt/etc/sudoers

# Configure mkinitcpio.conf
modules="btrfs"
hooks="base udev autodetect modconf kms keyboard keymap block encrypt resume filesystems fsck"
sed "s/^MODULES=(.*)/MODULES=(${modules})/" -i /mnt/etc/mkinitcpio.conf
sed "s/^HOOKS=(.*)/HOOKS=(${hooks})/" -i /mnt/etc/mkinitcpio.conf

# Rebuild ram-disk environment for Linux kernel
artix-chroot /mnt bash -c "mkinitcpio -p linux"

# CONFIGURE GRUB
devices="resume=LABEL=SWAP cryptdevice=LABEL=LUKS:root"
grub_cmds="loglevel=3 net.iframes=0 quiet splash ${devices}"

sed "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"${grub_cmds}\"/" \
    -i /mnt/etc/default/grub

# install grub
if [ -d /sys/firmware/efi/efivars/ ]; then
    grub_options="--target=x86_64-efi --efi-directory=/boot --bootloader-id=artix"
else
    grub_options="--recheck ${drive}"
fi
artix-chroot /mnt bash -c "grub-install ${grub_options}"
artix-chroot /mnt bash -c "grub-mkconfig -o /boot/grub/grub.cfg"

# FINISH
umount -R /mnt
cryptsetup close root
swapoff -a
set +x
echo "Installation complete!"
