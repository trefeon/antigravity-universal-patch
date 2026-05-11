#!/bin/bash
# ============================================================================
# Antigravity SIGILL Patch
# Fix "Language server killed with signal SIGILL" on older CPUs
#
# Supports: ARM64 (aarch64) and x86_64 (amd64)
# Method:   QEMU user-mode emulation wrapper
#
# Usage:
#   ./patch.sh              # Auto-detect and patch
#   ./patch.sh --diagnose   # Check system without patching
#   ./patch.sh --restore    # Remove patch, restore original binaries
#
# Remote usage (from Windows PowerShell):
#   type patch.sh | ssh user@server "tr -d '\r' | bash -s"
#   type patch.sh | ssh user@server "tr -d '\r' | bash -s -- --diagnose"
#
# Remote usage (from Linux/macOS):
#   cat patch.sh | ssh user@server "bash -s"
#   cat patch.sh | ssh user@server "bash -s -- --diagnose"
# ============================================================================

set -euo pipefail

# --- Configuration ---
VERSION="1.4.0"
ANTIGRAVITY_DATA_DIR="${ANTIGRAVITY_DATA_DIR:-}"  # Auto-detect if empty
INSTALL_PATH="/usr/local/bin/antigravity-patch.sh"
SERVICE_NAME="antigravity-autopatch"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Helpers ---
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

# --- Architecture Detection ---
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            ARCH="x86_64"
            QEMU_BIN="qemu-x86_64"
            LS_SUFFIX="x64"
            ;;
        aarch64|arm64)
            ARCH="aarch64"
            QEMU_BIN="qemu-aarch64"
            LS_SUFFIX="arm"
            ;;
        *)
            error "Unsupported architecture: $machine"
            exit 1
            ;;
    esac
}

# --- Find Antigravity Data Directory ---
find_data_dir() {
    if [ -n "$ANTIGRAVITY_DATA_DIR" ]; then
        if [ -d "$ANTIGRAVITY_DATA_DIR" ]; then
            return 0
        else
            error "Specified ANTIGRAVITY_DATA_DIR does not exist: $ANTIGRAVITY_DATA_DIR"
            exit 1
        fi
    fi

    # Search common locations
    local home="${HOME:-/root}"
    local candidates=(
        "$home/.antigravity-server"
        "/root/.antigravity-server"
    )

    # Also check all home directories
    if [ -d /home ]; then
        for homedir in /home/*/; do
            candidates+=("${homedir}.antigravity-server")
        done
    fi

    for dir in "${candidates[@]}"; do
        if [ -d "$dir/bin" ]; then
            ANTIGRAVITY_DATA_DIR="$dir"
            return 0
        fi
    done

    error "Could not find Antigravity server installation."
    echo "  Searched: ${candidates[*]}"
    echo "  Set ANTIGRAVITY_DATA_DIR environment variable to specify the path manually."
    exit 1
}

# --- CPU Diagnosis ---
diagnose_cpu() {
    header "CPU Information"
    echo -e "  Architecture:  ${BOLD}$ARCH${NC}"
    echo -e "  Machine:       $(uname -m)"

    if [ "$ARCH" = "x86_64" ]; then
        local model flags
        model="$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"
        echo -e "  CPU Model:     ${BOLD}$model${NC}"

        echo ""
        echo "  Feature check:"
        local required_features=("aes" "avx" "avx2" "bmi1" "bmi2" "fma" "movbe" "pclmulqdq" "popcnt" "sse4_2")
        flags="$(grep 'flags' /proc/cpuinfo 2>/dev/null | head -1)"
        for feat in "${required_features[@]}"; do
            if echo "$flags" | grep -qw "$feat"; then
                echo -e "    $feat: ${GREEN}✓${NC}"
            else
                echo -e "    $feat: ${RED}✘ MISSING${NC}"
            fi
        done
    elif [ "$ARCH" = "aarch64" ]; then
        local model features
        model="$(grep 'model name\|CPU part' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"
        echo -e "  CPU Model:     ${BOLD}$model${NC}"

        echo ""
        echo "  Feature check:"
        local required_features=("atomics" "lrcpc" "dcpop" "uscat" "sha512")
        features="$(grep 'Features' /proc/cpuinfo 2>/dev/null | head -1)"
        for feat in "${required_features[@]}"; do
            if echo "$features" | grep -qw "$feat"; then
                echo -e "    $feat: ${GREEN}✓${NC}"
            else
                echo -e "    $feat: ${RED}✘ MISSING${NC}"
            fi
        done
    fi
}

diagnose_ls() {
    header "Language Server Status"

    find_data_dir
    echo -e "  Data dir: $ANTIGRAVITY_DATA_DIR"

    local found=0
    for bin_dir in "$ANTIGRAVITY_DATA_DIR"/bin/*/extensions/antigravity/bin; do
        [ -d "$bin_dir" ] || continue
        found=1

        local ls_bin="$bin_dir/language_server_linux_$LS_SUFFIX"
        local ls_real="$bin_dir/language_server_linux_$LS_SUFFIX.real"
        local version_dir
        version_dir="$(echo "$bin_dir" | grep -oP 'bin/\K[^/]+')"

        echo ""
        echo -e "  Version: ${BOLD}$version_dir${NC}"

        if [ -f "$ls_real" ]; then
            echo -e "  Status:  ${GREEN}PATCHED${NC} (QEMU wrapper active)"
        elif [ -f "$ls_bin" ]; then
            # Test if binary runs
            local test_output
            test_output="$(timeout 3 "$ls_bin" --version 2>&1 || true)"
            if echo "$test_output" | grep -qi "SIGILL\|Illegal instruction\|FATAL ERROR\|signal 4"; then
                echo -e "  Status:  ${RED}BROKEN${NC} (SIGILL crash detected)"
                echo -e "  Error:   $(echo "$test_output" | head -1)"
            else
                echo -e "  Status:  ${GREEN}OK${NC} (binary runs natively)"
            fi
        else
            echo -e "  Status:  ${YELLOW}NOT FOUND${NC}"
        fi
    done

    if [ "$found" -eq 0 ]; then
        warn "No Antigravity server installations found in $ANTIGRAVITY_DATA_DIR/bin/"
    fi
}

