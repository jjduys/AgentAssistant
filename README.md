<p align="center">
  <img src="Resources/AppIcon.png" alt="AgentAssistant 图标" width="128">
</p>

# AgentAssistant

中文 | [English](README.en.md)

一个原生 macOS 菜单栏工具：把临时文字、文件和图片挂在屏幕边缘，随时编辑、预览或拖到其他应用，也可以在同一个菜单中控制系统的“永不睡眠”开关。

使用 Swift + AppKit 开发，无第三方运行依赖。当前版本为 **1.4.0（构建 11）**，项目原名 TCenter。

## 主要功能

| 功能 | 使用方式 |
| --- | --- |
| 文件吊栏 | 点击菜单栏助手图标、使用快捷键，或把鼠标移入指定屏幕角落 |
| 临时记录 | 在吊栏按 ⌘V，文字自动保存为 Markdown，也支持文件和图片 |
| 最近文件 | 一键打开最近访问的文件；文本进入编辑，图片进入预览 |
| 文件编辑 | 支持 Markdown、TXT、CSV、JSON、XML，编辑后自动保存 |
| 截图接收 | 识别截图操作，只接收本次捕获会话的新结果，保留原图 |
| 永不睡眠 | 查看系统状态、开启或关闭，并手动刷新状态 |

## 构建与安装

需要 macOS 13.0 及以上，以及包含 Swift 的 Xcode Command Line Tools。当前验证环境为 Apple Silicon；构建脚本生成当前机器架构的应用，Intel 环境尚未验证。

```sh
git clone https://github.com/jjduys/AgentAssistant.git
cd AgentAssistant

zsh scripts/build.sh
open build/AgentAssistant.app --args --show
```

GitHub 仓库、本地目录、Swift 包和应用名称均为 `AgentAssistant`；原仓库地址 `jjduys/TCenter` 会由 GitHub 自动跳转。

构建完成后，将 `build/AgentAssistant.app` 拖入“应用程序”即可安装。它是菜单栏应用，启动后通过顶部的助手图标使用，不显示 Dock 图标。

更新时，先正常退出正在运行的应用，再替换应用包并重新打开。在助手图标的右键菜单选择“关于 AgentAssistant”可以查看版本和构建号。

应用使用本机临时签名，未进行 Developer ID 公证。跨机器分发和其他系统版本的运行情况尚未完整验证。

## 日常使用

### 打开吊栏与最近文件

| 操作 | 默认快捷键 |
| --- | --- |
| 展开 / 收起吊栏 | Control + Option + Space（⌃⌥Space） |
| 打开最近访问的文件 | Control + Option + Return（⌃⌥Return） |

右键菜单栏助手图标，选择“设置…”可修改两个快捷键，也可通过应用菜单的 ⌘, 打开设置。快捷键至少包含 Control、Option、Command 中一个；重复或已被占用的组合键不能保存。设置保存后立即生效，重启后保留。

设置窗口打开时，全局快捷键暂时停用，关闭后恢复。快捷键注册状态可在“关于 AgentAssistant”中查看。

“最近访问”按应用内的访问记录判断：创建、导入、打开、重新激活编辑窗口、保存，以及成功拖出文件都会更新时间。后台缩略图读取不改变排序，记录重启后保留。吊栏从左到右按旧到新排列；已有编辑窗口会直接置前，最小化窗口会恢复。

### 鼠标四角触发

设置中可选左上、右上、左下、右下，**默认左上角**。进入所在屏幕对应角落的 **32 × 32 点**区域时展开吊栏；上方角落在屏幕上方显示，下方角落在屏幕下方显示。

- 停在触发区域或吊栏中时保持显示，拖拽期间也保持显示。
- 离开后 3 秒收起；重新进入会取消倒计时。
- 手动收起后，需要先离开触发区域，再进入才会重新展开。
- 点击其他应用会立即收起吊栏。

全局快捷键和角落触发无需辅助功能权限。

### 添加与移出文件

- 点击吊栏右侧的“＋ 添加”，可新建 MD、TXT、JSON、XML、CSV 文档或导入文件；右键菜单栏图标也有相同入口。
- 吊栏展开后按 ⌘V，可添加剪贴板中的文件、图片或文字。文字生成 `.md` 文件，保留原始内容。
- 支持从访达拖入文件。导入时复制到应用存储目录，原文件保留，重名副本自动避让。
- 点击挂件打开编辑器或图片预览；拖出挂件使用 macOS 文件复制语义。
- 点击挂件的 ×，仅将应用存储的副本移到废纸篓，原文件保留。

### 编辑与自动保存

| 文件类型 | 编辑方式 |
| --- | --- |
| MD / Markdown | 文本编辑；基础标题、列表、粗体、行内代码和代码块预览 |
| TXT | 原生文本编辑，支持剪切、复制、粘贴和撤销 |
| CSV | 表格编辑、增加 / 删除行列、源码切换；支持引号、转义、多行与 CRLF |
| JSON | 树状字段、值和类型编辑，增加 / 删除节点，源码切换 |
| XML | 元素、属性、文本和注释树编辑，增加 / 删除节点，源码切换 |
| 图片 | 按比例预览 PNG、JPEG、GIF、HEIC、HEIF、TIFF、WebP、BMP，解码能力以 macOS 为准 |

文本和 CSV 停止输入 350 毫秒后保存；树状字段结束编辑后校验并保存。关闭窗口或退出前会立即保存，保存失败时阻止关闭。关闭编辑窗口不删除挂载文件。

