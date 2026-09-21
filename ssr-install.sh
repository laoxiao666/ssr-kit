#!/usr/bin/env bash
#
# ssr-install.sh —— Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux SSR 服务端一键安装 + 修复
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
# 与老 CentOS 脚本的两处有意分歧（都不照抄，理由见 README）：
#   1) 不修改 SELinux 状态（老脚本会把 enforcing 永久改成 permissive）；只检测并给出排查命令。
#   2) 不为装 BBR 去升级内核 / 删除旧内核包（老脚本 yum remove kernel-3.*，有把机器搞崩的风险）。
#
# 非交互（给 CI / 批量用）：SSR_PORT SSR_PASS SSR_METHOD SSR_PROTOCOL SSR_OBFS 可覆盖交互输入。

set -u

VER="1.1.0"
D=/usr/local/shadowsocks
CONF=/etc/shadowsocksR.json
UNIT=/lib/systemd/system/shadowsocksR.service
SVC=shadowsocksR
SRC_URLS="https://codeload.github.com/shadowsocksrr/shadowsocksr/tar.gz/refs/tags/3.2.2 https://github.com/shadowsocksrr/shadowsocksr/archive/3.2.2.tar.gz"

METHODS=(aes-256-cfb aes-192-cfb aes-128-cfb aes-256-ctr aes-192-ctr aes-128-ctr aes-256-cfb8 aes-192-cfb8 aes-128-cfb8 camellia-128-cfb camellia-192-cfb camellia-256-cfb chacha20-ietf)
PROTOCOLS=(origin verify_deflate auth_sha1_v4 auth_aes128_md5 auth_aes128_sha1 auth_chain_a auth_chain_b auth_chain_c auth_chain_d auth_chain_e auth_chain_f)
OBFSLIST=(plain http_simple http_post tls1.2_ticket_auth tls1.2_ticket_fastauth)

say()  { printf '%s\n' "${*:-}"; }
step() { printf '\n########## %s ##########\n' "${*:-}"; }
die()  { printf '\n[!] %s\n' "${*:-}" >&2; exit 1; }

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
command -v systemctl >/dev/null 2>&1 || die "没有 systemctl：本脚本依赖 systemd（CentOS 6 及更早不支持）"
if [ ! -t 0 ] && [ -z "${SSR_PORT:-}" ]; then
    die "请用 bash <(curl -Ls 链接) 的方式运行（不要 curl ... | bash，会打乱交互输入），或用 SSR_PORT/SSR_PASS/SSR_METHOD/SSR_PROTOCOL/SSR_OBFS 环境变量非交互执行"
fi

osrel() { grep -m1 "^$1=" /etc/os-release 2>/dev/null | cut -d'"' -f2; }
OS_NAME=$(osrel PRETTY_NAME)
OS_ID=$(osrel ID)
OS_VERID=$(osrel VERSION_ID)
say "系统：${OS_NAME:-未知}"

if command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf >/dev/null 2>&1; then PM=dnf
elif command -v yum >/dev/null 2>&1; then PM=yum
else die "找不到 apt-get / dnf / yum，本脚本不支持这个发行版"
fi
EL_MAJ=""
[ "$PM" = "apt" ] || EL_MAJ=${OS_VERID%%.*}
say "包管理器：$PM${EL_MAJ:+（EL ${EL_MAJ}）}"

case "${OS_ID:-unknown}" in
    ubuntu|debian)
        case "${OS_VERID:-}" in
            20.04|22.04|24.04) say "Ubuntu ${OS_VERID} —— 支持" ;;
            *) say "[!] 未在 ${OS_NAME:-该系统} 上实测过（已验证：Ubuntu 20.04/22.04/24.04，CentOS/Rocky/Alma 7/8/9），继续尝试" ;;
        esac
        ;;
    centos|rhel|rocky|almalinux|fedora)
        say "${OS_ID} ${OS_VERID} —— 支持"
        if [ "${OS_ID:-}" = "centos" ] && [ "${EL_MAJ:-}" = "7" ]; then
            say "  [!] CentOS 7 已停止维护，官方 yum 源可能已下线；装包失败时按 README 换 vault 源再重试"
        fi
        ;;
    *) say "[!] 未识别的发行版（${OS_NAME:-未知}），按 $PM 继续尝试" ;;
esac

