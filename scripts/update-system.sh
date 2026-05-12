#!/usr/bin/env bash
set -euo pipefail

VERSION="0.2.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"

SYSTEM_A_LABEL="system_a"
SYSTEM_B_LABEL="system_b"
PERSISTENCE_LABEL="persistence"

GRUB_CFG_TEMPLATE="${SCRIPT_DIR}/grub-ab.cfg.template"
FORCE_YES=false
DRY_RUN=false

dry_run_info() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would execute: $*"
    fi
}

dry_run_exec() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would execute: $*"
    else
        "$@"
    fi
}

usage() {
    cat << USAGE
Magic Stick A/B System Manager v${VERSION}

Usage: update-system.sh [options] <command> [args]

Options:
  -y, --yes                  Skip all confirmation prompts (DANGEROUS!)
  -n, --dry-run              Show what would be done without executing

Commands:
  setup-ab <device> [iso]    Partition device + install GRUB + flash initial ISO
  install <device> <iso>     Install ISO content to a partition (A or B)
  switch <device>            Switch default boot partition (A<->B)
  status <device>            Show current A/B partition status
  verify <device>            Verify partition layout and GRUB installation

Partition layout (GPT):
  /dev/sdX1  system_a      (8 GB)  - System partition A
  /dev/sdX2  system_b      (8 GB)  - System partition B
  /dev/sdX3  persistence  (rest)   - User data (never touched by updates)

Each system partition contains:
  /vmlinuz              - Linux kernel
  /initrd.img           - Initial ramdisk
  /filesystem.squashfs  - Compressed root filesystem

GRUB is installed on the device MBR with a config that boots
from the active partition (A or B). Switching is done by
changing the default entry in grub.cfg.

WARNING: These commands modify partition tables and write to raw devices!
USE WITH CAUTION - always verify the target device.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

info() {
    echo "==> $*"
}

prompt_confirm() {
    if [[ "$FORCE_YES" == "true" ]]; then
        return 0
    fi
    local prompt="${1:-Type 'YES' to continue: }"
    read -rp "$prompt" confirm
    [[ "$confirm" == "YES" ]]
}

get_part_prefix() {
    local device="$1"
    if [[ "$device" =~ ^/dev/(nvme|loop) ]]; then
        echo "${device}p"
    else
        echo "${device}"
    fi
}

get_device_size_bytes() {
    local device="$1"
    blockdev --getsize64 "$device" 2>/dev/null || echo 0
}

label_to_partnum() {
    case "$1" in
        "${SYSTEM_A_LABEL}") echo 1 ;;
        "${SYSTEM_B_LABEL}") echo 2 ;;
        "${PERSISTENCE_LABEL}") echo 3 ;;
        *) echo 0 ;;
    esac
}

find_partition_by_label() {
    local device="$1"
    local label="$2"
    local prefix
    prefix=$(get_part_prefix "$device")
    local partnum
    partnum=$(label_to_partnum "$label")
    if [[ "$partnum" -eq 0 ]]; then
        blkid -L "$label" -o device 2>/dev/null || echo ""
    else
        echo "${prefix}${partnum}"
    fi
}

is_partition_mounted() {
    local part="$1"
    mount | grep -q "$part" 2>/dev/null
}

detect_active_partition() {
    local device="$1"
    local prefix
    prefix=$(get_part_prefix "$device")

    local part_a="${prefix}1"
    local part_b="${prefix}2"

    if mount | grep -q "$part_a"; then
        echo "A"
    elif mount | grep -q "$part_b"; then
        echo "B"
    else
        local boot_flag
        boot_flag=$(parted -s "$device" print 2>/dev/null | grep boot | head -1 | awk '{print $1}' || echo "1")
        if [[ "$boot_flag" == "1" ]]; then
            echo "A"
        else
            echo "B"
        fi
    fi
}