diagnose_qemu() {
    header "QEMU Status"

    if command -v "$QEMU_BIN" &>/dev/null; then
        local qemu_path qemu_ver
        qemu_path="$(which "$QEMU_BIN")"
        qemu_ver="$("$QEMU_BIN" --version 2>/dev/null | head -1 || echo 'unknown')"
        echo -e "  ${GREEN}Installed${NC}: $qemu_path"
        echo -e "  Version: $qemu_ver"
    elif command -v "${QEMU_BIN}-static" &>/dev/null; then
        local qemu_path qemu_ver
        qemu_path="$(which "${QEMU_BIN}-static")"
        qemu_ver="$("${QEMU_BIN}-static" --version 2>/dev/null | head -1 || echo 'unknown')"
        echo -e "  ${GREEN}Installed (static)${NC}: $qemu_path"
        echo -e "  Version: $qemu_ver"
        QEMU_BIN="${QEMU_BIN}-static"
    else
        echo -e "  ${RED}Not installed${NC}"
        echo "  Install with:"
        if command -v apt-get &>/dev/null; then
            echo "    sudo apt-get install -y qemu-user"
        elif command -v dnf &>/dev/null; then
            echo "    sudo dnf install -y qemu-user"
        elif command -v pacman &>/dev/null; then
            echo "    sudo pacman -S qemu-user"
        elif command -v apk &>/dev/null; then
            echo "    sudo apk add qemu-$ARCH"
        fi
    fi
}

