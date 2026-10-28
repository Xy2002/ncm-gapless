# Windows 自动维护：接口与权限边界

研究日期：2026-10-28。此文件记录设计依据；不把实现、模拟检查或某次启动成功当作未来版本的兼容证明。

## CEF 接口必须先确认 ABI

CEF 91 的 `cef_api_hash(int entry)` 返回平台 API 哈希（0）、通用哈希（1）和构建提交（2）。哈希由 C API 类型声明生成，用于识别可能的二进制不兼容；CEF 自身的 C++ 包装层也会在初始化前比较平台哈希。[CEF 91 API 定义](https://github.com/chromiumembedded/cef/blob/04c8d5653ca5b3e36b693d871cce1ef09617bfc9/include/cef_api_hash.h)、[初始化检查](https://github.com/chromiumembedded/cef/blob/04c8d5653ca5b3e36b693d871cce1ef09617bfc9/libcef_dll/wrapper/libcef_dll_wrapper.cc)。

当前 CEF 的同名函数已经变为 `cef_api_hash(int version, int entry)`，并具有 API 版本配置作用。因此必须先核对 `cef_version_info` 所属的已支持内核，再按对应签名调用，不能对任意未来版本尝试旧签名。[当前接口](https://github.com/chromiumembedded/cef/blob/master/include/cef_api_hash.h)。

当前网易云所带的 CEF 是定制构建。本机会话观测的返回值为：

| 项目 | 值 |
| --- | --- |
| 产品版本 | `91.2.3+g3268653+chromium-91.0.4472.169` |
| 平台 API 哈希（0） | `135912956b05b8d66775a091c5f7f17ae26eb09c` |
| 通用 API 哈希（1） | `0e4b5d3ff0027a5cf6e295b37d9b8b3dd2e80b7e` |
| 构建提交（2） | `326865300051196bd4a8e991bab2aa493c9c9a8f` |

这些值与上述上游参考提交的 Windows 平台哈希 `4150bd26e7bf639a9b1f3e5860af8c76eeae8570` 不同。原生加载器应绑定已观测的实际 ABI，并保持结构大小、函数指针、引用所有权和原回调恢复检查。API 哈希不能证明网易云播放桥接的语义不变；页面层仍须单独检查播放 SDK、回调、状态枚举和队列入口。

## 管理员维护任务的信任边界

Windows 任务以注册时指定的账户和权限运行。普通进程不能注册 SYSTEM 或最高权限任务；任务 DACL 决定谁能更新、运行或删除它。一次管理员安装可以注册后续维护任务，但应将动作、配置及其所有依赖放入仅 SYSTEM/Administrators 可写的目录，并为任务设置相应 DACL。[任务安全上下文](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks)、[任务权限收缩](https://learn.microsoft.com/en-us/windows/win32/taskschd/task-security-hardening)。

以下是本项目据此采用的约束，而非 Windows 自动提供的保证：

- SYSTEM 动作只执行固定的受保护维护代码。不得执行仓库、下载目录或 AppData 中可由普通用户替换的脚本。
- 下载包只作为数据输入；受保护代码独立验签、检查固定文件清单及文件哈希。不得以包内脚本、命令或路径控制管理员操作。
- 客户端目标由首次管理员安装固定。拒绝重解析点及可写祖先；对现有叶子文件使用新临时文件原子替换，避免覆盖写入跟随硬链接。
- 客户端运行时延期替换，不强制退出、不重启客户端。每分钟触发的短任务存在恢复延迟：更新后立即打开客户端，可能要等下一次正常启动才启用补丁。
- 卸载以本项目文件所有权和哈希为依据，不能先用旧客户端版本白名单拒绝操作，否则官方升级后连卸载也会被阻断。

## 签名更新、重放和回退

.NET 的 `RSACryptoServiceProvider.VerifyData` 可用公钥校验数据和签名。应对下载清单的原始字节验证 RSA/SHA-256 签名，再解析清单；公钥固定在受保护维护代码中。SHA-256 文件清单本身不提供发布者认证。[VerifyData](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsacryptoserviceprovider.verifydata?view=netframework-4.8.1)。

GitHub Release 资产具有上传、读取和删除接口，因此固定资产名或下载地址本身不等于不可变、可信的补丁身份。[Release 资产 API](https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28)。本项目还需：

- 清单绑定单调递增序号、包标识、固定文件名、长度及每文件 SHA-256；校验同序号同摘要，拒绝旧序号和同序号换包。
- 防降级最高序号存于管理员保护目录；功能回退保留最高序号，避免旧签名包被重放。
- 验签和复制必须消费同一份已锁定或受保护的字节，不能先检查后从可写路径重新读取。
- 激活前保存上一份可用版本，文件替换失败恢复旧版本；网络、签名和接口检查失败时记录诊断，保留已安装版本。
- 未来的内核或播放语义变化仍需发布经过验证的新补丁；自动下载与本机特征检测不能自行证明未知行为正确。

没有在研究过程中修改客户端安装、注册表、任务计划或启用配置。

## 实现审计的验收场景

自动维护还需要覆盖以下跨步骤情形；单独验证签名、复制或某次启动不足以覆盖它们：

- 物理卸载启动模块后再执行一次维护任务，文件仍应保持卸载状态。维护任务必须先撤销，避免把主动卸载当作文件缺失修复。
- 原厂转发 DLL 被改变、只有安装清单丢失、单个文件丢失分别处理；不能仅凭九个签名文件存在就报告整套安装健康。内容改变应保留并报告冲突。
- 旧待安装包已缓存，此时更高序号清单到达但包下载失败，仍允许从当前活动包离线修复。过时的待安装指针不能阻断所有维护。
- 客户端在进程快照检查后、文件事务中启动，不应读取混合版本。维护程序自身重装时也须与已有任务持有同一互斥锁。
- 复制事务出错的文件回退，与新版本成功复制后实际启动失败的功能回退，是两个验收边界。保存 `previous.json` 本身不等于具备功能回退能力。
- 由普通调用者提升权限安装、直接在管理员终端安装、替代管理员凭据安装的账号归属分别验证，避免把用户启用开关写到错误账号。
