# NCM Gapless

为网易云音乐桌面客户端提供连续专辑播放。提前准备下一首，在同一个音频时钟上接续播放，保留曲目本身的静音，不使用交叉淡化。

当前版本：`0.3.1-experimental`。

## 适用版本

| 平台 | 网易云客户端 | 运行要求 |
| --- | --- | --- |
| Windows x64 | `3.1.42.205594` | Windows PowerShell 5.1 或 PowerShell 7 |
| macOS Apple Silicon | `3.1.12.3444` | Python 3，首次运行需要联网 |

这是实验版本。未知客户端版本会拒绝启用；其他系统和架构的兼容情况见 [兼容说明](compatibility.json)。

## 开始使用

下载仓库源码 ZIP 或克隆仓库。使用便携包时也需完整解压并保留目录结构，启动前先完全退出网易云。

### Windows

1. 双击 `Start-NcmGapless.cmd` 启动并启用。
2. 在网易云中重新选择一首歌曲开始播放。
3. 双击 `Get-NcmGaplessStatus.cmd` 查看状态。

不需要安装 Python、Node.js 或使用管理员权限。非标准安装路径可手动指定：

```powershell
.\Start-NcmGapless.ps1 -ClientPath 'D:\Apps\CloudMusic\cloudmusic.exe'
```

### macOS

1. 安装好 Python 3 后，双击 `Start-NcmGapless.command`。
2. 首次运行会在程序目录创建 `.venv` 并安装依赖，之后自动复用。
3. 在网易云中重新选曲，双击 `Get-NcmGaplessStatus.command` 查看状态。

也可以在解压目录运行：

```bash
./Start-NcmGapless.command
```

启动器不会向系统 Python 安装包。非标准路径、手动安装和错误处理见 [macOS 使用说明](docs/macos.md)。

## 状态与停用

| 状态字段 | 含义 |
| --- | --- |
| `installed` | 补丁已启用 |
| `active` | 当前曲目已接管 |
| `nextReady` | 下一首已准备好 |
| `fallbacks` / `lastError` | 回退次数和最近错误 |

Windows 双击 `Stop-NcmGapless.cmd`，macOS 双击 `Stop-NcmGapless.command` 停用并恢复官方播放。

补丁只驻留在内存，不修改网易云安装文件。重启网易云后需要重新启用；更新补丁前，先停用旧版，再启动新版并重新选曲。

## 已知限制

- 首次选曲需要缓冲和解码，长音轨、网络失败或超出内存预算时可能回退官方播放。
- 支持授权播放信息中的 MP3、FLAC、WAV 和部分 AAC/M4A；无法可靠确定时长的格式会回退。
- 加密本地缓存、试听及权限受限音源不接管，不提供会员或版权限制绕过。
- 官方音效、空间音频、独占设备、蓝牙和系统媒体控制可能与官方播放器表现不同。
- 随机播放、单曲循环、动态修改队列、切换音质或设备等场景仍需完善。

## 更多文档

- [macOS 使用说明](docs/macos.md)
- [开发与贡献](CONTRIBUTING.md)
- [实现说明](docs/implementation.md)
- [路线图](docs/roadmap.md)
- [更新记录](CHANGELOG.md)

反馈问题时，请提供系统与客户端版本、补丁版本、重现步骤和脱敏状态。不要上传 Cookie、令牌、音源地址或歌曲文件。

本项目与网易云音乐没有官方关联，许可证尚待确定。
