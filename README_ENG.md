# USBManagerRecognition — Additional recognition schemes

[中文](README.md)

This project contains importable USBManager recognition schemes and their Windows companions. The Android app only implements the package control interface and management UI. Device detection, USB exposure, computer authentication and daemon code are supplied by the imported scheme.

**Authors may write their own Windows backend.** Wire protocols, USB interface types, authentication algorithms and driver requirements are scheme decisions. The existing `windows/USBManagerWinBackEnd` is a companion for the two reference schemes, not a required backend for third-party schemes.

## Project Structure

* `windows/USBManagerWinBackEnd/`: existing Windows companion and its instructions.
* `schemes/generic-configfs/`: generic ConfigFS detection, preparation and recovery.
* `schemes/nothing-qxr/`: Nothing / Qualcomm QXR detection, preparation and recovery.
* `runtime/`: authentication and native FunctionFS code used by these two schemes.
* `templates/custom-scheme/`: custom scheme template, unsupported until implemented.
* `tools/`: build and packaging scripts.
* `docs/`: package control contract and reference wire protocol.
* `dist/`: generated import packages, excluded from Git.

## Using the Reference Schemes

1. Build or obtain a scheme ZIP from `dist/` and copy it to the phone.
2. Import it on USBManager's Computer Recognition and Memory page, reviewing its author, version and root execution notice.
3. Grant root access, run the scheme's device check and enable recognition manually after it passes.
4. Start the companion using the [Windows instructions](windows/USBManagerWinBackEnd/README_ENG.md) and open the first-time pairing window on the phone.

Importing alone does not run code or establish device support. Importing, updating, switching schemes or changing firmware invalidates detection and requires manual enabling again. Unknown computers, failures and timeouts return to the normal USB chooser. Removing a scheme restores USB state, disables recognition and preserves its computer records.

The reference schemes share `storageId: usb-auth-v2` and keep computer identities and profiles in `/data/adb/usbmanager-schemes/usb-auth-v2`. On first use, they copy records from `/data/adb/usbmanager-auth/hosts` without deleting the originals. Third-party schemes default to their own ID; incompatible protocols should use different namespaces.

## Building

The Android app and this project build separately. The app requires no NDK; the two reference schemes still need NDK for their FunctionFS JNI runtime files.

Reference scheme builds require JDK with `javac --release 8` support (`javac` must be on PATH), Android Build Tools 37.0.0 and NDK 30.0.16248370. Building the Windows companion requires the .NET 8 SDK; its runtime requirements are documented in the Windows instructions.

From this project's root, build both reference ZIP packages in PowerShell:

```powershell
.\tools\Build-SchemePackages.ps1 -SdkPath 'your Android SDK directory'
```

For arm64-v8a only:

```powershell
.\tools\Build-SchemePackages.ps1 -SdkPath 'your Android SDK directory' -Abis arm64-v8a
```

The default package contains `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64` and `riscv64`. The first four require API 26; riscv64 requires API 37. A successful import does not replace the scheme's device check.

Set `ANDROID_SDK_ROOT` or `ANDROID_HOME` to omit `-SdkPath`. Use `-NdkVersion` and `-BuildToolsVersion` to select installed versions. ZIP packages are written to `dist/`; `build/` contains disposable intermediate files and packaging staging directories.

Build the Windows companion with:

```powershell
dotnet build .\windows\USBManagerWinBackEnd\USBManagerWinBackEnd.csproj -c Release
dotnet publish .\windows\USBManagerWinBackEnd\USBManagerWinBackEnd.csproj -c Release -r win-x64 --self-contained false
```

Distribute the complete Windows output directory alongside the scheme ZIPs; users import one scheme suitable for their device. Windows executables are not Android runtime files.

## Custom Schemes and Windows Backends

Read the [package specification](docs/SCHEME_PACKAGE_FORMAT_ENG.md) and [entry template](templates/custom-scheme/entry.sh). Custom packages only require `manifest.json` and `entry.sh`; `runtime/`, DEX, native libraries, USB Authenticate and the existing cryptographic protocol are optional.

Authors can use their own executables, interfaces and companion programs, translating authentication results to the required app control output. To use this project's Windows companion, implement the [optional reference protocol](docs/REFERENCE_WIRE_PROTOCOL_ENG.md). Authors must implement device checks and recovery, including recovery after timeout or process termination.

For any custom payload directory containing `manifest.json` and `entry.sh`:

```powershell
.\tools\Pack-Scheme.ps1 -Directory .\my-scheme -Output .\dist\my-scheme.zip
```

The tool generates the `files` SHA-256 table for every payload file and places the files at the ZIP root, without an enclosing directory. Packaging a script-only custom scheme does not require NDK.

The extracted Android reference runtime retains its original Mulan Public License v2; see [runtime/LICENSE](runtime/LICENSE).
