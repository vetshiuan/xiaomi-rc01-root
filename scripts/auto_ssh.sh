#!/bin/sh
# 开机自启脚本 —— 放到 /data/auto_ssh/auto_ssh.sh
# 由 firewall include 拉起（deploy.sh 会注册）
#
# 做三件事：
#   1. 重新打开 SSH（/etc 是 ramfs，每次开机都是原版 dropbear 脚本）
#   2. 把 /mnt/usb-<序列号> 软链成 /mnt/usb，之后所有脚本不用管挂载点变化
#   3. 拉起 WOL 的 uhttpd

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# --- 1. SSH 自启 ---
sed -i 's/channel=.*/channel="debug"/g' /etc/init.d/dropbear
sed -i 's/ -o "$channel" = "release"//g' /etc/init.d/dropbear
[ -f /etc/dropbear/dropbear_rsa_host_key ] || \
  /usr/bin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null
/etc/init.d/dropbear restart

# --- 2. USB 统一入口软链 ---
# 挂载点带盘序列号（/mnt/usb-xxxxxxxx），换盘或重新格式化就会变。
# 每次开机重新指向，之后所有脚本只认 /mnt/usb。
i=0
U=""
while [ $i -lt 15 ]; do
  U=$(mount | grep -o '/mnt/usb-[A-Za-z0-9]*' | head -1)
  [ -n "$U" ] && break
  i=$((i+1))
  sleep 1
done

if [ -n "$U" ]; then
  ln -sfn "$U" /mnt/usb
  mkdir -p /tmp/bin /tmp/docker/cli-plugins
  ln -sf "$U/mi_docker/docker-binaries/docker" /tmp/bin/docker
  # compose 是 CLI 插件；/ 是只读 squashfs，插件目录只能放 /tmp
  ln -sf "$U/tools/cli-plugins/docker-compose" /tmp/docker/cli-plugins/docker-compose
  echo "$(date '+%F %T') usb=$U" >> /data/auto_ssh/usb.log
else
  echo "$(date '+%F %T') usb NOT MOUNTED" >> /data/auto_ssh/usb.log
fi

# --- 3. WOL Web UI ---
sleep 3
pgrep -f "uhttpd -p 8088" >/dev/null 2>&1 || \
  /usr/sbin/uhttpd -p 8088 -h /data/www -x /cgi-bin >/dev/null 2>&1
