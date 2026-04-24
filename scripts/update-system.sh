#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"

VERSION="0.1.0"

usage() {
    echo "Magic Stick A/B System Updater v${VERSION}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup-ab <device>       Set up A/B partition layout on device"
    echo "  update <device> [iso]   Write new ISO to inactive partition"
    echo "  status <device>        Show current A/B partition status"
    echo ""
    echo "Partition layout (GPT):"
    echo "  /dev/sdX1  system_a      (~8 GB)  - System partition A (boot flag)"
    echo "  /dev/sdX2  system_b      (~8 GB)  - System partition B"
    echo "  /dev/sdX3  persistence  (rest)   - User data (never touched)"
    echo ""
    echo "WARNING: These commands modify partition tables and write to raw devices!"
}

get_part_prefix() {
    local device="$1"
    if [[ "$device" =~ ^/dev/(nvme|loop) ]]; then
        echo "${device}p"
    else
        echo "${device}"
    fi
}

cmd_status() {
    local device="$1"

    if [[ ! -b "$device" ]]; then
        echo "ERROR: ${device} is not a block device"
        exit 1
    fi

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

    local part_a="${prefix}1"
    local part_b="${prefix}2"
    local part_p="${prefix}3"

    echo "Partition layout:"
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
    echo "Active partition:"
    if mount | grep -q "${part_a}"; then
        echo "  System A (${part_a}) is mounted/active"
    elif mount | grep -q "${part_b}"; then
        echo "  System B (${part_b}) is mounted/active"
    else
        echo "  Cannot detect (device not mounted on this system)"
    fi
}

