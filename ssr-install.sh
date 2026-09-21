#!/usr/bin/env bash
#
# ssr-install.sh —— Ubuntu 20.04 / 22.04 / 24.04 SSR 服务端一键安装 + 修复
#
# 为什么不用网上那些 hijk / ccat 系的一键脚本：
#   它们装的是 shadowsocksr 3.2.2 的 Python 版，其中
#       shadowsocks/lru_cache.py:44  class LRUCache(collections.MutableMapping)
#   用的 collections.MutableMapping 在 Python 3.10 已被删除（Ubuntu 20.04 是 3.8 能跑，
#   22.04 是 3.10、24.04 是 3.12，import 就崩），并且依赖包里写死了 libsodium18
#   （新系统只有 libsodium23），一个包名找不到会让整条 apt 事务全部不装。
#   两处都会伪装成 "ssr启动失败，请检查端口是否被占用" 这种误导提示。
# 本脚本：装依赖（逐个装，不写死版本号）→ 装 SSR → 自动打 Python 3.10+ 兼容补丁
#        → 重写 systemd 单元为前台运行（报错能进 journal）→ 启动并实测验证 → 打印 ssr:// 链接。
# 可重复执行：已装过的机器会跳过下载、保留现有配置作为默认值，等同于修复。
#
# 非交互（给 CI / 批量用）：SSR_PORT SSR_PASS SSR_METHOD SSR_PROTOCOL SSR_OBFS 可覆盖交互输入。

set -u

VER="1.0.0"
D=/usr/local/shadowsocks
CONF=/etc/shadowsocksR.json
UNIT=/lib/systemd/system/shadowsocksR.service
SVC=shadowsocksR
SRC_URLS="https://codeload.github.com/shadowsocksrr/shadowsocksr/tar.gz/refs/tags/3.2.2 https://github.com/shadowsocksrr/shadowsocksr/archive/3.2.2.tar.gz"

METHODS=(aes-256-cfb aes-192-cfb aes-128-cfb aes-256-ctr aes-192-ctr aes-128-ctr aes-256-cfb8 aes-192-cfb8 aes-128-cfb8 camellia-128-cfb camellia-192-cfb camellia-256-cfb chacha20-ietf)
PROTOCOLS=(origin verify_deflate auth_sha1_v4 auth_aes128_md5 auth_aes128_sha1 auth_chain_a auth_chain_b auth_chain_c auth_chain_d auth_chain_e auth_chain_f)
OBFSLIST=(plain http_simple http_post tls1.2_ticket_auth tls1.2_ticket_fastauth)

say()  { printf '%s\n' "$*"; }
step() { printf '\n########## %s ##########\n' "$*"; }
die()  { printf '\n[!] %s\n' "$*" >&2; exit 1; }

# 菜单：选项和提示走 stderr，选定的值走 stdout，方便命令替换
pick() {
    local prompt="$1" def="$2" ans v; shift 2
    local opts=("$@") i
    {
        say "$prompt"
        for i in "${!opts[@]}"; do printf '   %d)%s\n' $((i + 1)) "${opts[$i]}"; done
    } >&2
    while :; do
        read -r -p "   请选择（回车 = ${def}）：" ans
        ans=${ans:-$def}
        if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then
            printf '%s' "${opts[$((ans - 1))]}"; return 0
        fi
        for v in "${opts[@]}"; do
            if [ "$ans" = "$v" ]; then printf '%s' "$ans"; return 0; fi
        done
        say "   输入无效，请重选" >&2
    done
}

cfgget() {
    python3 - "$CONF" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ''))
except Exception:
    print('')
PY
}

