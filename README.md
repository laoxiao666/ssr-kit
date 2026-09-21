# SSR 一键安装 / 修复脚本（Ubuntu 20.04 / 22.04 / 24.04）

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

## 为什么不用网上流传的 hijk 一键脚本

它们装的是 `shadowsocksr` 3.2.2 的 Python 版，在 **Ubuntu 22.04 及以后必然启动失败**，而报错信息是误导的（"ssr启动失败，请检查端口是否被占用"）。原因有两处：

1. `shadowsocks/lru_cache.py:44` 写的是 `class LRUCache(collections.MutableMapping)`。
   `collections.MutableMapping` 在 **Python 3.10 中已被删除**（Ubuntu 20.04 是 3.8 所以能跑；22.04 是 3.10、24.04 是 3.12）。import 阶段就抛
   `AttributeError: module 'collections' has no attribute 'MutableMapping'`，进程根本没起来，所以端口自然没人监听。
2. `preinstall()` 里 `apt install` 带了 `libsodium18`。新系统只有 `libsodium23`，而 apt 只要有一个包名找不到就**整条事务全部不装**，于是 `net-tools` 也没了；脚本偏偏用 `netstat -nltp | grep 端口` 判断成功与否——`netstat` 不存在时，**即使 SSR 正常运行也会报"启动失败"**。

本脚本的做法：逐个安装依赖并自动探测 libsodium 的真实包名 → 装完 SSR 后自动打 `collections.abc` 兼容补丁 → 把 systemd 单元从 `Type=forking` + `-d start` 改为前台 `Type=simple`（报错进 journal，不再被吞）→ 启动后实测端口监听才报成功。

## 已验证 / 未验证

在 Python 3.12.10 + OpenSSL 3.0.16 环境下：

- 复现了未打补丁时的 `AttributeError: module 'collections' has no attribute 'MutableMapping'`；打补丁后 `import shadowsocks.server` 通过。
- `aes-128/192/256-cfb|ctr|cfb8`、`camellia-128/192/256-cfb` 全部可初始化；`rc4-md5` 在 OpenSSL 3.0 下失败（别选）；`chacha20-ietf` 需要 libsodium。
- 服务端以 `protocol=auth_chain_a` + `obfs=tls1.2_ticket_auth` 实际启动并监听，能接受 TCP 连接，且对乱码请求正确报 `unsupported addrtype`。

未在真实 Ubuntu 上跑过 `systemd` / `apt` / `ufw` 部分（本机是 Windows）。脚本第 0/1/5/10 步会在你服务器上打印实测结果。

## 装完之后

```bash
systemctl status shadowsocksR     # 状态
journalctl -u shadowsocksR -f     # 实时日志
/etc/shadowsocksR.json            # 配置；改完 systemctl restart shadowsocksR
```

客户端里填**你 SSH 用的那个公网 IP** + 脚本打印的端口/密码/加密/协议/混淆，或直接扫脚本输出的二维码。

**端口要在两处放行**：`ufw`（脚本自动处理）+ 云厂商控制台的安全组，TCP 和 UDP 都要，漏 UDP 的典型症状是"能连上但打不开网页"。

仓库是 public 的：脚本里不含任何 IP 或密码，参数全部运行时输入、只写到服务器的 `/etc/shadowsocksR.json`。
