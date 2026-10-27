# TrustTunnel Manager

单文件 Bash 管理器，使用官方 TrustTunnel Endpoint、Cloudflare DNS 和 Certbot。适用于 Debian 12/13、Ubuntu 22.04/24.04，x86_64 或 aarch64，要求 systemd 和 root 权限。默认安装经过配置格式验证的官方 v1.1.0；可使用 `--version` 指定其他官方版本。

## 准备

- 一台可访问 GitHub、Cloudflare API 和 Let's Encrypt 的 VPS；需要允许客户端访问服务端的 TCP 和 UDP 443（如改用其他端口则使用对应端口）。脚本不会修改防火墙。
- 已托管在 Cloudflare 的域名，以及限于对应 Zone、具有 **Zone → DNS → Edit** 和 **Zone → Zone → Read** 权限的 API Token。DNS 记录使用 DNS Only。
- 证书 DNS-01 验证需要 DNS 正常传播。脚本默认不创建 AAAA 记录。启用 IPv6 后会配置 A 和 AAAA 记录，并让服务监听 IPv4/IPv6 双栈；服务器需要同时具备可用的公网 IPv4 和 IPv6，且防火墙须允许相应端口。

## 安装与入口

将 `trusttunnel.sh` 复制到服务器，执行：

```bash
sudo bash trusttunnel.sh install --domain vpn.example.com --cf-api YOUR_TOKEN
```

也可以把 Token 单独存入只有 root 可读的文件，并避免将其放进命令历史：

```bash
sudo bash trusttunnel.sh install --domain vpn.example.com --cf-token-file /root/cloudflare-token --email you@example.com
```

`--cf-api` 传入的 Token 可能被 shell 历史、进程列表或自动化系统记录。安装选项还包括 `--ip`、`--port`、`--username`、`--node-name`、`--password-file`、`--version` 、`--ipv6 IPv6|auto` 和 `--update-dns`。默认自动检测公网 IPv4、使用 443 端口、创建 `admin` 用户和随机密码。指定 `--ipv6 auto` 自动识别公网 IPv6，或指定具体的公网 IPv6 地址。未提供邮箱时 Certbot 使用无邮箱账户注册，无法收到证书过期通知。

无参数运行原脚本可进入安装面板：

```bash
sudo bash trusttunnel.sh
```

交互式安装或更换 Token 时，输入的 Token 会显示在终端。

安装成功后，从任意目录运行 `sudo TT` 打开面板，或使用 `sudo TT restart` 等子命令。面板的各级选项均使用数字选择。命令区分大小写。使用 `TT --help` 及 `TT <命令> --help` 查看选项。非交互命令缺少参数或遇到冲突时返回非零状态，不会提示输入。

如果同名 A 记录需要修改或从代理模式切换到 DNS Only，须明确指定 `--update-dns`。重复 A 记录和 CNAME 冲突需要先手动处理。检测到已有服务安装时，安装命令会停止，避免覆盖原文件；如果只预先安装了与当前脚本完全相同的 `/usr/local/bin/TT`，可以正常继续首次安装。安装过程中若网络、签发或服务启动失败，可能留下已创建的 DNS、证书或配置。如果只留下 `cloudflare.ini`，重新安装时输入相同 Token 即可复用；其他残留需要先检查。

## 常用命令

```bash
sudo TT status
sudo TT start
sudo TT stop
sudo TT restart
sudo TT logs                 # 最近日志；--follow 持续查看
sudo TT dns status
sudo TT dns sync --ip 203.0.113.10 --update-dns  # 改成实际公网 IPv4
sudo TT dns sync --ipv6 auto  # 为已有安装启用 IPv6 双栈
sudo TT dns sync --ipv6 2606:4700:4700::1111 --update-dns  # 替换为服务器公网 IPv6
sudo TT dns token --cf-token-file /root/new-token
sudo TT cert status
sudo TT cert renew           # 强制续签，受 CA 签发频率限制
sudo TT cert logs
sudo TT config port --port 8443
sudo TT config domain --domain new.example.com
sudo TT user list
sudo TT user add --username alice
sudo TT user reset --username alice --password-file /root/alice-password
sudo TT user delete --username alice --yes
sudo TT export --username alice --format mihomo-flow --protocol both --node-name "香港节点"
sudo TT export --username alice --format mihomo-full --output /root/alice.yaml
sudo TT export --username alice --format surge --protocol h3 --node-name "香港 H3"
sudo TT update               # 最新官方稳定版本
sudo TT update --version v1.1.0
sudo TT uninstall --yes       # 删除当前域名的 DNS、证书和管理器文件
# 安装未完成时，直接运行脚本并指定此前使用的完整域名：
sudo bash trusttunnel.sh uninstall --domain vpn.example.com --yes
```

