#!/bin/sh
# 拿到 root 之后跑这个：固化 SSH + 解除 Docker OPA 限制
#
# 用法（把整个文件贴到 root shell，或 base64 传过去）：
#   base64 -w0 scripts/deploy.sh | ssh root@192.168.31.1 'base64 -d | sh'
#
# 幂等，可以重复执行。

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

echo "=== 0. 检查空间 ==="
# /data 是 ubifs，空间很小（实测可能只剩 1MB 以内）。
# 空间不足时 uci commit 会静默失败，改了等于没改。
df -h /data
AVAIL=$(df -k /data | awk 'NR==2 {print $4}')
echo "available_kb=$AVAIL"
[ "$AVAIL" -lt 1024 ] && echo "WARNING: /data 剩余不足 1MB，先清理再继续" && exit 1

echo "=== 1. 固化 SSH 自启 ==="
# 注意：这段和 scripts/auto_ssh.sh 内容一致，改一个要改两个
mkdir -p /data/auto_ssh
cat > /data/auto_ssh/auto_ssh.sh << 'AUTOSSH_EOF'
#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

sed -i 's/channel=.*/channel="debug"/g' /etc/init.d/dropbear
sed -i 's/ -o "$channel" = "release"//g' /etc/init.d/dropbear
[ -f /etc/dropbear/dropbear_rsa_host_key ] || \
  /usr/bin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null
/etc/init.d/dropbear restart

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
  ln -sf "$U/tools/cli-plugins/docker-compose" /tmp/docker/cli-plugins/docker-compose
  echo "$(date '+%F %T') usb=$U" >> /data/auto_ssh/usb.log
else
  echo "$(date '+%F %T') usb NOT MOUNTED" >> /data/auto_ssh/usb.log
fi

sleep 3
pgrep -f "uhttpd -p 8088" >/dev/null 2>&1 || \
  /usr/sbin/uhttpd -p 8088 -h /data/www -x /cgi-bin >/dev/null 2>&1
AUTOSSH_EOF
chmod +x /data/auto_ssh/auto_ssh.sh

uci set firewall.auto_ssh=include
uci set firewall.auto_ssh.type='script'
uci set firewall.auto_ssh.path='/data/auto_ssh/auto_ssh.sh'
uci set firewall.auto_ssh.enabled='1'
uci commit firewall
echo "auto_ssh installed"

echo "=== 2. nvram ==="
# 只开 SSH。telnet_en / uart_en 也会被常规脚本一起打开，
# 但那是在扩大攻击面，用不到就别开。
nvram set ssh_en=1
nvram commit
echo "ssh_en=$(nvram get ssh_en)"

echo "=== 3. 解除 OPA ==="
cp /etc/config/mi_docker /data/mi_docker.bak
sed -i "s/authorization_plugins .*/authorization_plugins ''/g" /etc/config/mi_docker
# /etc 是 ramfs，不 commit 重启就还原
uci commit mi_docker
echo "backup: /data/mi_docker.bak"

echo "=== 4. 验证 ==="
echo "--- 落盘检查（这个才是重启后生效的）---"
grep -n "authorization_plugins" /data/etc/config/mi_docker
echo "--- fw include ---"
uci get firewall.auto_ssh.enabled
echo "--- auto_ssh.sh ---"
ls -l /data/auto_ssh/auto_ssh.sh
echo "=== DONE ==="
echo ""
echo "接下来重启 Docker 让 OPA 生效（不用重启路由器）："
echo "  /etc/init.d/mi_docker restart"
echo "验证："
echo "  \$(mount | grep -o '/mnt/usb-[^ ]*' | head -1)/mi_docker/docker-binaries/docker \\"
echo "    run --rm --privileged --network host nginx:alpine-slim echo OPA_REMOVED"