########## 1. 安装依赖 ##########
step "1. 安装依赖（逐个装，避免一个包名找不到就整条事务全部不装）"
pkg_upd() {
    case "$PM" in
        apt) apt-get update -qq >/dev/null 2>&1 ;;
        dnf) dnf makecache -q >/dev/null 2>&1 ;;
        yum) yum makecache fast >/dev/null 2>&1 || yum makecache >/dev/null 2>&1 ;;
    esac
}
pkg_ins() {
    case "$PM" in
        apt) apt-get install -y "$1" >/dev/null 2>&1 ;;
        dnf) dnf install -y "$1" >/dev/null 2>&1 ;;
        yum) yum install -y "$1" >/dev/null 2>&1 ;;
    esac
}
pkg_q() {
    if [ "$PM" = "apt" ]; then dpkg -s "$1" >/dev/null 2>&1; else rpm -q "$1" >/dev/null 2>&1; fi
}
pkg() {
    local p="$1"
    if pkg_ins "$p"; then say "  + $p"
    elif pkg_q "$p"; then say "  = $p 已安装"
    else say "  - $p 装不上（稍后按提示处理）"
    fi
}
pkg_upd
if [ "$PM" != "apt" ]; then
    # EPEL 提供 EL 上的 libsodium / qrencode，以及 CentOS 7 的 python3
    pkg epel-release
    if ! rpm -q epel-release >/dev/null 2>&1; then
        say "  [!] epel-release 包装不上，直接导入 EPEL rpm"
        rpm -Uvh --replacepkgs "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EL_MAJ:-7}.noarch.rpm" \
            >/dev/null 2>&1 && say "  + EPEL rpm 已导入" || say "  - EPEL 导入失败（libsodium/qrencode 可能装不上，不影响 aes-* 方案）"
        pkg_upd
    fi
fi
BASE_PKGS=(curl wget ca-certificates net-tools unzip tar openssl python3)
if [ "$PM" = "apt" ]; then BASE_PKGS+=(iproute2 qrencode); else BASE_PKGS+=(iproute qrencode); fi
for p in "${BASE_PKGS[@]}"; do pkg "$p"; done
command -v python3 >/dev/null 2>&1 || die "没有 python3，SSR 的 Python 版跑不起来"
PY=$(command -v python3)
say "python3：$($PY -V 2>&1)（本脚本的内联 Python 只用 json/base64 基础 API，兼容 EL7 的 3.6）"

# libsodium：apt 侧探测当前系统真实包名（老脚本写死 libsodium18 是翻车点之一），EL 侧就叫 libsodium
if [ "$PM" = "apt" ]; then
    SODIUM_CANDS=$(apt-cache search --names-only '^libsodium[0-9]+$' 2>/dev/null | awk '{print $1}' \
        | grep -xE 'libsodium[0-9]+' | sed 's/libsodium//' | sort -rn | sed 's/^/libsodium/')
else
    SODIUM_CANDS="libsodium"
fi
SODIUM=""
for s in $SODIUM_CANDS; do
    if pkg_ins "$s"; then say "  + $s"; SODIUM=$s; break; fi
done
[ -n "$SODIUM" ] || say "  - 没装上 libsodium（不影响 aes-* 系列）"
if ldconfig -p 2>/dev/null | grep -q 'libsodium\.so'; then
    say "libsodium 可用 ✓ （chacha20 / salsa20 系列可用）"
else
    say "[!] 没有 libsodium：别选 chacha20-ietf，用 aes-256-cfb"
fi

########## 2. 配置参数 ##########
step "2. 配置参数（回车即用默认值；老机器上默认值 = 现有配置）"
OLD_PORT=$(cfgget server_port); OLD_PASS=$(cfgget password)
OLD_METHOD=$(cfgget method); OLD_PROTO=$(cfgget protocol); OLD_OBFS=$(cfgget obfs)

ask_or_die() {   # ask_or_die "提示" 变量名 —— 读入并允许回车用默认值；stdin 不是终端时明确报错
    local prompt="$1" __n="$2"
    read -r -p "$prompt" "$__n" || die "读取输入失败：stdin 不是终端？请用 bash <(curl -Ls 链接) 的方式运行，或用 SSR_PORT/SSR_PASS 等环境变量非交互执行"
}

DEF_PORT=${SSR_PORT:-${OLD_PORT:-$((RANDOM % 20000 + 30000))}}
if [ -n "${SSR_PORT:-}" ]; then
    PORT=$SSR_PORT
else
    ask_or_die "   请输入端口（回车 = ${DEF_PORT}）：" PORT
    PORT=${PORT:-$DEF_PORT}
fi
while ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; do
    say "   输入错误，端口号为 1-65535 的数字"
    ask_or_die "   请重输端口：" PORT
    PORT=${PORT:-$DEF_PORT}
