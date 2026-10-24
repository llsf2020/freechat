# FreeChat

[English](README.md) | **简体中文**

自托管的类 Telegram 即时通讯软件，支持聊天、语音、视频（包括群组通话），并且支持**自动删除 / 阅后即焚**。基于 Matrix 协议，全部组件都是开源的。

> ⚠️ 项目还在测试阶段。iOS 客户端已在 CI 上编译通过、单元测试通过，但还没有在真机上试过。

## 特点

- **自动删除**：房间管理员设定时间（1 小时到 1 个月），到期后消息从服务器数据库里彻底删除，不留撤回记录；各设备同步删除本地副本。
- **阅后即焚**：每个人可以给自己发出的消息设定"所有人读过后多久删除"。
- **全服务器存期上限**：服务器上的任何消息最多保留多久（安装时设定，默认 7 天）。
- **私密房间**：加入需要密码，或者向管理员申请。
- **尽量少留元数据**：服务端不记录 IP 和设备名，日志默认不保存；推送只带事件 ID，不带内容和发送者；安卓推送用自建的 ntfy，不经过 Google。
- **严格模式**：登录状态和密钥只放在内存里，关掉 App 或页面后设备自动注销。
- **禁止截屏**：安卓可以禁止截屏和录屏；iOS 录屏时遮住受保护的房间。
- **一个脚本装好**：1 核 1 GB 内存的 VPS 就够，自动申请 HTTPS 证书；数据库可选整盘加密。

## 组成

| 层 | 组件 | 是否修改 |
|---|---|---|
| 服务端 | Tuwunel（Rust 写的 Matrix 服务端） | ✅ 自动删除、阅后即焚、私密房间、元数据最少化、存期上限 |
| 音视频 | LiveKit + lk-jwt-service + Element Call | 原样使用 |
| 网页端 | Element Web | ✅ 上述功能的界面；消息只放内存；严格模式 |
| 安卓 | Element X Android | ✅ 上述功能的界面；禁止截屏；消息不跨进程保留；严格模式 |
| iOS | Element X iOS | ✅ 上述功能、录屏时隐藏、多任务界面遮挡、严格模式（还没有在真机上试过） |
| App 底层 | matrix-rust-sdk（安卓和 iOS 共用） | ✅ 会话列表的消息预览只放内存；被删除的消息从设备缓存里清掉 |

目前只支持**网页、安卓、iOS**。桌面端（Windows、macOS、Linux）暂时不做。

## 快速开始

准备一台 Linux 服务器和一个指向它的域名，用 root 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/llsf2020/freechat/main/deploy/install.sh | sudo sh
```

服务器要求、防火墙端口、参数和日常管理命令见 [一键搭建](deploy/README.md)。

## 目录结构

```
upstream.conf      上游版本清单（基线 tag 和对应的提交哈希，构建时核对）
scripts/upstream.sh  查看新版本 / 同步上游 / 导出补丁
forks/<名称>/      各组件的 fork（独立 git 仓库，主仓库不跟踪）
patches/<名称>/    FreeChat 改动的补丁副本（主仓库跟踪）
docker/            镜像构建：按基线下载上游并打补丁、构建时的安全检查
deploy/            一键安装脚本（服务器上的全部配置都由它生成）
branding/          App 名字、包名、图标（改这里，编译时自动生效）
dev/               本机测试环境
.github/workflows/ CI：服务端和网页镜像、测试、安卓和 iOS 编译、安卓正式版 APK（手动运行）、网页锁文件更新
```

FreeChat 的改动以补丁形式保存在 `patches/` 里，构建时按 `upstream.conf` 下载上游源码、核对提交哈希后打上补丁。

安卓和 iOS 客户端用的 Rust SDK 不是官方发布的版本，而是按 `patches/matrix-rust-sdk` 从源码编出来的（`dev/build-rust-sdk.sh`）。CI 负责编译，SDK 补丁不变时直接用缓存。安卓正式版 APK 由手动运行的 `android-release` 工作流生成，SDK 会编全部四种安卓架构；APK 用仓库密钥 `FREECHAT_KEYSTORE`（base64）、`FREECHAT_KEYSTORE_PASSWORD`、`FREECHAT_KEY_ALIAS`、`FREECHAT_KEY_PASSWORD` 里的签名密钥签名，没配置时用公开的调试密钥签名，只能用于测试。

## 文档

以下文档为英文：

- [一键搭建](deploy/README.md)
- [品牌：名字、包名、图标](branding/README.md)

## 许可证

[AGPL-3.0](LICENSE)。各上游组件保留各自的许可证。按 AGPL 的要求，如果你把修改过的版本作为服务提供给别人使用，也要向他们提供对应的源代码。