read_grub_default() {
    local device="$1"
    local prefix
    prefix=$(get_part_prefix "$device")
    local part_a="${prefix}1"

    local mount_point
    mount_point=$(mktemp -d)

    if ! mount "${part_a}" "$mount_point" 2>/dev/null; then
        rmdir "$mount_point" 2>/dev/null || true
        echo "A"
        return
    fi
    trap 'umount "${part_a}" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT

    local default_entry
    default_entry=$(grep -E '^set default=' "${mount_point}/boot/grub/grub.cfg" 2>/dev/null | head -1 | sed 's/set default=//' | tr -d '"' || echo "0")

    if [[ "$default_entry" == "0" ]]; then
        echo "A"
    else
        echo "B"
    fi
}

cmd_status() {
    local device="$1"

    [[ -b "$device" ]] || die "${device} is not a block device"

    local prefix
    prefix=$(get_part_prefix "$device")

    echo "=== Magic Stick A/B Status ==="
    echo "Device: ${device}"
    echo ""

    echo "Partition table:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "${device}" 2>/dev/null || \
        fdisk -l "${device}" 2>/dev/null || \
        echo "  (Cannot read partition table)"
    echo ""

    echo "Partition details:"
    local part_a="${prefix}1"
    local part_b="${prefix}2"
    local part_p="${prefix}3"

    for i in 1 2 3; do
        local part="${prefix}${i}"
        if [[ -b "$part" ]]; then
            local label
            label=$(blkid -s LABEL -o value "$part" 2>/dev/null || echo "N/A")
            local fstype
            fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "N/A")
            local size
            size=$(lsblk -n -o SIZE "$part" 2>/dev/null || echo "N/A")
            echo "  ${part}: label=${label} fstype=${fstype} size=${size}"
        else
            echo "  ${part}: NOT FOUND"
        fi
    done

    echo ""
    echo "Boot configuration:"
    local active
    active=$(detect_active_partition "$device")
    echo "  Active partition: ${active}"

    echo ""
    echo "System partition contents:"
    for part_label in "$SYSTEM_A_LABEL" "$SYSTEM_B_LABEL"; do
        local part
        part=$(find_partition_by_label "$device" "$part_label")
        if [[ -b "$part" ]]; then
            echo ""
            echo "  ${part_label} (${part}):"
            local mount_point
            mount_point=$(mktemp -d)
            if mount -o ro "$part" "$mount_point" 2>/dev/null; then
                trap 'umount "$part" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT
                for f in vmlinuz initrd.img filesystem.squashfs; do
                    if [[ -f "${mount_point}/${f}" ]]; then
                        local fsize
                        fsize=$(du -h "${mount_point}/${f}" 2>/dev/null | cut -f1 || echo "?")
                        echo "    ${f}: ${fsize}"
                    else
                        echo "    ${f}: MISSING"
                    fi
                done
            else
                echo "    (cannot mount)"
                rmdir "$mount_point" 2>/dev/null || true
            fi
        fi
    done
}

