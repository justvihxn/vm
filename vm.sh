#!/bin/bash
set -Eeuo pipefail

# ==============================================================
# Justvihxn VM MANAGER v5.1
# QEMU/KVM + cloud-init VM manager for Linux hosts
#
# Supported: Ubuntu 24.04/22.04, Debian 12, Rocky Linux 9,
#            AlmaLinux 9
#
# Notes:
# - KVM is used automatically when /dev/kvm is available.
# - Without KVM, QEMU software emulation is used.
# - Disk resizing is expansion-only for safety.
# - VM configuration files contain the VM password and are chmod 600.
# ==============================================================

VERSION="5.1"
VM_DIR="${VM_DIR:-${HOME:-/root}/vms}"
mkdir -p "$VM_DIR"
umask 077

KVM_AVAILABLE=false
QEMU_CMD=()
VMS=()

# -------------------- UI helpers --------------------

print_status() {
    local type="${1:-INFO}"
    local message="${2:-}"

    case "$type" in
        INFO)    printf '\033[1;34m[INFO]\033[0m %s\n' "$message" ;;
        WARN)    printf '\033[1;33m[WARN]\033[0m %s\n' "$message" ;;
        ERROR)   printf '\033[1;31m[ERROR]\033[0m %s\n' "$message" ;;
        SUCCESS) printf '\033[1;32m[SUCCESS]\033[0m %s\n' "$message" ;;
        INPUT)   printf '\033[1;36m[INPUT]\033[0m %s' "$message" ;;
        *)       printf '[%s] %s\n' "$type" "$message" ;;
    esac
}

pause_screen() {
    read -r -p "$(print_status INPUT 'Press Enter to continue...')" _ || true
}

display_header() {
    clear 2>/dev/null || true
    printf '\033[1;35m==============================================================\033[0m\n'
  cat <<'EOF'
      _                 _             _   _                    
     | |  _   _   ___  | |_  __   __ (_) | |__   __  __  _ __  
  _  | | | | | | / __| | __| \ \ / / | | | '_ \  \ \/ / | '_ \ 
 | |_| | | |_| | \__ \ | |_   \ V /  | | | | | |  >  <  | | | |
  \___/   \__,_| |___/  \__|   \_/   |_| |_| |_| /_/\_\ |_| |_| EOF
    printf '\n'
    printf '                 Justvihxn VM MANAGER v%s\n' "$VERSION"
    printf '              QEMU • KVM • Cloud-Init • Linux\n'
    printf '\033[1;35m==============================================================\033[0m\n\n'
    print '\n'
    printf ' Hostname     : %s\n' "$(hostname)"
    printf ' User         : %s\n' "$(whoami)"
    printf ' Kernel       : %s\n' "$(uname -r)"
    printf ' Architecture : %s\n' "$(uname -m)"
}

# -------------------- Validation --------------------

validate_number() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_positive_number() {
    validate_number "${1:-}" && ((10#$1 > 0))
}

validate_size() {
    [[ "${1:-}" =~ ^[0-9]+([GgMm])$ ]]
}

validate_port() {
    validate_number "${1:-}" && ((10#$1 >= 1 && 10#$1 <= 65535))
}

validate_name() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$ ]]
}

validate_username() {
    [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_port_forwards() {
    local spec="${1:-}"
    local item host_port guest_port
    local -a items=()

    [[ -z "$spec" ]] && return 0

    IFS=',' read -r -a items <<< "$spec"

    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"

        if [[ "$item" != *:* ]]; then
            print_status ERROR "Invalid port forward '$item'; use host:guest"
            return 1
        fi

        host_port="${item%%:*}"
        guest_port="${item##*:}"

        if ! validate_port "$host_port" || ! validate_port "$guest_port"; then
            print_status ERROR "Invalid port forward '$item'; ports must be 1-65535"
            return 1
        fi
    done

    return 0
}

# -------------------- Paths/config --------------------

vm_config_path() {
    printf '%s/%s.conf' "$VM_DIR" "$1"
}

vm_pid_path() {
    printf '%s/%s.pid' "$VM_DIR" "$1"
}

vm_log_path() {
    printf '%s/%s.log' "$VM_DIR" "$1"
}

vm_image_path() {
    printf '%s/%s.qcow2' "$VM_DIR" "$1"
}

vm_seed_path() {
    printf '%s/%s-seed.iso' "$VM_DIR" "$1"
}

# -------------------- VM state --------------------

is_vm_running() {
    local vm_name="$1"
    local pid_file pid cmd

    pid_file="$(vm_pid_path "$vm_name")"

    [[ -f "$pid_file" ]] || return 1

    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || {
        rm -f "$pid_file"
        return 1
    }

    if kill -0 "$pid" 2>/dev/null; then
        cmd="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$cmd" == "qemu-system-x86_64" ]]; then
            return 0
        fi
    fi

    rm -f "$pid_file"
    return 1
}

get_vm_list() {
    local file base
    shopt -s nullglob

    for file in "$VM_DIR"/*.conf; do
        base="${file##*/}"
        printf '%s\n' "${base%.conf}"
    done | sort

    shopt -u nullglob
}

