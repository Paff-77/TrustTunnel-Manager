#!/usr/bin/env bash
# TrustTunnel Manager: Bash frontend; JSON/TOML encoding uses Python 3.
set -Eeuo pipefail
umask 077
APP=/opt/trusttunnel
ETC=/etc/trusttunnel-manager
CONF=$ETC/manager.json
CREDS=$ETC/users.json
CF=$ETC/cloudflare.ini
SERVICE=/etc/systemd/system/trusttunnel.service
HOOK=/etc/letsencrypt/renewal-hooks/deploy/trusttunnel-manager
BIN=/usr/local/bin/TT
DEFAULT_VERSION=v1.1.0
API=https://api.cloudflare.com/client/v4
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
root() { [[ $EUID == 0 ]] || fail '请使用 root 或 sudo 运行'; }
installed() { [[ -f $CONF && -f $CREDS ]] || fail '尚未完成安装'; }
need_value() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "选项 $1 需要一个值"; }
help() {
 case ${1:-main} in
 main) cat <<'EOF'
TrustTunnel Manager
用法: TT [命令] [选项]   无参数打开交互式面板
命令: install status start stop restart config dns cert user export logs update uninstall
详细用法: TT <命令> --help
首次安装: sudo bash trusttunnel.sh install --domain vpn.example.com --cf-api TOKEN
EOF
 ;;
 install) echo 'install --domain 域名 (--cf-api TOKEN | --cf-token-file 文件) [--ip IPv4] [--ipv6 IPv6|auto] [--port 443] [--username 用户] [--node-name 节点名] [--password-file 文件] [--email 邮箱] [--version 版本] [--update-dns]' ;;
 config) echo 'config port --port 端口 | config domain --domain 域名 [--ip IPv4] [--email 邮箱] [--update-dns]' ;;
 dns) echo 'dns status | dns sync [--ip IPv4] [--ipv6 IPv6|auto] [--update-dns] | dns token (--cf-api TOKEN | --cf-token-file 文件)' ;;
 cert) echo 'cert status | cert renew | cert logs' ;;
 user) echo 'user list | user add --username 用户 [--password-file 文件] | user reset --username 用户 [--password-file 文件] | user delete --username 用户 --yes' ;;
 export) echo 'export --username 用户 [--node-name 节点名] [--format mihomo-flow|mihomo-block|mihomo-full|surge|all] [--protocol h2|h3|both] [--output 文件]' ;;
 update) echo 'update [--version 版本]  (默认使用最新稳定版)' ;;
 uninstall) echo 'uninstall --yes [--domain 域名]  (删除 DNS、该域名证书和管理器文件；未完成安装需指定域名)' ;;
 logs) echo 'logs [--follow]';;
 status|start|stop|restart) echo "$1: 查看或控制 TrustTunnel 服务" ;;
 *) fail '未知命令' ;;
 esac
}
json_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
validate_domain() { python3 - "$1" <<'PY'
import re,sys
s=sys.argv[1]
if len(s)>253 or '.' not in s or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', p) for p in s.split('.')): sys.exit('无效域名：'+s)
PY
}
validate_ip() { python3 - "$1" <<'PY'
import ipaddress,sys
try:
 ip=ipaddress.ip_address(sys.argv[1]); assert ip.version==4 and ip.is_global
except (ValueError,AssertionError): sys.exit('请输入有效的公网 IPv4 地址')
PY
}
validate_ipv6() { python3 - "$1" <<'PYIP'
import ipaddress,sys
try:
 ip=ipaddress.ip_address(sys.argv[1]); assert ip.version==6 and ip.is_global and not ip.ipv4_mapped and not ip.is_multicast
 print(ip.compressed)
except (ValueError,AssertionError): sys.exit('请输入有效的公网 IPv6 地址')
PYIP
}
resolve_ipv6() {
 local ip=$1
 if [[ $ip == auto ]]; then ip=$(curl -6 -fsS --connect-timeout 10 --max-time 20 https://api64.ipify.org) || fail '无法自动识别公网 IPv6，请手动指定'; fi
 IPV6=$(validate_ipv6 "$ip") || fail 'IPv6 地址无效'
}
require_dualstack_version() { python3 - "$1" <<'PYVER'
import re,sys
m=re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)',sys.argv[1])
if not m or tuple(map(int,m.groups())) < (1,0,5): sys.exit('IPv6 双栈需要官方稳定版 v1.0.5 或更高版本')
PYVER
}
validate_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || fail '端口必须为 1–65535'; }
validate_name() { [[ $1 =~ ^[a-zA-Z0-9_.-]{1,64}$ ]] || fail '用户名只能包含字母、数字、下划线、点和连字符'; }
validate_node_name() { [[ -n $1 && ${#1} -le 100 && $1 != *[[:cntrl:]]* && $1 != *','* && $1 != *'='* && $1 != *'"'* && $1 != *'\'* && $1 != ' '* && $1 != *' ' ]] || fail '节点名称不能为空、超过 100 字符、首尾有空格，或包含逗号、等号、引号、反斜杠及控制字符'; }
validate_secret() { [[ -n $1 && ${#1} -le 512 && $1 != *$'\n'* && $1 != *$'\r'* && $1 != *$'\t'* && $1 != *[[:cntrl:]]* ]] || fail '凭据为空、过长或包含控制字符'; }
password() { if [[ -n ${PASSWORD_FILE:-} ]]; then [[ -f $PASSWORD_FILE ]] || fail '密码文件不存在'; PASS=$(<"$PASSWORD_FILE"); else PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))'); fi; validate_secret "$PASS"; }
public_ip() { curl -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org || fail '无法识别公网 IP，请使用 --ip'; }
atomic_text() { local dest=$1 tmp; tmp=$(mktemp "${dest}.XXXXXX"); cat > "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$dest"; }
write_cf() { local token=$1; validate_secret "$token"; [[ $token =~ ^[A-Za-z0-9_-]+$ ]] || fail 'Token 包含非法字符'; mkdir -p "$ETC"; printf 'dns_cloudflare_api_token = %s\n' "$token" | atomic_text "$CF"; }
read_token() { [[ -r $CF ]] || fail 'Cloudflare 凭据不存在'; TOKEN=$(sed -n 's/^dns_cloudflare_api_token = //p' "$CF"); [[ -n $TOKEN ]] || fail 'Cloudflare 凭据无效'; }
# Feed authorization through curl config stdin to avoid exposing it as a process argument.
cf_api() { local method=$1 path=$2 payload=${3:-}; local config; config=$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$TOKEN"); if [[ -n $payload ]]; then curl -fsS --connect-timeout 15 --max-time 45 -K <(printf '%s\n' "$config") -X "$method" --data-binary "$payload" "$API$path"; else curl -fsS --connect-timeout 15 --max-time 45 -K <(printf '%s\n' "$config") -X "$method" "$API$path"; fi; }
find_zone() {
 local candidate=$1 response id
 while [[ $candidate == *.* ]]; do
   response=$(cf_api GET "/zones?name=$candidate&status=active&per_page=50") || fail 'Cloudflare 查询失败，请检查 Token 和网络'
   id=$(printf '%s' "$response" | jq -er 'if .success then if (.result|length)==1 then .result[0].id else "" end else error("Cloudflare API error") end') || fail 'Cloudflare API 返回错误'
   if [[ -n $id ]]; then ZONE=$id; return; fi
   candidate=${candidate#*.}
 done
 fail '找不到域名所属的 Cloudflare Zone'
}
sync_dns() {
 local domain=$1 ip=$2 allow=$3 type=${4:-A} response count id old proxied payload
 validate_domain "$domain"
 if [[ $type == A ]]; then validate_ip "$ip"; elif [[ $type == AAAA ]]; then ip=$(validate_ipv6 "$ip") || fail 'IPv6 地址无效'; else fail '未知 DNS 记录类型'; fi
 read_token; find_zone "$domain"
 response=$(cf_api GET "/zones/$ZONE/dns_records?name=$domain&per_page=100") || fail 'DNS 查询失败'
 printf '%s' "$response" | jq -e '.success and (.result_info.total_count <= 100)' >/dev/null || fail 'DNS 查询失败或记录过多'
 [[ $(printf '%s' "$response" | jq '[.result[] | select(.type == "CNAME")] | length') == 0 ]] || fail '存在 CNAME 冲突，请手动处理'
 count=$(printf '%s' "$response" | jq --arg t "$type" '[.result[] | select(.type == $t)] | length')
 (( count <= 1 )) || fail "存在重复 $type 记录，请手动处理"
 payload=$(jq -nc --arg name "$domain" --arg ip "$ip" --arg type "$type" '{type:$type,name:$name,content:$ip,ttl:1,proxied:false}')
 if (( count == 0 )); then response=$(cf_api POST "/zones/$ZONE/dns_records" "$payload") || fail '创建 DNS 记录失败'
 else
  id=$(printf '%s' "$response" | jq -r --arg t "$type" '.result[] | select(.type == $t) | .id'); old=$(printf '%s' "$response" | jq -r --arg t "$type" '.result[] | select(.type == $t) | .content'); proxied=$(printf '%s' "$response" | jq -r --arg t "$type" '.result[] | select(.type == $t) | .proxied')
  if [[ $type == AAAA ]]; then old=$(validate_ipv6 "$old") || fail '现有 AAAA 记录不是有效公网 IPv6，请手动处理'; fi
  if [[ $old == "$ip" && $proxied == false ]]; then echo "$type DNS 已是目标状态"; return; fi
  [[ $allow == yes ]] || fail "现有 $type 记录与目标不同，使用 --update-dns 明确允许更新"
  response=$(cf_api PATCH "/zones/$ZONE/dns_records/$id" "$payload") || fail '更新 DNS 记录失败'
 fi
 printf '%s' "$response" | jq -e '.success' >/dev/null || fail 'Cloudflare 拒绝 DNS 更新'
 echo "$type DNS 已同步：$domain → $ip（DNS Only）"
}
check_os() (
 [[ -r /etc/os-release ]] || fail '无法识别操作系统'; . /etc/os-release
 case "$ID:$VERSION_ID" in debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;; *) fail '仅支持 Debian 12/13 与 Ubuntu 22.04/24.04';; esac
 case $(uname -m) in x86_64|aarch64) ;; *) fail '不支持的 CPU 架构';; esac
 [[ -d /run/systemd/system ]] || fail '需要 systemd 系统'
)
check_port() { local port=$1; command -v ss >/dev/null || fail '需要 iproute2（ss）才能检查端口'; if ss -H -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$port$"; then fail "端口 $port 已被 TCP 或 UDP 使用"; fi; }
install_deps() { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y curl jq python3 certbot python3-certbot-dns-cloudflare ca-certificates iproute2 openssl; }
fetch_binary() {
 local version=$1 dest=$2 meta asset url digest archive tmp arch
 [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail '版本格式无效'
 arch=$(uname -m); [[ $arch == x86_64 || $arch == aarch64 ]] || fail '架构不受支持'
 meta=$(curl -fsSL --connect-timeout 15 --max-time 60 "https://api.github.com/repos/TrustTunnel/TrustTunnel/releases/tags/$version") || fail '无法获取官方发行信息'
 asset=$(printf '%s' "$meta" | jq -ec --arg n "trusttunnel-$version-linux-$arch.tar.gz" '[.assets[] | select(.name == $n)] | if length==1 then .[0] else error("release asset not found") end') || fail '指定版本没有对应架构的发行包'
 url=$(printf '%s' "$asset" | jq -r '.browser_download_url'); digest=$(printf '%s' "$asset" | jq -r '.digest // empty')
 [[ $url == https://github.com/TrustTunnel/TrustTunnel/releases/download/* && $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail '发行包地址或 SHA-256 摘要无效'
 tmp=$(mktemp -d); archive=$tmp/release.tar.gz
 curl -fsSL --connect-timeout 15 --max-time 300 "$url" -o "$archive" || { rm -rf "$tmp"; fail '下载失败'; }
 printf '%s  %s\n' "${digest#sha256:}" "$archive" | sha256sum -c --status || { rm -rf "$tmp"; fail '发行包 SHA-256 校验失败'; }
 python3 - "$archive" "$dest" <<'PY'
import os,sys,tarfile
with tarfile.open(sys.argv[1], 'r:gz') as t:
 found=[m for m in t.getmembers() if os.path.basename(m.name)=='trusttunnel_endpoint' and m.isfile()]
 if len(found)!=1: sys.exit('发行包中的服务端文件不唯一')
 with t.extractfile(found[0]) as source, open(sys.argv[2], 'wb') as out:
  import shutil; shutil.copyfileobj(source,out)
os.chmod(sys.argv[2],0o700)
PY
 rm -rf "$tmp"
 "$dest" --version >/dev/null || fail '服务端二进制无法运行'
}
write_state() { jq -n --arg domain "$DOMAIN" --arg ip "$IP" --arg ipv6 "${IPV6:-}" --argjson port "$PORT" --arg version "$VERSION" --arg email "$EMAIL" --arg node_name "${NODE_NAME:-TT}" '{domain:$domain,ip:$ip,ipv6:$ipv6,port:$port,version:$version,email:$email,node_name:$node_name}' | atomic_text "$CONF"; }
load_state() { installed; DOMAIN=$(json_get "$CONF" domain); IP=$(json_get "$CONF" ip); IPV6=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ipv6", ""))' "$CONF"); PORT=$(json_get "$CONF" port); VERSION=$(json_get "$CONF" version); EMAIL=$(json_get "$CONF" email); NODE_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("node_name", "TT"))' "$CONF"); }
write_configs() {
 python3 - "$CONF" "$CREDS" "$APP" <<'PY'
import json,os,sys,tempfile
c=json.load(open(sys.argv[1])); users=json.load(open(sys.argv[2])); app=sys.argv[3]
def q(s): return json.dumps(s,ensure_ascii=False)
def atomic(name,s):
 fd,p=tempfile.mkstemp(dir=app,prefix='.config-')
 try:
  os.fchmod(fd,0o600)
  with os.fdopen(fd,'w') as f: f.write(s)
  os.replace(p,os.path.join(app,name))
 finally:
  if os.path.exists(p): os.unlink(p)
vpn='listen_address = '+q(('[::]:' if c.get('ipv6') else '0.0.0.0:')+str(c['port']))+'\nallow_private_network_connections = false\ncredentials_file = '+q(app+'/credentials.toml')+'\n[listen_protocols.http2]\n[listen_protocols.quic]\n'
host='[[main_hosts]]\nhostname = '+q(c['domain'])+'\ncert_chain_path = '+q('/etc/letsencrypt/live/'+c['domain']+'/fullchain.pem')+'\nprivate_key_path = '+q('/etc/letsencrypt/live/'+c['domain']+'/privkey.pem')+'\n'
cred=''.join('[[client]]\nusername = '+q(u['username'])+'\npassword = '+q(u['password'])+'\n' for u in users)
for n,s in [('vpn.toml',vpn),('hosts.toml',host),('credentials.toml',cred)]: atomic(n,s)
PY
}
issue_cert() {
 local domain=$1 email=$2 args=(certonly --non-interactive --agree-tos --dns-cloudflare --dns-cloudflare-credentials "$CF" --dns-cloudflare-propagation-seconds 30 --cert-name "$1" -d "$1")
 if [[ -n $email ]]; then args+=(--email "$email"); else args+=(--register-unsafely-without-email); fi
 certbot "${args[@]}" || fail '证书签发失败，请检查 Token 权限、域名及 DNS 传播'
}
setup_timer() {
 if systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q '^certbot.timer'; then systemctl enable --now certbot.timer
 else
  [[ ! -e /etc/systemd/system/trusttunnel-certbot.service && ! -e /etc/systemd/system/trusttunnel-certbot.timer ]] || fail '专用续签配置已存在'
  cat > /etc/systemd/system/trusttunnel-certbot.service <<'EOF'
[Unit]
Description=Renew Certbot certificates
[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew -q
EOF
  cat > /etc/systemd/system/trusttunnel-certbot.timer <<'EOF'
[Unit]
Description=Twice daily certificate renewal
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now trusttunnel-certbot.timer
 fi
 mkdir -p "$(dirname "$HOOK")"
 cat > "$HOOK" <<'EOF'
#!/bin/sh
set -eu
[ -r /etc/trusttunnel-manager/manager.json ] || exit 0
domain=$(python3 -c 'import json; print(json.load(open("/etc/trusttunnel-manager/manager.json"))["domain"])')
[ "${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/$domain" ] || exit 0
systemctl try-restart trusttunnel.service
EOF
 chmod 700 "$HOOK"
}
install_command() {
 root; local token='' token_file='' update=no; DOMAIN='' IP='' IPV6='' IPV6_INPUT='' PORT=443 USERNAME=admin NODE_NAME=TT PASSWORD_FILE='' EMAIL='' VERSION=$DEFAULT_VERSION
 while (($#)); do case $1 in
 --domain|--cf-api|--cf-token-file|--ip|--ipv6|--port|--username|--node-name|--password-file|--email|--version) need_value "$@"; case $1 in --domain) DOMAIN=${2,,};; --cf-api) token=$2;; --cf-token-file) token_file=$2;; --ip) IP=$2;; --ipv6) IPV6_INPUT=$2;; --port) PORT=$2;; --username) USERNAME=$2;; --node-name) NODE_NAME=$2;; --password-file) PASSWORD_FILE=$2;; --email) EMAIL=$2;; --version) VERSION=$2;; esac; shift 2;;
 --update-dns) update=yes; shift;; *) fail "未知选项：$1";; esac; done
 [[ -n $DOMAIN ]] || fail '需要 --domain'; [[ -n $token || -n $token_file ]] || fail '需要 --cf-api 或 --cf-token-file'; [[ -z $token || -z $token_file ]] || fail '只能选择一种 Token 输入方式'
 [[ -z $token_file ]] || { [[ -f $token_file ]] || fail 'Token 文件不存在'; token=$(<"$token_file"); }
 validate_domain "$DOMAIN"; validate_port "$PORT"; PORT=$((10#$PORT)); validate_name "$USERNAME"; validate_node_name "$NODE_NAME"; password; check_os
 if [[ -e $APP || -e $SERVICE || -e $HOOK || -f $CONF || -f $CREDS ]]; then
  if [[ -f $CONF && -f $CREDS ]]; then
   fail '检测到已有 TrustTunnel Manager 安装。请运行 TT status 查看状态，或运行 TT export --username 用户名 导出配置；如安装中途失败，请先排查状态，不要重新安装。'
  fi
  printf '发现以下已有文件或目录：\n' >&2
  local path
  for path in "$APP" "$ETC" "$SERVICE" "$HOOK"; do [[ ! -e $path ]] || printf '  %s\n' "$path" >&2; done
  fail '检测到未完成的安装或其他程序的文件；请保留这些文件并检查上次安装输出，避免覆盖已有配置。'
 fi
 # A prior failed DNS/certificate setup may have created only the credentials directory.
 if [[ -e $ETC || -L $ETC ]]; then
  [[ -d $ETC && ! -L $ETC ]] || fail '凭据目录不是普通目录，请检查'
  python3 - "$ETC" <<'PYDIR' || fail '凭据目录包含其他文件，无法安全自动继续；请检查'
import os,sys
p=sys.argv[1]; names=os.listdir(p)
if any(n != 'cloudflare.ini' for n in names): sys.exit(1)
f=os.path.join(p,'cloudflare.ini')
if os.path.lexists(f) and (os.path.islink(f) or not os.path.isfile(f)): sys.exit(1)
PYDIR
  if [[ -e $CF ]]; then
   [[ $(<"$CF") == "dns_cloudflare_api_token = $token" ]] || fail '已有 Cloudflare 凭据与输入的 Token 不一致，请检查；原凭据未修改。'
   echo '检测到之前保存的相同 Cloudflare 凭据，将继续安装。'
  fi
 fi
 if [[ -e $BIN ]] && ! cmp -s -- "$BIN" "$(readlink -f "$0")"; then
  fail "检测到已有命令 $BIN，其内容与当前脚本不同；请检查后再操作。"
 fi
 check_port "$PORT"; install_deps
 [[ -n $IP ]] || IP=$(public_ip); validate_ip "$IP"; [[ -z $IPV6_INPUT ]] || { resolve_ipv6 "$IPV6_INPUT"; require_dualstack_version "$VERSION"; }
 mkdir -m 700 -p "$APP" "$ETC"; if [[ ! -e $CF ]]; then write_cf "$token"; fi; unset token
 sync_dns "$DOMAIN" "$IP" "$update"
 [[ -z $IPV6 ]] || sync_dns "$DOMAIN" "$IPV6" "$update" AAAA
 issue_cert "$DOMAIN" "$EMAIL"
 fetch_binary "$VERSION" "$APP/trusttunnel_endpoint"
 printf '%s' "$PASS" | python3 -c 'import json,sys; print(json.dumps([{"username":sys.argv[1],"password":sys.stdin.read()}],ensure_ascii=False))' "$USERNAME" | atomic_text "$CREDS"; unset PASS
 write_state; write_configs
 cat > "$SERVICE" <<'EOF'
[Unit]
Description=TrustTunnel Endpoint
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=/opt/trusttunnel
ExecStart=/opt/trusttunnel/trusttunnel_endpoint /opt/trusttunnel/vpn.toml /opt/trusttunnel/hosts.toml
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
 if [[ ! -e $BIN ]] || ! cmp -s -- "$BIN" "$(readlink -f "$0")"; then install -m 700 "$(readlink -f "$0")" "$BIN"; fi
 systemctl daemon-reload; systemctl enable --now trusttunnel.service || fail '启动失败，请查看 journalctl -u trusttunnel；保留文件供排查'
 systemctl is-active --quiet trusttunnel.service || fail '服务未正常运行'
 echo "服务已启动。以下客户端配置包含明文密码，请注意保护终端和日志："
 export_command --username "$USERNAME" --format all --protocol both
 setup_timer || fail '服务已安装，但自动续签配置失败，请检查后重试'
 echo '安装完成，已配置证书自动续签。'
}
user_command() {
 root; installed; local action=${1:-} name='' update='' tmp; shift || :; PASSWORD_FILE=''
 while (($#)); do case $1 in --username|--password-file) need_value "$@"; if [[ $1 == --username ]]; then name=$2; else PASSWORD_FILE=$2; fi; shift 2;; --yes) update=yes; shift;; *) fail "未知选项：$1";; esac; done
 case $action in
 list) jq -r '.[].username' "$CREDS"; return;;
 add|reset|delete) validate_name "$name";; *) fail '请指定 user list/add/reset/delete';; esac
 if [[ $action == add ]]; then jq -e --arg n "$name" 'all(.[]; .username != $n)' "$CREDS" >/dev/null || fail '用户已存在'; else jq -e --arg n "$name" 'any(.[]; .username == $n)' "$CREDS" >/dev/null || fail '用户不存在'; fi
 if [[ $action == delete ]]; then [[ $update == yes ]] || fail '删除用户需要 --yes'; jq -e 'length > 1' "$CREDS" >/dev/null || fail '不能删除最后一个用户'; else password; fi
 tmp=$(mktemp "$ETC/users.XXXXXX"); cp "$CREDS" "$tmp"
 case $action in
 add) printf '%s' "$PASS" | python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); a.append({"username":sys.argv[2],"password":sys.stdin.read()}); print(json.dumps(a,ensure_ascii=False))' "$tmp" "$name" | atomic_text "$CREDS";;
 reset) printf '%s' "$PASS" | python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); p=sys.stdin.read(); [u.update(password=p) for u in a if u["username"]==sys.argv[2]]; print(json.dumps(a,ensure_ascii=False))' "$tmp" "$name" | atomic_text "$CREDS";;
 delete) jq --arg n "$name" 'map(select(.username != $n))' "$tmp" | atomic_text "$CREDS";; esac
 unset PASS; write_configs
 if ! systemctl restart trusttunnel.service || ! systemctl is-active --quiet trusttunnel.service; then mv "$tmp" "$CREDS"; write_configs; systemctl restart trusttunnel.service || :; fail '用户修改失败，已尝试恢复'; fi
 rm -f "$tmp"; echo '用户操作成功。'
}
export_command() {
 root; load_state; local username='' node_name='' format=mihomo-full protocol=both output='' tmp
 while (($#)); do case $1 in --username|--node-name|--format|--protocol|--output) need_value "$@"; case $1 in --username) username=$2;; --node-name) node_name=$2;; --format) format=$2;; --protocol) protocol=$2;; --output) output=$2;; esac; shift 2;; *) fail "未知选项：$1";; esac; done
 validate_name "$username"; [[ -n $node_name ]] || node_name=$NODE_NAME; validate_node_name "$node_name"; [[ $format =~ ^(mihomo-flow|mihomo-block|mihomo-full|surge|all)$ ]] || fail '不支持的导出格式'; [[ $protocol =~ ^(h2|h3|both)$ ]] || fail '不支持的协议'
 [[ -z $output || ! -e $output ]] || fail '输出文件已存在'
 tmp=$(mktemp); if ! python3 - "$CONF" "$CREDS" "$username" "$format" "$protocol" "$node_name" > "$tmp" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); users=json.load(open(sys.argv[2])); name,fmt,proto,node_name=sys.argv[3:]; matches=[u for u in users if u['username']==name]
if len(matches)!=1: sys.exit('用户不存在或数据异常')
u=matches[0]; modes=['h2','h3'] if proto=='both' else [proto]
def q(s): return json.dumps(s,ensure_ascii=False)
def label(mode): return node_name+'-'+mode.upper() if proto=='both' or node_name=='TT' else node_name
def fields(mode):
 return [('name',q(label(mode))),('type','trusttunnel'),('server',q(c['domain'])),('port',str(c['port'])),('username',q(name)),('password',q(u['password'])),('sni',q(c['domain'])),('quic','true' if mode=='h3' else 'false'),('udp','true'),('skip-cert-verify','false')]
def flow():
 print('proxies:')
 for m in modes: print('  - {'+', '.join(k+': '+v for k,v in fields(m))+'}')
def block():
 print('proxies:')
 for m in modes:
  prefix='  '
  for i,(k,v) in enumerate(fields(m)): print(prefix+('- ' if i==0 else '  ')+k+': '+v)
def surge():
 if any(any(ch in str(x) for ch in ',\n\r\t') or str(x)!=str(x).strip() or '"' in str(x) or '\\' in str(x) for x in (name,u['password'],node_name)) or '=' in node_name:
  if fmt == 'all': print('无法安全生成 Surge 配置，请更换凭据后重新导出。'); return
  sys.exit('用户名或密码无法安全用于 Surge，请更换凭据')
 for m in modes: print(label(m)+' = trust-tunnel, '+c['domain']+', '+str(c['port'])+', username='+name+', password='+u['password']+', sni='+c['domain']+(', h3=true' if m=='h3' else ''))
if fmt=='mihomo-flow': flow()
elif fmt=='mihomo-block': block()
elif fmt=='mihomo-full': block()
elif fmt=='surge': surge()
else:
 print('# Mihomo flow'); flow(); print('\n# Mihomo block'); block(); print('\n# Surge'); surge()
PY
 then rm -f "$tmp"; fail '导出失败'; fi
 if [[ -n $output ]]; then install -m 600 "$tmp" "$output"; echo "配置已保存到 $output"; else cat "$tmp"; fi; rm -f "$tmp"
}
dns_command() {
 root; load_state; local action=${1:-} update=no token='' file='' ipv6_input='' old_ipv6; old_ipv6=$IPV6; shift || :
 while (($#)); do case $1 in --ip|--ipv6|--cf-api|--cf-token-file) need_value "$@"; case $1 in --ip) IP=$2;; --ipv6) ipv6_input=$2;; --cf-api) token=$2;; --cf-token-file) file=$2;; esac; shift 2;; --update-dns) update=yes; shift;; *) fail "未知选项：$1";; esac; done
 case $action in
 status) echo "域名：$DOMAIN；IPv4：$IP；IPv6：${IPV6:-未启用}";;
 sync) [[ -z $ipv6_input ]] || { resolve_ipv6 "$ipv6_input"; require_dualstack_version "$VERSION"; }; sync_dns "$DOMAIN" "$IP" "$update"; [[ -z $IPV6 ]] || sync_dns "$DOMAIN" "$IPV6" "$update" AAAA
  if [[ -z $old_ipv6 && -n $IPV6 ]]; then
   local oldconf; oldconf=$(mktemp "$ETC/old.XXXXXX"); cp "$CONF" "$oldconf"; write_state; write_configs
   if ! systemctl restart trusttunnel.service || ! systemctl is-active --quiet trusttunnel.service; then mv "$oldconf" "$CONF"; write_configs; systemctl restart trusttunnel.service || :; fail 'IPv6 启用失败，已尝试恢复配置；DNS 记录请检查'; fi
   rm -f "$oldconf"
  else write_state; fi;;
 token) [[ -z $token || -z $file ]] || fail '只能选择一种 Token 输入方式'; [[ -z $file ]] || token=$(<"$file"); [[ -n $token ]] || fail '需要 Token'; validate_secret "$token"; TOKEN=$token; find_zone "$DOMAIN"; write_cf "$token"; unset TOKEN token; echo 'Token 已更新';;
 *) fail '请指定 dns status/sync/token';; esac
}
config_command() {
 root; load_state; local action=${1:-} newdomain='' newport='' newip='' newemail='' update=no oldconf; shift || :
 while (($#)); do case $1 in --domain|--port|--ip|--email) need_value "$@"; case $1 in --domain) newdomain=${2,,};; --port) newport=$2;; --ip) newip=$2;; --email) newemail=$2;; esac; shift 2;; --update-dns) update=yes; shift;; *) fail "未知选项：$1";; esac; done
 oldconf=$(mktemp "$ETC/old.XXXXXX"); cp "$CONF" "$oldconf"
 case $action in
 port) [[ -n $newport ]] || fail '需要 --port'; validate_port "$newport"; newport=$((10#$newport)); [[ $newport == "$PORT" ]] && { rm "$oldconf"; return; }; check_port "$newport"; PORT=$newport;;
 domain) [[ -n $newdomain ]] || fail '需要 --domain'; validate_domain "$newdomain"; [[ $newdomain != "$DOMAIN" ]] || fail '域名未改变'; [[ -z $newip ]] || IP=$newip; [[ -z $newemail ]] || EMAIL=$newemail; sync_dns "$newdomain" "$IP" "$update"; [[ -z $IPV6 ]] || sync_dns "$newdomain" "$IPV6" "$update" AAAA; issue_cert "$newdomain" "$EMAIL"; DOMAIN=$newdomain;;
 *) fail '请指定 config port/domain';; esac
 write_state; write_configs
 if ! systemctl restart trusttunnel.service || ! systemctl is-active --quiet trusttunnel.service; then mv "$oldconf" "$CONF"; write_configs; systemctl restart trusttunnel.service || :; fail '配置变更失败，已尝试恢复'; fi
 rm -f "$oldconf"; echo '配置已更新。'
}
cert_command() {
 root; load_state; case ${1:-} in
 status) openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/cert.pem" -noout -subject -dates; if ! openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/cert.pem" -noout -checkend 2592000 >/dev/null; then echo '警告：证书将在 30 天内过期'; fi;;
 renew) certbot renew --cert-name "$DOMAIN" --force-renewal;; logs) journalctl -u certbot.service -u trusttunnel-certbot.service --no-pager -n 100;; *) fail '请指定 cert status/renew/logs';; esac
}
update_command() {
 root; load_state; local ver='' temp
 while (($#)); do case $1 in --version) need_value "$@"; ver=$2; shift 2;; *) fail "未知选项：$1";; esac; done
 if [[ -z $ver ]]; then ver=$(curl -fsSL https://api.github.com/repos/TrustTunnel/TrustTunnel/releases/latest | jq -er 'select(.prerelease == false and .draft == false) | .tag_name') || fail '无法获取最新稳定版本'; fi
 [[ $ver != "$VERSION" ]] || { echo '已是指定版本'; return; }; [[ -z $IPV6 ]] || require_dualstack_version "$ver"
 temp=$(mktemp "$APP/.endpoint.XXXXXX"); fetch_binary "$ver" "$temp"
 cp -p "$APP/trusttunnel_endpoint" "$APP/.endpoint-rollback"; mv "$temp" "$APP/trusttunnel_endpoint"
 if ! systemctl restart trusttunnel.service || ! systemctl is-active --quiet trusttunnel.service; then mv "$APP/.endpoint-rollback" "$APP/trusttunnel_endpoint"; systemctl restart trusttunnel.service || :; fail "升级失败，已尝试恢复"; fi
 rm -f "$APP/.endpoint-rollback"; VERSION=$ver; write_state; echo "升级完成：$ver"
}
delete_managed_dns() {
 local domain=$1 mode=$2 response records line id type
 validate_domain "$domain"; read_token; find_zone "$domain"
 response=$(cf_api GET "/zones/$ZONE/dns_records?name=$domain&per_page=100") || fail 'DNS 查询失败，卸载已停止，Cloudflare 凭据仍保留'
 records=$(printf '%s' "$response" | python3 -c '
import ipaddress,json,re,sys
mode,ip4,ip6=sys.argv[1:]
data=json.load(sys.stdin)
if not data.get("success") or data.get("result_info",{}).get("total_count",101)>100: sys.exit("DNS 查询失败或记录过多")
rs=[r for r in data.get("result",[]) if r.get("type") in ("A","AAAA") and (mode=="partial" or r.get("type")=="A" or bool(ip6))]
for t in ("A","AAAA"):
 group=[r for r in rs if r["type"]==t]
 if len(group)>1: sys.exit("存在重复 "+t+" 记录，请先手动检查；未删除任何 DNS 记录")
 for r in group:
  if r.get("proxied") is not False: sys.exit("DNS 记录处于代理模式，请先手动检查；未删除任何 DNS 记录")
  rid=r.get("id","")
  if not re.fullmatch("[0-9a-f]{32}",rid): sys.exit("DNS 记录 ID 无效；未删除任何 DNS 记录")
  if mode!="partial":
   expected=ip4 if t=="A" else ip6
   try: matches=ipaddress.ip_address(r.get("content",""))==ipaddress.ip_address(expected)
   except ValueError: matches=False
   if not matches: sys.exit(t+" 记录与安装时的地址不一致，请先手动检查；未删除任何 DNS 记录")
  print(t+" "+rid)
' "$mode" "${IP:-}" "${IPV6:-}") || fail 'DNS 记录校验失败，卸载已停止'
 while read -r type id; do
  [[ -n $id ]] || continue
  response=$(cf_api DELETE "/zones/$ZONE/dns_records/$id") || fail "$type 记录删除失败，卸载已停止，Cloudflare 凭据仍保留；可重新运行"
  printf '%s' "$response" | jq -e '.success' >/dev/null || fail "$type 记录删除失败，卸载已停止，Cloudflare 凭据仍保留；可重新运行"
  echo "已删除 $domain 的 $type 记录"
 done <<< "$records"
}
uninstall_command() {
 root; local yes=no supplied_domain='' domain mode=full path other
 while (($#)); do case $1 in
  --yes) yes=yes; shift;; --domain) need_value "$@"; supplied_domain=${2,,}; shift 2;; *) fail "未知选项：$1";; esac; done
 [[ $yes == yes ]] || fail '卸载需要 --yes'
 if [[ -f $CONF && -f $CREDS ]]; then
  load_state; domain=$DOMAIN
  [[ -z $supplied_domain || $supplied_domain == "$domain" ]] || fail '指定域名与当前安装不一致'
 else
  mode=partial; domain=$supplied_domain; IP='' IPV6=''
  [[ -n $domain ]] || fail '安装未完成，卸载需要 --domain 指定此前使用的完整域名'
  [[ -f $CF ]] || fail '未找到 Cloudflare 凭据，无法自动删除 DNS 记录'
  [[ ! -e $APP && ! -e $SERVICE && ! -e $HOOK ]] || fail '检测到未识别的服务文件，请先检查，未做任何删除'
 fi
 validate_domain "$domain"
 if [[ -e /etc/letsencrypt/live/$domain && ! -f /etc/letsencrypt/renewal/$domain.conf ]]; then
  fail '证书目录存在但缺少对应 Certbot 续签配置，请先检查；未删除 DNS 或凭据'
 fi
 # A different renewal configuration may also rely on this credential.
 if [[ -d /etc/letsencrypt/renewal ]]; then
  for path in /etc/letsencrypt/renewal/*.conf; do
   [[ -f $path ]] || continue; [[ $path != "/etc/letsencrypt/renewal/$domain.conf" ]] || continue
   if grep -Fq -- "$CF" "$path"; then fail "其他证书续签配置仍使用该 Cloudflare 凭据：$path；请先迁移凭据"; fi
  done
 fi
 # Refuse to delete a certificate referenced by common unrelated services.
 for path in /etc/nginx /etc/apache2 /etc/httpd /etc/haproxy /etc/postfix; do
  [[ -d $path ]] || continue
  if grep -R -l -F "/etc/letsencrypt/live/$domain/" "$path" >/dev/null 2>&1; then fail "其他服务配置可能使用该证书：$path；请先迁移证书"; fi
 done
 delete_managed_dns "$domain" "$mode"
 if [[ -f /etc/letsencrypt/renewal/$domain.conf ]]; then
  certbot delete --non-interactive --cert-name "$domain" || fail '证书删除失败，卸载已停止；Cloudflare 凭据仍保留，可重新运行'
 fi
 if [[ $mode == full ]]; then
  if [[ -f $SERVICE ]]; then systemctl disable --now trusttunnel.service || fail '无法停止服务，卸载已停止，凭据仍保留'; fi
  if [[ -f /etc/systemd/system/trusttunnel-certbot.timer ]]; then systemctl disable --now trusttunnel-certbot.timer || fail '无法停止续签任务，卸载已停止，凭据仍保留'; fi
  rm -f "$SERVICE" "$HOOK" /etc/systemd/system/trusttunnel-certbot.timer /etc/systemd/system/trusttunnel-certbot.service
  systemctl daemon-reload || fail '无法重新加载 systemd，卸载已停止，凭据仍保留'
  rm -rf "$APP"; rm -f "$CONF" "$CREDS"
 fi
 rm -f "$CF"
 if [[ -d $ETC ]]; then rmdir "$ETC" 2>/dev/null || echo "提示：$ETC 中有其他文件，已保留该目录。"; fi
 if [[ -f $BIN ]] && grep -Fq '# TrustTunnel Manager: Bash frontend' "$BIN"; then rm -f "$BIN"; fi
 echo '卸载完成：已删除匹配的 Cloudflare DNS 记录、对应证书和管理器文件。'
}
menu() {
 [[ -t 0 && -t 1 ]] || fail '交互面板需要终端；自动化请使用子命令'
 local choice sub detail domain token ip ipv6 name node_name port format confirm
 local -a args
 while :; do
  cat <<'EOF'
========== TrustTunnel Manager ==========
1. 安装                        2. 服务管理
3. 端口与域名                  4. Cloudflare DNS
5. 证书管理                    6. 用户管理
7. 导出客户端配置              8. 服务日志
9. 更新服务端                 10. 卸载
0. 退出
EOF
  read -r -p '请选择: ' choice || return
  case $choice in
  1)
   read -r -p '完整域名: ' domain || return
   read -r -p 'Cloudflare API Token: ' token || return
   read -r -p '节点名称（留空使用 TT）: ' node_name || return
   read -r -p '公网 IPv4（留空自动识别）: ' ip || return
   echo 'IPv6：1. 不启用  2. 自动检测  3. 手动输入'; read -r -p '请选择: ' sub || return
   args=(--domain "$domain" --cf-api "$token"); [[ -z $node_name ]] || args+=(--node-name "$node_name"); [[ -z $ip ]] || args+=(--ip "$ip")
   case $sub in 1) ;; 2) args+=(--ipv6 auto);; 3) read -r -p '公网 IPv6: ' ipv6 || return; args+=(--ipv6 "$ipv6");; *) echo '无效选项'; unset token; continue;; esac
   (install_command "${args[@]}") || echo '操作未完成。'; unset token args;;
  2)
   echo '1. 查看状态  2. 启动  3. 停止  4. 重启  0. 返回'; read -r -p '请选择: ' sub || return
   case $sub in 1) (dispatch status);; 2) (dispatch start);; 3) (dispatch stop);; 4) (dispatch restart);; 0) :;; *) echo '无效选项';; esac || echo '操作未完成。';;
  3)
   echo '1. 修改端口  2. 修改域名  0. 返回'; read -r -p '请选择: ' sub || return
   case $sub in
    1) read -r -p '新端口: ' port || return; (config_command port --port "$port");;
    2) read -r -p '新域名: ' domain || return; echo '允许更新已有 DNS 记录？ 1. 否  2. 是'; read -r -p '请选择: ' confirm || return; case $confirm in 1) (config_command domain --domain "$domain");; 2) (config_command domain --domain "$domain" --update-dns);; *) echo '无效选项';; esac;;
    0) :;; *) echo '无效选项';; esac || echo '操作未完成。';;
  4)
   echo '1. 查看 DNS  2. 同步 DNS / 启用 IPv6  3. 更换 Token  0. 返回'; read -r -p '请选择: ' sub || return
   case $sub in
    1) (dns_command status);;
    2) args=(); read -r -p '公网 IPv4（留空使用现有地址）: ' ip || return; [[ -z $ip ]] || args+=(--ip "$ip")
       echo 'IPv6：1. 保持现状  2. 自动检测并启用  3. 手动输入并启用'; read -r -p '请选择: ' detail || return
       case $detail in 1) :;; 2) args+=(--ipv6 auto);; 3) read -r -p '公网 IPv6: ' ipv6 || return; args+=(--ipv6 "$ipv6");; *) echo '无效选项'; continue;; esac
       echo '允许更新已有 DNS 记录？ 1. 否  2. 是'; read -r -p '请选择: ' confirm || return
       case $confirm in 1) :;; 2) args+=(--update-dns);; *) echo '无效选项'; continue;; esac
       (dns_command sync "${args[@]}");;
    3) read -r -p '新 Cloudflare API Token: ' token || return; (dns_command token --cf-api "$token"); unset token;;
    0) :;; *) echo '无效选项';; esac || echo '操作未完成。';;
  5)
   echo '1. 证书状态  2. 强制续签  3. 查看续签日志  0. 返回'; read -r -p '请选择: ' sub || return
   case $sub in 1) (cert_command status);; 2) (cert_command renew);; 3) (cert_command logs);; 0) :;; *) echo '无效选项';; esac || echo '操作未完成。';;
  6)
   echo '1. 用户列表  2. 添加用户  3. 重置密码  4. 删除用户  0. 返回'; read -r -p '请选择: ' sub || return
   case $sub in
    1) (user_command list);;
    2|3|4) read -r -p '用户名: ' name || return
      case $sub in 2) (user_command add --username "$name");; 3) (user_command reset --username "$name");; 4) echo '确认删除？ 1. 取消  2. 删除'; read -r -p '请选择: ' confirm || return; [[ $confirm == 2 ]] && (user_command delete --username "$name" --yes);; esac;;
    0) :;; *) echo '无效选项';; esac || echo '操作未完成。';;
  7)
   echo '1. Mihomo 单行  2. Mihomo 块状  3. Surge  4. 全部格式  0. 返回'; read -r -p '请选择: ' sub || return
   case $sub in 1) format=mihomo-flow;; 2) format=mihomo-block;; 3) format=surge;; 4) format=all;; 0) continue;; *) echo '无效选项'; continue;; esac
   echo '1. HTTP/2  2. HTTP/3  3. 两者'; read -r -p '请选择: ' detail || return
   case $detail in 1) detail=h2;; 2) detail=h3;; 3) detail=both;; *) echo '无效选项'; continue;; esac
   read -r -p '用户名: ' name || return; read -r -p '节点名称（留空使用已保存名称）: ' node_name || return; args=(--username "$name" --format "$format" --protocol "$detail"); [[ -z $node_name ]] || args+=(--node-name "$node_name"); (export_command "${args[@]}") || echo '操作未完成。';;
  8) echo '1. 最近日志  2. 实时日志  0. 返回'; read -r -p '请选择: ' sub || return; case $sub in 1) (dispatch logs);; 2) (dispatch logs --follow);; 0) :;; *) echo '无效选项';; esac || echo '操作未完成。';;
  9) echo '更新官方 TrustTunnel 服务端程序。1. 取消  2. 更新'; read -r -p '请选择: ' confirm || return; [[ $confirm == 2 ]] && (update_command) || :;;
  10) echo '将删除此域名的 DNS 记录、证书和管理器文件。1. 取消  2. 卸载'; read -r -p '请选择: ' confirm || return; if [[ $confirm == 2 ]]; then if [[ -f $CONF && -f $CREDS ]]; then (uninstall_command --yes) && return || echo '操作未完成。'; else read -r -p '此前使用的完整域名: ' domain || return; (uninstall_command --yes --domain "$domain") && return || echo '操作未完成。'; fi; fi;;
  0) return;; *) echo '无效选项';;
  esac
 done
}
dispatch() {
 local cmd=${1:-}; [[ $# == 0 ]] || shift
 if [[ ${1:-} == --help || ${1:-} == -h ]]; then help "$cmd"; return; fi
 case $cmd in
 '' ) menu;; -h|--help|help) help "${1:-main}";;
 install) install_command "$@";;
 status) root; load_state; echo "域名：$DOMAIN  IPv4：$IP  IPv6：${IPV6:-未启用}  端口：$PORT  版本：$VERSION"; systemctl status trusttunnel.service --no-pager || return $?; cert_command status;;
 start|stop|restart) root; installed; [[ $# == 0 ]] || fail '该命令不接受选项'; systemctl "$cmd" trusttunnel.service;;
 config) config_command "$@";; dns) dns_command "$@";; cert) cert_command "$@";; user) user_command "$@";; export) export_command "$@";;
 logs) root; installed; if [[ ${1:-} == --follow && $# == 1 ]]; then journalctl -u trusttunnel.service -f; elif [[ $# == 0 ]]; then journalctl -u trusttunnel.service -n 100 --no-pager; else fail '未知选项'; fi;;
 update) update_command "$@";;
 uninstall) uninstall_command "$@";; *) fail "未知命令：$cmd；使用 --help 查看帮助";; esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then dispatch "$@"; fi