cmd_setup_ab() {
    local device="$1"
    local iso_file="${2:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would setup A/B partitions on ${device}"
        echo "[DRY-RUN]   - Create GPT partition table"
        echo "[DRY-RUN]   - Partition 1: ${SYSTEM_A_LABEL} (8 GB)"
        echo "[DRY-RUN]   - Partition 2: ${SYSTEM_B_LABEL} (8 GB)"
        echo "[DRY-RUN]   - Partition 3: ${PERSISTENCE_LABEL} (rest)"
        echo "[DRY-RUN]   - Format all partitions as ext4"
        echo "[DRY-RUN]   - Create persistence.conf"
        echo "[DRY-RUN]   - Install GRUB to ${device} MBR"
        [[ -n "$iso_file" ]] && echo "[DRY-RUN]   - Install ISO ${iso_file} to System A"
        return 0
    fi

    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root (use sudo)"
    [[ -b "$device" ]] || die "${device} is not a block device"

    local device_size
    device_size=$(get_device_size_bytes "$device")
    local min_size=$((24 * 1024 * 1024 * 1024))

    [[ "$device_size" -ge "$min_size" ]] || die "Device ${device} is too small ($(numfmt --to=iec "$device_size")). Minimum required: 24 GB (2x8GB system + 8GB persistence)"

    echo "=== Magic Stick A/B Setup ==="
    echo "Device: ${device} ($(numfmt --to=iec "$device_size"))"
    echo ""
    echo "This will create the following GPT partition layout:"
    echo "  Partition 1: ${SYSTEM_A_LABEL}    (8 GB)  - System A (GRUB default)"
    echo "  Partition 2: ${SYSTEM_B_LABEL}    (8 GB)  - System B"
    echo "  Partition 3: ${PERSISTENCE_LABEL} (rest)   - User data"
    echo ""
    echo "And install GRUB in the device MBR for dual-boot."
    echo ""
    echo "WARNING: This will ERASE ALL DATA on ${device}!"
    echo ""
    prompt_confirm || { echo "Aborted."; exit 0; }

    local prefix
    prefix=$(get_part_prefix "$device")

    echo ""
    info "Unmounting all partitions on ${device}..."
    for i in 1 2 3 4 5; do
        umount "${prefix}${i}" 2>/dev/null || true
    done
    umount "${device}"* 2>/dev/null || true

    info "Creating GPT partition table..."
    parted -s "$device" mklabel gpt

    info "Creating partition 1: ${SYSTEM_A_LABEL} (8 GB)..."
    parted -s "$device" mkpart "${SYSTEM_A_LABEL}" ext4 1MiB 8GiB
    parted -s "$device" set 1 boot on

    info "Creating partition 2: ${SYSTEM_B_LABEL} (8 GB)..."
    parted -s "$device" mkpart "${SYSTEM_B_LABEL}" ext4 8GiB 16GiB

    info "Creating partition 3: ${PERSISTENCE_LABEL} (rest)..."
    parted -s "$device" mkpart "${PERSISTENCE_LABEL}" ext4 16GiB 100%

    info "Informing kernel of partition changes..."
    partprobe "$device" 2>/dev/null || true
    sleep 2

    info "Formatting partitions..."
    mkfs.ext4 -L "${SYSTEM_A_LABEL}" "${prefix}1"
    mkfs.ext4 -L "${SYSTEM_B_LABEL}" "${prefix}2"
    mkfs.ext4 -L "${PERSISTENCE_LABEL}" "${prefix}3"

    local part_p="${prefix}3"
    local mount_point
    mount_point=$(mktemp -d)
    mount "${part_p}" "$mount_point"
    trap 'umount "${part_p}" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT

    info "Creating persistence configuration..."
    cat > "${mount_point}/persistence.conf" << 'EOF'
/ union
EOF

    info "Installing GRUB to device MBR..."
    install_grub "$device"

    echo ""
    echo "=== A/B Setup complete! ==="
    echo ""
    echo "Partition layout:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL "${device}"
    echo ""

    if [[ -n "$iso_file" ]]; then
        info "Installing ISO to System A..."
        cmd_install "$device" "$iso_file" "A"
    else
        echo "Next steps:"
        echo "  1. Install initial system:"
        echo "     sudo $0 install ${device} /path/to/magic-stick.iso A"
        echo ""
        echo "  2. Optional: install to System B:"
        echo "     sudo $0 install ${device} /path/to/magic-stick.iso B"
        echo ""
        echo "  3. Boot from USB and select System A or B in GRUB menu"
    fi
}

install_grub() {
    local device="$1"

    local prefix
    prefix=$(get_part_prefix "$device")
    local part_a="${prefix}1"

    local mount_point
    mount_point=$(mktemp -d)

    mount "${part_a}" "$mount_point" || die "Cannot mount ${part_a} for GRUB installation"
    trap 'sync; umount "${part_a}" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN

    mkdir -p "${mount_point}/boot/grub"

    generate_grub_cfg "${mount_point}/boot/grub/grub.cfg" "A"

    info "Installing GRUB BIOS (i386-pc) to ${device}..."
    grub-install --target=i386-pc \
        --boot-directory="${mount_point}/boot" \
        --force \
        "$device"

    if [[ -d /sys/firmware/efi ]] || [[ -d /boot/efi ]]; then
        info "UEFI firmware detected. Installing GRUB EFI..."
        local efi_dir="${mount_point}/boot/efi"
        mkdir -p "${efi_dir}"
        grub-install --target=x86_64-efi \
            --efi-directory="${efi_dir}" \
            --boot-directory="${mount_point}/boot" \
            --removable \
            --no-nvram \
            "$device" 2>/dev/null || warn "GRUB EFI installation failed (non-fatal for BIOS boot)"
    fi

    sync
}

