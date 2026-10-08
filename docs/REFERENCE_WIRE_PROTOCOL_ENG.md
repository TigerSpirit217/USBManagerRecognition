# USBManager Auth v2 Protocol for the Two Reference Schemes

[中文](REFERENCE_WIRE_PROTOCOL.md) | English

This document applies only to compatibility with the `generic-configfs` / `nothing-qxr` packages and `USBManagerWinBackEnd`. Third-party schemes may design their own protocols and Windows backends; only the [app control interface](SCHEME_PACKAGE_FORMAT_ENG.md) is required.

The reference phone implementation is in `runtime/java/com/tiger/usbmanager/auth/UsbAuthDaemon.java`, and the Windows implementation is in `windows/USBManagerWinBackEnd/Program.cs`. The source code on both sides provides the complete definition of fields and byte encodings.

USB descriptors: a vendor-specific interface named `USB Authenticate`, two Bulk endpoints (one IN and one OUT), the reference GUID `{8F60D3B2-3D44-4D15-8F28-5A46D65E0F31}`, and WinUSB compatible descriptors. The Windows backend dynamically enumerates and checks interfaces and endpoints. It does not depend on the phone's VID / PID or a fixed interface number. MTP must continue using its original driver.

Each request and response is 4096 bytes: ASCII text followed by zero padding. The body is everything before the first zero byte. Binary fields use standard Base64. The protocol flow is:

```text
Computer → HELLO2 identityPublic ephemeralPublic pcNonce label64
Phone → CHALLENGE2 phoneEphemeral phoneNonce
Computer → AUTH2 signature iv ciphertextWithTag
Phone → RESULT2 iv ciphertextWithTag
```

* Identity and ephemeral keys use P-256. Public keys use DER SubjectPublicKeyInfo encoding.
* Both sides generate random 32-byte nonces and encode them with Base64. AES-GCM uses a random 12-byte IV and a 16-byte authentication tag appended to the ciphertext.
* The transcript is the ASCII byte sequence `USBMANAGER/2\nidentityPublic\nephemeralPublic\nphoneEphemeral\npcNonce\nphoneNonce\nlabel64`, with no additional trailing newline.
* The raw ephemeral ECDH shared secret is the input to HKDF-SHA256. The salt is `SHA256(ASCII(pcNonce + phoneNonce))`, and the info is ASCII `USBManager Auth v2`. The output is a 32-byte AES key.
* The command is `LOOKUP` or `PAIR`. The ECDSA-SHA256 signature covers `transcript + '\n' + command` and uses RFC3279 DER sequence encoding.
* Encrypt the command with AES-256-GCM, using the transcript as AAD. The phone must verify the signature and GCM authentication before processing the command. The encrypted result body contains a status such as `KNOWN <id> <name>`, `PAIRED <id> <name>`, or `UNKNOWN <id>`.
* `LOOKUP` authenticates an already saved identity. An unknown identity may be added through `PAIR` only during the phone's one-time `pair` window. The phone persists that identity's computer configuration and returns the configuration through the control interface after closing the USB interface.

The reference Windows implementation first sends `LOOKUP`, then attempts `PAIR` if the identity is unknown. It protects the private key using DPAPI for the current Windows user. A compatible backend must use the raw ECDH shared secret; do not substitute a runtime's default derived-key function. Signature encoding, Base64 strings, and transcript newlines must also match exactly.
