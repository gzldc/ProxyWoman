<p align="center">
  <img src="docs/brand/appicon-light-1024.png" width="128" alt="ProxyWoman">
</p>

# ProxyWoman

A free, open-source, native macOS HTTP/HTTPS debugging proxy, built with Swift and SwiftNIO.

> ProxyWoman is an independent project and is **not affiliated with Proxyman** (与 Proxyman 无关).

**Status: public beta.** Things may still change between versions; please report problems in Issues.

## Features

- Capture HTTP/1.1, HTTP/2 and WebSocket traffic; decrypt HTTPS with a local root certificate.
- Flow list with filters, per-app and per-host sources, pinning, marking and hiding; detailed request
  and response viewers (JSON, images, hex, raw).
- Rules with multiple conditions and actions: modify headers, cookies, URL, query, status and bodies,
  return a predefined, manual or local-file response, delay, close the connection, set breakpoints,
  mark or hide sessions. Built-in templates to start from.
- Compose and repeat requests; export as cURL or HAR.
- Built-in MCP server so AI assistants can read captured traffic (off by default; write tools need
  explicit permission).
- System proxy on/off with automatic restore, upstream proxy chaining.
- Simplified Chinese and English interface.

## Install

1. From the [Releases](../../releases) page (macOS 14+), download the DMG for your Mac and its `.sha256`
   file: `ProxyWoman-<version>-apple-silicon.dmg` for Apple silicon (M1 and later) or
   `ProxyWoman-<version>-intel.dmg` for Intel. ( ▸ About This Mac shows which chip you have.)
2. Verify it: in the download folder run `shasum -a 256 -c ProxyWoman-<version>-<chip>.dmg.sha256`
   (it should print `OK`).
3. Open the DMG and drag **ProxyWoman** onto **Applications**.
4. First launch: the app is ad-hoc signed, **not signed with an Apple Developer ID and not notarized**,
   so macOS blocks it the first time. Either open **System Settings ▸ Privacy & Security** and click
   **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/ProxyWoman.app`.
   Only do this for a download from this repository's Releases page whose checksum matches.

Trusting ProxyWoman's root certificate (for HTTPS contents) is a separate step you do yourself inside the
app; see [Usage](#usage).

## Build

Requires macOS 14+ to run, and Swift 6.2 (Xcode 26+) to build.

```sh
swift build                    # build
swift test                     # run the tests
scripts/build-app.sh           # package a universal .app into build/
scripts/build-app.sh debug     # faster, host architecture only
```

## Usage

1. Launch `build/ProxyWoman.app`. The proxy listens on `127.0.0.1:9090` (the next free port up to 9099 if
   that one is busy) and lives in the menu bar.
2. Turn on **系统代理** (system proxy) from the menu bar icon or the main window toolbar. Every network
   service's HTTP and HTTPS proxy is pointed at ProxyWoman; turning it off (or quitting) restores your
   previous settings.
3. To see HTTPS contents, trust the root certificate: click **安装证书…** in the main window and follow
   the steps (macOS asks for your password). Until the root is trusted, decrypted HTTPS sites show
   certificate errors, so ProxyWoman asks before enabling the system proxy.

### curl and other command-line tools

curl does not read the system proxy or the keychain. Point it at the proxy and the root certificate
explicitly:

```sh
curl -x http://127.0.0.1:9090 \
  --cacert "$HOME/Library/Application Support/ProxyWoman/CA/root-ca.pem" \
  https://example.com/
```

The certificate onboarding sheet can copy the certificate path for you.

### Crash recovery

The original proxy settings are backed up before ProxyWoman changes them. If the app crashes or is
killed, the next launch restores them. Only settings that still point at ProxyWoman are restored;
anything another tool changed in the meantime is left alone.

### Upstream proxy chaining

If a proxy was already configured (for example Clash on `127.0.0.1:7897`), ProxyWoman uses it as its
upstream: traffic leaves through that proxy's CONNECT tunnel and its bypass list still applies, so your
network keeps working while capturing.

## Interface language

The interface is available in Simplified Chinese and English. Choose **Follow System** (the default),
**简体中文** or **English** in **Settings → General → Language**. The change applies after the app
restarts; the prompt offers **Restart Now**, and the system proxy state is kept across the restart.
With Follow System only the first language in the macOS preferred list counts: Chinese gives Simplified
Chinese, English gives English, and any other language gives Simplified Chinese.

## Limitations (beta)

- Upstream chaining supports plain HTTP CONNECT proxies only: no SOCKS upstream and no upstream
  authentication.
- Captured flows live in memory (at most 100 000 flows and 2 GB of bodies on disk; the oldest are dropped
  first), and each body is recorded up to 50 MB. Saving sessions is not supported yet.
- Per-app attribution names the process that opened the connection: for Safari that is
  `com.apple.WebKit.Networking`.
- The interface has Simplified Chinese and English only. Menu items supplied by macOS (Edit, Window),
  date pickers and number formats follow the system language list, so when the first preferred language
  is neither Chinese nor English they can differ from the app's text. Failure notes on sessions that were
  already recorded keep the language they were recorded in.

## Security

The root certificate's private key is stored at
`~/Library/Application Support/ProxyWoman/CA/root-ca-key.pem` with `0600` permissions. Anyone who
obtains this file can intercept your HTTPS traffic while the root is trusted, so never share it.

To stop trusting the root: open **Keychain Access**, find the certificate named **ProxyWoman CA (…)** (with its creation time) in the login
keychain, and either delete it or open it and set **Trust → When using this certificate** to
**Use System Defaults**. Deleting the `CA` folder makes ProxyWoman generate a new root on next launch.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

[简体中文](README.zh-CN.md)