generate_grub_cfg() {
    local cfg_file="$1"
    local default="$2"

    local default_entry
    if [[ "$default" == "B" ]]; then
        default_entry="1"
    else
        default_entry="0"
    fi

    cat > "$cfg_file" << GRUBCFG
# Magic Stick A/B Boot Configuration
# Generated by update-system.sh v${VERSION}
set default=${default_entry}
set timeout=10

serial --speed=115200
terminal_input console serial
terminal_output console serial

menuentry "Magic Stick - System A" {
    search --set=root --label ${SYSTEM_A_LABEL}
    linux /casper/vmlinuz boot=casper persistence persistence-label=${PERSISTENCE_LABEL} username=magic hostname=magic-stick locales=fr_FR.UTF-8 keyboard-layouts=fr quiet splash console=ttyS0,115200
    initrd /casper/initrd.img
}

menuentry "Magic Stick - System B" {
    search --set=root --label ${SYSTEM_B_LABEL}
    linux /casper/vmlinuz boot=casper persistence persistence-label=${PERSISTENCE_LABEL} username=magic hostname=magic-stick locales=fr_FR.UTF-8 keyboard-layouts=fr quiet splash console=ttyS0,115200
    initrd /casper/initrd.img
}

menuentry "Magic Stick - System A (nomodeset)" {
    search --set=root --label ${SYSTEM_A_LABEL}
    linux /casper/vmlinuz boot=casper persistence persistence-label=${PERSISTENCE_LABEL} username=magic hostname=magic-stick locales=fr_FR.UTF-8 keyboard-layouts=fr nomodeset console=ttyS0,115200
    initrd /casper/initrd.img
}

menuentry "Magic Stick - System B (nomodeset)" {
    search --set=root --label ${SYSTEM_B_LABEL}
    linux /casper/vmlinuz boot=casper persistence persistence-label=${PERSISTENCE_LABEL} username=magic hostname=magic-stick locales=fr_FR.UTF-8 keyboard-layouts=fr nomodeset console=ttyS0,115200
    initrd /casper/initrd.img
}
GRUBCFG
}

