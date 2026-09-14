# USBManagerWinBackEnd

无界面的 Windows 后端。它扫描 USB Authenticate WinUSB 接口，使用当前 Windows 用户的 P-256 身份密钥自动完成配对请求或已知电脑识别。

```powershell
dotnet build -c Release
USBManagerWinBackEnd.exe --install
```

`--install` 写入当前用户的 `HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run`，无需管理员权限。`--uninstall` 删除自启项。日志和 DPAPI 加密私钥位于 `%LOCALAPPDATA%\\USBManagerWinBackEnd`。

协议使用 ECDSA P-256 身份签名、临时 ECDH P-256、HKDF-SHA256 和 AES-256-GCM。首次配对必须先在手机页面点击“允许一台新电脑配对”。