# --- Install QEMU ---
install_qemu() {
    if command -v "$QEMU_BIN" &>/dev/null; then
        return 0
    fi
    if command -v "${QEMU_BIN}-static" &>/dev/null; then
        QEMU_BIN="${QEMU_BIN}-static"
        return 0
    fi

    info "Installing QEMU user-mode emulation..."

    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq qemu-user 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q qemu-user 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q qemu-user 2>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm qemu-user 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --quiet "qemu-$ARCH" 2>/dev/null
    elif command -v zypper &>/dev/null; then
        zypper install -y -q qemu-linux-user 2>/dev/null
    else
        error "Cannot install QEMU: no supported package manager found."
        echo "  Please install '$QEMU_BIN' manually and re-run this script."
        exit 1
    fi

    # Verify installation
    if command -v "$QEMU_BIN" &>/dev/null; then
        success "QEMU installed: $(which "$QEMU_BIN")"
    elif command -v "${QEMU_BIN}-static" &>/dev/null; then
        QEMU_BIN="${QEMU_BIN}-static"
        success "QEMU installed: $(which "$QEMU_BIN")"
    else
        error "QEMU installation failed. Please install '$QEMU_BIN' manually."
        exit 1
    fi
}

# --- Detect optimal QEMU CPU model ---
detect_qemu_cpu() {
    if [ "$ARCH" != "x86_64" ]; then
        echo "max"
        return
    fi

    # Map host CPU microarchitecture to QEMU model + missing features
    local flags cpu_family cpu_model
    flags="$(grep 'flags' /proc/cpuinfo 2>/dev/null | head -1)"
    cpu_family="$(grep 'cpu family' /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}')"
    cpu_model="$(grep -P '^\s*model\s+:' /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}')"

    local qemu_cpu="max"  # safe default
    local missing_features=""

    # Detect missing features that the LS binary requires
    local required_features=("aes" "avx" "avx2" "bmi1" "bmi2" "fma" "movbe" "pclmulqdq" "popcnt" "sse4_2")
    for feat in "${required_features[@]}"; do
        if ! echo "$flags" | grep -qw "$feat"; then
            missing_features="${missing_features},+${feat}"
        fi
    done

    # Match by cpu family:model (reliable across all naming schemes)
    # Reference: https://en.wikichip.org/wiki/intel/cpuid
    if [ "$cpu_family" = "6" ]; then
        case "$cpu_model" in
            15)        qemu_cpu="Conroe-v1${missing_features}" ;;       # Conroe/Merom
            23)        qemu_cpu="Penryn-v1${missing_features}" ;;       # Penryn
            26|30|46)  qemu_cpu="Nehalem-v2${missing_features}" ;;      # Nehalem
            37|44|47)  qemu_cpu="Westmere-v2${missing_features}" ;;     # Westmere/Arrandale
            42)        qemu_cpu="SandyBridge-v2${missing_features}" ;;  # Sandy Bridge
            58)        qemu_cpu="IvyBridge-v2${missing_features}" ;;    # Ivy Bridge
            60|69|70)  qemu_cpu="Haswell-v4${missing_features}" ;;      # Haswell
            61|71)     qemu_cpu="Broadwell-v4${missing_features}" ;;    # Broadwell
            78|94)     qemu_cpu="Skylake-Client-v4${missing_features}" ;; # Skylake
            85)        qemu_cpu="Cascadelake-Server-v5${missing_features}" ;; # Cascade Lake
            *)         qemu_cpu="max" ;;  # Unknown Intel model
        esac
    fi

    echo "$qemu_cpu"
}

# --- Generate Wrapper Script ---
generate_wrapper() {
    local qemu_path="$1"
    local ls_suffix="$2"
    local qemu_cpu="$3"
    cat <<WRAPPER
#!/bin/bash
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export GODEBUG=asyncpreemptoff=1
export MALLOC_ARENA_MAX=2
export GOMAXPROCS=1
# Disable tcache to prevent double-free crashes under emulation
export GLIBC_TUNABLES=glibc.malloc.tcache_count=0
# Lower priority + larger translation cache for smoother CPU usage
exec nice -n 10 $qemu_path -cpu $qemu_cpu "\$DIR/language_server_linux_${ls_suffix}.real" "\$@" 2> >(grep --line-buffered -v "RAW: rseq" >&2)
WRAPPER
}

