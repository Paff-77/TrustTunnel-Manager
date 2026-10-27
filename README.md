<div align="center">

# TrustTunnel Manager

**面向自托管 TrustTunnel Endpoint 的 Bash 安装与管理工具**

[![Shell](https://img.shields.io/badge/shell-bash-121011?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Debian](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Architecture](https://img.shields.io/badge/arch-x86__64%20%7C%20aarch64-4c8caf)](#系统要求)

把 TrustTunnel Endpoint、Cloudflare DNS 和 Let's Encrypt 证书管理整合到一个命令行工具中。

[快速开始](#快速开始) · [功能](#功能) · [命令参考](#命令参考) · [安全说明](#安全说明)

</div>

## 项目简介

TrustTunnel Manager 帮助你在 Linux VPS 上安装和维护官方 TrustTunnel Endpoint。初次安装可使用数字菜单，也可以用命令行完成；安装后通过 `TT` 打开面板或直接运行子命令。

```text
你的设备 ── TrustTunnel / HTTP/2 或 HTTP/3 ──> VPS
                                                  ├─ TrustTunnel Endpoint
Cloudflare DNS ── 域名解析 ───────────────────────┤
Let's Encrypt ── DNS-01 证书 ─────────────────────┘
```

## 功能

| 能力 | 说明 |
| --- | --- |
| 一键部署 | 检查环境、下载官方发行版、生成配置并注册 systemd 服务 |
| 域名管理 | 通过 Cloudflare API 同步 DNS A 记录；可选启用 IPv6 和 AAAA 记录 |
| TLS 证书 | 使用 Certbot DNS-01 签发并自动续签 Let's Encrypt 证书 |
| 日常维护 | 查看状态、控制服务、管理用户、修改域名或端口、查看日志 |
| 客户端配置 | 导出 Mihomo YAML 与 Surge 配置，支持 HTTP/2、HTTP/3 和自定义节点名称 |
| 版本升级 | 下载官方 Endpoint 发行包并校验 SHA-256；启动失败时尝试恢复旧程序 |
| 安全卸载 | 删除本工具管理的 DNS 记录、证书、服务和配置；发现冲突时停止处理 |

## 快速开始

### 系统要求

| 项目 | 支持范围 |
| --- | --- |
| 操作系统 | Debian 12/13、Ubuntu 22.04/24.04 |
| 架构 | x86_64、aarch64 |
| 权限 | root 或 `sudo` |
| 服务管理 | systemd |
| 网络 | 可访问 GitHub、Cloudflare API 和 Let's Encrypt |

VPS 的防火墙和云平台安全组需要允许客户端访问服务端端口。默认使用 TCP 和 UDP 443；脚本不会修改防火墙规则。

### 安装

在服务器上直接下载管理脚本并启动交互式面板：

```bash
curl -fsSLo trusttunnel.sh https://raw.githubusercontent.com/Paff-77/TrustTunnel-Manager/main/trusttunnel.sh
chmod +x trusttunnel.sh
sudo ./trusttunnel.sh
```

也可以使用 `wget`：

```bash
wget -O trusttunnel.sh https://raw.githubusercontent.com/Paff-77/TrustTunnel-Manager/main/trusttunnel.sh
chmod +x trusttunnel.sh
sudo ./trusttunnel.sh
```

也可以直接运行非交互安装。建议将 Cloudflare Token 放在 root 可读的凭据文件中：

```bash
sudo bash trusttunnel.sh install \
  --domain vpn.example.com \
  --cf-token-file /root/cloudflare-token \
  --email admin@example.com
```

Token 需要限于目标 Zone，并具有 `Zone → DNS → Edit` 和 `Zone → Zone → Read` 权限。安装时可指定 IPv4、IPv6、端口、用户名和节点名称；完整选项见 `TT install --help`。

安装完成后：

```bash
sudo TT                 # 打开数字菜单
sudo TT status          # 查看服务状态
sudo TT restart         # 重启服务
```

## 命令参考

| 命令 | 用途 | 示例 |
| --- | --- | --- |
| `status`、`start`、`stop`、`restart` | 查看或控制服务 | `sudo TT restart` |
| `dns status`、`dns sync`、`dns token` | 查看、同步 DNS 或更换 Token | `sudo TT dns sync --ipv6 auto` |
| `cert status`、`cert renew`、`cert logs` | 查看证书、续签或查看日志 | `sudo TT cert status` |
| `user list`、`user add`、`user reset`、`user delete` | 管理认证用户 | `sudo TT user add --username alice` |
| `config port`、`config domain` | 修改服务端口或域名 | `sudo TT config port --port 8443` |
| `export` | 生成 Mihomo 或 Surge 客户端配置 | `sudo TT export --username alice --format mihomo-full` |
| `logs` | 查看服务日志；`--follow` 持续查看 | `sudo TT logs --follow` |
| `update` | 更新官方 TrustTunnel Endpoint | `sudo TT update` |
| `uninstall --yes` | 卸载服务、记录、证书和管理器文件 | `sudo TT uninstall --yes` |

为已有安装启用 IPv6 双栈：

```bash
sudo TT dns sync --ipv6 auto
```

`auto` 会尝试检测公网 IPv6，也可以传入具体地址。启用需要 VPS 本身有可用的公网 IPv6，并允许防火墙放行相应流量。

### 导出客户端配置

安装成功后会直接显示客户端配置。也可以在之后单独导出：

```bash
sudo TT export \
  --username alice \
  --format mihomo-full \
  --protocol both \
  --node-name "香港节点"
```

Mihomo 输出包含正确缩进的 `proxies:` 节点列表。HTTP/2 和 HTTP/3 同时导出时，节点名称分别追加 `-H2` 与 `-H3`；只导出一种协议时使用完整自定义名称。`--output` 可将配置保存到权限为 `0600` 的新文件。

Surge 不支持 Trust Tunnel UDP relay。HTTP/3 需要客户端版本支持 `h3` 参数。详见 [Surge Trust Tunnel 文档](https://manual.nssurge.com/policies/trust-tunnel.html)和 [Mihomo TrustTunnel 文档](https://wiki.metacubex.one/en/config/proxies/trusttunnel/)。

## 更新管理脚本

`sudo TT update` 更新的是官方 TrustTunnel Endpoint 服务端程序，不会更新管理脚本。替换管理脚本时，将新版 `trusttunnel.sh` 上传至服务器，再运行：

```bash
sudo install -m 700 trusttunnel.sh /usr/local/bin/TT
```

## 安全说明

- 客户端配置包含明文密码；安装完成后会显示在终端。避免把安装输出、配置文件或截图发布到公开位置。
- 交互式 Token 输入会在终端中显示。命令行 `--cf-api TOKEN` 也可能进入 shell 历史或进程列表；自动化建议使用 `--cf-token-file`。
- 管理器凭据保存在 `/etc/trusttunnel-manager`，服务配置保存在 `/opt/trusttunnel`。不要把真实凭据或生成的客户端配置提交到 Git。
- DNS 记录发生冲突或与本工具保存的地址不符时，脚本会停止卸载或更新，避免误改其他用途的记录。
- 卸载会尝试删除当前域名的 A/AAAA DNS 记录和 Certbot 证书。若记录或证书正被其他服务使用，请先迁移。

## 验证范围

运行 `bash tests/test.sh` 执行本地检查。测试会验证命令入口、配置生成、特殊字符、模拟 DNS 响应和失败恢复；安装 `jq` 后会执行完整 DNS 模拟，安装 PyYAML 后会额外解析生成的 YAML。

官方 v1.1.0 x86_64 Endpoint 已用于验证服务端 TOML 配置可读取。真实 VPS 部署、Cloudflare/Let's Encrypt 在线签发，以及 Mihomo 和 Surge 的实际连通性需要在目标环境单独验收。
