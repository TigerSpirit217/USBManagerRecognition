# USBManager Recognition Scheme Package Specification v1

[中文](SCHEME_PACKAGE_FORMAT.md)

This is the **control interface between the Android app and a scheme**. It does not define the communication protocol between the phone and Windows. Authors may write their own phone daemon and Windows backend or reuse this project's reference implementation. The app does not validate Windows certificates, implement key exchange, or require a particular USB interface type. Authentication results are entirely the responsibility of the scheme imported by the user.

## 1. File Format

Place a UTF-8 JSON manifest at the ZIP root and include `entry.sh`. Paths may contain ASCII letters, digits, `_`, `-`, `.`, and `/`. Absolute paths, backslashes, empty path segments, `.` / `..` segments, and duplicate paths are forbidden. Scripts must use UTF-8 without a BOM and LF line endings. The app runs the entry point through `/system/bin/sh` and does not depend on executable permissions stored in the ZIP.

Minimal package:

```text
manifest.json
entry.sh
```

Additional files in the two reference packages:

```text
scheme.sh
runtime/usb_auth_root.sh
runtime/daemon.jar
lib/<abi>/libusbmanager_auth.so
```

Any additional file may be replaced or removed, provided the entry point still implements the control interface below. Windows programs are normally distributed separately and do not run on Android.

Example manifest (the packaging tool generates actual SHA-256 values in `files`):

```json
{
  "formatVersion": 1,
  "id": "example.my-scheme",
  "name": "My recognition scheme",
  "version": "1.0.0",
  "author": "Author name",
  "description": "A short description of supported devices, detection requirements, and the companion computer program",
  "entry": "entry.sh",
  "minSdk": 26,
  "abis": ["any"],
  "storageId": "example.my-scheme",
  "companion": { "name": "MyWindowsBackend", "protocol": "my-protocol-v1" },
  "files": { "entry.sh": "Replace with this file's 64-character lowercase SHA-256 digest" }
}
```

Field constraints:

| Field | Requirement |
|---|---|
| `formatVersion` | Integer `1`; unknown versions are rejected on import |
| `id` | 1–64 characters; the first character must be a lowercase letter or digit, followed by lowercase letters, digits, `.`, `_`, or `-` |
| `name` / `author` | Nonempty, at most 128 characters, with no control characters |
| `version` | Nonempty, at most 64 characters; semantic versioning is recommended |
| `description` | Nonempty, at most 2000 characters, with no control characters |
| `entry` | Must be `entry.sh` |
| `minSdk` | Integer from 26 to 100; the app itself requires at least API 26 |
| `abis` | Nonempty, with no duplicates; supported values are `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64`, and `riscv64`. CPU-independent scripts may use `["any"]` alone |
| `storageId` | Optional, with the same format as `id`; defaults to `id`. Only schemes with fully compatible data and authentication should share this value |
| `files` | Maps every payload file's relative path to its actual lowercase SHA-256 digest; must include `entry.sh` and exclude `manifest.json` |
| `companion` | Optional release information; the app does not use it to restrict protocols or execute computer programs |

The app rejects packages with missing files, undeclared extra files, checksum mismatches, missing entry points, or incompatible Android versions / ABIs. Limits are 64 KiB for the manifest, 32 MiB per file, 64 MiB in total after extraction, 127 payload files, and 256 ZIP entries. SHA-256 verifies integrity, not author trust. This is neither signature verification nor a root sandbox.

## 2. Single Entry Point and Arguments

The app invokes the following command as root:

```text
/system/bin/sh <package>/entry.sh ACTION STATE_DIR ABI APP_PROCESS MODE_OR_ID PROFILE
```

Quote every argument separately; do not concatenate input into executable shell code. Locate the entry point's directory using `$0`, without relying on the current working directory.

* `STATE_DIR`: `/data/adb/usbmanager-schemes/<storageId>`, used for the scheme's persistent database, locks, and session state. The entry point must create it and protect its permissions. The app does not delete this database when removing the package.
* `ABI`: an ABI included in the package and selected from those supported by the device, or `any`.
* `APP_PROCESS`: an Android Java launcher matching the bitness of the selected ABI. Authors may ignore it if they do not use DEX. The app supplies no daemon or native library.
* `MODE_OR_ID`: see the operation table. Valid USB modes are `none`, `mtp`, `ptp`, `rndis`, and `midi`.
* `PROFILE`: `Base64(UTF-8 name),USB mode,true|false`. During pairing, the name may be empty and the scheme supplies an initial name. During editing, the name must be nonempty, at most 64 characters, and contain no control characters. Pass `none` when no configuration argument is needed.

