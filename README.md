# 小米 RC01 / BE10000 不降级获取 root、固化 SSH 与配置 WOL 实操记录

小米万兆路由器（RC01 / BE10000 / AX10000）在 **固件 1.1.56** 上，不降级、不丢 WiFi 7 / MLO 拿到 root，把 SSH 自启固化下来，再按需配好局域网唤醒（WOL）的完整过程。下面每条命令都在 1.1.56 release（`hackCheck=3`）实测过。

仓库来源：XMiR-Patcher 的 [issue #105](https://github.com/openwrt-xiaomi/xmir-patcher/issues/105)（2025-05 起有人报「be10000 rom1.1.56 cannot install exploit」，一直没人回），逃逸方案来自 [PR #168](https://github.com/openwrt-xiaomi/xmir-patcher/pull/168)（@h8suga）。

## 适用范围

- **适用**：RC01 / BE10000 / AX10000，固件 1.1.5x。这些版本 Web API 漏洞被 `hackCheck=3` 全封，XMiR 直接跑不通。
- **可参考**：BE7000（RC06）1.1.38，PR #168 作者的测试环境，结论一致。
- **别用**：1.0.53 及更早。那些版本 Web API 漏洞还在，直接用 XMiR-Patcher 一键解锁就行，没必要走这条绕路。
- 本仓库只放文档和通用脚本，**不含 exploit 代码**，实际逃逸要配合上面的 PR #168 实现使用。

## 操作顺序

整体链路：改 SimpleDocker 默认密码 → 容器内走 release_agent 逃逸拿临时 root → 跑 deploy.sh 固化 SSH 自启（按需解 OPA）→ 需要远程唤醒再配 WOL。

### 1. 拿临时 root：改默认密码 + release_agent 逃逸

1.1.56 上 XMiR 依赖的 Web API 漏洞全被 `hackCheck version = 3` 封掉：

```
WARN: Exploits "arn_switch/start_binding/set_mac_filter/datacenter7" not working!!!
WARN: Exploits "Smartcontroller" are not usable (hackCheck:3)
WARN: Exploit "get_icon" not working!!! (API not founded)
```

社区那套「装 nginx:alpine → bind mount 挂到 /real_root → chroot 改 dropbear」也走不通，OPA 在 Docker daemon 层就拒了，容器建不起来：

```
Error response from daemon: authorization denied by plugin opa-docker-authz:
request rejected by administrative policy
```

能走的是小米官方的 SimpleDocker 容器：它带完整 `CAP_SYS_ADMIN`（因为要管理 Docker），够触发 cgroup v1 的 `release_agent` 逃逸——某个 cgroup 的最后一个进程退出时，内核会在**宿主命名空间**以 **uid=0** 执行 `release_agent` 指向的程序，而容器可以自己挂一个 cgroup 层级并设置它。

具体做法：

- 先登录 SimpleDocker 面板（`http://<路由器IP>:9001`），出厂凭据是 `admin/admin`。**动手第一件事是改掉默认密码**，否则等于把逃逸入口敞着。
- 容器里挂独立 cgroup 层级 → `release_agent` 指向宿主可见的 payload → 建子 cgroup 并开 `notify_on_release` → 让子 shell 进去再退出，触发内核执行 payload。payload 要做四件事：`nvram set ssh_en=1`、去掉 dropbear 的 release 检查、生成 RSA host key、写 root 密码（`/etc/shadow` 是符号链接，必须写 `readlink -f` 的真实路径，否则重启就丢）。
- 两个静默失败的坑：overlay 的 upperdir 随机 ID 在容器重建后会变，`release_agent` 还指旧目录内核就找不到文件、日志一个报错都没有；exec 环境里 `$$` 可能指到容器常驻进程而不是当前 shell，得用 `sh -c` 包一层让它拿自己的 PID。
- 完整的命令链和 payload 见 [docs/01-no-downgrade-root.md](docs/01-no-downgrade-root.md)。

这一步拿到的 root 是临时的：`/etc` 是 ramfs，重启全清，必须接着做步骤 2 固化。

### 2. 固化 SSH 自启（按需解 OPA）

拿到临时 root 后跑 [scripts/deploy.sh](scripts/deploy.sh)，幂等、可重复执行。它做两件事，都能单独跑、单独撤销：

1. 把 SSH 启动脚本挂到 firewall include，开机自动生效。因为 `/etc` 是 ramfs，脚本落在 `/data` 加 `uci commit` 才持久。
2. 清空 `authorization_plugins`，解除 Docker 的 OPA 限制。后果是**任何容器都能拿到完整权限**，只跑可信镜像。

只想留 SSH 就别碰第 2 步；要装特权容器再解 OPA。OPA 到底放不放行哪些容器参数（bind mount / --privileged / --cap-add / docker.sock 逐项实测），见 [docs/02-opa-limits.md](docs/02-opa-limits.md)。

deploy.sh 会一并铺好 auto_ssh.sh（[scripts/auto_ssh.sh](scripts/auto_ssh.sh)），它额外负责开机把带序列号的挂载点 `/mnt/usb-xxxxxxxx` 软链成 `/mnt/usb`——小米的挂载点带盘序列号，换盘或重新格式化就变，所有硬编码路径全废，建软链后脚本只认 `/mnt/usb`。

### 3. 配 WOL 远程唤醒（可选）

需要远程唤醒局域网里的电脑时再做。小米路由器没有 `ether-wake`，`nc` 也是精简版（不支持 UDP），但自带 `lua` + `luasocket`。

- [scripts/wol.lua](scripts/wol.lua) 解析 MAC → 拼 102 字节魔术包（6 个 0xFF + MAC 重复 16 次）→ UDP 发出，默认广播 + 主机定向、端口 9 和 7、各 3 次共 12 包，绕开广播丢弃和链路丢包。
- [scripts/setup_wol.sh](scripts/setup_wol.sh) 用路由器自带 uhttpd（8088）+ CGI 做网页触发，改脚本里的 `PC_MAC` / `PC_IP` / `PC_NAME` 后整段贴到 root shell 跑。
- 目标机（Windows）要开 S5 魔包唤醒、关快速启动（`powercfg /h off`），关机后主板网口指示灯应仍亮。「关机后唤不醒」的判别法、定向 vs 广播的排除法见 [docs/03-wake-on-lan.md](docs/03-wake-on-lan.md)。

## 文件清单

| 文件 | 用途 |
|---|---|
| [docs/01-no-downgrade-root.md](docs/01-no-downgrade-root.md) | 完整攻击链、cgroup `release_agent` 原理、两个静默失败的坑 |
| [docs/02-opa-limits.md](docs/02-opa-limits.md) | OPA 逐项实测：哪些容器参数放行、哪些被拒，以及解除方法 |
| [docs/03-wake-on-lan.md](docs/03-wake-on-lan.md) | 用路由器 lua 发魔术包实现 WOL，含「关机后唤不醒」判别法 |
| [scripts/deploy.sh](scripts/deploy.sh) | 固化 SSH 自启 + 解除 OPA（幂等） |
| [scripts/auto_ssh.sh](scripts/auto_ssh.sh) | 开机自启脚本本体，含 `/mnt/usb` 软链重建 |
| [scripts/wol.lua](scripts/wol.lua) | 单文件 WOL 发包，任何带 luasocket 的 OpenWrt 通用 |
| [scripts/setup_wol.sh](scripts/setup_wol.sh) | WOL 的 uhttpd + CGI 网页部署 |

## 常见坑与风险

- **SimpleDocker 9001 打不开**：cgroup 操作会让容器异常退出。去后台「存储功能」重启 Docker，或重插存储即可。
- **改了配置重启就丢**：`/etc` 是 ramfs。用 `uci set` + `uci commit` 写进 `/data`（deploy.sh 已处理）。
- **SSH 连不上，报 no matching host key**：dropbear 只提供 ssh-rsa，新版 OpenSSH 默认禁用。连接时加 `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa`。
- **可能掉绑定 / 亮橙灯**：改 dropbear 初始化脚本、清 `opa-docker-authz`、`nvram set ssh_en=1` 都可能让设备在米家里掉绑定或亮橙灯。先备份 `/data`，确认能刷回固件再动手。
- **解除 OPA 之后没有授权层**：Docker 不再兜底，跑一个来路不明的镜像等于把整台路由器交出去。
- **不要把 22 端口映射到公网。**

## 参考

- [XMiR-Patcher issue #105](https://github.com/openwrt-xiaomi/xmir-patcher/issues/105) —— 同一个问题，1.1.56。
- [XMiR-Patcher PR #168](https://github.com/openwrt-xiaomi/xmir-patcher/pull/168) —— connect8 方案原始实现（@h8suga）。
- 本仓库只放文档与通用脚本，**不含** exploits 代码，请直接用上面 PR 的实现。

<details>
<summary>English TL;DR</summary>

Xiaomi RC01 (BE10000) firmware **1.1.56** blocks all XMiR-Patcher web-API exploits (`hackCheck=3`), and the classic `bind-mount + chroot` recipe fails because `opa-docker-authz` rejects bind mounts. This repo documents a working path: the official **SimpleDocker** container carries full `CAP_SYS_ADMIN`, which is enough for a **cgroup v1 `release_agent` escape** to host root. Verified on RC01 / 1.1.56. Credit: [PR #168](https://github.com/openwrt-xiaomi/xmir-patcher/pull/168) by [@h8suga](https://github.com/h8suga). This repo ships docs and generic scripts only — no exploit code; use the PR implementation for the actual escape.

</details>