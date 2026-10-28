# macOS 更新维护

Mac 自动维护沿用 macOS 27 的系统快捷指令。网易云普通启动时运行一次短脚本，注入完成后检查补丁更新，然后退出；项目不安装常驻进程，也不修改网易云应用和原厂签名。

## 安装与使用

运行 `Start-NcmGapless.command`，按 [Mac 配置说明](macos.md) 完成首次快捷指令设置。程序把运行文件安装到 `~/Library/Application Support/NcmGapless`，后续自动启动使用这里的独立 Python 环境，不再依赖下载或解压目录。

该目录包含固定的 `macos_maintenance.py`、`macos_updates.py`、`macos-update-public-key.pem`，独立 `.venv`，以及按内容摘要隔离的 `versions/` 运行目录。启用状态、快捷指令入口和三个 `.command` 控制脚本也保存在这里。安装完成后可以删除原解压目录，但应保留创建虚拟环境所用的系统 Python。普通源码包也可以先安装本地运行文件，再接收后续的签名更新。

日常直接打开网易云即可。没有调试参数的实例仍需正常退出再重开，窗口可能短暂关闭。`Get-NcmGaplessStatus.command` 查询状态，`Stop-NcmGapless.command` 撤销自动启用并恢复官方播放。

启动脚本在注入后按需检查更新，成功检查间隔为 6 小时，失败后 30 分钟内不再重复请求。它不会为了检查更新唤醒或重启客户端。新补丁下载并验证后供下次启动使用，正在播放的会话继续使用原有补丁。

## 客户端更新的处理

启动前检查网易云的原厂代码签名和应用身份；页面就绪后检查实际播放接口。版本号变化但接口仍符合契约时可以继续注入。播放桥、事件、队列或其他必要能力不符时，保持官方播放并报告不兼容。

这不能保证未来所有网易云版本均可用。接口结构相同也不等于音频行为已验证；播放协议变化仍需要适配。当前也未覆盖同一网易云进程内的页面热重载：系统快捷指令按 App 启动触发，页面单独重载后需要退出并重新打开客户端。

## 补丁更新的校验

更新信封使用 RSA SHA-256 签名，签名对象是原始 manifest 字节。客户端固定信任项目公钥，并检查发布通道、递增序号、下载地址、包大小和 SHA-256，再逐项检查固定文件名单与内容摘要。更新 ZIP 不能提供任意安装路径或额外脚本。

签名运行包只有四个音频 JavaScript 模块、`macos_launcher.py`、`cdp_probe.py`、快捷指令模板和 Python 依赖清单。固定启动器、更新验证器和公钥不通过这个运行包自更新；这些组件需要变更时，使用新版完整程序包重新执行 `Start`。

下载或校验失败时继续使用已安装版本。新补丁在三个不同页面实例中激活失败后恢复上一版本；客户端不兼容不计入这项失败次数。没有进入启动脚本的崩溃也无法留下激活失败记录。网易云自身不兼容时不会通过回退承诺恢复无缝播放。停止后不会因更新检查重新启用补丁。

## 构建与发布

签名密钥不包含在仓库、ZIP 或产物中。发布者提供与 `tools/macos-update-public-key.pem` 对应的 RSA 私钥；构建脚本先校对公钥，再签名并用客户端验证器回读检查。密钥临时副本仅存在于受保护的临时目录，结束后删除。

```bash
python3 tools/build_macos_release.py \
  --sequence 1793172000 \
  --tag macos-release-v0.6.0-example \
  --version 0.6.0-experimental \
  --key /secure/location/release-private.pem
python3 tools/build_portable.py --platform macos --macos-maintenance
```

序号必须比之前发布的大；示例数值不应用于正式发布。输出位于 `artifacts/macos-maintenance/`，包含 `macos-update.json` 与 `macos-payload.zip`。普通便携包使用 `python3 tools/build_portable.py --platform macos`，不要求签名文件预先存在。

`.github/workflows/macos-check.yml` 运行离线维护与签名回归测试。`.github/workflows/macos-release.yml` 由 `macos-release-v*` 标签触发，使用独立的 `NCM_MACOS_RELEASE_KEY` secret，内容为 PEM 私钥的 Base64。它先发布版本资产，再更新 `macos-maintenance` 通道索引，不读取 Windows 发布 secret。

本轮未配置发布 secret，也没有推送发布标签或发布 Mac 维护版本。自动化测试不代替真实客户端升级、音频回录或主观听感验收；这些实机证据仍待补充。