done
if [ "$PORT" -lt 1024 ]; then
    say "   [!] ${PORT} 属于系统保留端口，若已被 ssh(22)/http(80) 等占用会启动失败，建议用 1024 以上"
fi
say "  端口号：$PORT"

DEF_PASS=${SSR_PASS:-${OLD_PASS:-$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)}}
if [ -n "${SSR_PASS:-}" ]; then
    PASS=$SSR_PASS
else
    ask_or_die "   请输入密码（回车 = ${DEF_PASS}，直接回车用随机值）：" PASS
    PASS=${PASS:-$DEF_PASS}
fi
say "  密码：$PASS"

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

########## 8. 防火墙 / SELinux ##########
step "8. 防火墙"
FW_DONE=""
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: *active'; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 && say "  ufw 已放行 ${PORT}/tcp"
    ufw allow "${PORT}/udp" >/dev/null 2>&1 && say "  ufw 已放行 ${PORT}/udp"
    FW_DONE=1
fi
if [ -z "$FW_DONE" ] && command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && say "  firewalld 已永久放行 ${PORT}/tcp+udp"
    say "  （老脚本会顺手 --add-service=http 把 80 也开了，这里不做）"
    FW_DONE=1
fi
if [ -z "$FW_DONE" ] && command -v iptables >/dev/null 2>&1 \
        && iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP'; then
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 \
        && say "  iptables 已插入 ${PORT}/tcp ACCEPT（重启后失效，需自行持久化）"
    iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1
    FW_DONE=1
fi
[ -n "$FW_DONE" ] || say "  未检测到启用中的 ufw / firewalld / iptables，跳过系统层放行"
say "  [!] 云服务器还要在控制台的安全组/防火墙里放行 ${PORT} 的 TCP 和 UDP，缺一不可"

if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    say "  SELinux = Enforcing。本脚本不修改它（老 CentOS 脚本会永久改成 permissive，不建议）"
    say "  若客户端连不上又查不出原因：ausearch -m avc -ts recent ；确认是被 SELinux 拦了再"
    say "      setsebool -P nis_enabled 1        # 允许服务做出站/DNS，比关 SELinux 精确得多"
fi

########## 9. BBR（可选加速） ##########
step "9. BBR"
if lsmod 2>/dev/null | grep -q '^tcp_bbr'; then
    say "  BBR 已启用"
else
    modprobe tcp_bbr >/dev/null 2>&1
    if lsmod 2>/dev/null | grep -q '^tcp_bbr'; then
        grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null || {
            printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
        }
        say "  BBR 已开启"
    else
        say "  内核没有 tcp_bbr（CentOS 7 自带的 3.10 内核需升到 4.9+ 才有）"
        say "  本脚本不会为此升级内核或卸载旧内核包 —— 老脚本那步 yum remove kernel-3.* 有把机器搞到起不来的风险"
        say "  不影响 SSR 正常使用，只是少了拥塞控制加速"
    fi
fi

########## 10. 实测验证 + 连接信息 ##########
step "10. 验证"
STATUS=$(systemctl is-active "$SVC" 2>/dev/null)
say "  systemctl is-active：$STATUS"
LISTEN=$(ss -lntp 2>/dev/null | grep ":$PORT " || netstat -lntp 2>/dev/null | grep ":$PORT ")
if [ -z "$LISTEN" ]; then
    say "  [!] 端口 $PORT 没有监听，最近日志："
    journalctl -u "$SVC" -n 25 --no-pager 2>/dev/null | sed 's/^/    /'
    if command -v ausearch >/dev/null 2>&1; then
        AVC=$(ausearch -m avc -ts recent 2>/dev/null | tail -n 5)
        if [ -n "$AVC" ]; then
            say "  上面没有明显报错的话，看这里 —— SELinux 最近的拒绝记录："
            printf '%s\n' "$AVC" | sed 's/^/    /'
        fi
    fi
    die "启动失败，把上面的日志贴出来"
fi
printf '%s\n' "$LISTEN" | sed 's/^/  /'

IP=$(curl -sL -m 12 -4 ip.sb 2>/dev/null | grep -E '^[0-9.]+$')
[ -z "$IP" ] && IP=$(curl -sL -m 12 ifconfig.me 2>/dev/null)
[ -z "$IP" ] && IP="你的服务器公网IP"
B64PASS=$(printf '%s' "$PASS" | base64 -w 0 | tr -d '=')
LINK=$(printf '%s' "$IP:$PORT:$PROTO:$METHOD:$OBFS:$B64PASS/?remarks=ssr&protoparam=&obfsparam=" | base64 -w 0 | tr -d '=')

say ""
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