# --- Patch ---
do_patch() {
    header "Antigravity SIGILL Patch v${VERSION}"
    echo -e "  Architecture: ${BOLD}$ARCH${NC}"
    echo -e "  QEMU binary:  $QEMU_BIN"

    find_data_dir
    echo -e "  Data dir:     $ANTIGRAVITY_DATA_DIR"

    install_qemu

    local qemu_path
    qemu_path="$(which "$QEMU_BIN")"

    local patched=0
    local skipped=0
    local failed=0

    for bin_dir in "$ANTIGRAVITY_DATA_DIR"/bin/*/extensions/antigravity/bin; do
        [ -d "$bin_dir" ] || continue

        local ls_bin="$bin_dir/language_server_linux_$LS_SUFFIX"
        local ls_real="$bin_dir/language_server_linux_$LS_SUFFIX.real"
        local version_dir
        version_dir="$(echo "$bin_dir" | grep -oP 'bin/\K[^/]+')"

        echo ""
        info "Processing: $version_dir"

        local qemu_cpu
        qemu_cpu="$(detect_qemu_cpu)"
        info "QEMU CPU model: $qemu_cpu"

        # Already patched?
        if [ -f "$ls_real" ]; then
            local size
            size="$(stat -c%s "$ls_bin" 2>/dev/null || echo "999999999")"
            if [ "$size" -lt 1000 ]; then
                # Already patched, but update the wrapper to ensure latest logic
                generate_wrapper "$qemu_path" "$LS_SUFFIX" "$qemu_cpu" > "$ls_bin"
                chmod +x "$ls_bin"
                chown --reference="$ls_real" "$ls_bin"
                success "Updated wrapper: $version_dir"
                patched=$((patched + 1))
                continue
            fi
        fi

        # Original binary must exist
        if [ ! -f "$ls_bin" ] && [ ! -f "$ls_real" ]; then
            warn "No language server binary found Ã¢â‚¬â€ skipping"
            continue
        fi

        # Backup original
        if [ -f "$ls_bin" ] && [ ! -f "$ls_real" ]; then
            mv "$ls_bin" "$ls_real"
            info "Backed up original binary"
        fi

        # Write wrapper
        local qemu_cpu
        qemu_cpu="$(detect_qemu_cpu)"
        info "QEMU CPU model: $qemu_cpu"
        generate_wrapper "$qemu_path" "$LS_SUFFIX" "$qemu_cpu" > "$ls_bin"
        chmod +x "$ls_bin"
        chown --reference="$ls_real" "$ls_bin"

        # Verify
        local test_output test_exit=0
        test_output="$(timeout 5 "$ls_bin" --version 2>&1)" || test_exit=$?
        if echo "$test_output" | grep -qi "Illegal instruction"; then
            error "Patch verification FAILED Ã¢â‚¬â€ still getting SIGILL"
            # Restore original
            mv "$ls_real" "$ls_bin"
            failed=$((failed + 1))
        else
            success "Patched successfully"
            patched=$((patched + 1))
        fi
    done

    header "Results"
    echo -e "  Patched:  ${GREEN}$patched${NC}"
    echo -e "  Skipped:  ${YELLOW}$skipped${NC} (already patched)"
    [ "$failed" -gt 0 ] && echo -e "  Failed:   ${RED}$failed${NC}"
    echo ""

    if [ "$patched" -gt 0 ] || [ "$skipped" -gt 0 ]; then
        success "Done! Reconnect from the IDE to activate the fix."
    elif [ "$failed" -gt 0 ]; then
        error "Patching failed. Please open an issue with your CPU info."
        exit 1
    else
        warn "No installations found to patch."
    fi
}

# --- Restore ---
do_restore() {
    header "Restoring Original Binaries"

    find_data_dir

    local restored=0
    for bin_dir in "$ANTIGRAVITY_DATA_DIR"/bin/*/extensions/antigravity/bin; do
        [ -d "$bin_dir" ] || continue

        local ls_bin="$bin_dir/language_server_linux_$LS_SUFFIX"
        local ls_real="$bin_dir/language_server_linux_$LS_SUFFIX.real"

        if [ -f "$ls_real" ]; then
            mv -f "$ls_real" "$ls_bin"
            success "Restored: $(basename "$(dirname "$(dirname "$(dirname "$bin_dir")")")")"
            restored=$((restored + 1))
        fi
    done

    if [ "$restored" -eq 0 ]; then
        info "Nothing to restore."
    else
        success "Restored $restored installation(s). Reconnect from the IDE."
    fi
}

