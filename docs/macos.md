# macOS 使用说明

历史实测为 Apple Silicon 上的网易云 `3.1.12.3444`。`0.6.0-experimental` 对新旧客户端都检查播放接口，兼容的新版可继续启用，检查失败时保留官方播放。自动启用需要 macOS 27，Intel 和新版客户端的真实音频表现尚未验收。

## 首次配置

需要已安装的 Python 3。双击 `Start-NcmGapless.command` 后，启动器把运行文件安装到 `~/Library/Application Support/NcmGapless`，在该目录独立创建 `.venv`，联网安装 `websocket-client`。依赖不会安装到系统 Python，也不会复制下载目录中的旧虚拟环境。

首次还会使用 Apple 的 `shortcuts sign` 签署本地通用模板，并打开系统导入界面。签署需要联网；网易云应用本身不会被修改或重新签名。

1. 双击 `Start-NcmGapless.command` 进入初始化向导，脚本自动准备依赖、定位客户端和生成系统快捷指令。
2. 在打开的系统界面添加“NCM Gapless 自动启用”。向导会检测导入完成，并打开这个快捷指令。
3. 展开顶部的网易云 App 条件，打开“自动化”；“通知”可以保持关闭。若脚本操作已停用，点“打开偏好设置”，开启“允许运行脚本”。该开关也可在“快捷指令 → 设置 → 高级”找到，是系统的全局脚本许可。
4. 回到终端按回车，脚本会正常退出客户端并从原应用入口重开，检查系统是否真的自动加载补丁。只有通过后才显示“配置完成”，并返回 `setupVerified: true`。
5. 首次启用后重新选曲开始播放。日常直接打开网易云即可，无需再运行初始化向导。

配置完成后，可以退出“快捷指令”界面。已有有效配置会直接自检，跳过首次设置问题。初始化会正常重开客户端；取消或失败时会撤销本次自动启用并尝试恢复官方播放。配置确认时可输入 `q`，任意阶段可按 Ctrl+C 取消。

