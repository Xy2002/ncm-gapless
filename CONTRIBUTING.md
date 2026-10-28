# 开发与贡献

先阅读 [README](README.md)、[路线图](docs/roadmap.md) 和 [实现记录](docs/implementation.md)，确认当前已验证范围与剩余问题。

## 本地开发

Windows 补丁运行需要已适配客户端与 Windows PowerShell；macOS 运行需要 Python 3，启动器会自动安装运行依赖，使用步骤见 [macOS 文档](docs/macos.md)。开发验证额外需要 Python、FFmpeg；JavaScript 检查使用 Node.js。

```powershell
python -m pip install -r requirements-dev.txt
node --test tests/controller.test.cjs tests/aac-timing.test.cjs
node --test tests/client-adapter.test.js tests/verify-disable.test.js
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-native.test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-attach.test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-install.test.ps1
python -m unittest discover -s tests -p "test_*.py" -v
```

上述测试检查控制流、AAC 解析、平台适配、启动器、打包和回录分析，使用可控 I/O，不连接客户端或驱动声卡。

中文介绍站位于 `site/`，无需构建或安装依赖。用 `python3 -m http.server 8000 --directory site` 本地预览；修改客户端支持范围或补丁版本时，同步页面正文和 JSON-LD。站点检查随 Python 测试一起运行，发布与搜索引擎提交见 [搜索收录说明](https://github.com/Xy2002/ncm-gapless/blob/main/docs/search-discovery.md)。

连接已通过启动器启用的目标客户端后：

```powershell
python tools\verify_audio.py
python tools\verify_integration.py
python tools\patch_control.py status
```

开发工具默认使用 9222 端口，其他端口用 `--port` 指定。启动器会自动发现端口，开发命令需要与实际端口一致。

## 区分验证类型

| 工具 | 行为与证据边界 |
| --- | --- |
| `verify_audio.py` | 生成样本，在真实 CEF 中离线渲染与解码，不输出声音 |
| `verify_integration.py` | 离线渲染实际引擎并检查官方事件参数契约 |
| `check_controls.py` | 实际暂停、恢复和定位当前曲目，会改变播放位置 |
| `observe_transition.py` | 观察自然播放的调度和状态，不证明声卡输出连续 |
| `measure_handoff.py` | Windows WASAPI 专用；默认定位至当前曲尾，短时回录默认输出设备，仅在内存对比 |
| `measure_handoff.py --natural` | 等待当前曲目自然结束后测量，不定位、暂停或变速 |
| `tools/inspect-*.js` 等诊断脚本 | 研究用途，运行前阅读脚本；不进入便携包 |

回录分析需要正在播放且已准备好下一首。其他应用声音或音效可能使匹配相关度不足，此时不能报告通过。测试应明确区分定位辅助检查与从头自然播放。

修复声音中断时，先建立能捕捉实际输出缺口的失败信号，再修改代码。不要仅用相邻的计划时间或正常的界面进度作为完成依据。

## 提交与反馈

每个独立修改使用新分支，描述触发条件、实际变化和验证范围。客户端或平台适配必须提供相应环境的运行记录；未知版本继续拒绝启用。

Issue 请提供：系统构建与架构、客户端版本、补丁版本、重现步骤、预期 / 实际行为及脱敏状态。若使用公开专辑复现，可以注明曲目衔接。

不要提交 `.local/`、`artifacts/`、个人路径、真实音乐、原始抓包或运行日志，也不要提交 Cookie、令牌、授权头值和签名音源地址。生成测试信号与只含能力 / 数值的验证记录可以提交。

## 便携包

```powershell
python tools\build_portable.py
```

打包工具按清单收集运行文件与脱敏文档，生成 `artifacts/` 下的 ZIP 和包内 SHA-256 清单。研究脚本、开发依赖和本机记录不进入运行包。

默认生成 Windows 包；`python3 tools/build_portable.py --platform macos` 生成 Mac 包。Mac 包包含启动器必需的两个 Python 模块、通用自动化模板及运行依赖清单，不包含虚拟环境和开发诊断脚本。`.command` 在包内保留执行权限。

Windows 可选启动模块先用 `tools/build_windows_startup.ps1` 构建，再以 `python tools/build_portable.py --windows-startup` 生成包含本项目 DLL 的独立包。本机 System32 绘图 DLL 只在安装时复制，不进入包；编译生成的 DLL 不进入 Git。详细边界见 [Windows 启动模块](docs/windows-startup.md)。

## 技术记录

Windows 自动维护使用 `tests/windows-maintenance.test.ps1` 验证真实签名、缓存修复、原子版本切换、中断恢复、故障回退和卸载重装。`--windows-maintenance` 打包需要先在本地签名生成固定载荷；签名私钥不得提交或输出，远端签名配置需要密钥所有者明确授权。发布流程与权限边界见 [维护说明](docs/windows-maintenance.md)。

实现与历史问题见 [实现记录](docs/implementation.md)。平台数据见 [兼容说明](compatibility.json)，运行记录保存在 [docs/evidence](docs/evidence/)。这些记录按版本保留，不能替代其他设备和版本的运行检查。
