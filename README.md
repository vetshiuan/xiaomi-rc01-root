# Xiaomi RC01 / BE10000 — root on firmware 1.1.56 without downgrading

小米万兆路由器（RC01 / BE10000 / AX10000）在 **1.1.56 稳定版**上获取 root 的实测记录。
不降级、不丢 WiFi 7 / MLO。

> **为什么有这个仓库**
> XMiR-Patcher 的 issue [#105](https://github.com/openwrt-xiaomi/xmir-patcher/issues/105)
> 从 2025-05 起就有人报「be10000 rom1.1.56 cannot install exploit」，至今无人回复。
> 社区给出的答案只有「降级到 1.0.5x」。这个仓库补上另一条路。

## English summary

Xiaomi RC01 (BE10000) firmware **1.1.56** blocks all XMiR-Patcher web-API exploits
(`hackCheck=3`), and the classic `bind-mount + chroot` recipe fails because
`opa-docker-authz` rejects bind mounts. This repo documents a working path:
the official **SimpleDocker** container carries full `CAP_SYS_ADMIN`, which is
enough for a **cgroup v1 `release_agent` escape** to host root.
Verified on RC01 / 1.1.56. Credit: [PR #168](https://github.com/openwrt-xiaomi/xmir-patcher/pull/168) by [@h8suga](https://github.com/h8suga).

## 适用与不适用

| | 说明 |
|---|---|
| ✅ 适用 | RC01 / BE10000 / AX10000，固件 1.1.5x（`hackCheck=3`，Web API 全部被封） |
| ⚠️ 参考 | BE7000 (RC06) 1.1.38 —— PR #168 原作者的测试环境，结论一致 |
| ❌ 别用 | 1.0.53 及更早。这些版本 Web API 漏洞还在，XMiR 一键就开，用本文是绕远路 |

## 为什么老方法在这台机器上失效

两条独立的路都被堵了：

**路 1：XMiR 的 Web API 漏洞** —— `hackCheck version = 3`，入口全封：

```
WARN: Exploits "arn_switch/start_binding/set_mac_filter/datacenter7" not working!!!
WARN: Exploits "Smartcontroller" are not usable (hackCheck:3)
WARN: Exploit "get_icon" not working!!! (API not founded)
```

**路 2：社区教程的 `bind mount + chroot`** —— 2023 年那批万兆路由器教程走的是
「装 nginx:alpine → 挂 `mi_docker/../../..` 到 `/real_root` → chroot 改 dropbear」。
这条路在 1.1.56 上直接被 OPA 拒掉，容器根本建不起来：

```
Error response from daemon: authorization denied by plugin opa-docker-authz:
request rejected by administrative policy
```

## 现在这条路

```
SimpleDocker (9001, admin/admin —— 出厂默认凭据，动手前先改掉)
  └─ 容器带完整 CAP_SYS_ADMIN（因为它要管理 Docker）
       └─ cgroup v1 release_agent 逃逸
            └─ 内核在宿主命名空间以 uid=0 执行 payload
                 └─ 改 dropbear 初始化脚本 + 设 root 密码 + 启动 SSH
```

`release_agent` 的原理：某个 cgroup 的**最后一个进程退出**时，内核会在
**宿主命名空间**执行 `release_agent` 指向的程序，**以 uid=0 运行**。
容器有 `CAP_SYS_ADMIN` 就能自己挂一个 cgroup 层级并设置它。

完整命令链、以及两个必须避开的坑，见 **[docs/01-no-downgrade-root.md](docs/01-no-downgrade-root.md)**。

## 文档与脚本

| 文件 | 内容 |
|---|---|
| [docs/01-no-downgrade-root.md](docs/01-no-downgrade-root.md) | 完整攻击链、cgroup `release_agent` 原理、两个静默失败的坑 |
| [docs/02-opa-limits.md](docs/02-opa-limits.md) | OPA 逐项实测表：哪些容器参数放行、哪些被拒；解除方法 |
| [docs/03-wake-on-lan.md](docs/03-wake-on-lan.md) | 用路由器 lua 发魔术包实现 WOL，含「关机后唤不醒」判别法 |
| [scripts/deploy.sh](scripts/deploy.sh) | 固化 SSH 自启 + 解除 OPA（幂等） |
| [scripts/auto_ssh.sh](scripts/auto_ssh.sh) | 开机自启脚本本体，含 `/mnt/usb` 软链重建 |
| [scripts/wol.lua](scripts/wol.lua) | 50 行 WOL 发包，任何带 luasocket 的 OpenWrt 通用 |
| [scripts/setup_wol.sh](scripts/setup_wol.sh) | WOL 的 uhttpd + CGI 网页部署 |

## 拿到 root 之后

`scripts/deploy.sh` 做两件事，都可以单独跑、单独撤销：

1. 把 SSH 启动脚本挂到 firewall include，开机自动生效
   （`/etc` 是 ramfs，重启清空，必须走 `/data` + uci commit）
2. 清空 `authorization_plugins`，解除 Docker 的 OPA 限制
   —— 后果是**任何容器都能拿到完整权限**，只跑可信镜像

`scripts/auto_ssh.sh` 是第 1 步落盘后的实际脚本，另外附带一个实用功能：
每次开机重建 `/mnt/usb` 软链。小米的挂载点带盘序列号（`/mnt/usb-xxxxxxxx`），
换盘或重新格式化就会变，所有硬编码路径全废；建软链后脚本只认 `/mnt/usb`。

## 副作用

| 现象 | 原因 | 处理 |
|---|---|---|
| SimpleDocker 9001 打不开 | cgroup 操作会让容器异常退出 | 后台「存储功能」重启 Docker，或重插存储 |
| 改了配置重启就丢 | `/etc` 是 ramfs | 用 `uci set` + `uci commit` 写进 `/data` |
| SSH 连不上，报 no matching host key | dropbear 只提供 ssh-rsa，新版 OpenSSH 默认禁用 | 加 `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa` |

## 风险

- 改 `dropbear` 初始化脚本、清 `opa-docker-authz`、`nvram set ssh_en=1`
  都可能让设备在米家里掉绑定或亮橙灯。**先备份 `/data`，能刷回固件再动手。**
- 解除 OPA 之后 Docker 没有授权层了，跑未知镜像等于把宿主交出去。
- **不要把 22 端口映射到公网。**

## 参考

- [XMiR-Patcher issue #105](https://github.com/openwrt-xiaomi/xmir-patcher/issues/105) — 同一个问题，1.1.56
- [XMiR-Patcher PR #168](https://github.com/openwrt-xiaomi/xmir-patcher/pull/168) — connect8 方案原始实现（@h8suga）
- 本仓库只放文档与通用脚本，**不含** exploits 代码，请直接用上面 PR 的实现
