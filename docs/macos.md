# macOS 使用说明

适用于网易云 `3.1.12.3444` 与 Apple Silicon。其他客户端版本拒绝启用，Intel 兼容性尚未确认。

## 安装与使用

运行需要已安装的 Python 3。`0.3.1` 起，双击启动器会在首次使用时自动创建解压目录中的 `.venv`，联网安装 `websocket-client` 后继续启动；后续复用环境，不向系统 Python 安装包。

若需要手动准备环境，在解压后的根目录运行：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-macos.txt
```

虚拟环境不能随便携包复制到其他机器，需要在目标机器上重新创建。

1. 完全退出网易云，再双击 `Start-NcmGapless.command`。默认从 `/Applications` 和 `~/Applications` 查找网易云，也会复用由启动器打开的现有实例。
2. 重新选择一首歌曲开始播放，让实验引擎接管。
3. 双击 `Get-NcmGaplessStatus.command` 查看 `installed`、`active`、`nextReady`、`errors` 和 `fallbacks`。
4. 双击 `Stop-NcmGapless.command` 恢复官方播放。重新启动客户端也会清除内存补丁。

也可在终端运行：

```bash
./Start-NcmGapless.command
./Get-NcmGaplessStatus.command
./Stop-NcmGapless.command
```

应用不在标准目录时，三个命令都接受相同路径参数：

```bash
./Start-NcmGapless.command --client-path '/Volumes/Apps/NeteaseMusic.app'
```

更新前先停用旧版，再运行新版启动器。已安装的旧补丁不会因再次点击启用而自动替换。

## 常见问题

启动器不修改应用包、签名、系统安全设置或账号配置。它自动选择空闲的本机调试端口。

已经通过普通方式打开且未启用调试的客户端，需要用户先正常退出。启动器不会强制结束正在运行的网易云。

| 错误 | 处理方式 |
| --- | --- |
| `NCM_EXIT_AND_RESTART_WITH_LAUNCHER` | 完全退出网易云，再运行启动器 |
| `NCM_INSTALLATION_NOT_UNIQUE_USE_CLIENT_PATH` | 确认已安装客户端；存在多个副本时用 `--client-path` 指定 |
| `CLIENT_VERSION_UNVERIFIED` | 当前仅适配 `3.1.12.3444`，升级后需重新验证 |
| `NCM_DEPENDENCY_MISSING` | 旧版便携包缺少首次初始化，请使用 `0.3.1` 或按上面的命令手动安装 |
| `NCM_DEPENDENCY_SETUP_FAILED` | 自动初始化失败，检查安装日志中的网络或目录权限错误，再按上面的命令手动安装 |
| `NCM_SCRIPT_ERROR_UNSUPPORTED_CLIENT_OR_STATE` | 确认客户端版本和主界面已加载，退出后重试并反馈脱敏状态 |

开发、测试与打包命令见 [开发与贡献](../CONTRIBUTING.md)。
