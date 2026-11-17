# Termvia

A native macOS terminal and SSH client with SFTP/SCP file transfers and host monitoring.

**0.2.2** · Apple Silicon · macOS 27 or later

[简体中文](README.zh-CN.md)

## Install

Download the ZIP from [Releases](https://github.com/KiceHub/Termvia/releases/latest), extract it, and move **Termvia.app** to Applications. The app is ad-hoc signed and is not notarized.

## Use

- Create a host from the start tab, enter its address and login details, and verify its fingerprint on first connection. Passwords, OpenSSH keys and PuTTY PPK keys are supported.
- Open a local terminal from the start tab. Sessions appear across the top; hosts and monitoring are on the left.
- Manage SOCKS5/HTTP CONNECT/WireGuard proxies on the searchable Proxies settings page. WireGuard uses an isolated userspace stack shared by SSH channels and does not change system routing or DNS. Each host selects one upstream host or proxy; upstream hosts can form a multi-hop chain. Each hop uses its own login and host-key verification.
- Right-click a session tab or Shift-right-click a terminal to split horizontally or vertically, connect any host, or close a pane. Resize the native dividers. Files and monitoring follow the focused host; split layouts do not overwrite host layouts.
- Open files in the built-in, single-window tabbed editor (up to 16 MB, UTF-8 by default), with line numbers, text zoom, encoding, LF/CRLF and syntax controls, or choose an external app in Settings. Remote files use private local caches and saved cache changes synchronize to the remote host; local files open directly. Failed or interrupted synchronization retains the cache in `~/Library/Caches/Termvia/Editor/`.
- Drag files from Finder or other windows onto the remote file browser to upload. Drop remote items onto a terminal to insert shell-quoted absolute paths. Upload drops are disabled outside the visible Files panel. Drag-out downloads to other apps are not included; use the download action or the local file pane.
- Drag hosts and groups to reorder them. The default group stays first.
- Use the bottom panel to browse files, upload or download through SFTP/SCP, and view transfers or logs. Transfers continue when the panel is closed; the bottom-right button reopens them.
- Open Settings to change terminal behavior, monitoring, login profiles and shortcuts. SSH keep alive is off by default. Use **…** to change language or appearance.

**⌘T** opens a start tab, **⇧⌘T** opens a local terminal, and **⌘,** opens Settings. Hold **⌘Q** to quit.

## Data

Data is stored in `~/Library/Application Support/Termvia/`. Saved SSH/proxy passwords and key passphrases are not additionally encrypted. Termvia uses its own host-key database and ignores `~/.ssh/config`. Interrupted transfers restart from the beginning.

## License

[Apache License 2.0](LICENSE). Third-party components and icons retain their own licenses; see [NOTICE](NOTICE).

Builds require Apple Silicon, the macOS 27 SDK, and Go 1.27.4 or later for the bundled WireGuard transport.
