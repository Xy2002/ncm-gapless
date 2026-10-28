# Windows 自动维护

完整解压 Windows maintenance 包，运行 `Install-NcmGaplessMaintenance.cmd`，允许一次管理员安装。维护任务和公钥保存在管理员保护的 `Program Files/NCMGaplessMaintenance`；当前账号的自动启用开关仍单独保存。安装后可移走下载目录。

维护任务由 Windows 在开机、登录及每分钟短暂执行，没有常驻监听程序。每轮检查当前安装；每 6 小时检查一次固定 GitHub 更新通道，网络失败后 30 分钟重试。离线时使用已验签缓存修复。任务不关闭、重开或启动网易云；运行中的客户端会延后处理。更新后若立即启动且加载模块已被删除，本次可能尚未加载，正常退出后一分钟内会修复，下次打开生效。

## 三层检查

- 安装目标：x64、网易云原厂 Authenticode 发布者，或已核验的原厂可执行文件 SHA-256；不执行客户端代码。目录和祖先必须由管理员保护，拒绝普通用户可写的自定义目录及链接路径。
- 原生加载：先检查 CEF 91 / Chromium 4472，再比较实际出货内核的 C API 平台哈希。哈希匹配不依赖网易云产品版本号；其他内核等待新版已签名加载器。
- 播放接入：Windows 新版按实际 SDK、事件桥、播放枚举、队列结构和 Web Audio 能力检查，失败保留官方播放。状态 `clientCompatibility: detected-playback-contract` 表示结构探测通过，不能据此宣称已完成新版本的真实音频验收。macOS 原有版本限制不受影响。

## 修复与更新

更新源为 [GitHub 维护通道](https://github.com/Xy2002/ncm-gapless/releases/tag/windows-maintenance)。下载的清单先用内置 RSA3072 公钥验证 SHA-256 签名，再验证包长度、哈希和固定九个文件。签名覆盖发布序号、版本、包地址、长度及各文件摘要。更低序号、同序号不同内容、额外文件、路径穿越和篡改包均拒绝。维护进程只将下载内容当作数据复制，固定的 SYSTEM 工作脚本不会执行下载脚本。

下载入口 TLS 连接失败时回退 GitHub 官方资产 API，仍检查 HTTPS 证书和原签名，不采用未知仓库或资产元数据中的任意下载地址。网络错误会持续显示到下次成功检查，不被普通健康轮询覆盖。

运行脚本放进 `ncm-gapless/versions/<摘要>`，完整写好后原子切换 `active.txt`。已经启动的旧实例可以使用原先的完整目录；原网易云 EXE、DLL、资源包和快捷方式不改。管理员保护的副本可恢复被更新删除的代理 DLL、脚本、转发 DLL及安装清单；已改变的现有文件会保留并报告冲突。安装器的卸载依据所有权，不再受当前网易云版本号限制。

写入失败会恢复原文件。新补丁连续三个不同启动实例报告加载失败时，客户端关闭后自动切回上一份验签缓存，并隔离失败版本；防降级最高序号不下降。接口不兼容和主动停用不累计这类失败。只有在短时助手写出结果时才能统计失败；助手启动前发生的原生崩溃、系统断电和未知第三方冲突没有完整的自动功能回退保证。

`Get-NcmGaplessStatus.cmd` 的 `maintenance` 显示最近结果：`healthy`、`repaired`、`updated`、`deferred-client-running`、`rolled-back` 或错误代码。

## 停用、卸载和边界

`Stop-NcmGapless.cmd` 撤销当前账号的自动加载；系统任务不会重新开启账号开关。`Uninstall-NcmGaplessMaintenance.cmd` 撤销维护任务，保留诊断和已签名缓存。彻底退出客户端后，`Uninstall-NcmGaplessStartup.cmd` 会先卸载维护任务，再移除当前启动模块，避免被下一轮修复装回；历史版本缓存可保留，已无加载入口。

适用范围是已经批准的同一安装路径。换安装盘、变成用户可写目录、更新为不同 CPU 架构或更换签名发布者时停止自动修复。未知 CEF ABI 仍需开发者发布适配版本；自动更新负责把发布后的适配包送达，不能自行推断任意未来接口的语义。公钥轮换及维护程序本身的升级需要安装新版维护组件。

## 发布

维护公钥提交在 `tools/update-public-key.xml`。签名私钥不进仓库；本地使用 Windows DPAPI，CI 使用仓库加密 secret `NCM_WINDOWS_RELEASE_KEY`（私钥 XML 的 Base64）。CI 仅对维护者创建的 `windows-release-v*` 标签运行；初次实机通道由本地验签构建发布。

`.github/workflows/windows-release.yml` 构建并检查原生模块，执行兼容性和维护回归，生成签名包，先发布不可变版本资产，再替换维护通道清单。发布序号单调递增，通道清单替换短暂不可用时保留缓存。初次安装包包含同一份签名清单和载荷。

验证命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-maintenance.test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-native.test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-attach.test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-startup-install.test.ps1
python tools/build_portable.py --platform windows --windows-maintenance
```

测试分开记录模拟版本变化、真实 Windows 加载器、受控签名更新、实机任务、实际网络下载和音频输出，不能相互替代。研究依据见 [Windows 维护研究](windows-maintenance-research.md)。