extract_iso_to_partition() {
    local iso_file="$1"
    local target_part="$2"
    local target_label="$3"

    info "Extracting ISO content to ${target_part} (${target_label})..."

    local iso_mount=""
    local mount_point=""
    local exit_code=0

    cleanup() {
        if [[ -n "$iso_mount" ]]; then
            umount "$iso_mount" 2>/dev/null || true
            rmdir "$iso_mount" 2>/dev/null || true
        fi
        if [[ -n "$mount_point" ]]; then
            sync
            umount "$mount_point" 2>/dev/null || true
            rmdir "$mount_point" 2>/dev/null || true
        fi
    }

    mount_point=$(mktemp -d)
    if ! mount "${target_part}" "$mount_point"; then
        rmdir "$mount_point" 2>/dev/null || true
        die "Cannot mount ${target_part}"
    fi

    info "Mounting ISO..."
    iso_mount=$(mktemp -d)
    if ! mount -o loop,ro "$iso_file" "$iso_mount"; then
        rmdir "$iso_mount" 2>/dev/null || true
        iso_mount=""
        cleanup
        die "Cannot mount ISO: ${iso_file} (may be corrupted)"
    fi

    local casper_dir=""
    for dir in "$iso_mount/casper" "$iso_mount/live"; do
        if [[ -d "$dir" ]]; then
            casper_dir="$dir"
            break
        fi
    done

    if [[ -z "$casper_dir" ]]; then
        cleanup
        die "No casper/ or live/ directory found in ISO"
    fi

    local casper_name
    casper_name=$(basename "$casper_dir")

    mkdir -p "${mount_point}/${casper_name}"

    info "Copying ${casper_name}/vmlinuz..."
    if [[ -f "${casper_dir}/vmlinuz" ]]; then
        if ! cp "${casper_dir}/vmlinuz" "${mount_point}/${casper_name}/vmlinuz" 2>&1; then
            cleanup
            die "Failed to copy vmlinuz (ISO may be truncated/corrupted)"
        fi
    elif [[ -f "${casper_dir}/vmlinuz.efi" ]]; then
        if ! cp "${casper_dir}/vmlinuz.efi" "${mount_point}/${casper_name}/vmlinuz"; then
            cleanup
            die "Failed to copy vmlinuz.efi"
        fi
    else
        cleanup
        die "vmlinuz not found in ISO"
    fi

    info "Copying ${casper_name}/initrd.img..."
    if [[ -f "${casper_dir}/initrd.img" ]]; then
        if ! cp "${casper_dir}/initrd.img" "${mount_point}/${casper_name}/initrd.img"; then
            cleanup
            die "Failed to copy initrd.img"
        fi
    elif [[ -f "${casper_dir}/initrd.lz" ]]; then
        if ! cp "${casper_dir}/initrd.lz" "${mount_point}/${casper_name}/initrd.img"; then
            cleanup
            die "Failed to copy initrd.lz"
        fi
    else
        cleanup
        die "initrd not found in ISO"
    fi

    info "Copying ${casper_name}/filesystem.squashfs..."
    local squashfs_path=""
    for path in "$iso_mount/casper/filesystem.squashfs" "$iso_mount/live/filesystem.squashfs"; do
        if [[ -f "$path" ]]; then
            squashfs_path="$path"
            break
        fi
    done

    if [[ -n "$squashfs_path" ]]; then
        if ! cp "$squashfs_path" "${mount_point}/${casper_name}/filesystem.squashfs"; then
            cleanup
            die "Failed to copy filesystem.squashfs"
        fi
    else
        cleanup
        die "filesystem.squashfs not found in ISO"
    fi

    cleanup
    info "ISO content installed to ${target_label}"
}

cmd_install() {
    local device="$1"
    local iso_file="$2"
    local target="${3:-A}"

    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root (use sudo)"
    [[ -b "$device" ]] || die "${device} is not a block device"
    [[ -f "$iso_file" ]] || die "ISO file not found: ${iso_file}"

    local prefix
    prefix=$(get_part_prefix "$device")

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would install ISO ${iso_file} to System ${target} on ${device}"
        echo "[DRY-RUN]   - Target partition: ${prefix}$([[ "$target" =~ ^[Aa]$ ]] && echo "1" || echo "2")"
        echo "[DRY-RUN]   - Extract vmlinuz, initrd.img, filesystem.squashfs"
        echo "[DRY-RUN]   - Re-install GRUB"
        return 0
    fi

    local target_label
    local target_part
    case "$target" in
        A|a)
            target_label="${SYSTEM_A_LABEL}"
            target_part="${prefix}1"
            ;;
        B|b)
            target_label="${SYSTEM_B_LABEL}"
            target_part="${prefix}2"
            ;;
        *)
            die "Invalid target: ${target}. Use A or B."
            ;;
    esac

    [[ -b "$target_part" ]] || die "Partition ${target_part} not found"

    local label
    label=$(blkid -s LABEL -o value "$target_part" 2>/dev/null || echo "")
    [[ "$label" == "$target_label" ]] || warn "Partition label is '${label}', expected '${target_label}'"

    echo "=== Magic Stick Install ==="
    echo "ISO:      ${iso_file}"
    echo "Device:   ${device}"
    echo "Target:   System ${target} (${target_part})"
    echo ""
    echo "This will write the ISO content to ${target_part}."
    echo "Data on this partition will be ERASED."
    echo "The persistence partition will NOT be touched."
    echo ""
    prompt_confirm || { echo "Aborted."; exit 0; }

    echo ""
    info "Unmounting target partition..."
    umount "${target_part}" 2>/dev/null || true

    extract_iso_to_partition "$iso_file" "$target_part" "$target_label"

    info "Re-installing GRUB..."
    install_grub "$device"

    echo ""
    echo "=== Install complete! ==="
    echo "System ${target} has been installed on ${target_part}."
    echo ""
    echo "To switch the default boot partition:"
    echo "  sudo $0 switch ${device}"
}

