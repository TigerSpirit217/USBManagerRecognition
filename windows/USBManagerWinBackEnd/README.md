# USBManagerWinBackEnd

[English](README_ENG.md)

USBManagerWinBackEnd 是 USBManager“电脑识别与记忆”功能的无界面 Windows 后端。它在后台识别手机提供的 USB Authenticate 接口，并使用当前 Windows 用户的持久身份完成自动鉴权或首次配对。

它现位于“额外识别方案项目”中，配套 `generic-configfs` 与 `nothing-qxr` 两套可导入方案。**用户可以自行编写其他 Windows 后端及鉴权协议**，只需在手机方案包中实现匹配的协议，并遵守 [软件认可的方案包结构与写法](../../docs/SCHEME_PACKAGE_FORMAT.md)。本后端的 [参考通信协议](../../docs/REFERENCE_WIRE_PROTOCOL.md)并非第三方方案的强制要求。

## Release 快速使用

解压完整 Release 压缩包后，请保持其中的 EXE、DLL 和运行库文件位于同一目录。三个入口均可直接双击：

* **USBManagerWinBackEnd.Install.exe**：推荐入口。为当前用户设置开机自启，并立即启动后端。
* **USBManagerWinBackEnd.exe**：仅启动本次后台运行，不设置开机自启。
* **USBManagerWinBackEnd.Uninstall.exe**：移除开机自启，并关闭正在运行的后端。

安装和卸载均不需要管理员权限，也不会显示常驻窗口。卸载会保留电脑身份和日志，以便以后重新安装后继续使用；如需完全清除，可手动删除 `%LOCALAPPDATA%\USBManagerWinBackEnd`。

## 手机端使用

1. 在 USBManager 中导入配套方案 ZIP，完成方案提供的设备支持检测，再开启“电脑识别与记忆”。
2. 首次连接时，在手机上点击“允许一台新电脑配对”。
3. 双击 `USBManagerWinBackEnd.Install.exe`。
4. 手机保存电脑后，后续插线会自动鉴权。

## 系统要求

* Windows 10 或 Windows 11。
* Release 若为依赖框架版本，需要与构建架构匹配的 .NET 8 Runtime；自包含 Release 无需另行安装运行库。
* 手机已通过 USBManager 的支持检测并开启该功能。

## 构建与发布

构建需要 .NET 8 SDK。以下命令在 `windows/USBManagerWinBackEnd/` 子目录执行；若在项目根目录执行，请使用[根目录 README](../../README.md#构建)中的完整项目路径。

普通构建：

    dotnet build -c Release

指定架构、依赖框架发布：

    dotnet publish -c Release -r win-x64 --self-contained false

生成目录会自动包含主程序以及 `.Install.exe`、`.Uninstall.exe` 两个双击入口。发布时应将整个输出目录打包，不能只单独分发某个 EXE。

命令行仍可用于自动化：

    USBManagerWinBackEnd.exe --install
    USBManagerWinBackEnd.exe --uninstall

## 工作方式

* 无窗口、无托盘图标，单进程后台运行。
* 动态枚举活动的 WinUSB 接口，并校验 USB 接口类别、端点和 `USB Authenticate` 接口名称。
* 不依赖固定的手机 VID、PID、接口编号或单一 GUID。
* 优先查询已保存身份；只有手机打开一次性配对窗口时，未知电脑才能加入信任列表。
* MTP、ADB 和 Authenticate 作为复合设备的独立接口并行工作。

## 身份与安全

数据保存在 `%LOCALAPPDATA%\USBManagerWinBackEnd`：

* `identity.dpapi`：当前电脑身份私钥，由当前 Windows 用户的 DPAPI 保护。
* `backend.log`：连接、鉴权结果和错误日志。

通信使用 ECDSA P-256 身份签名、临时 ECDH P-256、HKDF-SHA256 和 AES-256-GCM。USB 链路本身不作为身份凭据。删除 `identity.dpapi` 会创建新身份，手机将把它视为一台新电脑。

## 驱动与排障

Windows 应让 MTP 接口继续使用 Microsoft MTP 驱动，只让 Authenticate 子接口使用系统 WinUSB。不要用 Zadig 替换整台 Android 复合设备的驱动。

日志位于：

    %LOCALAPPDATA%\USBManagerWinBackEnd\backend.log

常见结果：

* `PAIRED <id> <name>`：首次配对成功。
* `KNOWN <id> <name>`：已保存电脑鉴权成功。
* `UNKNOWN <id>`：电脑身份尚未保存。
* `ERROR ...`：接口、驱动、超时或协议错误。

若没有日志，请确认程序文件完整、后端已运行、手机已暴露 Authenticate 接口，并在设备管理器中检查各子接口的驱动绑定。
