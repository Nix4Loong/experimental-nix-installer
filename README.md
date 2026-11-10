# Nix Installer for Nix4Loong

Nix installer of the [Nix4Loong](https://nix4loong.cn) project. Nix4Loong is a comprehensive effort to port NixOS and the Nix ecosystem to **LoongArch64** processors.

This installer is based on the [NixOS/experimental-nix-installer](https://github.com/NixOS/experimental-nix-installer) and has been specialized for LoongArch64 platforms. It provides a fast, friendly, and reliable way to install Nix as part of the broader nix4loong ecosystem.

## Requirements

The installer and Nix to be installed only supports:

- **LoongArch64 processors** with **LSX instruction set** and **FPU64**
- **New world** LoongArch systems (glibc >= `2.36`)
- **glibc-based** Linux distributions (musl is not supported)

The installer enables [flakes] by default and provides comprehensive support for LoongArch-specific requirements.

## Quick Start

Install Nix on your LoongArch64 system with this one-liner:

```shell
curl --proto '=https' --tlsv1.2 -sSf -L https://install.nix4loong.cn | sh -s -- install
```

## Installation

### Standard Installation

Install Nix with the default configuration:

```shell
curl --proto '=https' --tlsv1.2 -sSf -L https://install.nix4loong.cn | sh -s -- install
```

### Download Binary Directly

To download the installer binary for manual execution:

```shell
curl -sL -o nix-installer https://download.nix4loong.cn/nix-installer/latest/nix-installer-loongarch64-linux
chmod +x nix-installer
./nix-installer install
```

### Skip Confirmation

For non-interactive installations:

```shell
curl --proto '=https' --tlsv1.2 -sSf -L https://install.nix4loong.cn | \
  sh -s -- install --no-confirm
```

### Custom Configuration

You can customize the installation with various options:

```shell
curl --proto '=https' --tlsv1.2 -sSf -L https://install.nix4loong.cn | \
  NIX_BUILD_GROUP_NAME=nixbuilder sh -s -- install --nix-build-group-id 4000
```

## System Compatibility Checks

The installer performs several automatic checks to ensure compatibility:

1. **Architecture Check**: Verifies the system is running on LoongArch64
2. **New World Detection**: Checks for new world LoongArch system using:
   - Program interpreter path (`/lib64/ld-linux-loongarch-lp64d.so.1` for new world)
   - glibc version (>= 2.36 for new world)
3. **LSX Support**: Verifies LSX instruction set availability in `/proc/cpuinfo`
4. **FPU64 Support**: Verifies FPU64 availability in `/proc/cpuinfo`
5. **C Library Check**: Ensures glibc is used (rejects musl)
6. **Platform Check**: Confirms Linux kernel (rejects Android and other systems)

## New World vs Old World

LoongArch systems are divided into "new world" and "old world" categories. nix4loong **only supports new world systems**.

**New World Systems** (Supported):
- glibc >= 2.36
- Program interpreter: `/lib64/ld-linux-loongarch-lp64d.so.1`
- Modern ABI and syscall interfaces
- Better upstream compatibility

**Old World Systems** (Not Supported):
- glibc < 2.36
- Program interpreter: `/lib64/ld.so.1`
- Legacy interfaces

For more details about new world vs old world, see [areweloongyet.com](https://areweloongyet.com/docs/world-compat-details/).

## Upgrading Nix

Upgrade to the latest supported Nix version:

```shell
sudo -i nix upgrade-nix
```

## Uninstalling

Remove Nix installed by nix4loong:

```shell
/nix/nix-installer uninstall
```

## License

This project inherits the license from [NixOS/experimental-nix-installer](https://github.com/NixOS/experimental-nix-installer).
