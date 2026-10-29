# 更新日志

ProxyWoman 是免费开源的 macOS 原生 HTTP/HTTPS 抓包调试工具（Charles / Proxyman / Fiddler 替代品）。
下载：[GitHub Releases](https://github.com/gzldc/ProxyWoman/releases)。English: [CHANGELOG.md](CHANGELOG.md).

## [0.1.3] - 2026-10-29

### 新增
- **JWT 预览**：新增 JWT 标签页，自动解码请求头、Cookie、URL 参数里的 JWT，显示 Header、Payload、签发/生效/过期时间以及是否已过期。只解码，不校验签名。
- **打开 HAR / 会话（⌘O）**：文件 ▸ 打开 HAR / 会话…，可打开 ProxyWoman、Chrome/Safari 开发者工具、Charles、Proxyman 等导出的 HAR 1.2 文件；配合“导出 HAR”即可保存和重新打开抓包会话。
- **一键安装到 iOS 模拟器**：证书 ▸ 安装到 iOS 模拟器，把根证书装进所有正在运行的模拟器（`xcrun simctl keychain … add-root-cert`）。

### 修复
- 服务器在上传中途提前拒绝（例如请求体过大）时，返回服务器的真实响应，而不是 502。
- 规则所在分组关闭时，规则列表提示“这一项不会生效”。

## [0.1.2] - 2026-10-29

### 修复
- 上游连接还没建好时，超过 64 KB 的请求体（例如 ChatGPT 的请求）报“待发送数据超出缓冲上限”而失败。
- “高级代理设置”可以滚动，“完成”按钮始终可见；状态信息不再重叠。
- 根证书已被信任时，直接显示“重新生成”不可用的原因。
- MCP 和 HAR 导出里的版本号与 App 一致；“隐私”页面显示开源代码链接。

## [0.1.1] - 2026-10-29

### 新增
- **手机 / 局域网抓包**：在“高级代理设置”里允许局域网设备连接，显示代理地址和二维码；手机浏览器打开 `http://proxywoman.cert` 下载根证书。证书菜单新增“在手机上安装证书…”。
- **上游代理**：自动（沿用原系统代理，例如 Clash）、手动指定主机和端口、直连三种模式。
- **绕过代理设置**：把域名加入系统代理忽略列表，关闭系统代理时恢复原列表。
- **重新生成根证书**（需先取消信任旧证书）。

### 修复
- 内置模板名称跟随 App 语言。
- 去掉菜单里重复的“设置…”。

## [0.1.0] - 2026-10-26

首个公开版本。

- 抓取 HTTP/1.1、HTTP/2、HTTPS 和 WebSocket，按 App 和域名归类。
- 用本机生成的根证书解密 HTTPS。
- 规则（条件 + 动作）、内置模板、Map Local、Mock 响应。
- 断点、Compose 与重放、导出 cURL 和 HAR。
- 工具栏和状态栏的系统代理开关，自动恢复原设置；可串联 Clash 等已有代理。
- 内置 MCP 服务，供 AI 助手调用。
- 中英文界面。

[0.1.3]: https://github.com/gzldc/ProxyWoman/releases/tag/v0.1.3
[0.1.2]: https://github.com/gzldc/ProxyWoman/releases/tag/v0.1.2
[0.1.1]: https://github.com/gzldc/ProxyWoman/releases/tag/v0.1.1
[0.1.0]: https://github.com/gzldc/ProxyWoman/releases/tag/v0.1.0
