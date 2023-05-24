#!/bin/bash

# Enable Arch repositories (extra, community & multilib)
# https://wiki.artixlinux.org/Main/Repositories
enable_arch(){
    echo "Enabling Arch repositories..."

    # Package requirements
    pacman --needed --noconfirm -Sy vim git \
           || { echo "Error installing packages"; return 1; }

    # Download latest Arch mirrorlist
    url="https://github.com/archlinux/svntogit-packages\
/raw/packages/pacman-mirrorlist/trunk/mirrorlist"
    curl -L "${url}" -o /mnt/etc/pacman.d/mirrorlist-arch \
         || { echo "Error downloading Arch mirrorlist"; return 1; }

    # Set a server region defined in 'mirrorlist-arch'
    local region="United Kingdom"

    # Ensure region exists
    grep -qw "${region}" /mnt/etc/pacman.d/mirrorlist-arch \
         || { echo "Arch server location '${region}' not found."; return 1; }

    # Uncomment local servers in Arch mirrorlist
    vim -s <(printf "/%s\nvip:s/^#//g\n:wq\n" "${region}") \
        /mnt/etc/pacman.d/mirrorlist-arch

    # Add Arch mirrorlist & servers to pacman
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

    # Download Arch Linux support
    artix-chroot /mnt bash -c \
                 "pacman --noconfirm -Syy artix-archlinux-support" \
                 || { echo "Error downloading artix-archlinux-support"; return 1; }

    echo "Arch support installation complete!"
}
