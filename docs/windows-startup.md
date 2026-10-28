# Windows：从原入口自动启用

此方案在网易云创建 CEF 浏览器时配置本机调试接口，随后运行一次短时 PowerShell 加载器。加载成功后助手退出；它不监控进程、不关闭或重开客户端，也不修改桌面、开始菜单、任务栏、文件关联或协议关联。

由于加载点在客户端内部，所有实际启动这份 `cloudmusic.exe` 的入口共用同一条路径。已经运行时再次点击入口会复用原实例。当前只接受已核验的 `3.1.42.205594 x64` 可执行文件和 CEF `91.2.3 / Chromium 4472`；其他客户端继续使用官方初始化。

## 首次安装

1. 使用包含原生加载器的 Windows startup 便携包，完整解压。源码用户需先运行开发构建命令。
2. 从托盘菜单彻底退出网易云，然后双击 `Install-NcmGaplessStartup.cmd`。
3. 允许一次 Windows 管理员权限提示，将新模块和运行文件放入客户端目录。启用配置保存在当前账号下。
4. 以后照常打开网易云。双击 `Get-NcmGaplessStatus.cmd`，确认 `installed: true` 和 `automaticEnabled: true`；首次接管需要重新选曲。

运行无需 Python、Node.js 或持续运行的后台助手。普通启动最初几秒可能仍显示未加载，加载器会等待官方界面就绪。未知版本、接口不可用或加载失败时不替换客户端，不强制退出，可从状态中的错误代码诊断。

加载器检查实际播放接口是否可用，不等待图片等页面资源全部完成；最长等待 60 秒。客户端升级前先完全退出并卸载启动模块，新版本须重新验证后安装。

安装会新增：

- `MSIMG32.dll`：本项目编译的启动模块。
- `ncm_gapless_msimg32.dll`：从本机 System32 复制的原厂绘图转发模块。
- `ncm-gapless/`：经过校验的补丁、短时加载脚本、许可证和安装清单。

网易云原有的 EXE、DLL、资源包与快捷方式保持原字节。若检测到其他加载器或同名文件，安装会拒绝覆盖。安装后可移动原解压目录；运行依赖已经复制到客户端目录中。

## 停用与卸载

双击 `Stop-NcmGapless.cmd`，会先撤销当前账号的自动启用资格，等待正在执行的加载器退出，再卸载当前页面中的补丁。已关闭客户端时也可以停用。以后启动时，已安装模块只转发官方绘图接口，不再为当前账号配置或加载补丁。

重新启用可再次运行 `Install-NcmGaplessStartup.cmd`；文件没有变化时复用已安装模块，不必重复复制。当前实例若没有调试接口，下一次正常打开时生效，不自动重开。

彻底退出网易云后，运行 `Uninstall-NcmGaplessStartup.cmd` 移除本项目文件。卸载根据安装清单逐项核验 SHA-256；发现文件已改变时保留现场并报错，不删除未知文件。其他账号的启用配置相互独立，原生模块在同一个客户端安装目录中共享。

## 开发与证据边界

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/build_windows_startup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-native.test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-attach.test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-install.test.ps1
python tools/build_portable.py --platform windows --windows-startup
```

构建需要 MSVC x64 和 Windows SDK。原生检查使用真实 Windows 加载器、假的客户端和 CEF，覆盖系统接口转发、CEF 引用所有权、回调恢复、停用、版本拒绝和文件参数；加载器检查使用可控进程与 CDP；安装检查只对项目 `.local/` 中的副本操作。这些检查不播放音频。

启动模块的实机启用、官方退出和各入口验证与音频输出验收分开记录。未通过真实系统登录、文件关联或设备回录验收的场景，不从其他入口成功推导为已验证。此前自动退出 / 重开方案已撤销，见 [失败记录](windows-automatic-investigation.md)；此启动模块不使用那条路径。

本机 `3.1.42.205594 x64` 已完成原桌面、开始菜单、直接运行程序、注册协议启动、重复打开、停用与重新启用检查。启动后的主进程身份保持一致，监听地址为 `127.0.0.1`，加载器完成后退出。完整边界与源码哈希见 [启动模块验证记录](evidence/windows-startup-v1.json)。系统重新登录、真实歌曲文件关联和独立任务栏图标冷启动未单独实测；它们在实际启动同一客户端时共用这个初始化加载点。
