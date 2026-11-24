# win-context-menu

给程序员用的 Windows 右键菜单增强：终端、VS Code / WSL、JetBrains IDE、复制路径、新建文件模板等。

- 只写当前用户的注册表（HKCU），**不需要管理员权限**，不改系统设置
- **不常驻**：没有后台进程、不开机自启、不往资源管理器里加载 DLL；只有点菜单时才短暂运行
- 按本机实际安装的软件生成菜单，没装的软件不加对应项
- 可以在「设置 > 应用」或「控制面板 > 程序和功能」里卸载，卸载会还原所有改动

## 菜单项

| 位置 | 菜单 | 需要 |
|---|---|---|
| 文件夹 / 空白处 / 驱动器 | 在此处打开 WSL | WSL |
| 文件夹 / 空白处 / 驱动器 | 更多终端 > PowerShell、命令提示符、PowerShell (管理员) | 有 Windows Terminal 时在 Terminal 里打开 |
| 文件 / 文件夹 / 空白处 | 用 VS Code 打开、用 VS Code (WSL) 打开 | VS Code（WSL 项还需 WSL） |
| 文件 / 文件夹 / 空白处 | 用 GoLand 打开 | GoLand（自动使用最新安装的版本） |
| 文件 / 文件夹 | 复制路径 > Windows 路径、WSL 路径 (/mnt/...)、文件名 | 多选时合并为多行 |
| 空白处 | 复制当前文件夹路径 > Windows 路径、WSL 路径 | |
| 文件 / 文件夹 | 用所选项目新建文件夹 | 类似 macOS Finder |
| 文件 | 开发工具 > 计算 SHA256（复制到剪贴板）、取得所有权 | 取得所有权会请求管理员 |
| 文件夹 | 开发工具 > 取得所有权（含子项） | |
| `.sh` / `.bash` 文件 | 在 WSL 中运行 (bash) | WSL |
| 发送到 | VS Code、Chrome | 对应软件已安装 |
| 新建菜单 | 文本文档、Markdown、Shell、PowerShell、JSON、YAML、Python、Go | 扩展名没有关联程序时需要 VS Code |

Windows 11 上可选择恢复经典右键菜单（安装时询问），不用再点「显示更多选项」。2026 年 11 月更新（KB5132061）之后网上流传的单个注册表开关已经不够用，本工具会一并处理。

## 安装

系统要求：Windows 10 / 11。用到的 PowerShell 5.1 和 .NET Framework 4 都是系统自带的。

**方式一：一行命令（推荐）**

在 PowerShell 里运行：

```powershell
irm https://raw.githubusercontent.com/luzhifang/win-context-menu/main/get.ps1 | iex
```

会下载最新版本、安装，然后删掉下载的临时文件。想先看看它做了什么，可以打开 [get.ps1](get.ps1)。

**方式二：下载压缩包**

在 [Releases](https://github.com/luzhifang/win-context-menu/releases) 下载源码压缩包，解压后双击 `install.cmd`。安装完成后解压出来的目录可以删掉。

**方式三：git clone**

```powershell
git clone https://github.com/luzhifang/win-context-menu.git
cd win-context-menu
.\install.cmd
```

升级：重新运行任意一种安装方式即可（重复安装 = 先清理旧版再装新版）。

安装参数（`install.cmd` 后面加，或直接运行 `install.ps1`）：

| 参数 | 作用 |
|---|---|
| `-DryRun` | 只显示检测结果和将要添加的菜单，不做任何修改 |
| `-Classic Yes` / `-Classic No` | 不询问，直接开启 / 不开启 Win11 经典右键菜单 |

## 卸载

任选一种：

- 设置 > 应用 > 已安装的应用 >「右键菜单增强」> 卸载
- 控制面板 > 程序和功能 >「右键菜单增强」
- 运行 `%LOCALAPPDATA%\ContextMenu\uninstall.cmd`

卸载会删除所有菜单项，还原被改动的扩展名设置，删除「发送到」快捷方式和安装目录。

## 常见问题

**选中很多文件时菜单不见了？**
Windows 规定：选中超过 15 个项目时，这类菜单会被隐藏。

**双击 install.cmd 弹出安全警告？**
从网上下载的文件会带「来自其他计算机」标记，点「运行」即可；也可以先在压缩包的属性里勾选「解除锁定」再解压，或改用方式一。

**公司电脑上安装失败？**
安装时会调用系统自带的 `csc.exe` 现场编译一个小程序 `cm.exe`（不附带预编译的 exe，避免 SmartScreen 拦截）。有些企业安全软件会拦截这一步。

**会占用多少资源？**
平时为零。点菜单时，大多数菜单项会启动一次 `cm.exe`，几十毫秒到一秒内退出；「用 VS Code 打开」和终端类菜单直接启动对应程序。

**已经有 VS Code 自带的「通过 Code 打开」？**
安装时检测到就不会重复添加。

**IntelliJ IDEA / PyCharm 等其他 JetBrains IDE？**
在 `install.ps1` 的 `$JetBrains` 表里加一行，然后重新安装。IntelliJ IDEA 那一行已经写好但默认注释掉了，因为它的安装程序可能已经自带了右键菜单。

## 开发

| 文件 | 作用 |
|---|---|
| `install.cmd` / `install.ps1` | 检测软件、编译 cm.exe、复制文件、写注册表、记录改动、登记到「应用」 |
| `uninstall.cmd` / `uninstall.ps1` | 按安装记录还原，最后删除安装目录 |
| `common.ps1` | 安装和卸载共用的常量和函数（清理逻辑在这里） |
| `cm.cs` | 所有菜单动作，以及 JetBrains 查找（`--jb <exe>`）。C# 5 / .NET Framework 4，不加载 WinForms，尽量轻 |
| `get.ps1` | 一行命令安装 |
| `templates\` | 「新建」菜单的文件模板 |

- 安装目录：`%LOCALAPPDATA%\ContextMenu`。其中 `install-state.json` 记录每一项非菜单改动（含原值），卸载时按它还原；`cm.config` 是 cm.exe 读取的 VS Code / Terminal 路径。
- 所有菜单键名以 `CM.` 开头。
- 编码：`.ps1` / `.cs` 为 UTF-8 **带 BOM** + CRLF，`.cmd` 只用 ASCII + CRLF，`get.ps1` 不带 BOM。`.gitattributes` 让这些文件按原样存储，不要改成自动换行转换。
- 改完先运行 `install.ps1 -DryRun` 看看效果。
- 多选时，Explorer 对每个选中项各启动一次 cm.exe，程序用命名互斥体合并为一批（约 0.2 秒延迟）。
- 路径：VS Code 在安装时查找（卸载登记 / PATH / 常见位置）；JetBrains 在点击时查找（注册表 `SOFTWARE\JetBrains`、`Program Files\JetBrains`、Toolbox 目录，取 `build.txt` 版本最大的）；WSL 使用默认发行版。

## 许可证

[MIT](LICENSE)