########## 0. 环境检查 ##########
step "0. 环境检查"
[ "$(id -u)" = 0 ] || die "请用 root 运行（sudo -i 后再执行）"
command -v apt-get >/dev/null 2>&1 || die "不是基于 apt 的系统，本脚本只支持 Ubuntu/Debian"
if [ ! -t 0 ] && [ -z "${SSR_PORT:-}" ]; then
    die "请用 bash <(curl -Ls 链接) 的方式运行（不要 curl ... | bash，会打乱交互输入），或用 SSR_PORT/SSR_PASS/SSR_METHOD/SSR_PROTOCOL/SSR_OBFS 环境变量非交互执行"
fi
UBUNTU=$(. /etc/os-release 2>/dev/null; echo "${VERSION:-unknown}")
say "系统：$PRETTY_NAME"
case "$UBUNTU" in
    20.04*|22.04*|24.04*) say "Ubuntu $UBUNTU —— 支持" ;;
    *) say "[!] 未在 Ubuntu $UBUNTU 上验证过，继续但可能有问题" ;;
esac

########## 1. 安装依赖 ##########
step "1. 安装依赖（逐个装，避免一个包名不存在就整条 apt 事务失败）"
apt-get update -qq >/dev/null 2>&1
apt_get() {
    if apt-get install -y "$1" >/dev/null 2>&1; then
        say "  + $1"
    elif dpkg -s "$1" >/dev/null 2>&1; then
        say "  = $1 已安装"
    else
        say "  - $1 装不上（稍后按提示处理）"
    fi
}
for p in python3 ca-certificates curl wget net-tools iproute2 qrencode unzip; do apt_get "$p"; done
command -v python3 >/dev/null 2>&1 || die "没有 python3，SSR 的 Python 版跑不起来"
PY=$(command -v python3)
say "python3：$($PY -V 2>&1)"

SODIUM_CANDS=$($PY - <<'PY'
import re, subprocess
out = subprocess.run(['apt-cache', 'search', '--names-only', r'^libsodium\d+$'],
                     capture_output=True, text=True).stdout
ver = {}
for line in out.splitlines():
    fields = line.split()
    m = re.fullmatch(r'libsodium(\d+)', fields[0]) if fields else None
    if m:
        ver[m.group(0)] = int(m.group(1))
print('\n'.join(sorted(ver, key=lambda k: -ver[k])))
PY
)
SODIUM=""
for s in $SODIUM_CANDS; do
    if apt-get install -y "$s" >/dev/null 2>&1; then say "  + $s"; SODIUM=$s; break; fi
done
[ -n "$SODIUM" ] || say "  - 没装上任何 libsodium（不影响 aes-* 系列）"
if ldconfig -p 2>/dev/null | grep -q 'libsodium\.so'; then
    say "libsodium 可用 ✓ （chacha20 / salsa20 系列可用）"
else
    say "[!] 没有 libsodium：别选 chacha20-ietf，用 aes-256-cfb"
fi

########## 2. 配置参数 ##########
step "2. 配置参数（回车即用默认值；老机器上默认值 = 现有配置）"
OLD_PORT=$(cfgget server_port); OLD_PASS=$(cfgget password)
OLD_METHOD=$(cfgget method); OLD_PROTO=$(cfgget protocol); OLD_OBFS=$(cfgget obfs)

PORT=${SSR_PORT:-${OLD_PORT:-$((RANDOM % 20000 + 30000))}}
while ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; do
    read -r -p "   端口输入有误（需 1024-65535），请重输：" PORT
done
say "  端口：$PORT"

PASS=${SSR_PASS:-${OLD_PASS:-}}
if [ -z "$PASS" ]; then
    PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)
    say "  密码：$PASS   （随机生成，请记牢）"
else
    say "  密码：沿用现有密码"
fi

