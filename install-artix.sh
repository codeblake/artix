#!/bin/bash
# Installs Artix Linux With LUKS Root Encryption & BTRFS
# See README for further details
# ======================================================
# CONFIGURATION
# ======================================================
# Drive
drive="/dev/DRIVE"
boot="${drive}1"
root="${drive}2"
swap_size=auto
boot_size=512M

# DUEL-BOOT (i.e. a shared boot partition is used)
# Note:
# - ensure BOOT, SWAP, & ROOT are set to the correct partitions
# - when enabled, the boot partition will NOT be formatted
# - boot partition must be ready to use (i.e. created/formatted)
duel_boot=false

# System
timezone=Europe/London
locale=en_GB
user=blake
user_groups=wheel,video,audio,input,seat
hostname=ArtixPC

# Features
autologin=false
encrypt=false
arch_support=false
enable_aur=false

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
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "Only UEFI systems are currently supported"
    exit
fi
if [[ "${drive}" == "/dev/DRIVE" ]]; then
    echo "You forgot to set the DRIVE option!"
    exit
fi

echo "Checking for internet connection..."
ping -c 3 artixlinux.org &> /dev/null \
    || { echo "No internet connection found"; exit; }

# Sync clock
dinitctl start ntpd

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
if [[ "${ram_gb}" -lt 1 ]]; then
    echo "Not enough ram for SWAP"
    exit
fi

# Calculate SWAP size
if [[ "${swap_size}" == auto ]]; then
    swap_size="$(bc <<< "sqrt(${ram_gb}) * 4")G"
fi

# Get boot size if using an already created partition
# (note: only used for prompt confirmation)
if [[ $duel_boot == true ]]; then
    boot_bytes=$(blockdev --getsize64 "${boot}")
    boot_size="$(bc <<< "${boot_bytes} / 1000000000")G"
fi

# Request confirmation
drive_bytes=$(blockdev --getsize64 "${drive}")
drive_size="$(bc <<< "${drive_bytes} / 1000000000")G"

[[ $encrypt == true ]] && features+="encrypt "
[[ $arch_support == true ]] && features+="arch_support "
[[ $enable_aur == true ]] && features+="enable_aur "
[[ $autologin == true ]] && features+="autologin "
[[ $duel_boot == true ]] && features+="duel_boot "

echo "
================ CONFIRM INSTALLATION ================
Drive: ${drive} (size: ${drive_size})
BOOT Partition: ${boot}, Size: ${boot_size}
ROOT Partition: ${root}, Size: MAX
SWAP Size: ${swap_size}
------------------------------------------------------
Features: ${features}
------------------------------------------------------
!!! CAUTION: ALL data from ${drive} will be erased !!!
------------------------------------------------------"
if [[ $duel_boot == true ]]; then
    echo "Note: Installing GRUB onto ${boot} will NOT erase drive."
fi

echo "Are you sure you want install?"
unset input
read -rp "Type YES (in uppercase letters) to begin installation: " input
[[ "${input}" != "YES" ]] && exit

# Wipe file-system
wipefs -a "${drive}"

# Create partitions
if [[ $duel_boot == true ]]; then
    # create root partition
    printf ',+,L\n' "${swap_size}" \
        | sfdisk -qf -X gpt ${drive}
else
    # create UEFI boot & root partition
    printf ',%s,U,*\n,+,L\n' "${boot_size}" \
        | sfdisk -qf -X gpt ${drive}
fi

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

    # Change root path to mapper
    root="/dev/mapper/root"
fi

# Make BOOT filesystem
if [[ $duel_boot == false ]]; then
    mkfs.fat -n BOOT -F 32 "${boot}"
fi

# Make BTRFS ROOT filesystem
mkfs.btrfs -qfL ROOT "${root}"

# Mount btrfs ROOT drive
mount "${root}" /mnt

# Create BTRFS subvolumes
btrfs -q subvolume create /mnt/@
btrfs -q subvolume create /mnt/@home
btrfs -q subvolume create /mnt/@tmp
btrfs -q subvolume create /mnt/@var
btrfs -q subvolume create /mnt/@snapshots
btrfs -q subvolume create /mnt/@swap

# Mount BTRFS subvolumes
umount /mnt
options="noatime,compress=zstd"
mount -o "${options},subvol=@" "${root}" /mnt
mkdir /mnt/{boot,home,tmp,var,.snapshots,.swap}
mount -o "${options},subvol=@home" "${root}" /mnt/home
mount -o "${options},subvol=@tmp" "${root}" /mnt/tmp
mount -o "${options},subvol=@var" "${root}" /mnt/var
mount -o "${options},subvol=@snapshots" "${root}" /mnt/.snapshots \
    && chmod 750 /mnt/.snapshots
