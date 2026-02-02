# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Padavan firmware project based on the rt-n56u codebase with Linux kernel 4.4.198. It builds custom router firmware for MT7621-based devices (MIPS architecture) with support for various wireless chips (MT7615D/MT7615N/MT7915D).

## Build System Architecture

### Toolchain Setup

The project uses a MIPSEL cross-compilation toolchain located in `toolchain-mipsel/`:
- **Recommended**: Download prebuilt toolchain: `cd toolchain-mipsel && ./dl_toolchain.sh`
- **Alternative**: Build from source: `./build_toolchain` (takes significantly longer)
- Toolchain path is set via `CONFIG_TOOLCHAIN_DIR` and defaults to `toolchain-mipsel/toolchain-4.4.x`

### Build Commands

**From `trunk/` directory** (all builds must be run with `fakeroot`):

```bash
# Build firmware for a specific device
fakeroot ./build_firmware_modify DEVICE_NAME

# Example for K2P router
fakeroot ./build_firmware_modify K2P

# Clean build tree (REQUIRED between different device builds)
./clear_tree

# Individual component builds
make linux          # Build kernel only
make libc_only      # Build C library
make libs_only      # Build libraries
make user_only      # Build userspace applications
make romfs          # Build ROM filesystem
make image          # Generate final firmware image
```

### Configuration System

The build system uses a three-level configuration:

1. **Device Templates** (`trunk/configs/templates/*.config`): High-level firmware feature selection
   - Controls which packages/features to include (SS, AdGuard, Zerotier, etc.)
   - Configuration options use `CONFIG_FIRMWARE_INCLUDE_*` prefix

2. **Board Configs** (`trunk/configs/boards/DEVICE_NAME/`):
   - `board.h`: Hardware definitions (flash size, antenna config, USB support)
   - `board.mk`: Board-specific build rules
   - `kernel-4.4.x.config`: Kernel configuration for the device

3. **Project Config** (`trunk/.config`): Generated from template during build

### Firmware Customization in build_firmware_modify

The `build_firmware_modify` script automatically modifies the device template to include/exclude features. Key customizations are done via sed commands and echo statements to `.config`:

- Enable/disable packages: `echo "CONFIG_FIRMWARE_INCLUDE_SHADOWSOCKS=y" >> .config`
- CPU overclocking: `CONFIG_FIRMWARE_INCLUDE_OC=y` and `CONFIG_FIRMWARE_MT7621_OC="0x312"`
- The script will skip auto-customization if a second parameter is passed

## Directory Structure

```
trunk/
├── linux-4.4.x/               # Linux kernel source
│   └── arch/mips/boot/dts/ralink/  # Device tree files for MT7621 devices
├── configs/
│   ├── templates/             # Device-specific .config templates
│   └── boards/                # Per-device board configs (board.h, board.mk, kernel configs)
├── user/                      # Userspace applications and scripts
│   ├── scripts/               # System scripts (automount, monitoring, etc.)
│   ├── busybox/               # BusyBox configuration
│   └── shared/                # Shared headers and makefiles
├── vendors/Ralink/            # Vendor-specific build configuration
├── libc/                      # C library
├── libs/                      # Third-party libraries
├── tools/                     # Build tools and utilities
├── romfs/                     # Generated: ROM filesystem staging area
└── images/                    # Generated: Final firmware images (*.trx)

toolchain-mipsel/              # MIPSEL cross-compilation toolchain
```

## Adding New Device Support

1. Create device tree file: `trunk/linux-4.4.x/arch/mips/boot/dts/ralink/DEVICE.dts`
2. Create board directory: `trunk/configs/boards/DEVICE/`
   - Add `board.h` with hardware definitions
   - Add `board.mk` with build rules
   - Add `kernel-4.4.x.config` with kernel configuration
3. Create device template: `trunk/configs/templates/DEVICE.config`
4. Test build: `fakeroot ./build_firmware_modify DEVICE`

## Key Technical Details

### Hardware Platform
- **Architecture**: MIPSEL (MIPS Little Endian)
- **SoC**: MediaTek MT7621 (dual-core MIPS 1004Kc)
- **Kernel**: Linux 4.4.198 with MediaTek drivers
- **Hardware NAT**: Supports `raeth` and `mt7621 hwnat` legacy drivers
- **Shortcut Forwarding Engine**: QCA shortcut-fe support

### Kernel Configuration
- Kernel configs are dynamically modified by `build_firmware_modify` based on enabled features
- Use `func_enable_kernel_param` / `func_disable_kernel_param` functions in build script
- Module builds controlled by `CONFIG_MODULES` in kernel config

### ROM Filesystem
- Built using custom `romfs-inst.sh` tool
- Modules installed via `modules_install` target (or `modules_copy` for prebuilt)
- Final image stripped with `sstrip` if `CONFIG_FIRMWARE_PERFORM_SSTRIP=y`

### Build Variables
- `HOST_NCPU`: Auto-detected CPU count * `CPU_OVERLOAD` (default: 1)
- `CONFIG_CROSS_COMPILER_PATH`: Toolchain bin directory
- `KERNEL_HEADERS_PATH`: Kernel headers for userspace compilation
- Parallel builds: `-j$(HOST_NCPU)` used for kernel and module builds

## Common Modifications

### Enabling Kernel Features
Edit the `build_firmware_modify` script to add kernel parameters:
```bash
func_enable_kernel_param "CONFIG_FEATURE_NAME"      # Built-in (=y)
func_enable_kernel_param "CONFIG_FEATURE_NAME" "m"  # Module (=m)
```

### Adding User Scripts
Place scripts in `trunk/user/scripts/` and update `trunk/user/scripts/Makefile` to install them to romfs.

### Storage Backend
Recent commits show eMMC backing store support for persistent storage, prioritizing eMMC over MTD partitions. See `trunk/user/scripts/mtd_storage.sh` and `emmc_partition.sh`.

## Monitoring Scripts

Two custom monitoring scripts are in active development:
- `trunk/user/scripts/monitor_network.sh`: Network connectivity monitoring with IP/DNS checks, diagnostics, WiFi stats
- `trunk/user/scripts/monitor_crash.sh`: System crash monitoring (recently added, check git status)

## CI/CD

GitHub Actions workflow (`.github/workflows/CI.yml`) builds firmware for JDCLOUD-RE-SP-01B device:
- Installs build dependencies
- Downloads prebuilt toolchain
- Customizes configuration with sed/echo commands
- Builds firmware with `./build_firmware_modify`
- Uploads `.trx` image as artifact