load_vm_config() {
    local vm_name="$1"
    local config_file

    if ! validate_name "$vm_name"; then
        print_status ERROR "Invalid VM name"
        return 1
    fi

    config_file="$(vm_config_path "$vm_name")"

    if [[ ! -f "$config_file" ]]; then
        print_status ERROR "Configuration for VM '$vm_name' not found"
        return 1
    fi

    unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
    unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS
    unset IMG_FILE SEED_FILE CREATED PID_FILE LOG_FILE

    # shellcheck disable=SC1090
    source "$config_file"

    return 0
}

save_vm_config() {
    local config_file
    config_file="$(vm_config_path "$VM_NAME")"

    umask 077

    cat > "$config_file" <<EOF
VM_NAME=$(printf '%q' "$VM_NAME")
OS_TYPE=$(printf '%q' "$OS_TYPE")
CODENAME=$(printf '%q' "$CODENAME")
IMG_URL=$(printf '%q' "$IMG_URL")
HOSTNAME=$(printf '%q' "$HOSTNAME")
USERNAME=$(printf '%q' "$USERNAME")
PASSWORD=$(printf '%q' "$PASSWORD")
DISK_SIZE=$(printf '%q' "$DISK_SIZE")
MEMORY=$(printf '%q' "$MEMORY")
CPUS=$(printf '%q' "$CPUS")
SSH_PORT=$(printf '%q' "$SSH_PORT")
GUI_MODE=$(printf '%q' "$GUI_MODE")
PORT_FORWARDS=$(printf '%q' "$PORT_FORWARDS")
IMG_FILE=$(printf '%q' "$IMG_FILE")
SEED_FILE=$(printf '%q' "$SEED_FILE")
CREATED=$(printf '%q' "$CREATED")
PID_FILE=$(printf '%q' "$PID_FILE")
LOG_FILE=$(printf '%q' "$LOG_FILE")
EOF

    chmod 600 "$config_file"
}

# -------------------- Dependencies/host --------------------