# --- Watch Mode (persistent background daemon) ---
do_watch() {
    header "Antigravity Auto-Patcher v${VERSION} Ã¢â‚¬â€ Watch Mode"

    find_data_dir
    install_qemu

    local watch_dir="$ANTIGRAVITY_DATA_DIR/bin"
    info "Watching: $watch_dir"
    info "Architecture: $ARCH"

    # Patch anything unpatched right now
    do_patch_quiet

    # Prefer inotifywait for instant detection, fall back to polling
    if command -v inotifywait &>/dev/null; then
        info "Using inotifywait (real-time detection)"
        # Watch for new files/dirs created under bin/
        # -m = monitor (don't exit), -r = recursive, -q = quiet
        inotifywait -m -r -q -e create,moved_to "$watch_dir" 2>/dev/null |
        while read -r dir event file; do
            # Trigger on language_server binary or new version directory
            if [[ "$file" == language_server_linux_* ]] || [[ "$event" == *ISDIR* ]]; then
                # Debounce Ã¢â‚¬â€ let Antigravity finish writing all files
                sleep 8
                do_patch_quiet
            fi
        done
    else
        warn "inotifywait not found Ã¢â‚¬â€ using 30s polling fallback"
        warn "Install inotify-tools for instant detection"
        while true; do
            sleep 30
            do_patch_quiet
        done
    fi
}

