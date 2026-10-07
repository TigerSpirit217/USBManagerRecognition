# USBManager 识别方案包规范 v1

[English](SCHEME_PACKAGE_FORMAT_ENG.md)

这是 **Android 应用与方案之间的控制接口**。它不规定手机与 Windows 之间的通信协议；作者可以自行编写手机守护程序和 Windows 后端，也可以复用本项目的参考实现。应用不会验证 Windows 证书、实现密钥交换或强制使用某类 USB 接口，鉴权结果完全由用户导入的方案负责。

## 1. 文件格式

UTF-8 JSON 清单置于 ZIP 根部，必须有 `entry.sh`。路径使用 ASCII 字母、数字、`_`、`-`、`.` 和 `/`；禁止绝对路径、反斜杠、空目录段、`.` / `..` 路径段及重复路径。脚本使用 UTF-8 无 BOM 和 LF 换行。应用通过 `/system/bin/sh` 执行入口，不依赖 ZIP 中的可执行权限。

最小包：

```text
manifest.json
entry.sh
```

两套参考包附加文件：

```text
scheme.sh
runtime/usb_auth_root.sh
runtime/daemon.jar
lib/<abi>/libusbmanager_auth.so
```

所有附加文件均可替换或删除，只要入口仍能实现下面的控制接口。Windows 程序一般单独分发，不在 Android 上运行。

清单示例（`files` 用打包工具自动生成实际 SHA-256）：

```json
{
  "formatVersion": 1,
  "id": "example.my-scheme",
  "name": "我的识别方案",
  "version": "1.0.0",
  "author": "作者名称",
  "description": "适用设备、检测条件和配套电脑程序的简短说明",
  "entry": "entry.sh",
  "minSdk": 26,
  "abis": ["any"],
  "storageId": "example.my-scheme",
  "companion": { "name": "MyWindowsBackend", "protocol": "my-protocol-v1" },
  "files": { "entry.sh": "填写该文件的64位小写SHA-256" }
}
```

字段约束：

| 字段 | 要求 |
|---|---|
| `formatVersion` | 整数 `1`，未知版本拒绝导入 |
| `id` | 1–64 位，首位为小写字母或数字，其余为小写字母、数字、`.`、`_`、`-` |
| `name` / `author` | 非空，最多 128 字符，无控制字符 |
| `version` | 非空，最多 64 字符，推荐语义版本 |
| `description` | 非空，最多 2000 字符，无控制字符 |
| `entry` | 固定 `entry.sh` |
| `minSdk` | 整数，26–100；应用自身最低 API 26 |
| `abis` | 非空且不重复，可选 `armeabi-v7a`、`arm64-v8a`、`x86`、`x86_64`、`riscv64`；不依赖 CPU 的脚本可单独填 `["any"]` |
| `storageId` | 可选，格式与 `id` 相同；默认取 `id`。只有数据和鉴权完全兼容的方案才应共享它 |
| `files` | 所有有效载荷的相对路径到实际小写 SHA-256 的映射，必须包括 `entry.sh`，不包括 `manifest.json` |
| `companion` | 可选的发布信息，应用不据此限定协议或执行电脑程序 |

应用拒绝缺少文件、额外未声明文件、哈希不符、缺少入口、不兼容 Android / ABI 的包。清单最大 64 KiB，单文件最大 32 MiB，解压总量最大 64 MiB，有效载荷最多 127 个文件，ZIP 最多 256 个条目。SHA-256 用于完整性核对，不证明作者可信；这不是签名验证或 root 沙箱。

## 2. 唯一入口及参数

应用以 root 调用：

```text
/system/bin/sh <package>/entry.sh ACTION STATE_DIR ABI APP_PROCESS MODE_OR_ID PROFILE
```

所有参数独立引用，不能把输入拼成可执行 shell 代码。入口目录通过 `$0` 自行定位，不依赖当前工作目录。

* `STATE_DIR`：`/data/adb/usbmanager-schemes/<storageId>`，用于方案的持久数据库、锁与会话状态。入口负责创建并保护权限。应用移除包时不删除此数据库。
* `ABI`：从设备支持的架构中选出的包内 ABI，或 `any`。
* `APP_PROCESS`：与选定 ABI 位数一致的 Android Java 启动器。作者不使用 DEX 时可忽略它；应用不提供任何守护程序或原生库。
* `MODE_OR_ID`：见操作表。合法 USB 模式为 `none`、`mtp`、`ptp`、`rndis`、`midi`。
* `PROFILE`：`Base64(UTF-8名称),USB模式,true|false`。配对时名称可能为空，由方案给出初始名称；编辑时名称非空且最多 64 字符，不含控制字符。没有配置参数时传 `none`。