`203.0.113.10` 仅用于说明，请替换为有效公网地址。`--password-file` 文件内容为密码，不应含换行或控制字符；省略该选项时生成随机密码。导出的内容包含明文密码，请妥善保管；`--output` 创建的文件权限为 `0600`，已有文件不会被覆盖。Mihomo 的单行和块状格式均带有 `proxies:` 及相应缩进，`mihomo-full` 与块状格式等价；这些内容不包含规则和代理组。导出两种协议时，节点名称追加 `-H2`、`-H3`；单独导出一种协议时，自定义名称原样使用，默认名称分别为 `TT-H2` 和 `TT-H3`。安装时指定的名称会保存为默认值，导出时也可临时通过 `--node-name` 覆盖。`all` 是供人查看的多格式文本，不能作为单个客户端配置直接导入。

Surge 的 Trust Tunnel 不支持 UDP relay；HTTP/3 需要支持 `h3` 的客户端版本。不能安全表示为 Surge 字段的密码会使 Surge 导出失败，但仍可导出 Mihomo YAML。参见 [Surge 文档](https://manual.nssurge.com/policies/trust-tunnel.html)和 [Mihomo 文档](https://wiki.metacubex.one/en/config/proxies/trusttunnel/)。

### 更新已安装的管理脚本

`TT update` 不会更新管理脚本自身。将新版 `trusttunnel.sh` 上传到服务器后，运行以下命令替换管理入口（不会重新安装服务端或覆盖已有配置）：

```bash
sudo install -m 700 trusttunnel.sh /usr/local/bin/TT
```

旧版本状态文件会自动兼容。升级脚本后，可通过 `sudo TT dns sync --ipv6 auto` 为已有安装启用 IPv6；如果已有 AAAA 记录需要修改，附加 `--update-dns`。

## 维护与安全

配置及凭据位于 `/opt/trusttunnel` 和 `/etc/trusttunnel-manager`。服务启动成功后直接输出客户端配置，其中包含明文密码；请保护终端、安装日志和配置文件。状态输出不显示凭据。

服务通过 systemd 管理；Certbot 使用 Cloudflare DNS 插件，续签部署钩子只在当前域名证书续签成功时重启服务。安装及修改域名时不会执行续签演练。修改域名会申请新证书后切换服务。原域名的 DNS 记录和证书不会自动删除。`TT update` 只更新官方 TrustTunnel Endpoint 服务端程序，不更新管理脚本、Certbot 或系统软件。更新失败时会尝试用临时保留的旧程序恢复服务，成功后删除该临时文件。

卸载先通过 Cloudflare API 删除对应的 DNS 记录，再通过 Certbot 删除该域名证书，最后删除服务、配置及 `cloudflare.ini`。已有安装只删除与记录的 IP 一致的 A/AAAA 记录；安装未完成时需明确提供 `--domain`，脚本会删除该域名下 DNS Only 的 A/AAAA 记录。如果记录重复、已被代理或与安装记录不一致，脚本会停止并保留凭据。删除 API 或证书失败时也会保留凭据以便重试。证书可能被其他服务共用，脚本会检查常见服务配置以及其他证书续签配置；卸载前请确认该域名记录与证书不再被其他用途使用。其他域名的 DNS 和系统中共用的软件包不会被删除。

## 测试与限制

执行 `bash tests/test.sh`。若系统有 `jq`，测试还会使用模拟 Cloudflare 响应检查 A/AAAA 记录、更新授权和 CNAME 冲突，并模拟安装完成后的配置输出；若有 PyYAML，还会解析客户端 YAML。测试不修改系统服务或访问真实 Cloudflare。

代码已使用官方 v1.1.0 x86_64 服务端验证生成的 TOML 能被读取。实际 VPS 上的系统安装、DNS 签发和续签、跨发行版与架构测试、以及 Mihomo/Surge 的真实代理连接仍需在具备相应环境和凭据的服务器上验收。
