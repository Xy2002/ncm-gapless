# NCM Gapless · 网易云音乐无缝播放补丁

为 Windows 和 macOS 的网易云音乐桌面客户端提供实验性无缝播放。提前准备下一首，在同一个音频时钟上接续播放，保留曲目本身的静音，不使用交叉淡化。

[中文介绍与安装指南](https://xy2002.github.io/ncm-gapless/) · [下载 Windows 维护安装包](https://github.com/Xy2002/ncm-gapless/releases/download/windows-release-v0.5.0-ci-1793171964/ncm-gapless-0.5.0-windows-maintenance.zip) · [下载源码 ZIP](https://github.com/Xy2002/ncm-gapless/archive/refs/heads/main.zip)

当前开发版本：`0.6.0-experimental`。Mac 自动更新通道尚未发布。

## 适用版本

| 平台 | 网易云客户端 | 运行要求 |
| --- | --- | --- |
| Windows x64 | `3.1.42.205594` | Windows PowerShell 5.1 或 PowerShell 7 |
| macOS Apple Silicon | `3.1.12.3444` | Python 3；自动启用需要 macOS 27，首次配置需联网 |

上表是历史实测版本。Windows 新版需通过内核 ABI 与播放接口检查；macOS 每次注入都会检查播放接口，兼容的新版可继续启用。检查失败时保留官方播放。结构探测不等于真实音频验收，也不保证所有未来版本可用。其他系统和架构见 [兼容说明](compatibility.json)。

## 工作原理

网易云桌面客户端的界面运行在内置的 Chromium / CEF 中。启动器通过本机回环地址上的 Chrome DevTools Protocol 调试接口，将补丁加载到客户端页面。PowerShell 和 Python 负责启动、注入与状态查询，音频下载、解码和播放都在客户端页面中完成。

macOS 的持续启用使用系统“快捷指令”的 App 启动触发器。每次普通打开网易云时，系统执行一次短脚本，正常退出并重开缺少调试参数的实例，再加载补丁。启动器安装在用户目录，按需检查签名更新后退出。停止脚本先撤销自动启用，再卸载内存补丁。应用文件和原厂签名保持不变，项目不安装常驻监听进程。

```mermaid
flowchart LR
    A["官方界面、队列与 SDK"] -->|授权播放信息| B["播放桥接与控制器"]
    B --> C["下载音源并解码为 PCM"]
    C --> D["Web Audio 调度与输出"]
    D -.->|播放事件| B
    B -.->|状态同步| A
```

### 接入官方播放流程

补丁保留官方选曲、播放队列、音质选择和权限检查，在官方播放器加载受支持的音源时接管播放。Windows 拦截 `channel.call`，macOS 拦截 SDK 与旧界面各自的 `callAdapter`；两端共用后面的音频引擎。

接管后，声音由 Web Audio 输出，原生播放器停止播放该曲目。控制器将加载、播放、进度、定位和结束事件反馈给官方界面，让进度条与曲目信息跟随新的播放位置。未接管的调用仍交给原有接口处理。

### 在同一个音频时钟上衔接

当前曲目和下一首先解码为 PCM 音频缓冲，再交给同一个 `AudioContext` 中的音频节点。引擎提前指定下一首的开始时间。以 1 倍速、从头播放为例：

```text
下一首开始时间 = 当前首开始时间 + 当前首 PCM 帧数 / 采样率
```

下一首的音频已经排好时间，不需要等上一首的结束事件到达 JavaScript 后再启动。结束回调用于交接内部状态并通知官方界面，因此界面处理耗时不会直接成为两首歌之间的启动间隔。

补丁不通过检测静音来猜测曲目边界，也不做交叉淡化。曲目自身的静音会保留；连续播放效果仍取决于音源本身是否连续，以及下一首能否及时准备好。

### 预取、换曲与播放控制

补丁通过官方预取入口获取下一首的授权播放信息，只准备当前曲目与紧接的下一首。下一首下载、解码完成后，音频引擎将它排到当前曲目的结尾。

当官方队列随后切到同一首、同一音源时，控制器复用已经开始的音频并更新曲目状态，避免重新加载造成中断。音量和官方提供的曲目增益也会应用到新的音频节点。

暂停与恢复控制共用的音频时钟；定位或变速会重新安排音源。控制器监听队列、播放模式和音质变化，取消旧预取并重新准备，已失效的下载或解码结果不会接管后续曲目。

### 音源、格式与内存

音源来自当前账号经官方流程取得的播放信息。补丁只读取受支持的网易云音源地址；遇到 `401`、`403` 或 `410` 时，通过官方授权入口最多刷新一次链接。试听、受限音源和加密本地缓存继续使用官方播放路径。

MP3、FLAC、WAV 由客户端的 `decodeAudioData` 解码。AAC/M4A 还需要核对样本时长表、编码延迟和编辑列表，只有能确定有效采样范围时才调整容器时长元数据。压缩音频数据保持原样，无法确定精确时长或解码长度不符时回退官方播放。

每首歌需要完整下载并解码后才能播放，因此首次起播会有缓冲等待。默认单文件压缩数据预算为 80 MiB，当前与下一首的 PCM 缓冲合计预算为 256 MiB；浏览器和临时数据还会占用额外内存。当前曲目加载失败或超过预算时交回官方播放器，下一首未及时准备好时无法保证连续衔接。

## 开始使用

Windows 自动维护可直接使用下面的维护安装包；开发或使用其他入口时可下载源码 ZIP 或克隆仓库。所有 ZIP 均需完整解压并保留目录结构。

### Windows

希望网易云更新后自动检查兼容、恢复加载模块和获取补丁更新：

1. 下载 [Windows 维护安装包（0.5.0 实验版）](https://github.com/Xy2002/ncm-gapless/releases/download/windows-release-v0.5.0-ci-1793171964/ncm-gapless-0.5.0-windows-maintenance.zip)，或在 [Releases](https://github.com/Xy2002/ncm-gapless/releases) 的 Assets 中选择 `ncm-gapless-*-windows-maintenance.zip`。`Source code (zip)` 是源码包，不含已构建的维护载荷。
2. 完整解压，双击 `Install-NcmGaplessMaintenance.cmd`，允许一次管理员安装。完整维护包自带 `updates/windows-update.json` 和 `updates/windows-payload.zip`，首次安装也可离线进行。

使用当前源码 ZIP、克隆仓库或 Windows startup 包时，也可直接运行同一个安装器：如果缺少完整的本地签名清单和载荷，会自动从固定 Windows 维护通道下载，使用内置公钥验签并核对哈希后再安装，无需自己编译。下载的是通道已发布的 Windows 版本，可能与上方开发版本不同；下载失败会显示手动下载入口。需要禁止联网时，运行 `.\Install-NcmGaplessMaintenance.ps1 -Offline`；缺文件时会明确列出缺失路径与解决方法。

安装后系统任务定时短暂运行；运行中的客户端延后处理，不会自动关闭或重开。离线可从已验签缓存修复。详见 [自动维护说明](docs/windows-maintenance.md)。

需要从原图标、菜单、程序或其他入口打开时自动启用，可安装可选的 [Windows 启动模块](docs/windows-startup.md)：彻底退出客户端，双击 `Install-NcmGaplessStartup.cmd` 完成一次性安装。它在客户端初始化时加载补丁，加载器完成后退出；不会自动关闭或重开网易云。该入口需要含已编译模块的 Windows startup 包，源码用户需先构建。

只对本次运行启用时：

1. 完全退出网易云，再双击 `Start-NcmGapless.cmd` 启动并启用。
2. 在网易云中重新选择一首歌曲开始播放。
3. 双击 `Get-NcmGaplessStatus.cmd` 查看状态。

不需要安装 Python、Node.js 或使用管理员权限。非标准安装路径可手动指定：

```powershell
.\Start-NcmGapless.ps1 -ClientPath 'D:\Apps\CloudMusic\cloudmusic.exe'
```

### macOS

1. 安装好 Python 3 后，双击 `Start-NcmGapless.command` 进入初始化向导。脚本把运行文件安装到 `~/Library/Application Support/NcmGapless`，准备独立依赖并生成快捷指令。
2. 首次按向导在系统界面添加快捷指令、打开网易云自动化并允许脚本运行，回到终端按回车。脚本会实际重开客户端自检，通过后显示“配置完成”。
3. 首次启用后重新选曲。此后直接从原图标打开网易云，退出重开也会自动启用，直到执行停止脚本。安装目录中保留启用、停止和状态三个 `.command` 入口。

也可以在解压目录运行：

```bash
./Start-NcmGapless.command
```

配置成功后可删除下载的源码目录，请保留安装目录和 Python 3 本体。自动启用需要 macOS 27。首次系统许可需要本人确认，初始化和普通启动都可能正常重开客户端。更早系统的手动方式、旧版迁移和错误处理见 [macOS 使用说明](docs/macos.md)。

Mac 已实现启动后检查签名更新、下次启动切换版本及失败回退，更新通道尚未配置发布；当前不能依赖它获取新补丁。更新机制与验收边界见 [Mac 自动维护说明](docs/macos-maintenance.md)。

## 状态与停用

| 状态字段 | 含义 |
| --- | --- |
| `installed` | 补丁已启用 |
| `active` | 当前曲目已接管 |
| `nextReady` | 下一首已准备好 |
| `sampleRate` | 当前音频时钟的采样率 |
| `decodedBytes` | 当前与下一首的 PCM 缓冲字节数，不含进程其他内存 |
| `lastBoundaryDeltaFrames` | 最近一次换曲的计划边界帧差，`0` 表示调度对齐，尚未换曲时为 `null` |
| `fallbacks` / `lastError` | 回退次数和最近错误 |
| `automaticEnabled` | 自动启用状态；停止脚本会关闭它 |
| `automaticLastResult` / `automaticLastError` | Windows 最近一次启动加载结果与错误代码 |
| `maintenance` | 自动维护状态；各平台字段见维护说明 |
| `shortcutImported` | Mac 系统快捷指令已导入，还需开启其 App 自动化 |

Windows 双击 `Stop-NcmGapless.cmd`，macOS 双击 `Stop-NcmGapless.command` 停用并恢复官方播放。

音频补丁驻留在内存。可选 Windows 启动模块会新增自己的 DLL 与运行文件，保留网易云原有文件；安装后从原入口打开即可自动加载，停止脚本会撤销自动启用。Windows 自动维护在客户端关闭后处理更新和修复；未安装启动模块时，重启后仍需手动运行启动器。Mac 完成一次性配置后由系统恢复，更新包完整下载并验签后留待下次启动使用。

Windows 手动更新应先停用旧版，再从新目录安装或启用；Mac 手动更新运行新版 `Start`。完成后重新选曲。

停用会取消下载与预取、关闭 Web Audio 引擎、恢复原始桥接，再交回官方播放器。已接管曲目按当前位置和播放 / 暂停状态恢复；仍在加载的曲目从头恢复。

## 已知限制

- 首次选曲需要缓冲和解码，长音轨、网络失败或超出内存预算时可能回退官方播放。
- 支持授权播放信息中的 MP3、FLAC、WAV 和部分 AAC/M4A；无法可靠确定时长的格式会回退。
- 加密本地缓存、试听及权限受限音源不接管，不提供会员或版权限制绕过。
- 官方音效、空间音频、独占设备、蓝牙和系统媒体控制可能与官方播放器表现不同。
- 随机播放、单曲循环、动态修改队列、切换音质或设备等场景仍需完善。
- Mac 尚未覆盖同一进程内的页面重载。资源热更新若重建播放器页面，内存补丁会消失，需要正常退出并重新打开客户端。

## 代码入口

| 文件 | 职责 |
| --- | --- |
| [client-adapter.js](src/client-adapter.js) | 客户端版本与能力检查、平台桥接、官方队列和授权入口 |
| [netease-gapless.js](src/netease-gapless.js) | 播放接管、音源下载、预取、事件同步和失败回退 |
| [gapless-engine.js](src/gapless-engine.js) | 音频节点调度、暂停、定位、倍速和曲目交接 |
| [aac-timing.js](src/aac-timing.js) | AAC/M4A 有效采样范围检查与时长元数据处理 |
| [Start-NcmGapless.ps1](Start-NcmGapless.ps1) / [macos_launcher.py](tools/macos_launcher.py) | Windows / macOS 启动与内存补丁加载 |

## 更多文档

- [macOS 使用说明](docs/macos.md)
- [macOS 自动维护](docs/macos-maintenance.md)
- [开发与贡献](CONTRIBUTING.md)
- [实现说明](docs/implementation.md)
- [路线图](docs/roadmap.md)
- [更新记录](CHANGELOG.md)

反馈问题时，请提供系统与客户端版本、补丁版本、重现步骤和脱敏状态。不要上传 Cookie、令牌、音源地址或歌曲文件。

本项目原创代码和文档采用 [MIT 许可证](LICENSE)，第三方代码保留各自许可，见 [CEF 声明](LICENSES/CEF.txt)。本项目与网易云音乐没有官方关联，许可不涵盖网易云客户端或音乐内容。