cmd_setup_ab() {
    local device="$1"

    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: This command must be run as root (use sudo)"
        exit 1
    fi

    if [[ ! -b "$device" ]]; then
        echo "ERROR: ${device} is not a block device"
        exit 1
    fi

    local device_size
    device_size=$(blockdev --getsize64 "$device" 2>/dev/null || echo 0)
    local min_size=$((16 * 1024 * 1024 * 1024))

    if [[ "$device_size" -lt "$min_size" ]]; then
        echo "ERROR: Device ${device} is too small ($(numfmt --to=iec "$device_size"))"
        echo "Minimum required: 16 GB (for 2x8GB system + persistence)"
        exit 1
    fi

    echo "=== Magic Stick A/B Setup ==="
    echo "Device: ${device} ($(numfmt --to=iec "$device_size"))"
    echo ""
    echo "This will create the following GPT partition layout:"
    echo "  Partition 1: system_a    (~8 GB)  - System A (bootable)"
    echo "  Partition 2: system_b    (~8 GB)  - System B"
    echo "  Partition 3: persistence (rest)   - User data"
    echo ""
    echo "WARNING: This will ERASE ALL DATA on ${device}!"
    echo ""
    read -p "Type 'YES' to continue: " confirm

    if [[ "$confirm" != "YES" ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Unmounting all partitions on ${device}..."
    local prefix
    prefix=$(get_part_prefix "$device")
    for i in 1 2 3 4 5; do
        umount "${prefix}${i}" 2>/dev/null || true
    done
    umount "${device}"* 2>/dev/null || true

    echo "Creating GPT partition table..."
    parted -s "$device" mklabel gpt

    echo "Creating partition 1: system_a (8 GB)..."
    parted -s "$device" mkpart system_a ext4 1MiB 8GiB
    parted -s "$device" set 1 boot on

    echo "Creating partition 2: system_b (8 GB)..."
    parted -s "$device" mkpart system_b ext4 8GiB 16GiB

    echo "Creating partition 3: persistence (rest)..."
    parted -s "$device" mkpart persistence ext4 16GiB 100%

    echo ""
    echo "Formatting partitions..."
    mkfs.ext4 -L system_a "${prefix}1"
    mkfs.ext4 -L system_b "${prefix}2"
    mkfs.ext4 -L persistence "${prefix}3"

    echo ""
    echo "Creating persistence configuration..."
    local mount_point
    mount_point=$(mktemp -d)
    mount "${prefix}3" "$mount_point"

    cat > "${mount_point}/persistence.conf" << 'EOF'
/m union
EOF

    umount "${prefix}3"
    rmdir "$mount_point" 2>/dev/null || true

    echo ""
    echo "=== A/B Setup complete! ==="
    echo ""
    echo "Partition layout:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL "${device}"
    echo ""
    echo "Next step: Flash the initial ISO"
    echo "  sudo ${SCRIPT_DIR}/flash.sh ${device}"
    echo ""
    echo "Then set up the second partition for A/B:"
    echo "  sudo $0 update ${device}"
}

cmd_update() {
    local device="$1"
    local iso_file="${2:-}"

    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: This command must be run as root (use sudo)"
        exit 1
    fi

    if [[ ! -b "$device" ]]; then
        echo "ERROR: ${device} is not a block device"
        exit 1
    fi

    if [[ -z "$iso_file" ]]; then
        iso_file=$(ls -t "${BUILD_DIR}"/magic_stick_*.iso 2>/dev/null | head -1)
    fi

    if [[ -z "$iso_file" ]] || [[ ! -f "$iso_file" ]]; then
        echo "ERROR: No ISO file found"
        echo "Run scripts/build.sh first."
        exit 1
    fi

    local prefix
    prefix=$(get_part_prefix "$device")

    local part_a="${prefix}1"
    local part_b="${prefix}2"
    local part_p="${prefix}3"

    echo "=== Magic Stick A/B Update ==="
    echo "ISO:    ${iso_file}"
    echo "Device: ${device}"
    echo ""

    echo "Checking partition layout..."
    for i in 1 2 3; do
        if [[ ! -b "${prefix}${i}" ]]; then
            echo "ERROR: Partition ${prefix}${i} not found"
            echo "Run '$0 setup-ab ${device}' first."
            exit 1
        fi
    done

    local label_a
    label_a=$(blkid -s LABEL -o value "$part_a" 2>/dev/null || echo "")
    local label_b
    label_b=$(blkid -s LABEL -o value "$part_b" 2>/dev/null || echo "")

    if [[ "$label_a" != "system_a" ]] || [[ "$label_b" != "system_b" ]]; then
        echo "WARNING: Partition labels don't match expected A/B layout"
        echo "  ${part_a}: label='${label_a}' (expected: system_a)"
        echo "  ${part_b}: label='${label_b}' (expected: system_b)"
        echo ""
        read -p "Continue anyway? (y/N): " cont
        if [[ "$cont" != "y" && "$cont" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    echo "Detecting active partition..."
    local active=""
    if mount | grep -q "$part_a"; then
        active="A"
        echo "  Active: System A ($part_a)"
    elif mount | grep -q "$part_b"; then
        active="B"
        echo "  Active: System B ($part_b)"
    else
        echo "  WARNING: Cannot detect active partition (not mounted)"
        echo "  Assuming System A is active"
        active="A"
    fi

    local target_partition=""
    local target_device=""
    if [[ "$active" == "A" ]]; then
        target_partition="B"
        target_device="$part_b"
    else
        target_partition="A"
        target_device="$part_a"
    fi

    echo "  Target: System ${target_partition} (${target_device})"
    echo ""
    echo "WARNING: This will write the ISO to ${target_device}!"
    echo "The persistence partition will NOT be touched."
    echo ""
    read -p "Type 'YES' to continue: " confirm

    if [[ "$confirm" != "YES" ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Unmounting target partition..."
    umount "${target_device}" 2>/dev/null || true

    echo "Writing ISO to ${target_device}..."
    dd if="$iso_file" of="$target_device" bs=4M status=progress conv=fsync

    echo ""
    echo "Updating boot flags..."
    if [[ "$target_partition" == "A" ]]; then
        parted -s "$device" set 1 boot on
        parted -s "$device" set 2 boot off
    else
        parted -s "$device" set 1 boot off
        parted -s "$device" set 2 boot on
    fi

    echo ""
    echo "Syncing..."
    sync

    echo ""
    echo "=== Update complete! ==="
    echo "System ${target_partition} has been updated."
    echo ""
    echo "If the new system fails to boot:"
    echo "  - Select 'System ${active}' in the boot menu"
    echo "  - This will boot the previous (known-working) system"
    echo ""
    echo "Persistence partition was NOT modified (user data safe)."
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    setup-ab)
        cmd_setup_ab "$1"
        ;;
    update)
        cmd_update "$@"
        ;;
    status)
        cmd_status "$1"
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