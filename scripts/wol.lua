#!/usr/bin/lua
-- Wake-on-LAN sender for OpenWrt routers that ship lua + luasocket
-- (Xiaomi routers have no ether-wake and their nc is built without UDP support)
--
-- 用法:
--   lua wol.lua <MAC> [目标1] [目标2] ...
--
--   MAC      目标网卡 MAC，格式 AA:BB:CC:DD:EE:FF
--   目标...  可选。留空 = 默认发「广播 192.168.31.255 + 主机定向 192.168.31.100」
--            端口 9 和 7、每个组合 3 次，共 12 包 —— 容错，绕开广播丢弃和丢包
--
-- 例:
--   lua wol.lua AA:BB:CC:DD:EE:FF
--   lua wol.lua AA:BB:CC:DD:EE:FF 192.168.31.255 192.168.31.100

local socket = require("socket")

local mac = arg[1]
if not mac then
  print("usage: wol.lua <MAC> [target] [target2] ...")
  print("       wol.lua AA:BB:CC:DD:EE:FF")
  os.exit(1)
end

-- 默认目标：广播 + 主机定向（ArpOffload 开启时，网卡在 S5 会代答 ARP，定向包可达）
local DEFAULT_TARGETS = { "192.168.31.255", "192.168.31.100" }

local targets = {}
for i = 2, #arg do
  targets[#targets + 1] = arg[i]
end
if #targets == 0 then
  targets = DEFAULT_TARGETS
end

-- MAC -> 6 字节二进制
local parts = {}
for h in mac:gmatch("%x%x") do
  parts[#parts + 1] = string.char(tonumber(h, 16))
end
if #parts ~= 6 then
  print("BAD_MAC " .. mac)
  os.exit(1)
end

-- 魔术包 = 6 个 0xFF + MAC 重复 16 次 = 102 字节
local macbin = table.concat(parts)
local pkt = string.rep("\255", 6) .. string.rep(macbin, 16)

local udp = socket.udp()
udp:setoption("broadcast", true)
udp:setsockname("0.0.0.0", 0)

local okcount = 0
for _, host in ipairs(targets) do
  for _, port in ipairs({ 9, 7 }) do
    for n = 1, 3 do
      udp:setpeername(host, port)
      local ok, err = udp:send(pkt)
      if ok then
        okcount = okcount + 1
        print("WOL_SENT len=" .. #pkt .. " -> " .. host .. ":" .. port .. " #" .. n)
      else
        print("WOL_FAIL " .. host .. ":" .. port .. " " .. tostring(err))
      end
      socket.sleep(0.05)
    end
  end
end
udp:close()

print("TOTAL_OK=" .. okcount .. " mac=" .. mac)
