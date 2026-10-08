# USBManagerRecognition — 额外识别方案项目

中文 | [English](README_ENG.md)

此项目统一维护 USBManager 的可导入识别方案及其配套 Windows 程序。Android 主应用只保留方案调用和管理界面，不再内置 USB 挂载、设备支持检测、电脑鉴权算法或识别守护进程。

**允许作者自行编写 Windows 后端。** 手机与 Windows 之间的通信协议、USB 接口类型、鉴权方式、驱动要求都由方案决定。USBManager 只约定如何调用方案、读取检测和识别结果、管理电脑配置；现有 `USBManagerWinBackEnd` 是两套参考方案的配套实现，并非第三方方案的强制依赖。

## 项目结构

```text
windows/USBManagerWinBackEnd/   现有 Windows 后端及使用说明
schemes/generic-configfs/      通用 ConfigFS 方案：入口、设备检测、挂载与恢复
schemes/nothing-qxr/           Nothing / Qualcomm QXR 方案：入口、设备检测、挂载与恢复
runtime/java/                 两套参考方案共用的 USB Authenticate 鉴权实现
runtime/native/               两套参考方案共用的 FunctionFS JNI 实现
runtime/usb_auth_root.sh       两套参考方案共用的会话、状态与超时恢复代码
templates/custom-scheme/      自写方案的入口模板；默认不报告支持
tools/                        运行文件构建和 ZIP 打包工具
docs/                         应用调用规范及参考通信协议
dist/                         生成的导入包（不提交 Git）
```

## 使用参考方案

1. 构建或取得一个 `dist/*.zip` 方案包，复制到手机。
2. 在 USBManager 的“电脑识别与记忆”页面选择“导入方案包”，检查作者和版本，确认 root 执行提示。
3. 授予 USBManager root 权限，运行当前方案提供的“检测此设备”。通过后手动启用识别。
4. 按 [Windows 后端说明](windows/USBManagerWinBackEnd/README.md)启动配套程序，在手机打开首次配对窗口。

导入包本身不执行检测。更新、切换方案或系统固件变更后，检测状态会失效，必须重新检测再启用。识别失败、未知电脑或超时仍回到正常 USB 选择流程。移除方案会恢复 USB 状态并关闭识别，但保留其电脑数据库。

两套参考方案使用相同协议和 `storageId: usb-auth-v2`，所以共享 `/data/adb/usbmanager-schemes/usb-auth-v2` 下的电脑身份与配置。首次运行时会复制旧版 `/data/adb/usbmanager-auth/hosts` 的记录，保留原数据。第三方方案默认使用自己的方案 ID 作为数据命名空间；不兼容的协议应使用不同命名空间。

## 构建

主应用与本项目分别构建。Android 主应用不需要 NDK；本项目两套参考方案的 FunctionFS JNI 运行文件仍需要 NDK。

参考方案需要 JDK（支持 `javac --release 8`，并将 `javac` 加入 PATH）、Android Build Tools 37.0.0 和 NDK 30.0.16248370。Windows 后端构建需要 .NET 8 SDK，使用要求见后端说明。

在本项目根目录的 PowerShell 中构建两个全架构方案包：

```powershell
.\tools\Build-SchemePackages.ps1 -SdkPath '你的AndroidSDK目录'
```

单 arm64-v8a 方案包：

```powershell
.\tools\Build-SchemePackages.ps1 -SdkPath '你的AndroidSDK目录' -Abis arm64-v8a
```

默认包含 `armeabi-v7a`、`arm64-v8a`、`x86`、`x86_64`、`riscv64`。前四种参考运行文件最低 API 26，riscv64 最低 API 37；不能用导入成功代替真实设备支持检测。

也可设置 `ANDROID_SDK_ROOT` 或 `ANDROID_HOME` 后省略 `-SdkPath`。工具支持 `-NdkVersion` 和 `-BuildToolsVersion` 指定已安装版本。方案 ZIP 输出到 `dist/`，`build/` 为可删除的中间文件和打包暂存目录。

Windows 后端：

```powershell
dotnet build .\windows\USBManagerWinBackEnd\USBManagerWinBackEnd.csproj -c Release
dotnet publish .\windows\USBManagerWinBackEnd\USBManagerWinBackEnd.csproj -c Release -r win-x64 --self-contained false
```

发布时可一起分发 Windows 后端完整目录和两套方案 ZIP，用户只导入适合其设备的一套。不要把 Windows EXE 当成手机运行文件。

## 自写方案与 Windows 后端

请先阅读 **[方案包结构和调用规范](docs/SCHEME_PACKAGE_FORMAT.md)**，再参考 [入口模板](templates/custom-scheme/entry.sh)。清单与 `entry.sh` 是唯一必需的文件；`runtime/`、`.so`、DEX、USB Authenticate 和现有加密协议都不是强制要求。

作者可以用自己的可执行文件、接口和电脑程序完成鉴权，再将结果转换为应用规定的返回行。若希望兼容此项目的 Windows 后端，则使用 [参考通信协议](docs/REFERENCE_WIRE_PROTOCOL.md)。方案的支持检测、操作失败恢复和超时看门狗由作者负责。

任意自写方案目录可用以下工具生成包含 SHA-256 校验清单的 ZIP：

```powershell
.\tools\Pack-Scheme.ps1 -Directory .\my-scheme -Output .\dist\my-scheme.zip
```

目录根部必须有 `manifest.json` 和 `entry.sh`。`files` 校验表由工具生成；ZIP 根部就是这些文件，不应再包一层目录。仅打包不依赖原生代码的脚本方案无需 NDK。

迁出的 Android 参考运行代码保留原项目的木兰公共许可证第 2 版，见 [runtime/LICENSE](runtime/LICENSE)。
