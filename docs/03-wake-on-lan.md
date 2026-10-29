# 用路由器唤醒局域网内的电脑（WOL）

小米路由器没有 `ether-wake`，`nc` 也是精简版（不支持 UDP）。
但它自带 `lua` + `luasocket`，可以自己发包 —— 50 行脚本，不装任何东西。

## 效果

手机或任何能打开网页的设备，点一下按钮，关机的台式机自动开机。

```
浏览器 → 路由器 uhttpd:8088 → CGI → wol.lua → UDP 魔术包 → 目标机网卡
```

## 原理

WOL（Wake-on-LAN）是**二层广播**，魔术包内容是 `6 个 0xFF` + `目标 MAC 重复 16 次`，
共 102 字节，以 UDP 发到局域网广播地址的 7 或 9 端口。

因为不能跨网段，必须由**路由器**代为发送 —— 客户端只要能让路由器执行「发包」这个动作就行。

## 路由器侧

`scripts/wol.lua` 做三件事：解析 MAC → 拼 102 字节包 → UDP 发送。

```sh
lua wol.lua AA:BB:CC:DD:EE:FF 192.168.31.255 9
# WOL_SENT len=102 -> 192.168.31.255:9 #1
# TOTAL_OK=12 mac=AA:BB:CC:DD:EE:FF
```

默认行为（不传目标时）：广播 + 主机定向、端口 9 和 7、每个组合发 3 次，共 12 包。
多发几包是为了绕过广播被丢弃和链路降速丢包。

Web 触发用路由器自带的 `uhttpd`（8080 常被 nginx 占用，用 8088）：

```sh
/usr/sbin/uhttpd -p 8088 -h /data/www -x /cgi-bin
```

- 页面：`/data/www/index.html`
- CGI：`/data/www/cgi-bin/wol`（调 wol.lua）
- 开机自启：写进 firewall include 脚本（见 `scripts/auto_ssh.sh`）

部署脚本：`scripts/setup_wol.sh`（改里面的 MAC 为目标机 MAC）。

## 目标机侧要求

Windows 侧（管理 PowerShell 里跑）：

```powershell
# 查看网卡唤醒能力
Get-NetAdapterAdvancedProperty -Name "*" |
  Where-Object DisplayName -match "Wake|唤醒" |
  Select-Object Name, DisplayName, DisplayValue
```

四项都要开：

```
唤醒魔包（Wake on Magic Packet）      启用
唤醒模式匹配（Wake on Pattern）       启用
S5 魔包唤醒（*FromS5）                启用    ← 关机状态也能唤醒
快速启动 HiberbootEnabled             0       ← powercfg /h off
```

再检查：

1. **BIOS**：`Wake on LAN` / `Power On By PCI-E` / `ErP` 关闭
2. 网卡属性「电源管理」：允许此设备唤醒计算机、只允许幻数据包唤醒
3. **关机后主板网口指示灯应仍然亮着**。灯灭 = 网卡断电，WOL 一定失败

## 关机后唤不醒的判别法

不用猜，一次定位。关机后从路由器执行：

```sh
ping -c 2 <目标IP>
ip neigh | grep <目标IP>
```

| 关机后 ping | 含义 | 处理 |
|---|---|---|
| 通 / ARP 有记录 | 网卡待机供电 + 链路都在，只是不认魔术包 | 查 BIOS 的 `Resume By PCI-E Device` |
| 不通 / ARP 无记录 | 网卡完全断电 | 查 BIOS 的 `ErP Ready` |

有电却唤不醒，只剩两种可能：BIOS 没开 PCIe 唤醒，或包根本没到网卡。

**定向 vs 广播的排除法**：如果网卡开了 ARP Offload（S5 会代答 ARP），
主机定向包可以到达。先只发定向，能唤醒说明广播被丢；只发广播能唤醒说明定向的 ARP 没解析出来。

```sh
lua wol.lua AA:BB:CC:DD:EE:FF 192.168.31.100    # 只发定向
```

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| 点了没反应 | 网口灯关机后熄灭 | BIOS 关 ErP / 开 PCI-E 唤醒 |
| 点了没反应 | 快速启动没关 | `powercfg /h off` |
| 睡眠能唤醒、关机不能 | 缺 S5 唤醒 | 网卡属性开「S5 魔包唤醒」 |
| 页面打不开 | uhttpd 没起来 | `ps \| grep uhttpd`，看自启脚本有没有执行 |
| 只能内网访问 | 没做内网穿透 | 自己解决，**不要把 8088 直接映射到公网** |