mount -o "nodatacow,compress=no,subvol=@swap" "${root}" /mnt/.swap

# Create swap file
btrfs filesystem mkswapfile \
      --size "$swap_size" \
      --uuid clear \
      /mnt/.swap/swapfile
btrfs property set /mnt/.swap compression none
swapon /mnt/.swap/swapfile

# Mount boot partition.
mount "${boot}" /mnt/boot

# Sync packages
pacman -Syy

# Get CPU type & install microcode
ucode=amd-ucode
if [[ $(grep "vendor_id" /proc/cpuinfo) == *Intel* ]]; then
    ucode=intel-ucode
fi

# Install base packages
basestrap /mnt base base-devel dinit seatd-dinit pam_rundir booster

# Install Linux & utilities
basestrap /mnt \
          linux linux-firmware \
          refind btrfs-progs \
          git nano man-{db,pages} "${ucode}" \

# Install crypt service
if [[ "${encrypt}" == true ]]; then
    basestrap /mnt cryptsetup-dinit
fi

basestrap /mnt {iwd,dhcpcd,openntpd,cronie,openssh,ufw,dbus}-dinit

# Enable services
services="dbus ufw iwd dhcpcd openntpd cronie"
# NOTE: do not quote 'services' variable or space is ignored
for service in ${services}; do
    artix-chroot /mnt bash -c \
                 "ln -s /etc/dinit.d/$service /etc/dinit.d/boot.d/"
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
echo "${hostname}" > /mnt/etc/hostname

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
if [[ "${autologin}" == true ]]; then
    cp /mnt/etc/dinit.d/config/agetty-default.conf \
       /mnt/etc/dinit.c/config/agetty-tty1.conf
    sed "s/GETTY_ARGS=.*/GETTY_ARGS=\"--noclear --autologin ${user}\"/" \
        -i /mnt/etc/dinit.c/config/agetty-tty1.conf
fi

# Add PACMAN download style
pac_options=ILoveCandy
sed "s/# Misc options/# Misc options\n${pac_options}/g" \
    -i /mnt/etc/pacman.conf

# Set MAKEFLAGS to match CPU threads for faster compiling
cp /etc/makepkg.conf /etc/makepkg.conf.bak
sed "s/#MAKEFLAGS=\".*\"/MAKEFLAGS=\"-j$(nproc)\"/" \
    -i /mnt/etc/makepkg.conf

# Configure booster
echo "compress: zstd -9 -T0
modules: btrfs" > /mnt/etc/booster.yaml
artix-chroot /mnt bash -c "/usr/lib/booster/regenerate_images"

# Install rEFInd
artix-chroot /mnt bash -c "refind-install"

# Install rEFInd theme
## download repo
git clone https://github.com/bobafetthotmail/refind-theme-regular.git /mnt/tmp/refind-theme-regular
## remove unused directories and files
rm -rf /mnt/tmp/refind-theme-regular/{src,.git}
rm /mnt/tmp/refind-theme-regular/install.sh
## remove old theme (if previously installed to boot)
rm -rf /mnt/boot/EFI/refind/{regular-theme,refind-theme-regular}
rm -rf /mnt/boot/EFI/refind/themes/{regular-theme,refind-theme-regular}
## install theme
mkdir -p /mnt/boot/EFI/refind/themes
cp -r /mnt/tmp/refind-theme-regular /mnt/boot/EFI/refind/themes/
## enable theme
echo "# Load refind-theme-regular
include themes/refind-theme-regular/theme.conf" >> /mnt/boot/EFI/refind/refind.conf

# FEATURES
# ====================================================================
# Enable Arch repositories (extra, community & multilib)
# https://wiki.artixlinux.org/Main/Repositories
if [[ "${arch_support}" == true ]]; then
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
        || { echo "Error installing artix-archlinux-support"; exit; }

    # Update keys
    artix-chroot /mnt bash -c "pacman-key --populate archlinux"

    echo "Arch support installation complete!"
fi

# Install AUR helper
if [[ "${enable_aur}" == true ]]; then
    artix-chroot /mnt bash -c "pacman --noconfirm -Syy trizen" \
        || { echo "Error installing trizen AUR helper"; exit; }
    echo "AUR helper installation complete!"
fi

# FINISH
swapoff -a
umount -R /mnt
[[ "${encrypt}" == true ]] && cryptsetup close root
set +x

echo "
======================================================================
                        Installation Finished
======================================================================
"
echo "You can now reboot and log into system"
echo "NOTE: AFTER reboot be sure to enable the firewall with 'ufw enable'"
