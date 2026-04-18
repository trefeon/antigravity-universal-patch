# 🩹 Antigravity SIGILL Patch

**Fix Antigravity IDE's "Language server killed with signal SIGILL" crash on older CPUs.**

Antigravity (Google's VS Code fork) ships a language server binary compiled for modern CPUs. On older processors that lack certain instruction set extensions, the binary crashes immediately with `SIGILL` (Illegal Instruction), breaking all AI features (code completion, chat, inline suggestions).

This project provides a **zero-config, one-command fix** using QEMU user-mode emulation to transparently run the binary with full CPU feature emulation.

## 🔴 The Problem

When connecting to a remote server via SSH Remote, Antigravity installs and runs a language server binary. This binary is compiled with CPU features that older processors don't support:

| Architecture | Required Feature | Affected CPUs |
|---|---|---|
| **ARM64** (aarch64) | LSE Atomics (ARMv8.1+) | Cortex-A53, Cortex-A35, all ARMv8.0 |
| **x86_64** (amd64) | AES-NI, AVX2, BMI2 | Pre-Haswell Intel, Pre-Excavator AMD |

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

We use **QEMU user-mode emulation** to wrap the language server binary. QEMU emulates a CPU with all modern features (`-cpu max`), allowing the binary to run on any processor of the same base architecture.

### How it works
1. The original binary is renamed to `language_server_linux_*.real`
2. A tiny bash wrapper takes its place
3. The wrapper runs the real binary through `qemu-{arch} -cpu max`
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

### Patch specific server data directory
```bash
ANTIGRAVITY_DATA_DIR=/custom/path ./patch.sh
```

## 🔄 After Antigravity Updates

When Antigravity updates its server component, the patch needs to be re-applied (the old patched version is cleaned up by the updater). Simply re-run:

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

QEMU user-mode emulation translates CPU instructions at runtime. When running on the same base architecture (e.g., aarch64 on aarch64), QEMU's TCG (Tiny Code Generator) translates all instructions, including the ones the physical CPU doesn't support.

With `-cpu max`, QEMU emulates the most capable CPU possible for the architecture, including:
- **ARM64**: ARMv9 with SVE, LSE atomics, BTI, MTE, etc.
- **x86_64**: All extensions up to AVX-512, AES-NI, BMI2, etc.

### Advanced Fixes Applied
- **Thread Hang Fix**: Go binaries compiled for newer systems heavily utilize asynchronous preemption for their garbage collectors. QEMU user-mode emulation struggles translating these rapid signal interruptions, leading to deadlocks/hanging. The script sets `GODEBUG=asyncpreemptoff=1` to ensure the Antigravity language server runs rock-solid under emulation.
- **Log Noise Suppression**: Under QEMU emulation, Google's TCMalloc/Abseil will trip up on the `rseq` (Restartable Sequences) syscall and spam the IDE logs with harmless but confusing warnings. The wrapper filters these out (`grep -v`) for a clean experience.

### Performance Impact
The language server runs under full emulation, so there's a ~2-4x CPU overhead. However, since the LS is primarily I/O-bound (waiting for LSP requests, processing text), the impact on real-world usage is **minimal and imperceptible** for most workflows.

## 📄 License

MIT License — see [LICENSE](LICENSE).
