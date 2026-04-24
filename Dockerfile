FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build \
    debootstrap \
    ubuntu-keyring \
    xorriso \
    squashfs-tools \
    syslinux-common \
    isolinux \
    grub2-common \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-efi-remixed \
    shim-signed \
    mtools \
    dosfstools \
    cpio \
    zutils \
    fdisk \
    gdisk \
    parted \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /magic_stick

ENTRYPOINT ["bash"]