cmd_update() {
    local device="$1"
    local iso_file="${2:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would perform A/B update on ${device}"
        echo "[DRY-RUN]   - Detect active partition"
        echo "[DRY-RUN]   - Select inactive partition as target"
        echo "[DRY-RUN]   - Extract ISO contents to target partition"
        echo "[DRY-RUN]   - Switch GRUB default to target partition"
        echo "[DRY-RUN]   - Persistence partition left untouched"
        return 0
    fi

    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root (use sudo)"
    [[ -b "$device" ]] || die "${device} is not a block device"

    if [[ -z "$iso_file" ]]; then
        iso_file=$(ls -t "${BUILD_DIR}"/magic-stick_*.iso 2>/dev/null | head -1)
    fi

    [[ -f "$iso_file" ]] || die "No ISO file found. Run scripts/build.sh first."

    local prefix
    prefix=$(get_part_prefix "$device")

    local part_a="${prefix}1"
    local part_b="${prefix}2"

    echo "=== Magic Stick A/B Update ==="
    echo "ISO:    ${iso_file}"
    echo "Device: ${device}"
    echo ""

    for i in 1 2 3; do
        [[ -b "${prefix}${i}" ]] || die "Partition ${prefix}${i} not found. Run 'setup-ab' first."
    done

    local active
    active=$(detect_active_partition "$device")
    echo "Active partition: ${active}"

    local target_partition
    local target_label
    local target_part
    if [[ "$active" == "A" ]]; then
        target_partition="B"
        target_label="${SYSTEM_B_LABEL}"
        target_part="$part_b"
    else
        target_partition="A"
        target_label="${SYSTEM_A_LABEL}"
        target_part="$part_a"
    fi

    echo "Target: System ${target_partition} (${target_part})"
    echo ""
    echo "This will write the ISO content to ${target_part}."
    echo "The persistence partition will NOT be touched."
    echo ""
    prompt_confirm || { echo "Aborted."; exit 0; }

    echo ""
    info "Unmounting target partition..."
    umount "${target_part}" 2>/dev/null || true

    extract_iso_to_partition "$iso_file" "$target_part" "$target_label"

    info "Switching default boot to System ${target_partition}..."
    switch_grub_default "$device" "$target_partition"

    echo ""
    echo "=== Update complete! ==="
    echo "System ${target_partition} has been updated."
    echo "Default boot switched to System ${target_partition}."
    echo ""
    echo "Reboot to use the new system."
    echo "If it fails, select 'System ${active}' in the GRUB menu."
    echo ""
    echo "Persistence partition was NOT modified (user data safe)."
}

switch_grub_default() {
    local device="$1"
    local new_default="$2"

    local prefix
    prefix=$(get_part_prefix "$device")
    local part_a="${prefix}1"

    local mount_point
    mount_point=$(mktemp -d)

    mount "${part_a}" "$mount_point" 2>/dev/null || die "Cannot mount ${part_a}"
    trap 'sync; umount "${part_a}" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT

    generate_grub_cfg "${mount_point}/boot/grub/grub.cfg" "$new_default"
}

cmd_switch() {
    local device="$1"

    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root (use sudo)"
    [[ -b "$device" ]] || die "${device} is not a block device"

    local prefix
    prefix=$(get_part_prefix "$device")
    local part_a="${prefix}1"

    local current_default
    current_default=$(read_grub_default "$device")

    local new_default
    if [[ "$current_default" == "A" ]]; then
        new_default="B"
    else
        new_default="A"
    fi

    echo "=== Switching default boot partition ==="
    echo "Device: ${device}"
    echo "Current default: System ${current_default}"
    echo "New default:     System ${new_default}"
    echo ""

    switch_grub_default "$device" "$new_default"

    echo "Default boot partition switched to System ${new_default}."
    echo "Reboot to boot from System ${new_default}."
}

