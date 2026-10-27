# macOS 使用说明

适用于网易云 `3.1.12.3444` 与 Apple Silicon。自动启用需要 macOS 27；其他客户端版本拒绝启用，Intel 兼容性尚未确认。

## 首次配置

需要已安装的 Python 3。双击 `Start-NcmGapless.command` 后，启动器会在需要时创建程序目录中的 `.venv`，联网安装 `websocket-client`，并为当前客户端启用补丁。依赖不会安装到系统 Python。

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

辅助 Python 脚本在注入后退出。音频引擎运行在网易云自己的页面内，项目不安装 LaunchAgent 或常驻监听进程。原应用文件和原厂签名保持不变。

`Stop` 先删除项目的持续启用状态和调用入口，等待正在执行的操作结束，再恢复官方播放。关闭客户端后也能停止。系统快捷指令保留以供下次复用，但在停止状态下不再执行项目启动器；后续从原图标打开网易云也不会加载补丁。

更新补丁或移动程序目录前先运行旧目录的 `Stop`，再从新目录运行 `Start`。请保留启用时的目录与 `.venv`，不要把虚拟环境复制到其他机器。

## 状态字段

| 字段 | 含义 |
| --- | --- |
| `automaticEnabled` | 项目的持续启用标记；系统中的 App 自动化也需开启 |
| `shortcutImported` | 同名系统快捷指令是否已导入，不代表其中的自动化开关已开启 |
| `shortcutImportRequired` | 本次启用仍需完成首次导入 |
| `setupVerified` | 本次初始化已通过真实普通启动自检，仅在向导成功结果中返回 |
| `automaticLastRun` | 当前启用周期内最近一次按需调用的时间、安装结果和错误码 |
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
| `NCM_AUTOMATION_SOURCE_CHANGED` | 先停止，再从当前完整目录启用 |
| `NCM_CLIENT_QUIT_FAILED` / `NCM_CLIENT_QUIT_TIMEOUT` | 客户端未接受正常退出；处理其对话框或手动退出后重试，启动器不会强制结束进程 |
| `NCM_DEBUG_PORT_NOT_READY` | 已带调试参数的客户端尚未就绪，正常退出后重开；自动化不会反复重启它 |
| `NCM_EXIT_AND_RESTART_WITH_LAUNCHER` | 当前会话手动入口遇到普通启动实例；完全退出后再执行 |
| `NCM_INSTALLATION_NOT_UNIQUE_USE_CLIENT_PATH` | 检查安装；存在多个副本时指定 `--client-path` |
| `CLIENT_VERSION_UNVERIFIED` | 当前仅适配 `3.1.12.3444`，升级客户端后需重新验证 |
| `NCM_DEPENDENCY_MISSING` / `NCM_DEPENDENCY_SETUP_FAILED` | 从程序目录重新运行 `Start`，检查网络、Python 与目录权限 |
| `NCM_SCRIPT_ERROR_UNSUPPORTED_CLIENT_OR_STATE` | 确认客户端版本与主界面就绪，退出后重试并反馈脱敏状态 |

开发、测试与打包命令见 [开发与贡献](../CONTRIBUTING.md)。