首次添加与系统开关仍需本人确认。向导使用系统提供的导入、查看和签署接口，不需要辅助功能权限，也不直接改写快捷指令数据库。[Apple 脚本许可说明](https://support.apple.com/guide/shortcuts-mac/advanced-shortcuts-settings-apdfeb05586f/mac)

## 日常使用与停止

```bash
./Start-NcmGapless.command
./Get-NcmGaplessStatus.command
./Stop-NcmGapless.command
```

`Start` 开启持续启用并自检。已导入的系统规则会复用，不需要反复配置。普通启动的客户端缺少调试参数时，短脚本会请求正常退出，再以仅监听 `127.0.0.1` 的调试参数重新打开并注入补丁；窗口可能短暂关闭和重开。已带调试参数的实例直接复用，补丁已安装时跳过注入。

辅助 Python 脚本在注入和按需更新检查后退出。音频引擎运行在网易云自己的页面内，项目不安装 LaunchAgent 或常驻监听进程。启用前检查网易云的 Apple 签名信任、应用标识和开发者团队，检查失败时拒绝启用。原应用文件和原厂签名保持不变。

`Stop` 先删除项目的持续启用状态和调用入口，等待正在执行的操作结束，再恢复官方播放。关闭客户端后也能停止。系统快捷指令保留以供下次复用，但在停止状态下不再执行项目启动器；后续从原图标打开网易云也不会加载补丁。

配置成功后可删除下载的源码目录。安装目录中保留 `Start-NcmGapless.command`、`Stop-NcmGapless.command` 和 `Get-NcmGaplessStatus.command`，后续可直接双击使用。请保留安装目录和创建虚拟环境所用的 Python 3 本体，不要把 `.venv` 复制到其他机器。

从旧版升级时，在完整的新目录运行一次 `Start`，把原先绑定下载目录的配置迁移到固定安装目录。完成自检后再删除旧目录；系统快捷指令继续复用。

## 网易云与补丁更新

网易云更新后，每次注入都重新检查当前页面的播放接口，应用版本号未变时也检查。结构兼容的新版本可继续启用，内部接口变化时拒绝接管，不把播放接口检查当成音频验收。

维护流程在启动注入后检查补丁更新，两次成功检查至少间隔六小时，检查失败后至少等三十分钟再试。这是启动时的检查间隔，不是后台定时任务。完整下载并验签的新补丁留待下次启动使用；同一版本在三个不同页面实例中激活失败时回退到上一版，客户端兼容检查失败不计入回退次数。

当前更新通道尚未发布，签名密钥也未配置，不能依赖自动下载获得新补丁。发布与回退细节见 [自动维护说明](macos-maintenance.md)。本版本尚未完成真实客户端升级和音频验收。

同一进程内的页面重载不在自动恢复范围内。如果资源热更新重建了播放器页面，需要正常退出并重新打开网易云，才能再次触发系统自动化。

## 状态字段

| 字段 | 含义 |
| --- | --- |
| `automaticEnabled` | 项目的持续启用标记；系统中的 App 自动化也需开启 |
| `shortcutImported` | 同名系统快捷指令是否已导入，不代表其中的自动化开关已开启 |
| `shortcutImportRequired` | 本次启用仍需完成首次导入 |
| `setupVerified` | 本次初始化已通过真实普通启动自检，仅在向导成功结果中返回 |
| `automaticLastRun` | 当前启用周期内最近一次按需调用的时间、安装结果和错误码 |
| `maintenance.result` / `maintenance.error` | 最近一次维护结果和更新错误，不代表音频接管状态 |
| `maintenance.version` / `maintenance.failureCount` | 下次启动所用补丁版本，以及其不同页面实例激活失败次数 |
| `maintenance.rollbackAvailable` | 是否有可回退的上一版 |
| `installed` / `active` | 内存补丁已安装 / 当前曲目已由补丁接管 |
| `nextReady` | 下一首已准备好 |
| `errors` / `fallbacks` | 播放错误和回退次数 |

`automaticEnabled: true` 和 `shortcutImported: true` 后，正常退出并重新打开网易云；`automaticLastRun.installed: true` 表示按需入口已运行并完成安装。安装后仍按现有播放规则，在官方加载受支持音源时接管。

## 非标准路径与手动方式

应用不在标准目录时，启用命令可以指定路径：

```bash
./Start-NcmGapless.command --client-path '/Volumes/Apps/NeteaseMusic.app'
```

自动化、停止和状态命令默认复用启用时保存的客户端路径；也可用 `--client-path` 覆盖本次查询或控制。

更早的 macOS，或只希望启用当前会话时，先完全退出网易云，再运行已有的手动入口：

```bash
python3 tools/macos_launcher.py install
```

该方式不注册持续启用状态，退出客户端后需要再次执行。手动准备依赖可使用：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-macos.txt
```

## 常见问题

| 错误或现象 | 处理方式 |
| --- | --- |
| 已导入但重开后未启用 | 打开“NCM Gapless 自动启用”，展开网易云条件并确认“自动化”已打开；检查全局脚本许可和 `automaticLastRun` |
| `NCM_SETUP_REQUIRES_TERMINAL` | 从 Finder 双击 `Start-NcmGapless.command`，或在交互终端运行，按向导完成首次确认 |
| `NCM_SETUP_NOT_READY` | 普通启动自检未通过，按向导确认两个系统开关后重试；最多验证三次，失败会回滚 |
| `NCM_SETUP_CANCELLED` / `NCM_OPERATION_CANCELLED` | 初始化已取消或等待超时，重新双击启动脚本即可重试 |
| `NCM_AUTOMATION_REQUIRES_MACOS_27` | 使用上面的当前会话手动入口，或在 macOS 27 配置自动化 |
| `NCM_AUTOMATION_IMPORT_FAILED` | 检查网络与系统快捷指令能否正常签署文件，再运行 `Start`；失败时持续启用标记会撤销 |
| `NCM_AUTOMATION_SHORTCUT_NOT_UNIQUE` | 系统存在多个同名快捷指令，保留正确配置的一个后重试 |
| `NCM_AUTOMATION_SOURCE_CHANGED` | 从完整的新目录运行 `Start`，重新安装并完成配置迁移 |
| `NCM_CLIENT_QUIT_FAILED` / `NCM_CLIENT_QUIT_TIMEOUT` | 客户端未接受正常退出；处理其对话框或手动退出后重试，启动器不会强制结束进程 |
| `NCM_DEBUG_PORT_NOT_READY` | 已带调试参数的客户端尚未就绪，正常退出后重开；自动化不会反复重启它 |
| `NCM_EXIT_AND_RESTART_WITH_LAUNCHER` | 当前会话手动入口遇到普通启动实例；完全退出后再执行 |
| `NCM_INSTALLATION_NOT_UNIQUE_USE_CLIENT_PATH` | 检查安装；存在多个副本时指定 `--client-path` |
| `NCM_CLIENT_SIGNATURE_INVALID` / `NCM_CLIENT_PUBLISHER_UNVERIFIED` | 无法确认官方客户端签名和身份；使用官方安装包，勿绕过校验 |
| `CLIENT_VERSION_UNVERIFIED` | 无法识别客户端版本或平台；检查是否为官方桌面客户端，附脱敏状态反馈 |
| `CLIENT_PLAYBACK_CONTRACT_UNSUPPORTED` / `CLIENT_BRIDGE_MISSING` / `PLAYBACK_INTERFACE_MISSING` | 当前页面缺少所需播放接口，保留官方播放并等待兼容适配 |
| `NCM_DEPENDENCY_MISSING` / `NCM_DEPENDENCY_SETUP_FAILED` | 重新运行 `Start`，检查网络和 Python；如果安装目录中的 Python 已损坏，从完整程序包运行 `Start` 修复 |
| `NCM_SCRIPT_ERROR_UNSUPPORTED_CLIENT_OR_STATE` | 确认客户端版本与主界面就绪，退出后重试并反馈脱敏状态 |

开发、测试与打包命令见 [开发与贡献](../CONTRIBUTING.md)。
