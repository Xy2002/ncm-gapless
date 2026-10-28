# Windows 启动时加载路径研究

日期：2026-10-28。目标：网易云 `3.1.42.205594 x64`，从原有任意入口启动时自动启用补丁；不依赖检测后的退出和重开。

## 结论

推荐继续验证一个本项目自己的最小原生启动加载器：通过应用目录的系统绘图 DLL 代理，在浏览器进程进入 `cef_initialize` 时接入 CEF 的命令行回调，添加仅面向本机的调试配置；初始化成功后，再启动短时的补丁加载助手。该设计沿用已有的 CDP 注入，不需要拦截 V8、修改网页包或运行常驻监视器。这里是从源代码与 ABI 资料得到的实现建议，尚不是本机运行验收结果。

没有找到已证实可用于当前官方客户端的持久调试配置或明文资源覆盖设置。现成 BetterNCM 二进制和直接重写 `orpheus.ntpk` 均不宜直接采用。

## `orpheus.ntpk` 已有签名，不能当普通 ZIP 改写

开源宿主 open-orpheus 的 `WebPack.ts` 明确实现了 100 字节头：4 字节 ASCII 版本、32 字节元数据、64 字节 RSA-512 / SHA1 签名，随后为签名覆盖的明文 ZIP；读取 ZIP 之前先校验签名。[包读取源码，固定提交](https://github.com/YUCLing/open-orpheus/blob/0a0aaab1c339e324eb77eb675aa90131c17e4673/src/main/packs/WebPack.ts)

对本机安装文件进行了只读检查：版本为 `0003`，ZIP 起点为 100；使用上述源码中的公钥，以 RSA PKCS#1 v1.5 校验 `文件[36:100]` 对 `文件[100:]` 的 SHA1 签名，结果匹配。原文件 SHA-256 为 `170413b1675708e87a9e89c2d122a8643a51e86b5b5ae1c6260cfeaf25b19be4`。头部 32 字节元数据不等于 ZIP 的 MD5，具体含义尚未确认。

上述证据确认现有文件具有可验证的签名，不单独证明官方客户端在哪条路径强制校验它。修改 ZIP 后保留原头部会破坏签名；重新打包并不等于得到可启动资源包。不建议为这项功能修改原厂校验逻辑或替换公钥。

open-orpheus 的 `web.pack` 优先、`orpheus.ntpk` 回退逻辑属于它自己的宿主实现，不能视为官方 Windows 客户端支持同名明文覆盖的证据。[宿主包选择源码](https://github.com/YUCLing/open-orpheus/blob/0a0aaab1c339e324eb77eb675aa90131c17e4673/src/main/pack.ts)

## 原生启动加载的源码依据

BetterNCM 旧代码把自身作为 `msimg32.dll` 代理加载，转发系统 DLL 导出；在 `DLL_PROCESS_ATTACH` 中对 `cloudmusic.exe` 调用初始化。主进程的 `App::Init` 安装 CEF hooks；其中 `cef_initialize` 包装器会在调用原函数之前替换 `application->on_before_command_line_processing`。[DLL 代理入口](https://github.com/std-microblock/chromatic/blob/1b7eb7fdaa08de15e579c86dadb6ef848a72b6f1/src/hijack.cpp)，[主进程初始化](https://github.com/std-microblock/chromatic/blob/1b7eb7fdaa08de15e579c86dadb6ef848a72b6f1/src/App.cpp#L716)，[CEF 包装器](https://github.com/std-microblock/chromatic/blob/1b7eb7fdaa08de15e579c86dadb6ef848a72b6f1/src/EasyCEFHooks.cpp#L238)

这证明了已有项目采用的早期接入机制，并不证明上述整套代码或预编译 DLL 兼容当前版本。旧分支 README 的兼容声明仅覆盖 `2.10.* ~ 3.0.*`；当前主仓库说明旧项目维护不足、已经重写为 chromatic，且新项目仍在开发。[旧版兼容声明](https://github.com/std-microblock/chromatic/blob/1b7eb7fdaa08de15e579c86dadb6ef848a72b6f1/README.md)，[当前维护说明](https://github.com/std-microblock/chromatic/blob/91cd9c32d7c732d2fca204d6a05f5422443b6a34/README.md)

BetterNCM 原生 Rust 绑定文档说明可以构建面向 NCM 3.0+ 的 x64 插件，但这也不是 `3.1.42.205594` 的加载器实机兼容记录。上游还存在用户报告：`1.3.4` 加载器使 `3.1.3` 拒绝启动。因此不建议为本次需求直接安装旧版加载器。[绑定库说明](https://github.com/BetterNCM/betterncm-native-plugin-rs#编译须知)，[上游问题 #555](https://github.com/std-microblock/chromatic/issues/555)

## CEF 91 回调边界

核查的是 CEF Chromium 4472 分支，固定提交 `04c8d5653ca5b3e36b693d871cce1ef09617bfc9`。官方 C API 允许在 `on_before_command_line_processing` 中修改参数，回调发生在 CEF / Chromium 处理参数之前；浏览器进程的 `process_type` 为空。官方同时警告修改子进程参数可能导致未定义行为和崩溃。本方案应只处理浏览器进程。[CEF app C API](https://github.com/chromiumembedded/cef/blob/04c8d5653ca5b3e36b693d871cce1ef09617bfc9/include/capi/cef_app_capi.h)

原回调应恰好执行一次，再追加本项目参数；保留其他原参数。`application` 和原回调均可能为空，遇到未满足的接口条件应保持官方启动。不得保留回调提供的命令行对象。追加前检查对象有效、可写以及结构尺寸覆盖所访问字段。[CEF 命令行 C API](https://github.com/chromiumembedded/cef/blob/04c8d5653ca5b3e36b693d871cce1ef09617bfc9/include/capi/cef_command_line_capi.h)

依据这些头文件，按 x64 自然布局推导如下；实现时仍需编译期 `static_assert` 与目标文件身份检查，不能将推导代替运行证明。[引用计数基结构](https://github.com/chromiumembedded/cef/blob/04c8d5653ca5b3e36b693d871cce1ef09617bfc9/include/capi/cef_base_capi.h)

| 项目 | x64 推导尺寸 / 偏移 |
| --- | --- |
| `cef_base_ref_counted_t` | 40 字节：`size_t` 和四个函数指针 |
| `cef_app_t` | 80 字节 |
| `on_before_command_line_processing` | 偏移 40 |
| `cef_command_line_t` | 200 字节 |
| `append_switch_with_value` | 偏移 160；访问前至少覆盖到 168 字节 |

## DLL 生命周期与验证要求

旧加载器在 `DllMain` 内调用 `LoadLibrary` 并进行大量初始化，不应照搬。Microsoft 明确指出 `DllMain` 持有加载器锁，不应调用 `LoadLibrary`、`CreateProcess`、COM 或注册表操作，也不应等待其他线程。新方案应在该阶段仅做必要的已知模块接口设置，把助手创建推迟到正常的 CEF 初始化调用中。[Microsoft DLL 最佳实践](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-best-practices)

Windows 的 DLL 搜索还受 KnownDLL、已加载模块、应用目录、包依赖图等因素影响；应用目录代理是否足够早加载，必须用当前客户端导入表和实际启动验证。[Microsoft DLL 搜索顺序](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order)

后续验收至少应确认：原系统导出完整转发；安装文件和包保持原字节；不同入口启动后的主进程 PID 不因补丁发生替换；监听端点限于回环地址；补丁状态确实为已启用；重复点击不创建多份助手；禁用后新启动不再加载；版本不匹配与安装冲突时能保留官方启动。登录、文件关联和协议参数应各自提供证据，不能从桌面入口成功推出全部场景已验收。

## 实现后续

同日已实现并在当前客户端验证这一启动模块，详见 [使用说明](windows-startup.md) 与 [运行记录](evidence/windows-startup-v1.json)。实现额外核查了 CEF CAPI 引用传递：原回调和 `cef_initialize` 会消费传入引用，包装器在继续访问前显式持有引用，并在回调恢复后释放。安装与音频输出的验收边界保持分开。
