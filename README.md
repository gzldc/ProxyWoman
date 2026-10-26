<p align="center">
  <img src="docs/brand/appicon-light-1024.png" width="128" alt="ProxyWoman app icon">
</p>

# ProxyWoman

**ProxyWoman is a free, open-source, native macOS HTTP/HTTPS debugging proxy**, written in Swift with SwiftNIO and
SwiftUI. It captures and decrypts the network traffic of apps and browsers on your Mac, shows every request and
response in detail, and lets you change traffic on the fly with rules, breakpoints and mock responses. It is a free
alternative to tools such as Proxyman, Charles Proxy and Fiddler Everywhere, and it includes a built-in MCP server
so that AI assistants (Claude, Cursor and others) can read the traffic you capture.

> ProxyWoman is an independent project and is **not affiliated with Proxyman**, Charles or Fiddler (与 Proxyman 无关).

[简体中文说明](README.zh-CN.md)

| | |
|---|---|
| Platform | macOS 14 Sonoma or later, Apple silicon (arm64) and Intel (x86_64) |
| License | Apache License 2.0, free for personal and commercial use |
| Interface languages | English and Simplified Chinese |
| Protocols | HTTP/1.1, HTTP/2, HTTPS (TLS interception), WebSocket |
| Download | [Releases](../../releases): `ProxyWoman-<version>-arm.dmg` (Apple silicon) or `ProxyWoman-<version>-intel.dmg` (Intel) |

## Contents