check_dependencies() {
    local commands=(
        qemu-system-x86_64
        qemu-img
        wget
        cloud-localds
        openssl
        ss
        numfmt
    )
    local missing=()
    local cmd

    for cmd in "${commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    print_status WARN "Missing dependencies: ${missing[*]}"

    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        print_status INFO "Attempting to install required Ubuntu/Debian packages..."

        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y \
            qemu-system-x86 \
            qemu-utils \
            cloud-image-utils \
            wget \
            openssl \
            iproute2 \
            coreutils

        local still_missing=()
        for cmd in "${commands[@]}"; do
            command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
        done

        if ((${#still_missing[@]})); then
            print_status ERROR "Still missing: ${still_missing[*]}"
            return 1
        fi

        print_status SUCCESS "Dependencies installed"
        return 0
    fi

    print_status ERROR "Install these packages and run the script again:"
    print_status INFO "Ubuntu/Debian: apt install qemu-system-x86 qemu-utils cloud-image-utils wget openssl iproute2 coreutils"
    return 1
}

check_host_virtualization() {
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        KVM_AVAILABLE=true
    else
        KVM_AVAILABLE=false
    fi
}

# -------------------- cloud-init --------------------

generate_cloud_init() {
    local user_hash
    local user_data="$VM_DIR/${VM_NAME}-user-data"
    local meta_data="$VM_DIR/${VM_NAME}-meta-data"

    # The password itself is not put into cloud-init's chpasswd section.
    # The SHA-512 hash is sufficient for the user's initial password.
    user_hash="$(openssl passwd -6 "$PASSWORD")"

    umask 077

    cat > "$user_data" <<EOF
#cloud-config
hostname: $HOSTNAME
fqdn: $HOSTNAME
manage_etc_hosts: true
ssh_pwauth: true
disable_root: false

users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $user_hash

ssh_authorized_keys: []

package_update: false
package_upgrade: false
EOF

    cat > "$meta_data" <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    chmod 600 "$user_data" "$meta_data"

    printf '%s\n' "$user_data" "$meta_data"
}

setup_vm_image() {
    local user_data meta_data

    print_status INFO "Preparing VM image..."

    mkdir -p "$VM_DIR"

    if [[ ! -f "$IMG_FILE" ]]; then
        print_status INFO "Downloading image from $IMG_URL..."

        if ! wget --progress=dot:giga -O "$IMG_FILE.tmp" "$IMG_URL"; then
            rm -f "$IMG_FILE.tmp"
            print_status ERROR "Failed to download image"
            return 1
        fi

        if ! qemu-img info "$IMG_FILE.tmp" >/dev/null 2>&1; then
            rm -f "$IMG_FILE.tmp"
            print_status ERROR "Downloaded file is not a valid QEMU disk image"
            return 1
        fi

        mv "$IMG_FILE.tmp" "$IMG_FILE"
        chmod 600 "$IMG_FILE"
    else
        print_status INFO "Image already exists; skipping download."
    fi

    # Only expand an image. Never delete it to force a resize.
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" >/dev/null 2>&1; then
        print_status WARN "Image was not resized to $DISK_SIZE (it may already be that size or larger)."
    fi

    user_data="$VM_DIR/${VM_NAME}-user-data"
    meta_data="$VM_DIR/${VM_NAME}-meta-data"

    generate_cloud_init >/dev/null

    if ! cloud-localds "$SEED_FILE" "$user_data" "$meta_data"; then
        print_status ERROR "Failed to create cloud-init seed image"
        return 1
    fi

    chmod 600 "$SEED_FILE"

    # These source files are no longer needed after cloud-localds.
    rm -f "$user_data" "$meta_data"

    print_status SUCCESS "VM image and cloud-init seed prepared"
}

# -------------------- OS definitions --------------------

declare -A OS_OPTIONS=(
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|debian12|debian|debian"
    ["Rocky Linux 9"]="rocky|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
)

# -------------------- VM creation --------------------

create_new_vm() {
    print_status INFO "Creating a new VM"

    local -a os_names=()
    local idx=1 os choice
    local DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD
    local gui_input

    echo

    for os in "${!OS_OPTIONS[@]}"; do
        os_names[$idx]="$os"
        printf '  %d) %s\n' "$idx" "$os"
        idx=$((idx + 1))
    done

    while true; do
        read -r -p "$(print_status INPUT "Choose OS (1-${#os_names[@]}): ")" choice

        if validate_number "$choice" &&
           ((10#$choice >= 1 && 10#$choice <= ${#os_names[@]})); then
            os="${os_names[$((10#$choice))]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL \
                DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD \
                <<< "${OS_OPTIONS[$os]}"
            break
        fi

        print_status ERROR "Invalid selection"
    done

    while true; do
        read -r -p "$(print_status INPUT "VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"

        if validate_name "$VM_NAME" && [[ ! -e "$(vm_config_path "$VM_NAME")" ]]; then
            break
        fi

        print_status ERROR "Invalid or already-used VM name"
    done

    while true; do
        read -r -p "$(print_status INPUT "Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"

        if validate_name "$HOSTNAME"; then
            break
        fi

        print_status ERROR "Invalid hostname"
    done

    while true; do
        read -r -p "$(print_status INPUT "Username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"

        if validate_username "$USERNAME"; then
            break
        fi

        print_status ERROR "Invalid username"
    done

    while true; do
        read -r -s -p "$(print_status INPUT "Password (Enter for default): ")" PASSWORD
        echo
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"

        if [[ -n "$PASSWORD" ]]; then
            break
        fi

        print_status ERROR "Password cannot be empty"
    done

    while true; do
        read -r -p "$(print_status INPUT "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"

        if validate_size "$DISK_SIZE"; then
            break
        fi

        print_status ERROR "Use a size such as 20G or 512M"
    done

    while true; do
        read -r -p "$(print_status INPUT "Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"

        if validate_positive_number "$MEMORY"; then
            break
        fi

        print_status ERROR "Memory must be a positive number"
    done

    while true; do
        read -r -p "$(print_status INPUT "CPU count (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"

        if validate_positive_number "$CPUS"; then
            break
        fi

        print_status ERROR "CPU count must be a positive number"
    done

    while true; do
        read -r -p "$(print_status INPUT "SSH host port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"

        if ! validate_port "$SSH_PORT"; then
            print_status ERROR "Invalid port"
            continue
        fi

        if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])$SSH_PORT$"; then
            print_status ERROR "Port $SSH_PORT is already in use"
            continue
        fi

        break
    done

    while true; do
        read -r -p "$(print_status INPUT "Enable GUI mode? (y/N): ")" gui_input
        gui_input="${gui_input:-n}"

        case "$gui_input" in
            y|Y) GUI_MODE=true; break ;;
            n|N) GUI_MODE=false; break ;;
            *) print_status ERROR "Please answer y or n" ;;
        esac
    done

    while true; do
        read -r -p "$(print_status INPUT "Extra TCP forwards host:guest, comma-separated (optional): ")" PORT_FORWARDS

        if validate_port_forwards "$PORT_FORWARDS"; then
            break
        fi
    done

    IMG_FILE="$(vm_image_path "$VM_NAME")"
    SEED_FILE="$(vm_seed_path "$VM_NAME")"
    PID_FILE="$(vm_pid_path "$VM_NAME")"
    LOG_FILE="$(vm_log_path "$VM_NAME")"
    CREATED="$(date '+%Y-%m-%d %H:%M:%S %z')"

    setup_vm_image || return 1
    save_vm_config

    print_status SUCCESS "VM '$VM_NAME' created"
}

# -------------------- QEMU command --------------------

build_qemu_command() {
    local idx=1
    local item host_port guest_port
    local -a forward_items=()

    QEMU_CMD=(
        qemu-system-x86_64
        -name "$VM_NAME"
        -m "$MEMORY"
        -smp "$CPUS"
        -drive "file=$IMG_FILE,if=virtio,format=qcow2"
        -drive "file=$SEED_FILE,if=virtio,format=raw,readonly=on"
        -boot order=c
        -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
        -device "virtio-net-pci,netdev=net0"
        -device virtio-balloon-pci
        -object "rng-random,filename=/dev/urandom,id=rng0"
        -device "virtio-rng-pci,rng=rng0"
    )

    if [[ -n "$PORT_FORWARDS" ]]; then
        IFS=',' read -r -a forward_items <<< "$PORT_FORWARDS"

        for item in "${forward_items[@]}"; do
            item="${item//[[:space:]]/}"
            host_port="${item%%:*}"
            guest_port="${item##*:}"

            QEMU_CMD+=(
                -netdev "user,id=net${idx},hostfwd=tcp::$host_port-:$guest_port"
                -device "virtio-net-pci,netdev=net${idx}"
            )

            idx=$((idx + 1))
        done
    fi

    check_host_virtualization

    if [[ "$KVM_AVAILABLE" == true ]]; then
        QEMU_CMD+=(
            -enable-kvm
            -cpu host
        )
    else
        QEMU_CMD+=(
            -cpu qemu64
        )
    fi

    if [[ "$GUI_MODE" == true && -n "${DISPLAY:-}" ]]; then
        QEMU_CMD+=(
            -vga virtio
            -display gtk
        )
    else
        if [[ "$GUI_MODE" == true ]]; then
            print_status WARN "No DISPLAY detected; using headless mode."
        fi

        QEMU_CMD+=(
            -nographic
            -serial mon:stdio
        )
    fi
}

# -------------------- VM lifecycle --------------------

start_vm() {
    local vm_name="$1"
    local pid

    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status WARN "VM '$vm_name' is already running"
        return 0
    fi

    [[ -f "$IMG_FILE" ]] || {
        print_status ERROR "Image not found: $IMG_FILE"
        return 1
    }

    if [[ ! -f "$SEED_FILE" ]]; then
        print_status INFO "Cloud-init seed is missing; rebuilding..."
        setup_vm_image || return 1
    fi

    validate_port_forwards "$PORT_FORWARDS" || return 1

    build_qemu_command

    print_status INFO "Starting VM '$vm_name'"
    print_status INFO "SSH: ssh -p $SSH_PORT $USERNAME@localhost"

    # GUI mode needs to remain attached to its display environment.
    # Headless mode is logged so the manager stays usable over SSH.
    if [[ "$GUI_MODE" == true && -n "${DISPLAY:-}" ]]; then
        "${QEMU_CMD[@]}" >>"$LOG_FILE" 2>&1 &
    else
        "${QEMU_CMD[@]}" >>"$LOG_FILE" 2>&1 &
    fi

    pid=$!
    echo "$pid" > "$PID_FILE"
    chmod 600 "$PID_FILE" "$LOG_FILE" 2>/dev/null || true

    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        print_status SUCCESS "VM '$vm_name' started (PID $pid)"
        print_status INFO "QEMU log: $LOG_FILE"
    else
        rm -f "$PID_FILE"
        print_status ERROR "QEMU exited immediately"
        tail -n 30 "$LOG_FILE" 2>/dev/null || true
        return 1
    fi
}

stop_vm() {
    local vm_name="$1"
    local pid

    load_vm_config "$vm_name" || return 1

    if ! is_vm_running "$vm_name"; then
        print_status INFO "VM '$vm_name' is not running"
        return 0
    fi

    pid="$(cat "$PID_FILE")"

    print_status INFO "Stopping VM '$vm_name' (PID $pid)"

    kill -TERM "$pid" 2>/dev/null || true

    for _ in {1..40}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            print_status SUCCESS "VM '$vm_name' stopped"
            return 0
        fi
        sleep 0.25
    done

    print_status WARN "Graceful stop timed out; forcing termination"
    kill -KILL "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"

    print_status SUCCESS "VM '$vm_name' stopped"
}

show_vm_info() {
    local vm_name="$1"

    load_vm_config "$vm_name" || return 1

    echo
    echo "=========================================="
    echo "VM:             $VM_NAME"
    echo "OS:             $OS_TYPE $CODENAME"
    echo "Hostname:       $HOSTNAME"
    echo "Username:       $USERNAME"
    echo "SSH Port:       $SSH_PORT"
    echo "Memory:         $MEMORY MB"
    echo "CPUs:           $CPUS"
    echo "Disk target:    $DISK_SIZE"
    echo "GUI Mode:       $GUI_MODE"
    echo "Port Forwards:  ${PORT_FORWARDS:-None}"
    echo "Image:          $IMG_FILE"
    echo "Seed:           $SEED_FILE"
    echo "Log:            $LOG_FILE"
    echo "Created:        $CREATED"

    if is_vm_running "$vm_name"; then
        echo "Status:         Running"
        echo "PID:            $(cat "$PID_FILE")"
    else
        echo "Status:         Stopped"
    fi

    echo "=========================================="
}

# -------------------- Disk management --------------------

resize_vm_disk() {
    local vm_name="$1"
    local new_disk_size current_bytes new_bytes

    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status ERROR "Stop the VM before resizing its disk"
        return 1
    fi

    while true; do
        read -r -p "$(print_status INPUT 'New disk size (e.g. 50G): ')" new_disk_size

        if ! validate_size "$new_disk_size"; then
            print_status ERROR "Invalid disk size"
            continue
        fi

        current_bytes="$(
            qemu-img info --output=json "$IMG_FILE" 2>/dev/null |
            sed -n 's/.*"virtual-size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
            head -n 1
        )"

        new_bytes="$(numfmt --from=iec "$new_disk_size" 2>/dev/null || true)"

        if [[ "$current_bytes" =~ ^[0-9]+$ && "$new_bytes" =~ ^[0-9]+$ ]]; then
            if ((new_bytes <= current_bytes)); then
                print_status ERROR "New size must be larger than the current virtual size"
                print_status INFO "Disk shrinking is intentionally disabled for safety"
                continue
            fi
        fi

        if qemu-img resize "$IMG_FILE" "$new_disk_size"; then
            DISK_SIZE="$new_disk_size"
            save_vm_config
            print_status SUCCESS "Disk expanded to $new_disk_size"
            return 0
        fi

        print_status ERROR "Disk resize failed"
        return 1
    done
}

# -------------------- Configuration editing --------------------

edit_vm_config() {
    local vm_name="$1"
    local edit_choice v

    load_vm_config "$vm_name" || return 1

    while true; do
        echo
        echo "1) Hostname"
        echo "2) Username"
        echo "3) Password"
        echo "4) SSH Port"
        echo "5) GUI Mode"
        echo "6) Port Forwards"
        echo "7) Memory"
        echo "8) CPU Count"
        echo "9) Disk Size (expand only)"
        echo "0) Back"

        read -r -p "$(print_status INPUT 'Choice: ')" edit_choice

        case "$edit_choice" in
            1)
                read -r -p "$(print_status INPUT 'New hostname: ')" v
                validate_name "$v" || {
                    print_status ERROR "Invalid hostname"
                    continue
                }
                HOSTNAME="$v"
                setup_vm_image || continue
                save_vm_config
                ;;
            2)
                read -r -p "$(print_status INPUT 'New username: ')" v
                validate_username "$v" || {
                    print_status ERROR "Invalid username"
                    continue
                }
                USERNAME="$v"
                setup_vm_image || continue
                save_vm_config
                ;;
            3)
                read -r -s -p "$(print_status INPUT 'New password: ')" v
                echo

                [[ -n "$v" ]] || {
                    print_status ERROR "Password cannot be empty"
                    continue
                }

                PASSWORD="$v"
                setup_vm_image || continue
                save_vm_config
                ;;
            4)
                read -r -p "$(print_status INPUT 'New SSH port: ')" v

                validate_port "$v" || {
                    print_status ERROR "Invalid port"
                    continue
                }

                if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])$v$"; then
                    print_status ERROR "Port $v is already in use"
                    continue
                fi

                SSH_PORT="$v"
                save_vm_config
                ;;
            5)
                read -r -p "$(print_status INPUT 'GUI? (y/n): ')" v

                case "$v" in
                    y|Y) GUI_MODE=true ;;
                    n|N) GUI_MODE=false ;;
                    *) print_status ERROR "Invalid choice"; continue ;;
                esac

                save_vm_config
                ;;
            6)
                read -r -p "$(print_status INPUT 'Port forwards host:guest,...: ')" v

                validate_port_forwards "$v" || continue

                PORT_FORWARDS="$v"
                save_vm_config
                ;;
            7)
                read -r -p "$(print_status INPUT 'Memory MB: ')" v

                validate_positive_number "$v" || {
                    print_status ERROR "Invalid memory"
                    continue
                }

                MEMORY="$v"
                save_vm_config
                ;;
            8)
                read -r -p "$(print_status INPUT 'CPU count: ')" v

                validate_positive_number "$v" || {
                    print_status ERROR "Invalid CPU count"
                    continue
                }

                CPUS="$v"
                save_vm_config
                ;;
            9)
                resize_vm_disk "$vm_name"
                ;;
            0)
                return 0
                ;;
            *)
                print_status ERROR "Invalid selection"
                ;;
        esac
    done
}