# --- Quiet patch (for watch/daemon mode) ---
do_patch_quiet() {
    local qemu_path
    qemu_path="$(which "$QEMU_BIN" 2>/dev/null || which "${QEMU_BIN}-static" 2>/dev/null || true)"
    [ -z "$qemu_path" ] && return 1

    for bin_dir in "$ANTIGRAVITY_DATA_DIR"/bin/*/extensions/antigravity/bin; do
        [ -d "$bin_dir" ] || continue

        local ls_bin="$bin_dir/language_server_linux_$LS_SUFFIX"
        local ls_real="$bin_dir/language_server_linux_$LS_SUFFIX.real"

        # Already patched Ã¢â‚¬â€ skip silently
        if [ -f "$ls_real" ]; then
            local size
            size="$(stat -c%s "$ls_bin" 2>/dev/null || echo "999999999")"
            [ "$size" -lt 1000 ] && continue
        fi

        # No binary Ã¢â‚¬â€ skip
        [ -f "$ls_bin" ] || [ -f "$ls_real" ] || continue

        # Needs patching
        local version_dir
        version_dir="$(echo "$bin_dir" | grep -oP 'bin/\K[^/]+')"
        info "New binary detected Ã¢â‚¬â€ patching: $version_dir"

        if [ -f "$ls_bin" ] && [ ! -f "$ls_real" ]; then
            mv "$ls_bin" "$ls_real"
        fi

        local qemu_cpu
        qemu_cpu="$(detect_qemu_cpu)"
        generate_wrapper "$qemu_path" "$LS_SUFFIX" "$qemu_cpu" > "$ls_bin"
        chmod +x "$ls_bin"
        chown --reference="$ls_real" "$ls_bin"
        success "Auto-patched: $version_dir (cpu=$qemu_cpu)"
    done
}

# --- Install Auto-Patch Service ---
do_install() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Installation requires root."
        exit 1
    fi

    header "Installing Auto-Patch Service v${VERSION}"

    # Copy script to install path
    local source="${BASH_SOURCE[0]:-$0}"
    if [ -f "$source" ] && [ "$source" != "bash" ] && [ "$source" != "-bash" ] && [ "$source" != "-" ]; then
        cp "$source" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        success "Script installed to $INSTALL_PATH"
    else
        error "Cannot install from piped input."
        echo "  Copy to server first, then run: ./patch.sh --install"
        exit 1
    fi

    # Install inotify-tools for real-time detection (non-fatal if fails)
    if ! command -v inotifywait &>/dev/null; then
        info "Installing inotify-tools..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq inotify-tools 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf install -y -q inotify-tools 2>/dev/null || true
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm inotify-tools 2>/dev/null || true
        elif command -v apk &>/dev/null; then
            apk add --quiet inotify-tools 2>/dev/null || true
        fi
        if command -v inotifywait &>/dev/null; then
            success "inotify-tools installed"
        else
            warn "inotify-tools not available Ã¢â‚¬â€ will use 30s polling fallback"
        fi
    else
        success "inotify-tools already installed"
    fi

    # Stop old timer-based service if exists
    systemctl stop ${SERVICE_NAME}.timer 2>/dev/null || true
    systemctl disable ${SERVICE_NAME}.timer 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.timer

    # Create systemd service (persistent watcher)
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<UNIT
[Unit]
Description=Antigravity SIGILL Auto-Patcher (filesystem watcher)
After=network.target
StartLimitBurst=5
StartLimitIntervalSec=300

[Service]
Type=simple
ExecStart=$INSTALL_PATH --watch
Restart=always
RestartSec=30
Environment=HOME=/root
StandardOutput=journal
StandardError=journal
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
UNIT
    success "Created ${SERVICE_NAME}.service (persistent watcher)"

    # Enable and start
    systemctl daemon-reload
    systemctl enable --now ${SERVICE_NAME}.service 2>/dev/null
    success "Service enabled and started"

    # Show status
    echo ""
    systemctl status ${SERVICE_NAME}.service --no-pager -l 2>/dev/null || true
}

# --- Uninstall Auto-Patch Service ---
do_uninstall() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Uninstallation requires root."
        exit 1
    fi

    header "Removing Auto-Patch Service"

    systemctl stop ${SERVICE_NAME}.service 2>/dev/null || true
    systemctl disable ${SERVICE_NAME}.service 2>/dev/null || true
    systemctl stop ${SERVICE_NAME}.timer 2>/dev/null || true
    systemctl disable ${SERVICE_NAME}.timer 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    rm -f /etc/systemd/system/${SERVICE_NAME}.timer
    systemctl daemon-reload 2>/dev/null
    success "Systemd units removed"

    rm -f "$INSTALL_PATH"
    success "Script removed from $INSTALL_PATH"

    info "Existing patches on binaries are preserved."
    info "Use --restore to remove patches from binaries."
}

# --- Main ---
main() {
    local mode="patch"

    for arg in "$@"; do
        case "$arg" in
            --diagnose|-d) mode="diagnose" ;;
            --restore|-r)  mode="restore" ;;
            --install|-i)  mode="install" ;;
            --uninstall)   mode="uninstall" ;;
            --watch|-w)    mode="watch" ;;
            --help|-h)
                echo "Antigravity SIGILL Patch v${VERSION}"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --diagnose, -d    Check system without patching"
                echo "  --restore, -r     Remove patch, restore originals"
                echo "  --install, -i     Install auto-patch background service"
                echo "  --uninstall       Remove auto-patch service"
                echo "  --watch, -w       Run filesystem watcher (used by service)"
                echo "  --help, -h        Show this help"
                echo ""
                echo "Environment:"
                echo "  ANTIGRAVITY_DATA_DIR   Override auto-detected data directory"
                exit 0
                ;;
            *)
                error "Unknown option: $arg"
                exit 1
                ;;
        esac
    done

    detect_arch

    case "$mode" in
        diagnose)
            echo -e "${BOLD}${CYAN}Antigravity SIGILL Patch v${VERSION} Ã¢â‚¬â€ Diagnostics${NC}"
            diagnose_cpu
            diagnose_qemu
            diagnose_ls
            ;;
        restore)
            do_restore
            ;;
        install)
            do_install
            ;;
        uninstall)
            do_uninstall
            ;;
        watch)
            do_watch
            ;;
        patch)
            do_patch
            ;;
    esac
}

main "$@"
