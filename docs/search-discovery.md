# 中文搜索收录与发布

本项目的中文介绍页位于 `site/`，默认发布地址为 `https://xy2002.github.io/ncm-gapless/`。页面提供适用版本、安装步骤、原理和常见问题，搜索引擎无需执行 JavaScript 即可读取正文。

2026-10-27 首次发布前检查时，GitHub Pages 尚未启用，仓库没有 Release，站长平台验证和收录确认也尚未完成。新增页面、通过检查、公开上线、提交收录和实际收录是不同状态；后续结果需分别核实，排名仍由搜索引擎决定。

## 发布到 GitHub Pages

1. 在仓库 Settings → Pages → Build and deployment 中，将 Source 设为 GitHub Actions，参见 [GitHub 官方说明](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)。
2. 将页面及 `.github/workflows/pages.yml` 合并到 `main`。PR 只验证页面，`main` 更新后才部署。
3. 在 Actions 中确认发布工作流成功，再打开 `https://xy2002.github.io/ncm-gapless/`，确认正文、样式、下载和文档链接可用。
4. 检查 `https://xy2002.github.io/ncm-gapless/sitemap.xml` 可直接访问，且其中 URL 与页面 canonical 一致。

工作流只上传 `site/`。验证文件也必须放在该目录，才能随页面发布；源码、证据目录和本机文件不作为网站内容上传。

若改用自定义域名，先完成域名和 HTTPS 配置，再同步修改页面 canonical、Open Graph URL、结构化数据和 `sitemap.xml`，避免不同地址混用。

## 提交给搜索引擎

需要使用站点所有者自己的账号完成验证。不要提交账号密码、Cookie 或 API 令牌到仓库。平台要求公开访问的站点所有权验证文件或元标签属于公开校验材料，完成验证后按平台要求保留。

### Google

1. 打开 [Google Search Console](https://search.google.com/search-console)，添加 URL-prefix 属性 `https://xy2002.github.io/ncm-gapless/`，包含 HTTPS 和完整项目路径。
2. 选择 HTML 文件或 HTML 元标签验证。文件放入 `site/`，或将元标签放入 `site/index.html` 的 `<head>`，发布后回到后台验证。不要尝试验证无权管理的整个 `github.io` 域。
3. 在 Sitemaps 提交 `https://xy2002.github.io/ncm-gapless/sitemap.xml`。
4. 使用网址检查查看首页的实时可访问情况，再请求编入索引。之后查看页面索引报告和拒绝原因。

页面需要允许抓取、返回正常内容并符合索引要求，参见 [Google 技术要求](https://developers.google.com/search/docs/essentials/technical)。[Sitemap 只帮助发现 URL](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)，提交成功不代表已经收录。

### Bing

进入 [Bing Webmaster Tools](https://www.bing.com/webmasters/)，按后台允许的 URL 范围添加站点。可使用后台提供的所有权验证方式，或在可用时从已验证的 Google Search Console 导入，参见 [Bing 官方验证说明](https://www.bing.com/webmasters/help/add-and-verify-site-12184f8b)。

验证成功后提交相同 Sitemap，并使用 URL 检查工具确认抓取和索引状态。若后台要求当前账号无法控制的域名范围，先解决域名控制权，不把整个平台域名当作自己的站点。

### 百度

进入 [百度搜索资源平台](https://ziyuan.baidu.com/)，按当前后台要求添加网站、验证所有权，再使用账号实际开放的链接提交功能。百度对可添加的站点和提交方式可能有不同要求，应以后台结果为准。

若项目路径无法添加，或站点从目标地区无法稳定访问，先处理网站地址和访问问题。需要独立域名时再配置，不把完成页面开发写成已经获得百度收录。

## robots.txt 的路径

抓取规则使用主机根路径 `https://xy2002.github.io/robots.txt`。`https://xy2002.github.io/ncm-gapless/robots.txt` 不能控制项目站点的抓取，参见 [Google robots.txt 规范](https://developers.google.com/crawling/docs/robots-txt/robots-txt-spec)。

本项目不生成无效的子路径 robots.txt。若要设置根路径规则，需要在 `xy2002.github.io` 对应的站点仓库维护，并检查是否意外屏蔽 `/ncm-gapless/`。没有 robots.txt 本身不等于禁止抓取。

## 中文内容与搜索意图

| 搜索意图 | 自然使用的词语 | 对应内容 |
| --- | --- | --- |
| 找到项目 | NCM Gapless、网易云音乐无缝播放补丁 | 页面标题、介绍、下载入口 |
| 解决切歌停顿 | 网易云无缝播放、网易云切歌间隔 | 预取原理、连续衔接条件 |
| 判断能否使用 | Windows 网易云无缝播放、Mac 网易云无缝播放 | 精确客户端版本、架构、运行要求 |
| 完成安装或排错 | 网易云无缝播放怎么设置、Mac 补丁安装 | 分平台步骤、状态检查、停用方法 |

这些词语来自项目功能与用户问题，没有搜索量或排名保证。正文回答实际问题即可，不重复堆词，也不为相近关键词复制内容相同的页面。

README 标题和介绍保留中文用途，并链接介绍页。仓库 About 可填写中文简介、网站地址及准确的音乐播放主题。面向中文社区分享实测安装教程和原理说明时，链接同一个主地址，方便用户核实版本和使用限制。

## 文案的事实边界

- 当前为实验补丁。Windows x64 适配网易云 `3.1.42.205594`；macOS Apple Silicon 适配 `3.1.12.3444`。未知客户端版本拒绝启用，Intel Mac 尚未验证。
- 保留音源本身的静音，不做交叉淡化。下一首未及时准备、网络或格式失败时，无法保证连续衔接。
- 调度边界对齐不等于所有设备的输出或主观听感均已验收。蓝牙、官方音效等限制继续以 [兼容说明](../compatibility.json) 和 [实现记录](implementation.md) 为准。
- 不提供会员或版权限制绕过；与网易云音乐没有官方关联。许可证尚待确定，不宣传为已采用开源许可证的软件。
- 无 Release 时，下载入口应明确为源码 ZIP，不称为已经发布的稳定安装包。

## 记录结果

发布后分别记录页面可访问 URL、Actions 部署结果、站长平台验证结果、提交日期和实际索引结果。只有搜索引擎后台确认索引或搜索结果出现目标 URL，才记录为已收录。

后续根据站长平台中的真实查询词、展示、点击和未收录原因调整内容。代码检查通过不能证明上线，提交成功不能证明收录，收录也不能证明排名靠前。
