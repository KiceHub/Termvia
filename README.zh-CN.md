# Termvia

原生 macOS 终端与 SSH 客户端，集成 SFTP/SCP 文件传输和主机监控。

**0.1.1** · Apple Silicon · macOS 27 及以上

[English](README.md)

## 安装

从 [Releases](https://github.com/KiceHub/Termvia/releases/latest) 下载 ZIP，解压后将 **Termvia.app** 移至「应用程序」。应用使用临时签名，尚未经过 Apple 公证。

## 使用

- 在起始页新建主机，填写地址和登录信息，首次连接时核对服务器指纹。支持密码、OpenSSH 私钥和 PuTTY PPK 密钥。
- 起始页也可打开本地终端。会话标签位于顶栏，主机与监控位于左侧。
- 拖动主机或分组调整顺序，默认分组固定置顶。
- 底栏可浏览文件、通过 SFTP/SCP 上传下载，以及查看传输与日志。关闭底栏后传输继续，点击右下角按钮可重新打开。
- 设置中可调整终端、监控、登录信息和快捷键，SSH 保活默认关闭。通过 **…** 切换语言和外观。

**⌘T** 新建起始标签，**⇧⌘T** 打开本地终端，**⌘,** 打开设置，长按 **⌘Q** 退出。

## 数据

应用数据位于 `~/Library/Application Support/Termvia/`。保存的密码与私钥口令没有额外加密。应用使用独立的主机指纹库，不读取 `~/.ssh/config`。传输中断后重传会从头开始。

## 许可

[Apache License 2.0](LICENSE)。第三方组件与图标保留各自许可，详见 [NOTICE](NOTICE)。