if [ -n "${SSR_METHOD:-}" ]; then METHOD=$SSR_METHOD
else METHOD=$(pick "  加密方式：" "${OLD_METHOD:-aes-256-cfb}" "${METHODS[@]}"); fi
if [ -n "${SSR_PROTOCOL:-}" ]; then PROTO=$SSR_PROTOCOL
else PROTO=$(pick "  SSR 协议：" "${OLD_PROTO:-origin}" "${PROTOCOLS[@]}"); fi
if [ -n "${SSR_OBFS:-}" ]; then OBFS=$SSR_OBFS
else OBFS=$(pick "  混淆：" "${OLD_OBFS:-plain}" "${OBFSLIST[@]}"); fi
say "  加密=$METHOD  协议=$PROTO  混淆=$OBFS"

case "$METHOD" in
    chacha20*|salsa20*|sodium:*)
        ldconfig -p 2>/dev/null | grep -q 'libsodium\.so' || die "$METHOD 需要 libsodium，当前不可用，请改用 aes-256-cfb"
        ;;
esac

########## 3. 下载并安装 SSR ##########
step "3. SSR 服务端本体"
if [ -f "$D/server.py" ]; then
    say "  已存在 $D/server.py，跳过下载（只做补丁和配置）"
else
    TMP=$(mktemp -d) || die "mktemp 失败"
    trap 'rm -rf "${TMP:-}"' EXIT
    OK=""
    for u in $SRC_URLS; do
        say "  下载 $u"
        if curl -fLsS -m 180 -o "$TMP/s.tar.gz" "$u"; then OK=$u; break; fi
    done
    [ -n "$OK" ] || die "下载失败：GitHub 不可达？确认服务器能访问 codeload.github.com / github.com"
    tar -zxf "$TMP/s.tar.gz" -C "$TMP" || die "解压失败"
    SRC=$(find "$TMP" -maxdepth 1 -type d -name 'shadowsocksr-*' | head -n 1)
    [ -n "$SRC" ] && [ -f "$SRC/shadowsocks/server.py" ] || die "包结构不对，找不到 server.py"
    mkdir -p /usr/local
    cp -a "$SRC/shadowsocks" "$D" || die "安装到 $D 失败"
    rm -rf "$TMP"; trap - EXIT
    say "  已安装到 $D"
fi
[ -f "$D/server.py" ] || die "$D/server.py 不存在"

########## 4. 打 Python 3.10+ 兼容补丁 ##########
step "4. Python 3.10+ 兼容补丁"
test_import() {
    $PY -c "import sys; sys.path.insert(0, '/usr/local'); import shadowsocks.server; print('IMPORT OK')" 2>&1
}
say "  补丁前："
test_import | tail -n 4 | sed 's/^/    /'

for f in "$D/lru_cache.py" "$D/ordereddict.py"; do
    [ -f "$f" ] || continue
    if grep -qE 'collections\.(MutableMapping|Mapping|Iterable|Callable|Sequence|Set)\b' "$f"; then
        [ -f "$f.bak" ] || cp -a "$f" "$f.bak"
        sed -i -E 's/collections\.(MutableMapping|Mapping|Iterable|Callable|Sequence|Set)/collections.abc.\1/g' "$f"
        grep -q '^import collections\.abc' "$f" || \
            sed -i '0,/^import collections$/s//import collections\nimport collections.abc/' "$f"
        say "  已修补 $f   （备份 $f.bak）"
    else
        say "  $f 无需修补"
    fi
done

step "5. 补丁后自检"
AFTER=$(test_import)
printf '%s\n' "$AFTER" | tail -n 4 | sed 's/^/    /'
printf '%s' "$AFTER" | grep -q 'IMPORT OK' || die "仍然 import 失败，请把上面这段报错贴出来再排查"

########## 6. 写配置 ##########
step "6. 写配置文件 $CONF"
[ -f "$CONF" ] && [ ! -f "$CONF.bak" ] && cp -a "$CONF" "$CONF.bak"
$PY - "$CONF" "$PORT" "$PASS" "$METHOD" "$PROTO" "$OBFS" <<'PY'
import json, sys
path, port, pw, method, proto, obfs = sys.argv[1:7]
cfg = {
    "server": "0.0.0.0",
    "server_ipv6": "::",
    "server_port": int(port),
    "local_port": 1080,
    "password": pw,
    "timeout": 600,
    "method": method,
    "protocol": proto,
    "protocol_param": "",
    "obfs": obfs,
    "obfs_param": "",
    "redirect": "",
    "dns_ipv6": False,
    "fast_open": False,
    "workers": 1,
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=4)
    f.write("\n")