文本读取支持 UTF-8 和带 BOM 的 UTF-16，保存统一使用 UTF-8。JSON 树状保存会重新缩进和排序键，XML 序列化可能调整格式细节；Markdown 预览为基础子集。

## 截图接收

正常使用 macOS 截图工具即可。应用通过截图工具的启动 / 激活、工具栏显示变化，以及系统允许观察的截图按键事件，识别一次捕获会话。

- 会话开始时记录目录基线，只接收随后创建的截图结果；启动时不会扫描并导入历史图片。
- 等待文件稳定后复制到吊栏，原图保留。每次会话成功接收一张后结束。
- 支持截图保存为文件或写入剪贴板；剪贴板模式不依赖截图目录访问权限。
- 已处理文件的身份和内容摘要会持久化，避免删除挂件或重启后重复导入。
- 截图工具栏消失后最多等待 30 秒落盘，会话总时长最多 120 秒；超时或取消后不回扫历史结果。

文件接收取决于系统截图目录的访问权限；全局截图按键和 Esc 事件能否被观察，取决于系统现有权限。识别不到截图操作时，可展开吊栏后用 ⌘V 手动添加。在“关于 AgentAssistant”中可以查看监听状态。

剪贴板没有可靠统一的截图来源标记：在等待剪贴板截图的会话期间，主动复制其他图片也可能被当作本次截图接收。浮动缩略图仍在编辑时，文件模式需要等系统实际保存后才能接收。

## 永不睡眠

右键菜单栏助手图标，菜单顶部提供三项操作：

| 菜单项 | 含义 |
| --- | --- |
| 永不睡眠：已开启 / 已关闭 | 显示系统当前状态；读取失败时显示“状态未知” |
| 关闭 / 开启永不睡眠 | 切换系统 `SleepDisabled` 开关 |
| 刷新状态 | 立即重新读取系统状态 |

切换时由 macOS 请求管理员授权，应用不读取或保存管理员密码。固定执行的命令为：

```sh
# 开启
pmset -a disablesleep 1

# 关闭
pmset -a disablesleep 0
```

命令通过系统管理员授权执行，随后回读核对；取消授权或执行失败时，菜单以重新读取的实际状态为准。应用也会每 5 秒及系统唤醒后自动同步，切换期间禁止重复操作。

**退出应用会保留当前系统设置。** 如需恢复，请先在菜单中关闭永不睡眠。此功能不改变屏幕关闭计时、原有睡眠计时或其他进程的电源请求；关闭后是否自动睡眠，还取决于系统原有配置。

## 数据与旧版兼容

AgentAssistant 沿用原 TCenter 的应用标识和存储位置，因此可以直接继续使用已有便签、截图历史、快捷键和四角设置。

| 内容 | 位置 |
| --- | --- |
| 文件副本 | `~/Library/Application Support/TCenter/Files/` |
| 最近访问记录 | `~/Library/Application Support/TCenter/Files/.access-history.json` |
| 截图处理记录 | `~/Library/Application Support/TCenter/screenshot-history.json` |
| 应用设置 | `local.tcenter.app` 偏好域，设置键为 `TCenter.settings` |

可在右键菜单中选择“打开存储目录”。备份时，保存上述应用数据目录；如需保留快捷键和触发角落，也应同时保留对应的应用偏好设置。

## 开发与测试

```sh
# 构建应用，同时生成各尺寸图标和 ICNS
zsh scripts/build.sh

# 文件格式、存储、访问排序及设置等核心检查
build/AgentAssistant.app/Contents/MacOS/AgentAssistant --self-test

# 编辑器、吊栏、菜单、图标及交互回归
build/AgentAssistant.app/Contents/MacOS/AgentAssistant --ui-test

# 睡眠逻辑专项测试
zsh scripts/test-power.sh

# 验证应用包
codesign --verify --deep --strict build/AgentAssistant.app
plutil -lint build/AgentAssistant.app/Contents/Info.plist
```

测试使用独立目录和模拟睡眠后端，不修改真实睡眠设置。界面回归会短暂创建测试窗口，渲染结果位于 `build/ui-check/`。构建产物、测试日志和本机备份均保存在 Git 忽略的 `build/` 目录中。

已验证核心逻辑、编辑器和菜单回归、图标生成、系统全局快捷键通道，以及单屏四角的进入、停留和收起。真实管理员授权切换、多屏 / 全屏、向外部应用拖放及完整真实截图流程尚未全部完成实机验收。详细范围和历史记录见 [VALIDATION.md](VALIDATION.md)。

### 代码结构

```text
Sources/
  App.swift                 菜单栏入口、文件操作与窗口协调
  Shelf.swift               吊栏、文件卡片、拖放和自动收起
  Editor.swift              文本、Markdown、CSV、JSON、XML 和图片视图
  Models.swift              文件存储、最近访问记录与格式编解码
  Settings.swift            快捷键录入和四角设置
  ShelfHotKey.swift         系统全局快捷键注册
  ScreenshotMonitor.swift   截图会话识别、接收和持久化去重
  PowerService.swift        系统睡眠状态与管理员命令
  SleepController.swift     异步切换、状态刷新和错误处理
  SleepMenu.swift           永不睡眠菜单
  BrandIcon.swift           应用与菜单栏图标的原生矢量绘制
  SelfTests.swift           核心检查
  UITests.swift             界面与场景回归
Tests/PowerTests.swift      睡眠逻辑专项测试
Tools/GenerateIcons.swift  图标资源生成
scripts/build.sh           构建与应用打包
scripts/test-power.sh      编译并运行睡眠测试
```
