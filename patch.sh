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
VERSION="1.0.0"
ANTIGRAVITY_DATA_DIR="${ANTIGRAVITY_DATA_DIR:-}"  # Auto-detect if empty

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
    local candidates=(
        "$HOME/.antigravity-server"
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
        local required_features=("aes" "avx" "avx2" "bmi2" "pclmulqdq" "popcnt" "sse4_2")
        flags="$(grep 'flags' /proc/cpuinfo 2>/dev/null | head -1)"
        for feat in "${required_features[@]}"; do
            if echo "$flags" | grep -qw "$feat"; then
                echo -e "    $feat: ${GREEN}✓${NC}"
            else
                echo -e "    $feat: ${RED}✗ MISSING${NC}"
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
                echo -e "    $feat: ${RED}✗ MISSING${NC}"
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

# --- Generate Wrapper Script ---
generate_wrapper() {
    local qemu_path="$1"
    local ls_suffix="$2"
    cat <<WRAPPER
#!/bin/bash
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export GODEBUG=asyncpreemptoff=1
# Suppress TCMalloc rseq warnings printed directly to stderr by QEMU context
exec $qemu_path -cpu max "\$DIR/language_server_linux_${ls_suffix}.real" "\$@" 2> >(grep --line-buffered -v "RAW: rseq syscall failed" >&2)
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

        # Already patched?
        if [ -f "$ls_real" ]; then
            local size
            size="$(stat -c%s "$ls_bin" 2>/dev/null || echo "999999999")"
            if [ "$size" -lt 1000 ]; then
                success "Already patched — skipping"
                skipped=$((skipped + 1))
                continue
            fi
        fi

        # Original binary must exist
        if [ ! -f "$ls_bin" ] && [ ! -f "$ls_real" ]; then
            warn "No language server binary found — skipping"
            continue
        fi

        # Backup original
        if [ -f "$ls_bin" ] && [ ! -f "$ls_real" ]; then
            mv "$ls_bin" "$ls_real"
            info "Backed up original binary"
        fi

        # Write wrapper
        generate_wrapper "$qemu_path" "$LS_SUFFIX" > "$ls_bin"
        chmod +x "$ls_bin"

        # Verify
        local test_output test_exit=0
        test_output="$(timeout 5 "$ls_bin" --version 2>&1)" || test_exit=$?
        if echo "$test_output" | grep -qi "Illegal instruction"; then
            error "Patch verification FAILED — still getting SIGILL"
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

# --- Main ---
main() {
    local mode="patch"

    for arg in "$@"; do
        case "$arg" in
            --diagnose|-d) mode="diagnose" ;;
            --restore|-r)  mode="restore" ;;
            --help|-h)
                echo "Antigravity SIGILL Patch v${VERSION}"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --diagnose, -d    Check system without patching"
                echo "  --restore, -r     Remove patch, restore originals"
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
            echo -e "${BOLD}${CYAN}Antigravity SIGILL Patch v${VERSION} — Diagnostics${NC}"
            diagnose_cpu
            diagnose_qemu
            diagnose_ls
            ;;
        restore)
            do_restore
            ;;
        patch)
            do_patch
            ;;
    esac
}

main "$@"
