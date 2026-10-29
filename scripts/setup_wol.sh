#!/bin/sh
# WOL Web UI 部署（uhttpd + CGI）
# 依赖：scripts/wol.lua 已放到 /data/wol.lua
#
# 用法：改下面的 PC_MAC 和 PC_IP，然后整段贴到路由器 root shell 执行

PC_MAC="AA:BB:CC:DD:EE:FF"     # ← 改成目标机 MAC
PC_IP="192.168.31.100"         # ← 改成目标机固定 IP
PC_NAME="MY-PC"                # ← 页面上显示的名字
WEB_PORT=8088

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

echo "=== 1. web dir ==="
mkdir -p /data/www/cgi-bin

echo "=== 2. CGI ==="
cat > /data/www/cgi-bin/wol << CGIEOF
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo ""
echo "Sending magic packet to ${PC_MAC} ..."
/usr/bin/lua /data/wol.lua ${PC_MAC} 192.168.31.255 ${PC_IP}
echo ""
echo "OK. 如果目标机是关机状态（S5），10-20 秒内应该开始启动。"
CGIEOF
chmod +x /data/www/cgi-bin/wol

echo "=== 3. page ==="
cat > /data/www/index.html << HTMLEOF
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wake ${PC_NAME}</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;background:#111;color:#eee;display:flex;
align-items:center;justify-content:center;height:100vh;margin:0}
.box{text-align:center;padding:40px 30px;background:#1c1c1e;border-radius:16px;box-shadow:0 8px 30px #0008}
h1{font-size:20px;margin:0 0 8px;font-weight:600}
p{color:#888;font-size:13px;margin:0 0 24px}
a{display:inline-block;padding:16px 48px;background:#0a84ff;color:#fff;text-decoration:none;
border-radius:12px;font-size:17px;font-weight:600}
a:active{background:#0060df}
</style></head>
<body><div class="box"><h1>${PC_NAME}</h1><p>${PC_MAC}</p>
<a href="/cgi-bin/wol">唤醒</a></div></body></html>
HTMLEOF

echo "=== 4. restart uhttpd ==="
for pid in $(ps w | grep "uhttpd -p ${WEB_PORT}" | grep -v grep | awk '{print $1}'); do
  kill "$pid" 2>/dev/null
done
sleep 1
/usr/sbin/uhttpd -p ${WEB_PORT} -h /data/www -x /cgi-bin
sleep 2

echo "=== 5. self test ==="
curl -s -m 5 "http://127.0.0.1:${WEB_PORT}/cgi-bin/wol"
echo "---"
netstat -tlnp 2>/dev/null | grep ${WEB_PORT} || echo "PORT_NOT_LISTENING"

echo ""
echo "完成。访问 http://192.168.31.1:${WEB_PORT}/"
echo "开机自启：把 uhttpd 那行加进 /data/auto_ssh/auto_ssh.sh"
