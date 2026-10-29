# Changelog

All notable changes to ProxyWoman, a free, open-source native macOS HTTP/HTTPS debugging proxy (Charles / Proxyman / Fiddler alternative).
Downloads: [GitHub Releases](https://github.com/gzldc/ProxyWoman/releases). 中文版：[CHANGELOG.zh-CN.md](CHANGELOG.zh-CN.md).

## [0.1.3] - 2026-10-29

### Added
- **JWT preview**: a JWT tab decodes tokens found in request headers, cookies and the query string, showing the header, payload, issued/not-before/expiry times and whether the token has expired. Read-only; the signature is not verified.
- **Open HAR / Session (⌘O)**: File ▸ Open HAR / Session… opens HAR 1.2 files from ProxyWoman, Chrome/Safari DevTools, Charles, Proxyman and other tools. Together with Export HAR, capture sessions can be saved and reopened.
- **One-click iOS Simulator setup**: Certificate ▸ Install Certificate on iOS Simulator adds the root certificate to every booted simulator (`xcrun simctl keychain … add-root-cert`).

### Fixed
- When a server rejects an upload midway (for example a body that is too large), its real response is relayed instead of a 502.
- Rules inside a turned-off group show a warning that they have no effect.

## [0.1.2] - 2026-10-29

### Fixed
- Request bodies over 64 KB that arrived while the upstream connection was still opening (for example ChatGPT requests) failed with "Pending request data exceeds the buffer limit".
- Advanced Proxy Settings scrolls and keeps Done visible; status rows no longer overlap.
- When the root certificate is trusted, the reason Regenerate is unavailable is shown directly.
- The version reported to MCP and in HAR exports matches the app; the Privacy page links to the source code.

## [0.1.1] - 2026-10-29

### Added
- **Phone / LAN capture**: allow LAN devices in Advanced Proxy Settings, with the proxy address and a QR code; open `http://proxywoman.cert` on the phone to download the root certificate. Certificate ▸ Install Certificate on Phone….
- **Upstream proxy modes**: automatic (reuse the original system proxy, such as Clash), manual host and port, or direct.
- **Bypass Proxy Settings**: hosts are added to the system bypass list; the original list is restored when the system proxy is turned off.
- **Regenerate the root certificate** (remove trust from the old one first).

### Fixed
- Built-in template names follow the app language.
- Removed the duplicate "Settings…" menu item.

## [0.1.0] - 2026-10-26

First public release.

- Capture HTTP/1.1, HTTP/2, HTTPS and WebSocket traffic, grouped by app and domain.
- HTTPS decryption with a locally generated root certificate.
- Rules with conditions and actions, built-in templates, Map Local and mock responses.
- Breakpoints, Compose and repeat, cURL and HAR export.
- System proxy switch in the toolbar and status bar with automatic restore; chains to an existing proxy such as Clash.
- Built-in MCP server for AI assistants.
- English and Simplified Chinese UI.

[0.1.3]: https://github.com/gzldc/ProxyWoman/releases/tag/v0.1.3
[0.1.2]: https://github.com/gzldc/ProxyWoman/releases/tag/v0.1.2
[0.1.1]: https://github.com/gzldc/ProxyWoman/releases/tag/v0.1.1
[0.1.0]: https://github.com/gzldc/ProxyWoman/releases/tag/v0.1.0
