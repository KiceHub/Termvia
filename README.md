# Termvia

A native macOS terminal and SSH client with SFTP/SCP file transfers and host monitoring.

**0.1.1** · Apple Silicon · macOS 27 or later

[简体中文](README.zh-CN.md)

## Install

Download the ZIP from [Releases](https://github.com/KiceHub/Termvia/releases/latest), extract it, and move **Termvia.app** to Applications. The app is ad-hoc signed and is not notarized.

## Use

- Create a host from the start tab, enter its address and login details, and verify its fingerprint on first connection. Passwords, OpenSSH keys and PuTTY PPK keys are supported.
- Open a local terminal from the start tab. Sessions appear across the top; hosts and monitoring are on the left.
- Drag hosts and groups to reorder them. The default group stays first.
- Use the bottom panel to browse files, upload or download through SFTP/SCP, and view transfers or logs. Transfers continue when the panel is closed; the bottom-right button reopens them.
- Open Settings to change terminal behavior, monitoring, login profiles and shortcuts. SSH keep alive is off by default. Use **…** to change language or appearance.

**⌘T** opens a start tab, **⇧⌘T** opens a local terminal, and **⌘,** opens Settings. Hold **⌘Q** to quit.

## Data

Data is stored in `~/Library/Application Support/Termvia/`. Saved passwords and key passphrases are not additionally encrypted. Termvia uses its own host-key database and ignores `~/.ssh/config`. Interrupted transfers restart from the beginning.

## License

[Apache License 2.0](LICENSE). Third-party components and icons retain their own licenses; see [NOTICE](NOTICE).
