# macOS 持续启用研究

日期：2026-10-27。目标客户端：macOS 网易云 `3.1.12.3444`。目标是在启用一次后，从原入口打开客户端也能自动加载补丁，直到执行停止脚本。

## 采用的方案

`0.4.0` 使用 macOS 27 自带“快捷指令”的 App 启动触发器。用户完成一次性导入、打开项目自动化并允许脚本操作后，系统在网易云启动时调用短脚本；脚本安装补丁后退出。项目不安装常驻监听器，也不修改网易云应用或原厂签名。

已在 macOS `27.0.1 arm64` 验证：关闭快捷指令界面后普通启动自动安装、辅助脚本退出、停止后不再注入、客户端关闭时停止，以及重新启用无需再次导入。原厂签名严格检查通过，主程序哈希与实验前一致。具体步骤见 [macOS 使用说明](macos.md)，执行记录见 [生命周期验证](evidence/macos-automation-v0.4.0.json)。本轮没有重做音频回录或其他设备验收。

Apple 文档列出了可自动运行的 App 触发器。本机系统日志和实际重开实验进一步确认，这个规则按应用从未运行变为运行的事件触发；仅切回已经运行的客户端不会触发。[Apple 自动化说明](https://support.apple.com/en-ph/guide/shortcuts-mac/apdfbdbd7123/10.0/mac/27)

## 为什么没有修改启动资源

用户要求保留原厂签名。授权读取应用容器后，已找到实际更新包，并确认它与应用内资源不同：

| 项目 | 应用内资源包 | 实际更新包 |
| --- | --- | --- |
| 路径 | `Contents/Resources/resources.pack` | 用户容器内 `Data/Documents/storage/Package/package.pack` |
| 大小 | 37,229,993 字节 | 37,229,921 字节 |
| 主脚本构建号 | `976f18d` | `114fa7e`，与当时运行页面一致 |
| ZIP 条目数 | 1,377 | 1,377 |
| 主入口 | `webfiles/app.html` | `webfiles/app.html` |

资源包前 100 字节为封装头：前四字节为 `0003`，后续 32 字节 ASCII 为版本字符串 `3.1.12.3444` 的 MD5，剩余 64 字节为签名区域。版本 MD5 不是资源内容的校验和，重算它不能使修改内容通过签名验证。

对本机 arm64 实现的静态分析定位到以下行为：

- `YYYPackageManager.checkLocalPackage` 优先检查用户更新包，调用 `verifyWithPackPath:zipData:` 校验版本和资源签名；无效更新包会被删除，再回退到应用内包。
- `YYYWebfilesManager.dataForRelativePath:` 优先读取已加载的资源包或缓存。普通本地文件不能优先覆盖有效包中的同名条目；磁盘模式也会从有效包重新生成 `webfiles.zip`。
- `webfiles/script` 是原生 URL 到资源包内部路径的映射，不是用户脚本目录。

修改应用内资源还会破坏 `CodeResources` 封装。重新签名能产生新签名，不能保留原开发者身份。[Apple 代码签名说明](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)、[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/)

## 独立副本实验

研究中曾使用独立标识、沙箱容器与进程通信组的测试副本，在资源读取方法返回主页面时追加启动脚本。副本移除了复制来的迁移配置与登录项，禁止网络客户端权限，并用测试加载器拦截钥匙串调用；运行时检查确认了测试容器与拦截。

脚本使用仓库四个真实模块，在页面和原生桥接就绪后自行安装。调试连接只读取结果，没有承担注入。观察到 `installed: true`，但 `active: false`、`playing: false`；这只证明了副本中的启动安装路径，没有验证真实播放。

该路径需要修改主程序并重签测试副本，已因原厂签名约束而放弃。没有应用到正式客户端，测试副本也未替换原安装。

## 其他排查结果

本机 `launchd.plist(5)` 警告 `WatchPaths` 可能漏掉文件变化。本轮未找到每次普通启动时可靠变化的专用标记；播放日志和缓存又频繁变化，因此没有部署文件监听任务。

`MKWebFastHookAjax.js` 与 `YYYWebCookieHookAjax.js` 属于 WKWebView 路线，没有证据表明它们是当前 CEF 主播放器的持久入口。原项目通过 `WKUserScript` 加载脚本。[原始实现](https://github.com/zhengmiaokai/MKWebResources/blob/ae30dcbbaa5c016d2e2ed10229ded6e3e534b757/MKWebResources/HookAjax/MKHookAjaxHandler.m)

CEF 的 `OnContextCreated`、`ExecuteJavaScript` 和 `LoadExtension` 是宿主接口，不代表网易云向用户暴露了自动加载配置。本轮没有找到可用的用户脚本或扩展入口。[CEF 上下文接口](https://github.com/chromiumembedded/cef/blob/5845/include/cef_render_process_handler.h)、[脚本接口](https://github.com/chromiumembedded/cef/blob/5845/include/cef_frame.h)、[扩展接口](https://github.com/chromiumembedded/cef/blob/5845/include/cef_request_context.h)

授权前的[只读快照](evidence/macos-persistence-research.json)与授权后的[研究快照](evidence/macos-persistence-followup.json)按阶段保留。后者记录的是采用系统自动化前的状态；最终结果以本页开头的生命周期验证为准。
