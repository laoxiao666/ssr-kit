# SSR 一键安装 / 修复脚本（Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux）

当前版本 **1.1.0**（脚本最后会打印，用来确认你跑的是哪一版）。

在服务器上执行（**注意是 `bash <(...)`，不是 `curl | bash`**，否则会打乱交互输入）：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/laoxiao666/ssr-kit/main/ssr-install.sh)
```

改过脚本后 raw 链接有约 5 分钟缓存，加个参数破缓存：`...ssr-install.sh?v=2`。

### raw 拉不下来时（`Connection reset`）

`raw.githubusercontent.com` 会被间歇性重置，而 `github.com` / `codeload.github.com` 通常仍可达。任选一条：

```bash
# 1) 用 git clone（最稳，走 github.com）
git clone --depth 1 https://github.com/laoxiao666/ssr-kit && bash ssr-kit/ssr-install.sh

# 2) 走 GitHub API 取内容（raw 的等价替代，不依赖第三方）
curl -sL https://api.github.com/repos/laoxiao666/ssr-kit/contents/ssr-install.sh \
  | python3 -c "import json,base64,sys;sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)['content']).decode('utf-8').encode('utf-8'))" \
  > /root/ssr-install.sh && bash /root/ssr-install.sh

# 3) jsDelivr CDN（国内可达性好；但把第三方放进了信任链，且 @main 有缓存，重要变更前请核对内容）
bash <(curl -Ls https://cdn.jsdelivr.net/gh/laoxiao666/ssr-kit@main/ssr-install.sh)
```

非交互执行（批量装机）：

```bash
SSR_PORT=38880 SSR_PASS=xxxx SSR_METHOD=aes-256-cfb SSR_PROTOCOL=auth_chain_a SSR_OBFS=tls1.2_ticket_auth \
  bash <(curl -Ls https://raw.githubusercontent.com/laoxiao666/ssr-kit/main/ssr-install.sh)
```

脚本是幂等的：重复执行会跳过下载、把现有配置的端口/密码/加密方式作为默认值，等同于"修复 + 改配置"。

## 端口和密码是自定义的

第 2 步会依次问你：端口、密码、加密方式、协议、混淆。**直接回车**表示接受括号里的默认值——第一次装时默认值是随机生成的（会打印出来），修老机器时默认值就是你**现有的配置**。想改就输入新值，改完重启即可：

```bash
# 交互式改端口/密码：重跑脚本，在提示处输入新值
bash <(curl -Ls https://raw.githubusercontent.com/laoxiao666/ssr-kit/main/ssr-install.sh)

# 或者非交互指定
SSR_PORT=40080 SSR_PASS='你的密码' bash <(curl -Ls https://raw.githubusercontent.com/laoxiao666/ssr-kit/main/ssr-install.sh)
```

端口允许 1-65535（低于 1024 会提示可能与 ssh/http 冲突）；密码可以带空格和符号（配置用 `json.dump` 写入，特殊字符不会被拼坏）。

## CentOS / RHEL 系列的差异

同一份脚本按发行版分支（`apt` / `dnf` / `yum` 自动判别），和 Ubuntu 的不同之处：

- **EPEL**：EL 上的 `libsodium`、`qrencode`、以及 CentOS 7 的 `python3` 都在 EPEL 里，脚本会先装 `epel-release`；装不上就直接导入官方 rpm（`https://dl.fedoraproject.org/pub/epel/epel-release-latest-$MAJOR.noarch.rpm`，URL 已实测可达）。EPEL 失败不影响 `aes-*` 方案，只是没有 chacha20。
- **firewalld**：在用 `firewall-cmd --permanent --add-port=端口/tcp|udp` + `--reload`。老 CentOS 脚本还会顺手 `--add-service=http` 把 80 一起开，这里**不做**。firewalld 没运行才退回 `iptables`（并提示重启后失效）。
- **SELinux：脚本不改它。** 老 CentOS 脚本会把 `enforcing` 永久 sed 成 `permissive` 并 `setenforce 0`，等于关掉整机的强制访问控制。这里只在检测到 Enforcing 时打印排查命令，并且启动失败时自动 dump 最近的 AVC 拒绝记录给你看：
  ```bash
  ausearch -m avc -ts recent          # 有记录说明确实被 SELinux 拦了
  setsebool -P nis_enabled 1           # 精确放行服务出站，比关 SELinux 好
  ```
- **BBR：只 `modprobe tcp_bbr` + 写 sysctl，绝不动内核。** 老 CentOS 脚本为了 BBR 会装 elrepo 新内核并 `yum remove kernel-3.*`——这类操作有把机器搞到无法启动的真实风险，所以 CentOS 7 的 3.10 内核会直接提示"没有 BBR"，SSR 照常可用。
- **CentOS 7 / 8 已 EOL**，官方 mirrorlist 已下线，装包会失败。换到 vault 归档源（URL 已实测可达）：
  ```bash
  sed -i -e 's|^mirrorlist=|#mirrorlist=|g' \
         -e 's|^#baseurl=http://mirror.centos.org/centos/$releasever|baseurl=https://vault.centos.org/7.9.2009|g' \
         /etc/yum.repos.d/CentOS-Base.repo
  yum clean all && yum makecache
  ```
  Rocky / AlmaLinux 8/9 不需要这一步。

## 为什么不用网上流传的 hijk 一键脚本

它们装的是 `shadowsocksr` 3.2.2 的 Python 版，在 **Ubuntu 22.04 及以后必然启动失败**，而报错信息是误导的（"ssr启动失败，请检查端口是否被占用"）。原因有两处：

1. `shadowsocks/lru_cache.py:44` 写的是 `class LRUCache(collections.MutableMapping)`。
   `collections.MutableMapping` 在 **Python 3.10 中已被删除**（Ubuntu 20.04 是 3.8 所以能跑；22.04 是 3.10、24.04 是 3.12）。import 阶段就抛
   `AttributeError: module 'collections' has no attribute 'MutableMapping'`，进程根本没起来，所以端口自然没人监听。
2. `preinstall()` 里 `apt install` 带了 `libsodium18`。新系统只有 `libsodium23`，而 apt 只要有一个包名找不到就**整条事务全部不装**，于是 `net-tools` 也没了；脚本偏偏用 `netstat -nltp | grep 端口` 判断成功与否——`netstat` 不存在时，**即使 SSR 正常运行也会报"启动失败"**。

本脚本的做法：逐个安装依赖并自动探测 libsodium 的真实包名 → 装完 SSR 后自动打 `collections.abc` 兼容补丁 → 把 systemd 单元从 `Type=forking` + `-d start` 改为前台 `Type=simple`（报错进 journal，不再被吞）→ 启动后实测端口监听才报成功。

补一句发行版差异：`collections.MutableMapping` 是 **Python 3.10 才删除**的。所以老 CentOS 脚本在它那个年代是能用的——CentOS 7/8 的 python3 是 3.6，EL9 是 3.9（只告警）；而 Ubuntu 22.04 是 3.10、24.04 是 3.12，直接崩。换句话说 CentOS 那边迟早也会在同一行上翻车（EL10 / Python 3.12），本脚本的补丁对两边都无害。

## 已验证 / 未验证（请勿把"支持"当成"已测"）

**已实测**（Python 3.12.10 + OpenSSL 3.0.16，以及 bash 交互测试）：

- 复现了未打补丁时的 `AttributeError: module 'collections' has no attribute 'MutableMapping'`；打补丁后 `import shadowsocks.server` 通过。
- `aes-128/192/256-cfb|ctr|cfb8`、`camellia-128/192/256-cfb` 全部可初始化；`rc4-md5` 在 OpenSSL 3.0 下失败（别选）；`chacha20-ietf` 需要 libsodium。
- 服务端以 `protocol=auth_chain_a` + `obfs=tls1.2_ticket_auth` 实际启动并监听，能接受 TCP 连接，且对乱码请求正确报 `unsupported addrtype`。
- 端口/密码输入的四种组合（非法值重问、回车取默认、自定义、环境变量覆盖、stdin 非终端时明确报错不卡死）。
- libsodium 包名探测管道、`/etc/os-release` 解析（含文件缺失和 Debian 的降级路径）在 `set -u` 下无未定义变量。
- Ubuntu 22.04 真机首跑暴露的 `PRETTY_NAME: unbound variable` 已在 1.0.1 修掉。

**未实测**：

- `apt` / `dnf` / `yum` 装包、`systemd` 单元生效、`ufw` / `firewalld` 放行、`ss` 验证——脚本运行环境是 Linux，开发机是 Windows，无法本地验证。第 0/1/5/10 步会在你服务器上打印实测结果。
- **CentOS / RHEL / Rocky / Alma 分支尤其如此**：EL 的差异（EPEL、包名 `iproute`、firewalld、SELinux）是按官方文档和老脚本的行为对齐写的，目前没有 CentOS 真机跑过。你在 CentOS 上第一次执行时，请把输出留档，有问题我就改。

## 装完之后

```bash
systemctl status shadowsocksR     # 状态
journalctl -u shadowsocksR -f     # 实时日志
/etc/shadowsocksR.json            # 配置；改完 systemctl restart shadowsocksR
```

客户端里填**你 SSH 用的那个公网 IP** + 脚本打印的端口/密码/加密/协议/混淆，或直接扫脚本输出的二维码。

**端口要在两处放行**：`ufw`（脚本自动处理）+ 云厂商控制台的安全组，TCP 和 UDP 都要，漏 UDP 的典型症状是"能连上但打不开网页"。

仓库是 public 的：脚本里不含任何 IP 或密码，参数全部运行时输入、只写到服务器的 `/etc/shadowsocksR.json`。
