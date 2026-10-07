# USBManagerWinBackEnd

[中文](README.md)

USBManagerWinBackEnd is the headless Windows companion for USBManager's computer recognition and memory feature. It monitors the USB Authenticate interface exposed by the phone and uses a persistent identity for the current Windows user to perform automatic authentication or first-time pairing.

It is now part of the additional recognition project and accompanies the `generic-configfs` and `nothing-qxr` importable schemes. Authors may implement their own Windows backend and authentication protocol. Only the phone scheme's [package control contract](../../docs/SCHEME_PACKAGE_FORMAT.md) is required; the [reference wire protocol](../../docs/REFERENCE_WIRE_PROTOCOL.md) is optional for custom schemes.

## Quick Start for Releases

Extract the complete Release archive and keep all EXE, DLL, and runtime files in the same directory. Each of these entry points can be launched by double-clicking:

* **USBManagerWinBackEnd.Install.exe**: recommended. Registers startup for the current user and starts the backend immediately.
* **USBManagerWinBackEnd.exe**: runs the backend for the current session without registering startup.
* **USBManagerWinBackEnd.Uninstall.exe**: removes the startup entry and stops the running backend.

Installation and removal do not require administrator privileges and do not open a persistent window. Removal keeps the computer identity and logs so a later reinstall can continue using them. To erase all local data, manually delete `%LOCALAPPDATA%\USBManagerWinBackEnd`.

## Phone Setup

1. In USBManager, import a companion scheme ZIP, complete its device check, and enable Computer Recognition and Memory.
2. On the first connection, tap Allow a New Computer to Pair on the phone.
3. Double-click `USBManagerWinBackEnd.Install.exe`.
4. After the phone saves the computer, later cable connections authenticate automatically.

## Requirements

* Windows 10 or Windows 11.
* A framework-dependent Release requires the .NET 8 Runtime matching its architecture. A self-contained Release does not require a separate runtime installation.
* The phone must pass USBManager's support check and have the feature enabled.

## Build and Release

Building requires the .NET 8 SDK. Run the following commands from the `windows/USBManagerWinBackEnd/` subdirectory. From the repository root, use the full project paths in the [root README](../../README_ENG.md#building).

Standard build:

    dotnet build -c Release

Framework-dependent publish for a selected architecture:

    dotnet publish -c Release -r win-x64 --self-contained false

The output automatically includes the main executable and the `.Install.exe` and `.Uninstall.exe` double-click launchers. Package the complete output directory for a Release; do not distribute one EXE by itself.

Command-line forms remain available for automation:

    USBManagerWinBackEnd.exe --install
    USBManagerWinBackEnd.exe --uninstall

## Operation

* Runs as a single background process with no window or tray icon.
* Dynamically enumerates active WinUSB interfaces and validates the USB class, endpoints, and `USB Authenticate` interface name.
* Does not depend on a fixed phone VID, PID, interface number, or single GUID.
* Looks up an existing identity first. An unknown computer can join the trust list only while the phone has opened its one-time pairing window.
* MTP, ADB, and Authenticate operate concurrently as separate interfaces of the composite device.

## Identity and Security

Data is stored in `%LOCALAPPDATA%\USBManagerWinBackEnd`:

* `identity.dpapi`: the computer identity private key, protected by DPAPI for the current Windows user.
* `backend.log`: connection, authentication, and error records.

The protocol uses ECDSA P-256 identity signatures, ephemeral ECDH P-256, HKDF-SHA256, and AES-256-GCM. The USB cable is not treated as an identity credential. Deleting `identity.dpapi` creates a new identity, which the phone treats as a new computer.

## Drivers and Troubleshooting

Windows should keep the Microsoft MTP driver on the MTP interface and bind only the Authenticate sub-interface to the system WinUSB driver. Do not use Zadig to replace the driver for the entire Android composite device.

The log is located at:

    %LOCALAPPDATA%\USBManagerWinBackEnd\backend.log

Common results:

* `PAIRED <id> <name>`: first-time pairing succeeded.
* `KNOWN <id> <name>`: a saved computer authenticated successfully.
* `UNKNOWN <id>`: the computer identity has not been saved.
* `ERROR ...`: an interface, driver, timeout, or protocol error occurred.

If no log is created, confirm that the program package is complete, the backend is running, the phone exposes the Authenticate interface, and each sub-interface has the correct driver binding in Device Manager.