## 3. 操作与输出

标准输出按行返回，下表中的结果行必须独占一行。诊断建议写标准错误；不能输出伪造的成功结果。只有退出码 `0` 的结果才被接受。其他退出码、超时和格式错误进入失败流程。

| ACTION | MODE_OR_ID / PROFILE | 成功输出 | 应用超时 |
|---|---|---|---|
| `detect` | `closed` / `none` | `USBMGR_SUPPORTED 1` | 45 秒 |
| `start` | `closed` / `none` | `AUTH_RESULT KNOWN\|ID\|NAME64\|MODE\|ADB` 或 `UNKNOWN` / `TIMEOUT` | 80 秒 |
| `start` | `pair` / 初始配置 | `AUTH_RESULT PAIRED\|ID\|NAME64\|MODE\|ADB`，已有身份也可返回 `KNOWN` | 120 秒 |
| `restore` | `closed` / `none` | `USBMGR_RESTORED` | 20 秒 |
| `list` | `closed` / `none` | 每台电脑一行 `ID\|NAME64\|LAST_SEEN\|MODE\|ADB`，空列表不输出记录 | 10 秒 |
| `edit` | ID / 新配置 | `UPDATED` | 10 秒 |
| `delete` | ID / `none` | `DELETED` | 10 秒 |

`ID` 是稳定的 64 位小写十六进制电脑标识。若自己的协议使用其他标识，可对其规范字节串计算 SHA-256 并在方案内部映射，不要求 ID 来自某种公钥算法。`NAME64` 是标准 Base64 编码的 UTF-8 名称。`LAST_SEEN` 为 Unix 毫秒。`ADB` 必须为 `true` 或 `false`。

超时输出为单行 `AUTH_RESULT TIMEOUT`。未知身份可输出 `AUTH_RESULT UNKNOWN|ID|NAME64||false`，不能自动保存为可信电脑。`KNOWN` / `PAIRED` 必须带有效模式。`closed` 禁止把未知电脑加入信任；`pair` 表示用户明确打开配对窗口，方案须限制该窗口时长和可新增电脑数量。鉴权算法本身由作者决定，但不能把“线已插入”直接当作可信身份。

`detect` 不通过可输出 `USBMGR_SUPPORTED 0` 并返回非零。检测是否需要数据线、是否需要配套后端、会改哪些临时状态，必须在方案描述和说明中写清。检测失败也必须恢复 USB 状态，不能由应用猜测挂载方法。

## 4. 生命周期与恢复责任

1. 导入只做文件校验、展示信息和保存；用户确认前不执行包内脚本。替换已有运行过的方案时，应用先关闭识别并调用旧方案的 `restore`，恢复失败则保留旧方案。
2. 方案导入、更新或切换后，启用状态为关闭。只有当前导入版本在当前固件上检测通过，用户才能启用。
3. 应用在 USB 连接时调用 `start closed`，收到可信结果后应用其 USB 模式和 ADB 配置；其他结果继续正常选择窗口。配对和编辑通过对应入口完成。
4. `restore` 必须幂等；无会话时也返回成功。退出、失败、拔线、关闭识别和超时都必须释放接口并恢复临时 USB 状态。不能要求主应用懂具体 USB 驱动。
   拔线取消时可能在 `start` 仍运行的同时调用 `restore`，方案应能取消自己的活动会话。应用按导入版本核对恢复请求，避免旧会话去执行新方案；方案自身也必须避免旧看门狗恢复后续的新会话。
5. 应用会终止超时的调用进程，但这不能保证其 root 子进程或守护程序一并退出。方案必须提供独立的超时看门狗、持久状态记录和恢复路径；恢复成功前不能删除保存的原状态。
6. 更新包不能改变持久电脑 ID 的语义。若数据格式不兼容，应更换 `storageId` 或在方案内完成迁移。应用不会代替方案迁移密钥或鉴权数据库。

参考方案在包内实现操作锁、USB 状态保存、120 秒看门狗以及旧数据迁移。其 Windows 协议是一个可替换的实现，不是方案规范的一部分。