- [What you can do with it](#what-you-can-do-with-it)
- [Install](#install)
- [Quick start](#quick-start)
- [Features in detail](#features-in-detail)
- [Use with AI assistants (MCP)](#use-with-ai-assistants-mcp)
- [Command-line tools such as curl](#command-line-tools-such-as-curl)
- [Settings](#settings)
- [FAQ](#faq)
- [Build from source](#build-from-source)
- [Limitations](#limitations)
- [Security](#security)
- [License](#license)

## What you can do with it

- **Inspect API calls** from macOS apps, browsers and command-line tools: URL, method, status, headers, cookies,
  query parameters, request and response bodies, timing and the app that made each request.
- **Read HTTPS traffic** by trusting a root certificate that ProxyWoman generates locally on your Mac.
- **Mock and modify traffic without changing code**: return a fake response, map a URL to a local file, rewrite
  headers or bodies, change status codes, add delays or simulate failures.
- **Pause requests with breakpoints**, edit them, then continue or abort them.
- **Send and repeat requests** with Compose, and export flows as cURL or HAR.
- **Let an AI assistant analyse your traffic** through the built-in Model Context Protocol (MCP) server.

## Install

1. Download the DMG for your Mac from the [Releases](../../releases) page, together with its `.sha256` file:
   - Apple silicon (M1, M2, M3, M4 and later): `ProxyWoman-<version>-arm.dmg`
   - Intel: `ProxyWoman-<version>-intel.dmg`

   To see which chip you have, open  ▸ **About This Mac**.
2. Check the download. In the download folder, run
   `shasum -a 256 -c ProxyWoman-<version>-<chip>.dmg.sha256`; it should print `OK`.
3. Open the DMG and drag **ProxyWoman** onto **Applications**.
4. First launch: the app is ad-hoc signed. It is **not signed with an Apple Developer ID and not notarized**, so
   macOS blocks it the first time. Open **System Settings ▸ Privacy & Security** and click **Open Anyway**, or run
   `xattr -dr com.apple.quarantine /Applications/ProxyWoman.app`. Only do this for a download from this
   repository's Releases page whose checksum matches.

## Quick start

1. **Launch ProxyWoman.** The proxy listens on `127.0.0.1:9090`, or on the next free port up to 9099 if 9090 is
   busy. The app also has a menu bar icon.
2. **Turn on the system proxy** from the toolbar or the menu bar icon (**System Proxy**). Every network service's
   HTTP and HTTPS proxy then points at ProxyWoman. Turning it off, or quitting the app, restores your previous
   settings.
3. **Trust the root certificate to see HTTPS contents.** Choose **Certificate ▸ Install Certificate on This
   Mac…** and follow the steps; macOS asks for your password. Until the root is trusted, HTTPS sites that
   ProxyWoman decrypts show certificate errors, so ProxyWoman asks before enabling the system proxy. You choose
   which hosts are decrypted in **SSL Proxying List…**.
4. **Browse or run your app.** Requests appear in the traffic list as they happen. Select one to see its
   details.

## Features in detail

### Traffic list and sources

- A live list of every request, with columns for URL, app, method, status, time, duration and request and
  response size.
- A source sidebar: **All Traffic**, **Pinned**, **Apps** (grouped by the process that made the request),
  **Domains**, **Marked**, **Hidden** and **Not Decrypted**.
- Quick search and filters (URL, method, status, content type and more), pinning of apps and domains, colour
  marks with text, and hiding noisy sessions.
- Layouts: details side by side with the list, or stacked below it.

### Request and response details

- Overview, request and response tabs with headers, query parameters, cookies, raw messages and bodies.
- Body viewers for JSON (tree and text), images, hex dumps and plain text, with automatic decoding of gzip,
  deflate and Brotli bodies.
- TLS and certificate information for HTTPS connections.
- WebSocket message list with direction, type, size and time, with export as JSONL, raw text or HAR.
- Copy as cURL; export flows as HAR.

### Rules: modify traffic automatically

Rules are edited in a Rule Builder window and listed in the **Rules** tab of the main window, where they can be
grouped, ordered, enabled and disabled.

- **Conditions** (match all, any or none, with an optional limit on how many times a rule fires):
  - Request: URL, host, path, scheme, method, request headers, request cookies, request body, request body
    size, client HTTP version, client IP, process (app), request date and time.
  - Response: status code, response headers, response cookies, response body, response body size, duration,
    remote IP, remote HTTP version, protocol (HTTP, WebSocket, RPC, gRPC, server-sent events, Socket.IO), TLS
    certificate details.
  - Other: all sessions, comment, session state and other session-wide fields.
  - Operators depend on the field: contains, equals, starts or ends with, regular expression, exists, greater
    or less than, before or after a date, is empty, and their negations, with optional case sensitivity.
  - The editor shows live how many of the captured sessions the conditions match.
- **Actions** (several per rule, executed in order):
  - Modify request or response headers and cookies (set, add, replace, remove, find and replace).
  - Modify request or response bodies, the URL, query parameters or the status code.
  - Return a predefined response (for example 404, 500 or a redirect), a manually written response, or a local
    file (Map Local).
  - Delay the request, close the connection gracefully or abruptly, or return a CONNECT tunnel.
  - Set a request or response breakpoint.
  - Mark the session with colours and text, add a comment, hide it, or skip HTTPS decryption.
  - Optionally stop processing further rules.
- **Built-in templates**: a disabled **Default Templates** group with ready-made rules, such as allow or block
  lists by app or host, hiding CONNECT tunnels, mapping remote URLs, redirecting with 307, bypassing CORS,
  disabling caching, blocking cookies, setting a User-Agent, and marking scripts and JSON. Enable or copy them
  as a starting point.
- Rules can be imported, and all rules can be paused at once.

### Breakpoints

Pause a matching request before it is sent, or a response before it reaches the app. You can then edit the
method, URL, headers and body, and either continue or abort. The Breakpoints window lists everything that is
paused.

### Compose and repeat

Build a request from scratch or from a captured flow, edit it, send it and inspect the response. Repeat a
request many times with a configurable count, concurrency and interval, optionally applying your rules.

### System proxy, recovery and upstream proxies

- ProxyWoman backs up your proxy settings before changing them. If the app crashes or is killed, the next
  launch restores them. It only restores settings that still point at ProxyWoman, so anything another tool
  changed in the meantime is left alone.
- If a proxy was already configured (for example Clash or another proxy client on `127.0.0.1:7897`),
  ProxyWoman uses it as its upstream. Traffic leaves through that proxy's CONNECT tunnel and its bypass list
  still applies, so your network keeps working while you capture.
- Hosts that must not be intercepted (for example services that pin their certificates) can be passed through
  without decryption.

## Use with AI assistants (MCP)

ProxyWoman includes an MCP (Model Context Protocol) server, so AI assistants such as Claude Desktop, Claude Code
and Cursor can read your captured traffic.

- Enable it in **Settings ▸ MCP (AI Integration)**. It is off by default.
- The settings page shows ready-to-paste configuration for each client. The configuration runs the helper
  `ProxyWoman.app/Contents/MacOS/proxywoman-mcp`, which talks to the running app over a local socket that only
  your user account can access.
- Read-only tools: `get_status`, `list_flows`, `search_flows`, `get_flow`, `list_rules`, `export_flow_curl`,
  `export_har`.
- Write tools are off by default and must each be allowed explicitly: `create_rule`, `update_rule`,
  `set_rule_enabled`, `set_recording`.
- Sensitive values such as authorization headers, cookies and tokens are redacted by default before they reach
  the AI client.

Example prompts: "Which requests to api.example.com failed in the last minute?", "Explain this JSON response",
"Create a rule that returns 500 for /checkout".

## Command-line tools such as curl

curl does not read the system proxy or the keychain. Point it at the proxy and the root certificate explicitly:

```sh
curl -x http://127.0.0.1:9090 \
  --cacert "$HOME/Library/Application Support/ProxyWoman/CA/root-ca.pem" \
  https://example.com/
```

The certificate onboarding sheet can copy the certificate path for you. Many other tools accept
`HTTP_PROXY=http://127.0.0.1:9090` and `HTTPS_PROXY=http://127.0.0.1:9090` together with the same certificate.

## Settings

| Page | What it controls |
|---|---|
| General | Interface language, port, capture and system proxy at launch, menu bar icon, layout, quit confirmation, certificate shortcuts |
| Appearance | Theme, font, time format, zebra rows, text wrapping |
| HTTPS | SSL proxying list (which hosts are decrypted), pass-through hosts, undecrypted sessions |
| Traffic Control | Allow and block lists, network conditions |
| Privacy | What the app does and does not collect (no analytics) |
| Tools | Copy formats such as cURL |
| MCP (AI Integration) | MCP server, tool permissions, redaction and client configuration |
| Advanced | System proxy restore details, automatic deletion of old sessions, cache limits |

### Interface language

The interface is available in Simplified Chinese and English. Choose **Follow System** (the default),
**简体中文** or **English** in **Settings ▸ General ▸ Language**. The change applies after the app restarts. The
prompt offers **Restart Now**, and the system proxy stays as it was across the restart. With Follow System, only
the first language in the macOS preferred list counts: Chinese gives Simplified Chinese, English gives English,
and any other language gives Simplified Chinese.

## FAQ

**Is ProxyWoman free?** Yes. It is open source under the Apache License 2.0, with no paid tier, no account and
no analytics.

**Does it work on Apple silicon and on Intel Macs?** Yes. There is a separate DMG for each: `-arm` for Apple
silicon and `-intel` for Intel.

**Why does macOS say the app can't be verified?** The app is not notarized by Apple. See step 4 of
[Install](#install).

**Why do HTTPS sites show certificate errors?** Either the ProxyWoman root certificate is not trusted yet, or the
site pins its certificate. Install the certificate, or pass the host through without decryption.

**Can I capture iPhone traffic?** Point the iPhone's Wi-Fi proxy at your Mac's IP address and the ProxyWoman
port, then install and trust the ProxyWoman root certificate on the device. The iOS Simulator uses the Mac's
network settings.

**Does ProxyWoman upload my traffic?** No. Captured flows stay on your Mac, in memory with large bodies spooled
to disk. The MCP server only answers the AI client you configure, and redacts sensitive values by default.

**How is it different from Proxyman, Charles or Fiddler?** It covers the same core workflow (capture, HTTPS
decryption, rules, breakpoints, compose), is completely free and open source, is native Swift, and has a
built-in MCP server for AI assistants.

## Build from source

Requires macOS 14+ to run, and Swift 6.2 (Xcode 26+) to build.

```sh
swift build                    # build
swift test                     # run the tests
scripts/build-app.sh debug     # package build/ProxyWoman.app for this Mac's architecture (fast)
scripts/build-app.sh           # package a universal release app into build/
scripts/make-dmg.sh            # build release DMGs for arm64 and x86_64 into dist/
```

The project is a single Swift package:

| Module | Purpose |
|---|---|
| `App` | SwiftUI and AppKit macOS app |
| `Packages/ProxyCore` | SwiftNIO proxy engine: HTTP/1.1, HTTP/2, TLS interception, WebSocket, upstream chaining |
| `Packages/RulesEngine` | Rule model, matching and actions |
| `Packages/FlowStore` | In-memory flow storage with on-disk body spooling |
| `Packages/AppCore` | View models and app logic, independent of the network engine |
| `Packages/Viewers` | Body and message viewers |
| `Packages/MCPKit`, `Packages/MCPWire` | MCP server and its `proxywoman-mcp` helper |
| `Packages/Localization` | English and Simplified Chinese strings |

Issues and pull requests are welcome.

## Limitations

- Upstream chaining supports plain HTTP CONNECT proxies only: no SOCKS upstream and no upstream
  authentication.
- Captured flows live in memory: at most 100 000 flows and 2 GB of bodies on disk, and the oldest are dropped
  first. Each body is recorded up to 50 MB. Saving sessions to a file is not supported yet; export HAR instead.
- Per-app attribution names the process that opened the connection. For Safari that is
  `com.apple.WebKit.Networking`.
- No transparent proxy (Network Extension) yet, so apps that ignore the system proxy are not captured.
- The app is not notarized and does not update itself yet. Download new versions from Releases.
- Menu items supplied by macOS (Edit, Window), date pickers and number formats follow the system language
  list, so when the first preferred language is neither Chinese nor English they can differ from the app's
  text.

## Security

The root certificate's private key is stored at
`~/Library/Application Support/ProxyWoman/CA/root-ca-key.pem` with `0600` permissions. Anyone who
obtains this file can intercept your HTTPS traffic while the root is trusted, so never share it.

To stop trusting the root, open **Keychain Access** and find the certificate named **ProxyWoman CA (…)** in the
login keychain. Either delete it, or open it and set **Trust ▸ When using this certificate** to **Use System
Defaults**. If you delete the `CA` folder, ProxyWoman generates a new root on its next launch.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

<sub>Keywords: macOS HTTP proxy, HTTPS debugging proxy, network debugger, web debugging proxy, API debugging,
traffic inspector, man-in-the-middle proxy, SSL proxying, Map Local, Map Remote, breakpoint, mock API, HAR export,
WebSocket debugger, HTTP/2, SwiftNIO, MCP server, Proxyman alternative, Charles Proxy alternative, Fiddler
alternative, 抓包工具, Mac 抓包.</sub>
