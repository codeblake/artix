#!/bin/bash
# Installs Artix Linux With LUKS Root Encryption & BTRFS
# See README for further details
# ======================================================
# CONFIGURATION
# ======================================================
# Drive
drive=/dev/DRIVE
boot="${drive}1"
swap="${drive}2"
root="${drive}3"
swap_size=auto

# System
timezone=Europe/London
locale=en_GB
user=blake
user_groups=wheel,video,audio,input,seat
hostname=artix

# Features
encrypt=false
arch_support=false
enable_aur=false
autologin=true

# ======================================================
# INSTALLATION
# ======================================================

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
echo "Enter a password for ${user} (also used for encryption if enabled)"
while true; do
    read -sr -p "Password: " password
    printf "\n"
    read -sr -p "Confirm password: " password2
    printf "\n"
    [[ "${password}" == "${password2}" ]] && break
    echo "Incorrect password!";
    read -rp "Press ENTER to try again...";
done

# Get system RAM size
pacman --needed --noconfirm -Sy bc
ram_kB=$(awk 'FNR==1 {print $2}' /proc/meminfo)
ram_gb=$(bc <<< "${ram_kB} / 1000^2")

# Check there is at least 1GB RAM for swap
[[ $ram_gb -lt 1 ]] && { echo "Not enough ram for SWAP"; exit; }

# Calculate SWAP size
[[ -z $swap_size || $swap_size == auto ]] \
    && swap_size="$(bc <<< "sqrt(${ram_gb}) * 4")G"

# Set BOOT size
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
------------------------------------------------------"
echo "Are you sure you want install?"
unset input
read -rp "Type YES (in uppercase letters) to begin installation: " input
[[ "${input}" != "YES" ]] && exit

# Create partitions
printf ',%s,"%s",*\n,%s,S\n,+,L\n' \
       "${boot_size}" "${boot_type}" "${swap_size}" \
    | sfdisk -qf -X gpt ${drive}

# Encryption setup
if [[ $encrypt == true ]]; then
    # Create encrypted drive
    echo "${password}" | cryptsetup --type luks2 \
                                    --label LUKS \
                                    --cipher aes-xts-plain64 \
                                    --hash sha512 \
                                    --use-random \
                                    luksFormat "${root}"

    # Open encrypted drive
    echo "${password}" | cryptsetup luksOpen ${root} root
fi

# enable SWAP partition
mkswap -L SWAP ${swap}
swapon ${swap}

# Make BOOT filesystem
if [ -d /sys/firmware/efi/efivars/ ]; then
    mkfs.fat -n BOOT -F 32 ${boot}
else
    mkfs.ext4 -qL BOOT ${boot}
fi

# Make BTRFS ROOT filesystem
mkfs.btrfs -qL ROOT /dev/mapper/root

# Mount btrfs ROOT drive
mount /dev/mapper/root /mnt

# Create BTRFS subvolumes
btrfs -q subvolume create /mnt/@
btrfs -q subvolume create /mnt/@home
btrfs -q subvolume create /mnt/@snapshots

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
basestrap /mnt \
          base base-devel runit seatd-runit pam_rundir

# Install Linux & utilities
basestrap /mnt \
          linux linux-firmware \
          grub efibootmgr os-prober \
          btrfs-progs mkinitcpio-nfs-utils \
          git vim man-db man-pages ${ucode} \
          runit-bash-completions

# Install runit services
if [[ $encrypt == true ]]; then
    basestrap /mnt cryptsetup-runit
fi

basestrap /mnt \
          iwd-runit dhcpcd-runit openntpd-runit \
          cronie-runit openssh-runit ufw-runit

# Enable runit services
services="ufw iwd dhcpcd openntpd cronie openssh"
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

# Add new user
artix-chroot /mnt bash -c "useradd -mG ${user_groups} ${user}"
artix-chroot /mnt bash -c "echo \"${user}:${password}\" | chpasswd"

# Set user privileges
echo "
Cmnd_Alias STAT = /usr/bin/sv status,/usr/bin/ufw status
Cmnd_Alias PACMAN = /usr/bin/checkupdates
Cmnd_Alias REBOOT = /bin/halt,/bin/reboot
Defaults pwfeedback
%wheel ALL=(ALL) ALL
${user} ALL=(ALL) NOPASSWD: PACMAN,REBOOT,STAT
" >> /mnt/etc/sudoers

# Add user to autologin (note: password must match decryption password)
if [[ $autologin == true ]]; then
    sed "s/GETTY_ARGS=\".*\"/GETTY_ARGS=\"--noclear --autologin ${user}\"/" \
        -i /mnt/etc/runit/sv/agetty-tty1/conf
fi

# Add PACMAN download style
pac_options=ILoveCandy
sed "s/# Misc options/# Misc options\n${pac_options}/g" \
    -i /mnt/etc/pacman.conf

