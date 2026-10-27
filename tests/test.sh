#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
./trusttunnel.sh --help | grep -q 'TT'
for cmd in install status start stop restart config dns cert user export logs update uninstall; do ./trusttunnel.sh "$cmd" --help >/dev/null; done
if ./trusttunnel.sh invalid > /dev/null 2>&1; then echo 'unknown command accepted' >&2; exit 1; fi
if ./trusttunnel.sh </dev/null >/dev/null 2>&1; then echo 'menu unexpectedly accepted non-terminal' >&2; exit 1; fi
(
 source "$ROOT/trusttunnel.sh"
 root() { :; }
 APP=$work/app ETC=$work/etc CONF=$ETC/manager.json CREDS=$ETC/users.json
 mkdir -p "$APP" "$ETC"
 printf '%s\n' '{"domain":"vpn.example.com","ip":"8.8.8.8","port":443,"version":"v1.1.0","email":""}' > "$CONF"
 printf '%s\n' '[{"username":"test","password":"a\"b: #$\\\\value"}]' > "$CREDS"
 write_configs
 grep -q 'listen_address = "0.0.0.0:443"' "$APP/vpn.toml"
 python3 - "$CONF" <<'PY_IPV6'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['ipv6']='2606:4700:4700::1111'; open(p,'w').write(json.dumps(c))
PY_IPV6
 write_configs
 grep -q 'listen_address = "\[::\]:443"' "$APP/vpn.toml"
 python3 - "$APP" <<'PY'
import sys
try: import tomllib
except ImportError: sys.exit(0)
from pathlib import Path
p=Path(sys.argv[1])
for x in ('vpn.toml','hosts.toml','credentials.toml'): tomllib.loads((p/x).read_text())
assert tomllib.loads((p/'credentials.toml').read_text())['client'][0]['password']=='a"b: #$\\\\value'
PY
 export_command --username test --format mihomo-full --node-name '我的节点' --output "$work/client.yaml" >/dev/null
 export_command --username test --format mihomo-flow --protocol h3 --node-name '香港 H3' --output "$work/flow.yaml" >/dev/null
 export_command --username test --format mihomo-block --protocol h3 --node-name '香港 H3' --output "$work/block.yaml" >/dev/null
 grep -q '^proxies:$' "$work/flow.yaml"
 grep -q '^  - name: "香港 H3"' "$work/block.yaml"
 [[ $(stat -c %a "$work/client.yaml") == 600 ]]
 grep -q '^proxies:' "$work/client.yaml"
 if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$work/client.yaml" <<'PY_YAML'
import sys,yaml
nodes=yaml.safe_load(open(sys.argv[1]))['proxies']
assert [n['name'] for n in nodes]==['我的节点-H2','我的节点-H3']
assert len(nodes)==2 and nodes[0]['password']=='a"b: #$\\\\value' and not nodes[0]['quic'] and nodes[1]['quic']
from pathlib import Path
for f in ['flow.yaml','block.yaml']:
 d=yaml.safe_load((Path(sys.argv[1]).parent/f).read_text())
 assert len(d['proxies'])==1 and d['proxies'][0]['name']=='香港 H3' and d['proxies'][0]['quic']
PY_YAML
 fi
 if (export_command --username test --format surge) >/dev/null 2>&1; then echo 'unsafe Surge credential accepted' >&2; exit 1; fi
 if (export_command --username missing) >/dev/null 2>&1; then echo 'unknown user accepted' >&2; exit 1; fi
 if command -v jq >/dev/null; then
  systemctl() { return 0; }
  printf '%s' 'safe_password' > "$work/pass"
  user_command add --username alice --password-file "$work/pass" >/dev/null
  grep -q 'alice' "$CREDS"
  if (user_command add --username alice --password-file "$work/pass") >/dev/null 2>&1; then echo 'duplicate user accepted' >&2; exit 1; fi
  systemctl() { return 1; }
  if (user_command reset --username alice --password-file "$work/pass") >/dev/null 2>&1; then echo 'failed restart accepted' >&2; exit 1; fi
  python3 - "$CREDS" <<'PY_USER'
import json,sys
assert any(u['username']=='alice' and u['password']=='safe_password' for u in json.load(open(sys.argv[1])))
PY_USER
  (
   APP=$work/update/app ETC=$work/update/etc CONF=$ETC/manager.json CREDS=$ETC/users.json
   mkdir -p "$APP" "$ETC"
   printf '%s\n' '{"domain":"vpn.example.com","ip":"8.8.8.8","port":443,"version":"v1.1.0","email":""}' > "$CONF"
   printf '%s\n' '[{"username":"test","password":"test"}]' > "$CREDS"
   printf 'old-program' > "$APP/trusttunnel_endpoint"
   fetch_binary() { printf 'new-program' > "$2"; }; systemctl() { return 1; }
   if (update_command --version v1.2.0) >/dev/null 2>&1; then echo 'failed upgrade accepted' >&2; exit 1; fi
   [[ $(cat "$APP/trusttunnel_endpoint") == old-program ]]
   [[ $(json_get "$CONF" version) == v1.1.0 ]]
  )
  CF=$ETC/cloudflare.ini
  printf 'dns_cloudflare_api_token = test_token\n' > "$CF"
  cf_api() {
   case "$2" in
    /zones\?*) printf '%s' '{"success":true,"result":[{"id":"zone"}]}' ;;
    */dns_records\?*) printf '%s' "$DNS_RESPONSE" ;;
    */dns_records*) printf '%s' '{"success":true}' ;;
    *) return 1 ;;
   esac
  }
  DNS_RESPONSE='{"success":true,"result":[],"result_info":{"total_count":0}}'
  sync_dns vpn.example.com 8.8.8.8 no >/dev/null
  sync_dns vpn.example.com 2606:4700:4700::1111 no AAAA >/dev/null
  DNS_RESPONSE='{"success":true,"result":[{"id":"a6","type":"AAAA","content":"2606:4700:4700::1001","proxied":false}],"result_info":{"total_count":1}}'
  if (sync_dns vpn.example.com 2606:4700:4700::1111 no AAAA) >/dev/null 2>&1; then echo 'IPv6 update without authorization accepted' >&2; exit 1; fi
  sync_dns vpn.example.com 2606:4700:4700::1111 yes AAAA >/dev/null
  DNS_RESPONSE='{"success":true,"result":[{"id":"a","type":"A","content":"1.1.1.1","proxied":false}],"result_info":{"total_count":1}}'
  if (sync_dns vpn.example.com 8.8.8.8 no) >/dev/null 2>&1; then echo 'DNS update without authorization accepted' >&2; exit 1; fi
  sync_dns vpn.example.com 8.8.8.8 yes >/dev/null
  DNS_RESPONSE='{"success":true,"result":[{"type":"CNAME"}],"result_info":{"total_count":1}}'
  if (sync_dns vpn.example.com 8.8.8.8 yes) >/dev/null 2>&1; then echo 'CNAME conflict accepted' >&2; exit 1; fi
  (
   ETC=$work/partial/etc CONF=$ETC/manager.json CREDS=$ETC/users.json CF=$ETC/cloudflare.ini
   APP=$work/partial/app SERVICE=$work/partial/service HOOK=$work/partial/hook BIN=$work/partial/TT
   mkdir -p "$ETC"
   printf 'dns_cloudflare_api_token = test_token\n' > "$CF"
   cf_api() {
    case $1:$2 in
     GET:/zones\?*) printf '%s' '{"success":true,"result":[{"id":"zone"}]}' ;;
     GET:*/dns_records\?*) printf '%s' '{"success":true,"result":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"A","content":"8.8.8.8","proxied":false}],"result_info":{"total_count":1}}' ;;
     DELETE:*) [[ -f $CF ]] || return 1; printf '%s' '{"success":true}' ;;
     *) return 1;;
    esac
   }
   uninstall_command --yes --domain vpn.example.com >/dev/null
   [[ ! -e $CF && ! -d $ETC ]]
  )
  (
   ETC=$work/partial-fail/etc CONF=$ETC/manager.json CREDS=$ETC/users.json CF=$ETC/cloudflare.ini
   APP=$work/partial-fail/app SERVICE=$work/partial-fail/service HOOK=$work/partial-fail/hook BIN=$work/partial-fail/TT
   mkdir -p "$ETC"; printf 'dns_cloudflare_api_token = test_token\n' > "$CF"
   cf_api() {
    case $1:$2 in
     GET:/zones\?*) printf '%s' '{"success":true,"result":[{"id":"zone"}]}' ;;
     GET:*/dns_records\?*) printf '%s' '{"success":true,"result":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"A","content":"8.8.8.8","proxied":false}],"result_info":{"total_count":1}}' ;;
     DELETE:*) return 1;; *) return 1;;
    esac
   }
   if (uninstall_command --yes --domain vpn.example.com) >/dev/null 2>&1; then echo 'failed DNS deletion accepted' >&2; exit 1; fi
   [[ -f $CF ]]
  )
  (
   ETC=$work/dns-conflict/etc CF=$ETC/cloudflare.ini; mkdir -p "$ETC"; printf 'dns_cloudflare_api_token = test_token\n' > "$CF"
   IP=8.8.8.8 IPV6=''
   cf_api() { case "$2" in /zones\?*) printf '%s' '{"success":true,"result":[{"id":"zone"}]}' ;; *) printf '%s' '{"success":true,"result":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"A","content":"1.1.1.1","proxied":false}],"result_info":{"total_count":1}}';; esac; }
   if (delete_managed_dns vpn.example.com full) >/dev/null 2>&1; then echo 'changed DNS record accepted' >&2; exit 1; fi
  )
  (
   APP=$work/migrate/app ETC=$work/migrate/etc CONF=$ETC/manager.json CREDS=$ETC/users.json
   mkdir -p "$APP" "$ETC"
   printf '%s\n' '{"domain":"vpn.example.com","ip":"8.8.8.8","port":443,"version":"v1.1.0","email":""}' > "$CONF"
   printf '%s\n' '[{"username":"test","password":"test"}]' > "$CREDS"
   sync_dns() { :; }; systemctl() { :; }
   dns_command sync --ipv6 2606:4700:4700::1111 >/dev/null
   grep -q 'listen_address = "\[::\]:443"' "$APP/vpn.toml"
   [[ $(json_get "$CONF" ipv6) == 2606:4700:4700::1111 ]]
  )
  (
   APP=$work/rollback/app ETC=$work/rollback/etc CONF=$ETC/manager.json CREDS=$ETC/users.json
   mkdir -p "$APP" "$ETC"
   printf '%s\n' '{"domain":"vpn.example.com","ip":"8.8.8.8","port":443,"version":"v1.1.0","email":""}' > "$CONF"
   printf '%s\n' '[{"username":"test","password":"test"}]' > "$CREDS"
   sync_dns() { :; }; systemctl() { return 1; }
   if (dns_command sync --ipv6 2606:4700:4700::1111) >/dev/null 2>&1; then echo 'failed IPv6 restart accepted' >&2; exit 1; fi
   grep -q 'listen_address = "0.0.0.0:443"' "$APP/vpn.toml"
  )
 else echo 'Skipped DNS mock tests: jq is unavailable' >&2; fi
 [[ $(validate_ipv6 2606:4700:4700::1111) == 2606:4700:4700::1111 ]]
 if (validate_ipv6 ::1) >/dev/null 2>&1; then exit 1; fi
 if command -v jq >/dev/null; then (
   APP=$work/install/app ETC=$work/install/etc CONF=$ETC/manager.json CREDS=$ETC/users.json CF=$ETC/cloudflare.ini
   SERVICE=$work/install/service BIN=$work/install/TT HOOK=$work/install/hook
   mkdir -p "$work/install" "$ETC"
   printf 'dns_cloudflare_api_token = test_token\n' > "$CF"
   if (install_command --domain vpn.example.com --cf-api different_token --ip 8.8.8.8) >"$work/token-mismatch" 2>&1; then echo 'mismatched credential accepted' >&2; exit 1; fi
   grep -q 'Token 不一致' "$work/token-mismatch"
   [[ ! -e $APP && $(cat "$CF") == 'dns_cloudflare_api_token = test_token' ]]
   cp "$0" "$BIN" # A matching preinstalled TT entry is safe.
   check_os() { :; }; check_port() { :; }; install_deps() { :; }; sync_dns() { :; }
   issue_cert() { :; }; setup_timer() { :; }; certbot() { echo "unexpected renewal test" >&2; return 1; }; systemctl() { :; }
   fetch_binary() { printf '#!/bin/sh\nexit 0\n' > "$2"; chmod +x "$2"; }
   install_command --domain vpn.example.com --cf-api test_token --ip 8.8.8.8 --ipv6 2606:4700:4700::1111 --node-name 节点 > "$work/install-output"
   grep -q '# Mihomo flow' "$work/install-output"
   grep -q '# Mihomo block' "$work/install-output"
   grep -q '# Surge' "$work/install-output"
   [[ $(grep -c '^proxies:$' "$work/install-output") == 2 ]]
   ! grep -q '# Mihomo proxies' "$work/install-output"
   grep -q '节点-H3 = trust-tunnel' "$work/install-output"
   grep -q 'listen_address = "\[::\]:443"' "$APP/vpn.toml"
   if (install_command --domain vpn.example.com --cf-api test_token --ip 8.8.8.8) >"$work/repeat-output" 2>&1; then echo 'repeat install accepted' >&2; exit 1; fi
   grep -q '已有 TrustTunnel Manager 安装' "$work/repeat-output"
  )
  (
   APP=$work/timer-fail/app ETC=$work/timer-fail/etc CONF=$ETC/manager.json CREDS=$ETC/users.json CF=$ETC/cloudflare.ini
   SERVICE=$work/timer-fail/service BIN=$work/timer-fail/TT HOOK=$work/timer-fail/hook
   mkdir -p "$work/timer-fail"
   check_os() { :; }; check_port() { :; }; install_deps() { :; }; sync_dns() { :; }
   issue_cert() { :; }; systemctl() { :; }; setup_timer() { return 1; }
   fetch_binary() { printf '#!/bin/sh\nexit 0\n' > "$2"; chmod +x "$2"; }
   if (install_command --domain vpn.example.com --cf-api test_token --ip 8.8.8.8) >"$work/timer-output" 2>&1; then echo 'failed renewal setup accepted' >&2; exit 1; fi
   grep -q '^proxies:$' "$work/timer-output"
   grep -q 'TT-H3 = trust-tunnel' "$work/timer-output"
  ); fi
 if (validate_node_name 'bad\name') >/dev/null 2>&1; then echo 'unsafe node name accepted' >&2; exit 1; fi
 if (validate_node_name 'bad,name') >/dev/null 2>&1; then echo 'unsafe node name accepted' >&2; exit 1; fi
 validate_domain vpn.example.com
 if (validate_domain 'a;bad.example.com') >/dev/null 2>&1; then exit 1; fi
 if (validate_ip 127.0.0.1) >/dev/null 2>&1; then exit 1; fi
 if (validate_port 65536) >/dev/null 2>&1; then exit 1; fi
)
python3 - <<'PY_MENU'
import os,pty,select,subprocess,time
master,slave=pty.openpty()
p=subprocess.Popen(['./trusttunnel.sh'],stdin=slave,stdout=slave,stderr=slave,close_fds=True)
os.close(slave)
os.write(master,b'7\n4\n3\nmissing\n\n0\n')
out=b''; deadline=time.time()+5
while p.poll() is None and time.time()<deadline:
 ready,_,_=select.select([master],[],[],.2)
 if ready:
  try: out+=os.read(master,8192)
  except OSError: break
if p.poll() is None: p.kill(); raise AssertionError('menu did not exit')
os.close(master)
assert b'HTTP/2' in out and b'Mihomo' in out and p.returncode==0, out
PY_MENU
echo 'Tests passed.' 
