# 开发与贡献

先阅读 [README](README.md)、[路线图](docs/roadmap.md) 和 [实现记录](docs/implementation.md)，确认当前已验证范围与剩余问题。

## 本地开发

补丁运行只需要当前已适配的网易云客户端与 Windows PowerShell。控制流和 AAC 元数据回归需要支持 `node --test` 的 Node.js，生成媒体与回录分析验证额外需要 Python、FFmpeg。

```powershell
python -m pip install -r requirements-dev.txt
node --test tests/controller.test.cjs tests/aac-timing.test.cjs
python -m unittest discover -s tests -p "test_*.py" -v
```

上述 Node.js 测试执行真实控制器、引擎和 AAC 解析逻辑，以可控客户端 / 音频节点和虚拟时钟覆盖下载、解码、暂停恢复与卸载状态；AAC 元数据用例没有真实音频包。Python 测试检查回录分析方法。这两类测试均不打开声卡、不连接网易云，不等于实际客户端验收。

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
| `measure_handoff.py` | 默认定位至当前曲尾，短时回录默认输出设备，仅在内存对比 |
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