# Set MAKEFLAGS to match CPU threads for faster compiling
cp /etc/makepkg.conf /etc/makepkg.conf.bak
sed "s/#MAKEFLAGS=\".*\"/MAKEFLAGS=\"-j$(nproc)\"/" \
    -i /mnt/etc/makepkg.conf

# Configure mkinitcpio.conf
modules="btrfs"
sed "s/^MODULES=(.*)/MODULES=(${modules})/" -i /mnt/etc/mkinitcpio.conf

if [[ $encrypt == true ]]; then
    hooks="base udev autodetect modconf kms keyboard keymap block encrypt resume filesystems fsck"
    sed "s/^HOOKS=(.*)/HOOKS=(${hooks})/" -i /mnt/etc/mkinitcpio.conf
fi

# Rebuild ram-disk environment for Linux kernel
artix-chroot /mnt bash -c "mkinitcpio -p linux"

# Configure GRUB
if [[ $encrypt == true ]]; then
    devices="resume=LABEL=SWAP cryptdevice=LABEL=LUKS:root"
    grub_cmds="loglevel=3 net.iframes=0 quiet splash ${devices}"

    sed "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"${grub_cmds}\"/" \
        -i /mnt/etc/default/grub
fi

# install grub
if [ -d /sys/firmware/efi/efivars/ ]; then
    grub_options="--target=x86_64-efi --efi-directory=/boot --bootloader-id=artix"
else
    grub_options="--recheck ${drive}"
fi
artix-chroot /mnt bash -c "grub-install ${grub_options}"
artix-chroot /mnt bash -c "grub-mkconfig -o /boot/grub/grub.cfg"

echo "
----------------------------------------------------------------------
                    Main Installation Complete
----------------------------------------------------------------------
"

# Enable Arch repositories (extra, community & multilib)
# https://wiki.artixlinux.org/Main/Repositories
if [[ $arch_support == true ]]; then
    echo "Enabling Arch repositories..."

    # Package requirements
    pacman --needed --noconfirm -Sy vim git \
        || { echo "Error installing packages"; exit; }

    # Download latest Arch mirrorlist
    url="https://github.com/archlinux/svntogit-packages\
/raw/packages/pacman-mirrorlist/trunk/mirrorlist"
    curl -L "${url}" -o /mnt/etc/pacman.d/mirrorlist-arch \
        || { echo "Error downloading Arch mirrorlist"; exit; }

    # Set a region defined in 'mirrorlist-arch'
    region="United Kingdom"

    # Ensure region exists
    grep -qw "${region}" /mnt/etc/pacman.d/mirrorlist-arch \
        || { echo "Arch server location '${region}' not found."; exit; }

    # Uncomment local servers in Arch mirrorlist
    vim -s <(printf "/%s\nvip:s/^#//g\n:wq\n" "${region}") \
        /mnt/etc/pacman.d/mirrorlist-arch &>/dev/null

    # Add Arch mirrorlist & servers to pacman
    echo "
# Arch
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
" >> /mnt/etc/pacman.conf

    # Download Arch Linux support
    artix-chroot /mnt bash -c \
                 "pacman --noconfirm -Syy artix-archlinux-support" \
        || { echo "Error downloading artix-archlinux-support"; exit; }

    # Update keys
    artix-chroot /mnt bash -c "pacman-key --populate archlinux"

    echo "Arch support installation complete!"
fi

# Install AUR helper
if [[ $enable_aur == true ]]; then
    if [[ $arch_support == true ]]; then
        artix-chroot /mnt bash -c "pacman --noconfirm -Syy trizen"
    else
        # install dependencies
        deps="git pacutils perl-{libwww,term-ui,json,data-dump,lwp-protocol-https,term-readline-gnu}"
        artix-chroot /mnt bash -c "pacman --noconfirm --needed -Sy ${deps}"

        # download package
        rm -rf /mnt/home/${user}/trizen &> /dev/null
        clone="git clone https://aur.archlinux.org/trizen"
        artix-chroot /mnt bash -c "runuser -l ${user} -c \"${clone}\""

        # build package
        build="cd /home/${user}/trizen && makepkg --noconfirm"
        artix-chroot /mnt bash -c "runuser -l ${user} -c \"${build}\""

        # add package to pacman
        artix-chroot /mnt bash -c "pacman -U --noconfirm /home/${user}/trizen/*.zst"

        # remove unnecessary files
        rm -rf "/mnt/home/${user}/trizen"
    fi
    echo "AUR helper installation complete!"
fi

# FINISH
umount -R /mnt
[[ $encrypt == true ]] && cryptsetup close root
swapoff -a
set +x

echo "
======================================================================
                        Installation Finished
======================================================================
"
echo "You can now reboot and log into system"
echo "NOTE: AFTER reboot be sure to enable the firewall with 'ufw enable'"
