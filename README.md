# 🩹 Antigravity SIGILL Patch

**Fix Antigravity IDE's "Language server killed with signal SIGILL" crash on older CPUs.**

Antigravity (Google's VS Code fork) ships a language server binary compiled for modern CPUs. On older processors that lack certain instruction set extensions, the binary crashes immediately with `SIGILL` (Illegal Instruction), breaking all AI features (code completion, chat, inline suggestions).

This project provides a **zero-config, one-command fix** using QEMU user-mode emulation to transparently run the binary with full CPU feature emulation.

## 🔴 The Problem

When connecting to a remote server via SSH Remote, Antigravity installs and runs a language server binary. This binary is compiled with CPU features that older processors don't support:

| Architecture | Required Feature | Affected CPUs |
|---|---|---|
| **ARM64** (aarch64) | LSE Atomics, SHA-512 | Cortex-A53, Cortex-A35, all ARMv8.0 |
| **x86_64** (amd64) | AES-NI, AVX2, FMA, BMI1/2, MOVBE | Pre-Haswell Intel, Pre-Excavator AMD |

### Error in logs
```
(Antigravity) Language server killed with signal SIGILL
(Antigravity) Failed to start language server: Error: Language server exited before sending start data
```

Or on x86:
```
FATAL ERROR: This binary was compiled with aes enabled, but this feature is not available on this processor
```

## ✅ The Fix

We use **QEMU user-mode emulation** to wrap the language server binary. QEMU emulates the host CPU microarchitecture with only the missing instruction sets added, minimizing emulation overhead.

### How it works
1. The original binary is renamed to `language_server_linux_*.real`
2. A tiny bash wrapper takes its place
3. The wrapper runs the real binary through QEMU with host-matched CPU emulation
4. Antigravity sees no difference — the fix is completely transparent

## 🚀 Quick Start

### One-liner (run on your LOCAL machine)
```bash
# For a remote server accessible via SSH:
cat patch.sh | ssh user@your-server "bash -s"

# From Windows (PowerShell):
type patch.sh | ssh user@your-server "tr -d '\r' | bash -s"
```

### Direct on the server
```bash
curl -fsSL https://raw.githubusercontent.com/trefeon/antigravity-universal-patch/main/patch.sh | bash
# or
wget -qO- https://raw.githubusercontent.com/trefeon/antigravity-universal-patch/main/patch.sh | bash
```

### Manual
```bash
git clone https://github.com/trefeon/antigravity-universal-patch.git
cd antigravity-universal-patch
chmod +x patch.sh
./patch.sh
```

## 📋 Requirements

- **Linux** (Debian/Ubuntu, Fedora/RHEL, Arch, Alpine supported)
- **Root access** or sudo privileges (for installing QEMU)
- **~70MB disk space** for QEMU user-mode package

## ⚙️ Advanced Usage

### Diagnose without patching
```bash
./patch.sh --diagnose
```

### Unpatch (restore original binary)
```bash
./patch.sh --restore
```

### Install auto-patch service (persistent)
```bash
sudo ./patch.sh --install
```
This installs a systemd service that watches for Antigravity updates and automatically re-patches new binaries using `inotifywait`. No more manual re-patching after updates.

### Uninstall auto-patch service
```bash
sudo ./patch.sh --uninstall
```

### Patch specific server data directory
```bash
ANTIGRAVITY_DATA_DIR=/custom/path ./patch.sh
```

## 🔄 After Antigravity Updates

**With auto-patch service installed** (`--install`): patches are applied automatically within seconds of an update. No action needed.

**Without the service**: re-run the patch manually after each Antigravity server update:

```bash
cat patch.sh | ssh user@your-server "bash -s"
```

## 🧪 Tested On

| Device | CPU | Architecture | Status |
|---|---|---|---|
| Amlogic S9xx Box | Cortex-A53 (ARMv8.0) | aarch64 | ✅ Working |
| Acer Laptop | Intel i3-2330M (Sandy Bridge) | x86_64 | ✅ Working |
| Acer Laptop | Intel i3-M330 (Westmere) | x86_64 | ✅ Working |
| Raspberry Pi 3 | Cortex-A53 | aarch64 | Should work |
| Raspberry Pi 2 | Cortex-A7 (ARMv7) | armhf | Not supported* |

\* ARMv7 (32-bit) is a different architecture entirely and not supported by Antigravity's server.

## 📝 How It Works (Technical Details)

QEMU user-mode emulation translates CPU instructions at runtime. When running on the same base architecture (e.g., x86_64 on x86_64), QEMU's TCG (Tiny Code Generator) translates only the instructions the physical CPU can't execute natively.

### Intelligent CPU Matching

Instead of using a generic `-cpu max` (which emulates everything and wastes CPU), the patch **detects the host CPU microarchitecture** and selects the closest QEMU model, adding only the missing instruction sets:

| Host CPU | QEMU Model | Added Extensions |
|---|---|---|
| Westmere (i3-M330) | `Westmere-v2` | `+aes,+avx,+avx2,+bmi1,+bmi2,+fma,+movbe,+pclmulqdq` |
| Sandy/Ivy Bridge | `SandyBridge-v2` | `+aes,+avx2,+bmi1,+bmi2,+fma,+movbe` |
| ARM Cortex-A53 | `max` | Full emulation (different ISA level) |

This reduces TCG translation overhead by **40-60%** compared to `-cpu max` on x86 hosts.

### Performance Tuning (v1.4.0)

The wrapper applies several performance optimizations for smooth operation on low-resource hardware:

| Setting | Purpose |
|---|---|
| `GOMAXPROCS=1` | Limits Go runtime to 1 thread — reduces synchronization overhead under emulation |
| `nice -n 10` | Lowers QEMU scheduling priority so the host system stays responsive |
| `GODEBUG=asyncpreemptoff=1` | Disables Go async preemption that causes deadlocks under QEMU emulation |
| `MALLOC_ARENA_MAX=2` | Reduces glibc heap fragmentation on low-RAM systems |

### Additional Fixes
- **Thread Hang Fix**: Go binaries compiled for newer systems heavily utilize asynchronous preemption for their garbage collectors. QEMU user-mode emulation struggles translating these rapid signal interruptions, leading to deadlocks/hanging. The `GODEBUG=asyncpreemptoff=1` flag ensures the language server runs rock-solid under emulation.
- **Log Noise Suppression**: Under QEMU emulation, Google's TCMalloc/Abseil will trip up on the `rseq` (Restartable Sequences) syscall and spam the IDE logs with harmless but confusing warnings. The wrapper filters these out (`grep -v`) for a clean experience.

### Performance Impact
The language server runs under partial emulation, so there's a ~1.5-3x CPU overhead (reduced from ~2-4x with the generic `-cpu max` approach). Since the LS is primarily I/O-bound (waiting for API responses, processing text), the impact on real-world usage is **minimal and imperceptible** for most workflows. Idle CPU usage is typically **4-8%**.

## 📄 License

MIT License — see [LICENSE](LICENSE).