cmd_verify() {
    local device="$1"

    [[ -b "$device" ]] || die "${device} is not a block device"

    local prefix
    prefix=$(get_part_prefix "$device")

    echo "=== Magic Stick A/B Verification ==="
    echo "Device: ${device}"
    echo ""

    local errors=0

    echo "[1/5] Checking partition table..."
    local pt_type
    pt_type=$(parted -s "$device" print 2>/dev/null | grep "Partition Table:" | awk '{print $3}' || echo "")
    if [[ "$pt_type" == "gpt" ]]; then
        echo "  OK: GPT partition table"
    else
        echo "  FAIL: Expected GPT, got '${pt_type}'"
        ((errors++))
    fi

    echo "[2/5] Checking partition labels..."
    local part_a="${prefix}1"
    local part_b="${prefix}2"
    local part_p="${prefix}3"

    for part_num in 1 2 3; do
        local part="${prefix}${part_num}"
        local expected_label
        case "$part_num" in
            1) expected_label="${SYSTEM_A_LABEL}" ;;
            2) expected_label="${SYSTEM_B_LABEL}" ;;
            3) expected_label="${PERSISTENCE_LABEL}" ;;
        esac

        if [[ ! -b "$part" ]]; then
            echo "  FAIL: Partition ${part} not found"
            ((errors++))
            continue
        fi

        local label
        label=$(blkid -s LABEL -o value "$part" 2>/dev/null || echo "")
        if [[ "$label" == "$expected_label" ]]; then
            echo "  OK: ${part} label=${label}"
        else
            echo "  FAIL: ${part} label='${label}' (expected '${expected_label}')"
            ((errors++))
        fi
    done

    echo "[3/5] Checking system partition contents..."
    for part_num in 1 2; do
        local part="${prefix}${part_num}"
        local part_label
        part_label=$(blkid -s LABEL -o value "$part" 2>/dev/null || echo "?")
        local mount_point
        mount_point=$(mktemp -d)
        if mount -o ro "$part" "$mount_point" 2>/dev/null; then
            trap 'umount "$part" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT
            for f in vmlinuz initrd.img filesystem.squashfs; do
                if [[ -f "${mount_point}/${f}" ]]; then
                    echo "  OK: ${part_label}/${f}"
                else
                    echo "  WARN: ${part_label}/${f} not found"
                fi
            done
        else
            echo "  WARN: Cannot mount ${part} (may be empty)"
            rmdir "$mount_point" 2>/dev/null || true
        fi
    done

    echo "[4/5] Checking persistence..."
    local part_p_dev="${prefix}3"
    if [[ -b "$part_p_dev" ]]; then
        local mount_point
        mount_point=$(mktemp -d)
        if mount -o ro "$part_p_dev" "$mount_point" 2>/dev/null; then
            trap 'umount "$part_p_dev" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN EXIT
            if [[ -f "${mount_point}/persistence.conf" ]]; then
                echo "  OK: persistence.conf found"
            else
                echo "  WARN: persistence.conf not found"
            fi
        else
            echo "  WARN: Cannot mount persistence partition"
            rmdir "$mount_point" 2>/dev/null || true
        fi
    else
        echo "  FAIL: Persistence partition not found"
        ((errors++))
    fi

    echo "[5/5] Checking GRUB..."
    if [[ -f "/boot/grub/i386-pc/boot.img" ]] || command -v grub-install >/dev/null 2>&1; then
        echo "  OK: grub-install available"
    else
        echo "  WARN: grub-install not found"
    fi

    echo ""
    if [[ "$errors" -eq 0 ]]; then
        echo "=== Verification passed ==="
    else
        echo "=== Verification completed with ${errors} error(s) ==="
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            FORCE_YES=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    setup-ab)
        cmd_setup_ab "$@"
        ;;
    install)
        cmd_install "$@"
        ;;
    update)
        cmd_update "$@"
        ;;
    switch)
        cmd_switch "$@"
        ;;
    status)
        cmd_status "$1"
        ;;
    verify)
        cmd_verify "$1"
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown command: ${COMMAND}"
        usage
        exit 1
        ;;
esac