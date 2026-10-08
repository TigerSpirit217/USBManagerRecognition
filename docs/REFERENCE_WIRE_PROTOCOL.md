# 两套参考方案的 USBManager Auth v2 协议

中文 | [English](REFERENCE_WIRE_PROTOCOL_ENG.md)

本文件只用于兼容 `generic-configfs` / `nothing-qxr` 包及 `USBManagerWinBackEnd`。第三方方案可以自行设计协议和 Windows 后端，只需遵守 [应用控制接口](SCHEME_PACKAGE_FORMAT.md)。

参考手机实现位于 `runtime/java/com/tiger/usbmanager/auth/UsbAuthDaemon.java`，Windows 实现位于 `windows/USBManagerWinBackEnd/Program.cs`。两端源码是字段与字节编码的完整定义。

USB 描述符：厂商自定义接口，名称 `USB Authenticate`，两个 Bulk 端点（一入一出），参考 GUID `{8F60D3B2-3D44-4D15-8F28-5A46D65E0F31}`，WinUSB 兼容描述符。Windows 后端动态枚举并检查接口与端点，不依赖手机 VID / PID 或固定接口编号。MTP 应继续使用原来的驱动。

每次请求和回应为 4096 字节：ASCII 文本，剩余以零填充，首个零之前的内容为正文。二进制字段用标准 Base64。协议流程：

```text
电脑 → HELLO2 identityPublic ephemeralPublic pcNonce label64
手机 → CHALLENGE2 phoneEphemeral phoneNonce
电脑 → AUTH2 signature iv ciphertextWithTag
手机 → RESULT2 iv ciphertextWithTag
```

* 身份及临时密钥：P-256；公钥为 DER SubjectPublicKeyInfo。
* 两端 nonce 均为随机 32 字节，Base64 编码。AES-GCM IV 为随机 12 字节，认证标签 16 字节，附在密文末尾。
* Transcript 是 ASCII 字节：`USBMANAGER/2\nidentityPublic\nephemeralPublic\nphoneEphemeral\npcNonce\nphoneNonce\nlabel64`，末尾没有额外换行。
* 临时 ECDH 的原始共享秘密用于 HKDF-SHA256；salt 是 `SHA256(ASCII(pcNonce + phoneNonce))`，info 是 ASCII `USBManager Auth v2`，输出 32 字节 AES 密钥。
* 命令为 `LOOKUP` 或 `PAIR`。ECDSA-SHA256 签名覆盖 `transcript + '\n' + command`，编码为 RFC3279 DER 序列。
* 命令使用 AES-256-GCM 加密，AAD 为 transcript；手机校验签名和 GCM 后才能处理。加密结果正文是 `KNOWN <id> <name>`、`PAIRED <id> <name>` 或 `UNKNOWN <id>` 等状态。
* `LOOKUP` 对已保存身份鉴权。未知身份只有在手机一次性 `pair` 窗口内才能通过 `PAIR` 加入。手机把该身份的电脑配置持久保存，结束接口后通过控制接口返回配置。

Windows 参考实现先 `LOOKUP`，未知时再尝试 `PAIR`，私钥以当前用户 DPAPI 保护。自行实现兼容后端时必须使用原始 ECDH 秘密，不能替换为某个运行库默认的派生密钥函数；签名编码、Base64 字符串和 transcript 换行也必须完全一致。