PY
say "  已写入（协议/加密/端口已按上面的选择生效）"

########## 7. systemd ##########
step "7. systemd 服务"
[ -f "$UNIT" ] && [ ! -f "$UNIT.bak" ] && cp -a "$UNIT" "$UNIT.bak"
cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=ShadowsocksR (python 3.2.2, patched for py3.10+)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$D
LimitNOFILE=32768
ExecStart=$PY $D/server.py -c $CONF
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_EOF
say "  已写入 $UNIT"

pkill -f "server.py -c $CONF" >/dev/null 2>&1
systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1
systemctl restart "$SVC"
sleep 3

########## 8. 防火墙 ##########
step "8. 防火墙"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: *active'; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 && say "  ufw 已放行 ${PORT}/tcp"
    ufw allow "${PORT}/udp" >/dev/null 2>&1 && say "  ufw 已放行 ${PORT}/udp"
else
    say "  ufw 未启用，跳过"
fi
say "  [!] 云服务器还要在控制台的安全组/防火墙里放行 ${PORT} 的 TCP 和 UDP，缺一不可"

########## 9. BBR（可选加速） ##########
step "9. BBR"
if lsmod 2>/dev/null | grep -q '^tcp_bbr'; then
    say "  BBR 已启用"
else
    if ! grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null; then
        printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    lsmod 2>/dev/null | grep -q '^tcp_bbr' && say "  BBR 已开启" || say "  内核无 tcp_bbr，跳过（不影响 SSR）"
fi

########## 10. 实测验证 + 连接信息 ##########
step "10. 验证"
STATUS=$(systemctl is-active "$SVC" 2>/dev/null)
say "  systemctl is-active：$STATUS"
LISTEN=$(ss -lntp 2>/dev/null | grep ":$PORT " || netstat -lntp 2>/dev/null | grep ":$PORT ")
if [ -z "$LISTEN" ]; then
    say "  [!] 端口 $PORT 没有监听，最近日志："
    journalctl -u "$SVC" -n 25 --no-pager 2>/dev/null | sed 's/^/    /'
    die "启动失败，把上面的日志贴出来"
fi
printf '%s\n' "$LISTEN" | sed 's/^/  /'

IP=$(curl -sL -m 12 -4 ip.sb 2>/dev/null | grep -E '^[0-9.]+$')
[ -z "$IP" ] && IP=$(curl -sL -m 12 ifconfig.me 2>/dev/null)
[ -z "$IP" ] && IP="你的服务器公网IP"
B64PASS=$(printf '%s' "$PASS" | base64 -w 0 | tr -d '=')
LINK=$(printf '%s' "$IP:$PORT:$PROTO:$METHOD:$OBFS:$B64PASS/?remarks=ssr&protoparam=&obfsparam=" | base64 -w 0 | tr -d '=')

say
say "============================================"
say " SSR 已运行   (ssr-install v$VER)"
say "   IP      : $IP"
say "   端口    : $PORT   (TCP + UDP)"
say "   密码    : $PASS"
say "   加密    : $METHOD"
say "   协议    : $PROTO"
say "   混淆    : $OBFS"
say "   链接    : ssr://$LINK"
say "============================================"
if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "ssr://$LINK" 2>/dev/null || true
fi
say "常用命令："
say "  systemctl status $SVC          # 看状态"
say "  journalctl -u $SVC -f          # 看实时日志"
say "  改配置：$CONF  然后 systemctl restart $SVC"
say "  重跑本脚本即可修复或改端口/密码（会保留现值为默认）"