# -------------------- Delete/performance --------------------

delete_vm() {
    local vm_name="$1"
    local confirm

    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status WARN "VM is running; stop it first"
        return 1
    fi

    read -r -p "$(print_status INPUT "Delete VM '$vm_name' and all its data? (y/N): ")" confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status INFO "Deletion cancelled"
        return 0
    fi

    rm -f \
        "$IMG_FILE" \
        "$SEED_FILE" \
        "$VM_DIR/${VM_NAME}-user-data" \
        "$VM_DIR/${VM_NAME}-meta-data" \
        "$(vm_config_path "$vm_name")" \
        "$PID_FILE" \
        "$LOG_FILE"

    print_status SUCCESS "VM '$vm_name' deleted"
}

show_vm_performance() {
    local vm_name="$1"
    local pid

    load_vm_config "$vm_name" || return 1

    if ! is_vm_running "$vm_name"; then
        print_status INFO "VM '$vm_name' is not running"
        return 0
    fi

    pid="$(cat "$PID_FILE")"

    echo
    echo "QEMU process:"
    ps -p "$pid" -o pid,%cpu,%mem,rss,vsz,etime,cmd --no-headers || true

    echo
    echo "Host memory:"
    free -h

    echo
    echo "Disk image:"
    qemu-img info "$IMG_FILE" 2>/dev/null || true

    echo
    echo "Disk usage:"
    du -h "$IMG_FILE" 2>/dev/null || true
}