## 3. Operations and Output

Return output one line at a time on standard output. Each result line in the table below must occupy its own line. Write diagnostics to standard error where possible; never emit a false success result. Results are accepted only with exit code `0`. Other exit codes, timeouts, and malformed output follow the failure path.

| ACTION | MODE_OR_ID / PROFILE | Successful output | App timeout |
|---|---|---|---|
| `detect` | `closed` / `none` | `USBMGR_SUPPORTED 1` | 45 seconds |
| `start` | `closed` / `none` | `AUTH_RESULT KNOWN\|ID\|NAME64\|MODE\|ADB`, or `UNKNOWN` / `TIMEOUT` | 80 seconds |
| `start` | `pair` / initial configuration | `AUTH_RESULT PAIRED\|ID\|NAME64\|MODE\|ADB`; an existing identity may also return `KNOWN` | 120 seconds |
| `restore` | `closed` / `none` | `USBMGR_RESTORED` | 20 seconds |
| `list` | `closed` / `none` | One `ID\|NAME64\|LAST_SEEN\|MODE\|ADB` line per computer; an empty list emits no records | 10 seconds |
| `edit` | ID / new configuration | `UPDATED` | 10 seconds |
| `delete` | ID / `none` | `DELETED` | 10 seconds |

`ID` is a stable 64-character lowercase hexadecimal computer identifier. If a custom protocol uses another identifier, the scheme may hash its canonical byte representation with SHA-256 and maintain an internal mapping. The ID does not have to originate from a particular public-key algorithm. `NAME64` is the UTF-8 name encoded with standard Base64. `LAST_SEEN` is a Unix timestamp in milliseconds. `ADB` must be `true` or `false`.

For a timeout, output the single line `AUTH_RESULT TIMEOUT`. An unknown identity may produce `AUTH_RESULT UNKNOWN|ID|NAME64||false` and must not be automatically saved as a trusted computer. `KNOWN` / `PAIRED` must include a valid mode. `closed` forbids adding unknown computers to the trust list. `pair` means the user explicitly opened a pairing window; the scheme must limit its duration and the number of computers that may be added. Authors choose the authentication algorithm, but must not treat a connected cable alone as a trusted identity.

A failed `detect` operation may output `USBMGR_SUPPORTED 0` and return a nonzero exit code. Clearly document whether detection requires a cable or companion backend and which temporary states it changes, both in the scheme description and its instructions. Failed detection must also restore USB state; the app must not have to guess how to expose the interface.

## 4. Lifecycle and Recovery Responsibilities

1. Import only validates files, displays information, and saves the package. Package scripts are not executed before user confirmation. When replacing a scheme that has already run, the app first disables recognition and calls the old scheme's `restore`. If recovery fails, the old scheme is retained.
2. Importing, updating, or switching schemes leaves recognition disabled. Users may enable it only after the currently imported version passes detection on the current firmware.
3. On USB connection, the app calls `start closed`. A trusted result causes the app to apply its USB mode and ADB configuration; other results continue to the normal chooser. Pairing and editing use their corresponding entry point operations.
4. `restore` must be idempotent and return success even when there is no session. Exit, failure, unplugging, disabling recognition, and timeouts must all release the interface and restore temporary USB state. The main app must not need knowledge of a particular USB driver.
   Cancellation on unplug may call `restore` while `start` is still running, so the scheme must be able to cancel its active session. The app checks recovery requests against the imported revision to prevent an old session from executing a new scheme. The scheme must also prevent an old watchdog from restoring over a subsequent new session.
5. The app terminates the invocation process on timeout, but cannot guarantee that its root child processes or daemons exit as well. The scheme must provide an independent timeout watchdog, persistent state records, and a recovery path. Do not delete the saved original state before recovery succeeds.
6. Package updates must not change the meaning of persistent computer IDs. If the data format is incompatible, change `storageId` or implement migration inside the scheme. The app does not migrate keys or authentication databases for schemes.

The reference schemes implement operation locks, USB state preservation, a 120-second watchdog, and migration of old records inside the package. Their Windows protocol is a replaceable implementation, not part of this package specification.
