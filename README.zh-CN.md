<p align="center">
  <img src="docs/brand/appicon-light-1024.png" width="128" alt="ProxyWoman">
</p>

# ProxyWoman

免费、开源的原生 macOS HTTP/HTTPS 抓包调试代理，使用 Swift 和 SwiftNIO 构建。

> ProxyWoman 是独立项目，与 Proxyman 无关（not affiliated with Proxyman）。

**当前状态：公开 Beta 版。** 版本之间可能还有变化，遇到问题请在 Issues 中反馈。

## 功能

- 抓取 HTTP/1.1、HTTP/2 和 WebSocket 流量；用本地根证书解密 HTTPS。
- 流量列表支持筛选、按应用和域名分类、固定、标记和隐藏；请求和响应详情支持 JSON、图片、十六进制和原文查看。
- 多条件、多动作的规则：修改请求头、Cookie、URL、查询参数、状态码和正文，返回预置、手写或本地文件响应，延迟、关闭连接、断点、标记或隐藏会话；内置规则模板。
- Compose 构造和重复发送请求；导出为 cURL 或 HAR。
- 内置 MCP 服务，可让 AI 助手读取抓到的流量（默认关闭，写入类工具需逐项授权）。
- 系统代理一键开关并自动恢复，支持上游代理串联。
- 简体中文和英文界面。

## 安装

1. 从 [Releases](../../releases) 页面（macOS 14 及以上）下载适合你电脑的 DMG 和对应的 `.sha256` 文件：
   Apple 芯片（M1 及以后）下载 `ProxyWoman-<版本>-arm.dmg`，Intel 芯片下载
   `ProxyWoman-<版本>-intel.dmg`。（ ▸ 关于本机 可以看到芯片类型。）
2. 校验：在下载文件夹运行 `shasum -a 256 -c ProxyWoman-<版本>-<芯片>.dmg.sha256`，应输出 `OK`。
3. 打开 DMG，把 **ProxyWoman** 拖到 **Applications**。
4. 首次打开：App 为 ad-hoc 签名，**没有 Apple 开发者 ID 签名，也没有公证**，macOS 第一次会拦截。
   打开 **系统设置 ▸ 隐私与安全性**，点 **仍要打开**；或运行
   `xattr -dr com.apple.quarantine /Applications/ProxyWoman.app`。
   只对来自本仓库 Releases 页面、且校验和一致的下载这样做。

信任 ProxyWoman 的根证书（用于查看 HTTPS 内容）是单独的一步，由你在 App 内自己完成，见下文“使用”。

## 构建

运行需要 macOS 14 及以上；构建需要 Swift 6.2（Xcode 26+）。

```sh
swift build                    # 编译
swift test                     # 运行测试
scripts/build-app.sh           # 打包通用架构的 .app，输出到 build/
scripts/build-app.sh debug     # 只编当前架构，更快
```

## 使用

1. 打开 `build/ProxyWoman.app`。代理监听 `127.0.0.1:9090`（被占用时依次尝试到 9099），图标在菜单栏。
2. 在菜单栏图标或主窗口工具栏打开 **系统代理**：所有网络服务的 HTTP/HTTPS 代理都会指向 ProxyWoman；
   关闭开关或退出 App 时恢复原来的设置。
3. 要看 HTTPS 内容，需要信任根证书：在主窗口点 **安装证书…**，按步骤操作（系统会要求输入密码）。
   根证书被信任之前，被解密的 HTTPS 网站会报证书错误，所以开启系统代理前 ProxyWoman 会先提醒。

### curl 等命令行工具

curl 不读取系统代理，也不读取钥匙串，需要显式指定代理和根证书：

```sh
curl -x http://127.0.0.1:9090 \
  --cacert "$HOME/Library/Application Support/ProxyWoman/CA/root-ca.pem" \
  https://example.com/
```

证书安装页可以直接复制证书路径。

### 崩溃恢复

修改系统代理之前，ProxyWoman 会先备份原来的设置。App 崩溃或被强制结束后，下次启动时自动恢复。
只恢复仍然指向 ProxyWoman 的设置；期间被其他工具改过的设置保持不动。

### 上游代理

如果系统里原本就设置了代理（例如 Clash，`127.0.0.1:7897`），ProxyWoman 会把它当作上游，
经它的 CONNECT 隧道出网，并沿用原来的代理例外列表，抓包时网络不会中断。

## 界面语言

界面提供简体中文和 English。在 **设置 → 通用 → 界面语言** 中可选 **跟随系统**（默认）、**简体中文** 或 **English**；
更改后需重启 App 才生效，可在提示中选择“立即重启”（重启前后系统代理状态保持不变）。
跟随系统时，只看 macOS 首选语言列表的第一项：中文显示简体中文，英文显示 English，其他语言显示简体中文。

## 限制（Beta）

- 上游代理只支持 HTTP CONNECT：不支持 SOCKS 上游，也不支持需要认证的上游。
- 抓到的记录只在内存中（最多 10 万条、落盘正文最多 2 GB，超出时先丢弃最早的记录），每个正文最多记录
  50 MB。暂不支持保存会话。
- 按应用归类显示的是发起连接的进程：Safari 的请求显示为 `com.apple.WebKit.Networking`。
- 界面只有简体中文和英文。macOS 自带的菜单项（如“编辑”“窗口”）、日期选择器和数字格式跟随系统语言列表，
  在首选语言既非中文也非英文时，可能与 App 文字的语言不同。已记录的会话中的错误说明保留记录时的语言。

## 安全

根证书私钥保存在 `~/Library/Application Support/ProxyWoman/CA/root-ca-key.pem`，权限 `0600`。
在根证书受信任期间，拿到这个文件的人可以拦截你的 HTTPS 流量，请勿外传。

取消信任：打开 **钥匙串访问**，在“登录”钥匙串中找到名为 **ProxyWoman CA (…)**（括号里是生成时间）的证书，删除它，
或者双击打开后把 **信任 → 使用此证书时** 改为 **使用系统默认**。删除 `CA` 文件夹后，
ProxyWoman 下次启动会生成新的根证书。

## 许可证

Apache License 2.0，详见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。

[English](README.md)