# -------------------- VM selection --------------------

select_vm() {
    local prompt="${1:-VM number:}"
    local vm_num selected

    mapfile -t VMS < <(get_vm_list)

    if ((${#VMS[@]} == 0)); then
        print_status ERROR "No VMs exist"
        return 1
    fi

    echo
    local i status

    for i in "${!VMS[@]}"; do
        if is_vm_running "${VMS[$i]}"; then
            status="Running"
        else
            status="Stopped"
        fi

        printf '  %2d) %-24s [%s]\n' \
            "$((i + 1))" "${VMS[$i]}" "$status"
    done

    while true; do
        read -r -p "$(print_status INPUT "$prompt ")" vm_num

        if validate_number "$vm_num" &&
           ((10#$vm_num >= 1 && 10#$vm_num <= ${#VMS[@]})); then
            selected="${VMS[$((10#$vm_num - 1))]}"
            printf '%s\n' "$selected"
            return 0
        fi

        print_status ERROR "Invalid VM number"
    done
}

# -------------------- Main menu --------------------

main_menu() {
    local choice selected

    while true; do
        display_header

        mapfile -t VMS < <(get_vm_list)

        echo "Virtual Machines:"

        if ((${#VMS[@]} == 0)); then
            echo "  No VMs created yet."
        else
            local i status

            for i in "${!VMS[@]}"; do
                if is_vm_running "${VMS[$i]}"; then
                    status="Running"
                else
                    status="Stopped"
                fi

                printf '  %2d) %-24s [%s]\n' \
                    "$((i + 1))" "${VMS[$i]}" "$status"
            done
        fi

        echo
        echo "Main Menu:"
        echo "  1) Create a new VM"

        if ((${#VMS[@]} > 0)); then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
        fi

        echo "  0) Exit"
        echo

        read -r -p "$(print_status INPUT 'Enter your choice: ')" choice

        case "$choice" in
            1)
                create_new_vm
                pause_screen
                ;;
            2)
                if selected="$(select_vm "VM number: ")"; then
                    start_vm "$selected"
                fi
                pause_screen
                ;;
            3)
                if selected="$(select_vm "VM number: ")"; then
                    stop_vm "$selected"
                fi
                pause_screen
                ;;
            4)
                if selected="$(select_vm "VM number: ")"; then
                    show_vm_info "$selected"
                fi
                pause_screen
                ;;
            5)
                if selected="$(select_vm "VM number: ")"; then
                    edit_vm_config "$selected"
                fi
                pause_screen
                ;;
            6)
                if selected="$(select_vm "VM number: ")"; then
                    delete_vm "$selected"
                fi
                pause_screen
                ;;
            7)
                if selected="$(select_vm "VM number: ")"; then
                    resize_vm_disk "$selected"
                fi
                pause_screen
                ;;
            8)
                if selected="$(select_vm "VM number: ")"; then
                    show_vm_performance "$selected"
                fi
                pause_screen
                ;;
            0)
                print_status INFO "Goodbye!"
                return 0
                ;;
            *)
                print_status ERROR "Invalid option"
                pause_screen
                ;;
        esac
    done
}

# -------------------- Entry point --------------------

if [[ $EUID -ne 0 ]]; then
    print_status WARN "Running as non-root. VM files will be stored under $VM_DIR."
fi

if ! check_dependencies; then
    exit 1
fi

check_host_virtualization

if [[ "$KVM_AVAILABLE" == true ]]; then
    print_status SUCCESS "KVM is available; hardware acceleration enabled."
else
    print_status WARN "KVM is unavailable; QEMU software emulation will be used."
fi

main_menu
