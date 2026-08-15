local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local m, s, o
local online_devices


local function normalize_mac(mac)
	if not mac then return "" end
	return tostring(mac):upper()
end

local function parse_rate_value(val)
	if not val or val == "" then return nil end
	val = tostring(val):lower():gsub("%s+", "")
	local num, unit = val:match("^([%d%.]+)%s*([a-z]*)$")
	if not num then return nil end
	num = tonumber(num)
	if not num or num <= 0 then return nil end

	if unit == "m" or unit == "mbit" or unit == "mb" or unit == "mbps" then
		return math.floor(num * 1024)
	elseif unit == "k" or unit == "kbit" or unit == "kb" or unit == "kbps" or unit == "" then
		return math.floor(num)
	end
	return math.floor(num)
end

local function add_device(devices, seen, mac, ip, name)
	mac = normalize_mac(mac)
	if mac == "" then return end

	local item = seen[mac]
	if item then
		if item.ip == "" and ip ~= "" then item.ip = ip end
		if item.name == "" and name and name ~= "*" and name ~= "?" then item.name = name end
		return
	end

	item = {
		mac = mac,
		ip = ip or "",
		name = (name and name ~= "*" and name ~= "?") and name or ""
	}
	seen[mac] = item
	table.insert(devices, item)
end

local function load_online_devices()
	local devices = {}
	local seen = {}
	local fp

	fp = io.open("/tmp/dhcp.leases", "r")
	if fp then
		for line in fp:lines() do
			local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
			add_device(devices, seen, mac, ip, name)
		end
		fp:close()
	end

	fp = io.open("/proc/net/arp", "r")
	if fp then
		local is_first = true
		for line in fp:lines() do
			if is_first then
				is_first = false
			else
				local ip, _, _, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
				if mac and mac ~= "00:00:00:00:00:00" then
					add_device(devices, seen, mac, ip, "")
				end
			end
		end
		fp:close()
	end

	table.sort(devices, function(a, b)
		local av = a.name ~= "" and a.name or (a.ip ~= "" and a.ip or a.mac)
		local bv = b.name ~= "" and b.name or (b.ip ~= "" and b.ip or b.mac)
		return av < bv
	end)

	return devices
end

local function device_label(device)
	local parts = {}
	if device.name ~= "" then table.insert(parts, device.name) end
	if device.ip ~= "" then table.insert(parts, device.ip) end
	if device.mac ~= "" then table.insert(parts, device.mac) end
	return table.concat(parts, " / ")
end

local function saved_device_label(mac)
	return translate("当前已保存设备") .. " / " .. normalize_mac(mac)
end

local function has_online_device(mac)
	mac = normalize_mac(mac)
	if mac == "" then return false end
	for _, item in ipairs(online_devices or {}) do
		if item.mac == mac then return true end
	end
	return false
end

local function ensure_option_value(option, value, label)
	if not value or value == "" then return end
	for _, key in ipairs(option.keylist or {}) do
		if key == value then return end
	end
	option:value(value, label)
end

local function apply_now()
	sys.call("uci commit netspeedcontrol >/dev/null 2>&1")
	sys.call("/etc/init.d/netspeedcontrol reload >/tmp/netspeedcontrol.log 2>&1 || /usr/bin/netspeedcontrol.sh apply >/tmp/netspeedcontrol.log 2>&1")
end

online_devices = load_online_devices()

m = Map("netspeedcontrol", translate("设备上网控制 - 规则管理"))
m.description = translate("配置控制规则。优先从在线设备下拉框选择，未在线设备可手动填写 MAC。支持按时间段断网及上传/下载限速。")

function m.on_after_commit(self)
	apply_now()
end

s = m:section(TypedSection, "rule", translate("规则列表"))
s.addremove = true
s.anonymous = true
s.template = "cbi/tblsection"

o = s:option(Flag, "enabled", translate("启用"))
o.rmempty = false

o = s:option(Value, "name", translate("规则名称"))
o.placeholder = "KidPhone"
o.rmempty = false

o = s:option(ListValue, "mac", translate("受控设备"))
o:value("", translate("请选择在线设备"))
o.rmempty = false

for _, device in ipairs(online_devices) do
	o:value(device.mac, device_label(device))
end

function o.cfgvalue(self, section)
	local current_mac = normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")
	if current_mac ~= "" then
		if not has_online_device(current_mac) then
			ensure_option_value(self, current_mac, saved_device_label(current_mac))
		end
		return current_mac
	end
	return ""
end

function o.write(self, section, value)
	local custom_mac = normalize_mac(self.map:formvalue("cbid.netspeedcontrol." .. section .. "._custom_mac") or "")
	local selected_mac = normalize_mac(value or "")
	local final_mac = custom_mac ~= "" and custom_mac or selected_mac

	if final_mac ~= "" then
		uci:set("netspeedcontrol", section, "mac", final_mac)
		uci:set("netspeedcontrol", section, "target_type", "mac")
		uci:delete("netspeedcontrol", section, "ip")
	else
		uci:delete("netspeedcontrol", section, "mac")
		uci:delete("netspeedcontrol", section, "target_type")
		uci:delete("netspeedcontrol", section, "ip")
	end
end

o = s:option(Value, "_custom_mac", translate("手动填写 MAC"))
o.datatype = "macaddr"
o.placeholder = "AA:BB:CC:DD:EE:FF"

function o.cfgvalue(self, section)
	local current_mac = normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")
	if current_mac ~= "" and not has_online_device(current_mac) then
		return current_mac
	end
	return ""
end

function o.write(self, section, value)
	-- 在 mac option write 中统一合并处理
end

function o.remove(self, section)
end

o = s:option(ListValue, "mode", translate("控制方式"))
o:value("block", translate("设定时间内断网"))
o:value("limit", translate("设定时间内限速"))
o.default = "block"
o.rmempty = false

o = s:option(ListValue, "target_scope", translate("控制范围"))
o:value("all", translate("全网流量 (所有访问)"))
o:value("app", translate("指定应用分类"))
o:value("custom_domain", translate("自定义域名"))
o.default = "all"
o.rmempty = false

o = s:option(ListValue, "app_category", translate("应用分类"))
o:value("short_video", translate("🎬 短视频与直播 (抖音/快手/B站)"))
o:value("gaming", translate("🎮 网络游戏 (腾讯/网易/米哈游/Steam)"))
o:value("video", translate("🍿 影视视频 (爱奇艺/腾讯视频/优酷)"))
o:value("social", translate("💬 社交聊天 (微信/QQ/微博)"))
o.default = "short_video"
o:depends("target_scope", "app")

o = s:option(Value, "custom_domains", translate("自定义域名"))
o.placeholder = "baidu.com tieba.baidu.com"
o.description = translate("多个域名请用空格隔开（支持泛域名解析捕获，例如填写 baidu.com 会自动包含所有子域名）。")
o:depends("target_scope", "custom_domain")


o = s:option(Value, "weekdays", translate("生效星期"))
o.placeholder = "1 2 3 4 5"
o.description = translate("1-7表示周一至周日，留空代表每天。")

o = s:option(Value, "start_time", translate("开始时间"))
o.placeholder = "21:00"
o.rmempty = false
o.description = translate("24小时制，例如 21:00。")

function o.validate(self, value)
	if not value or value == "" then
		return nil, translate("开始时间不能为空！")
	end
	if not value:match("^([01]%d|2[0-3]):[0-5]%d$") then
		return nil, translate("开始时间格式错误，请输入标准的 24 小时制时间，例如 21:00！")
	end
	return value
end

o = s:option(Value, "stop_time", translate("结束时间"))
o.placeholder = "07:00"
o.rmempty = false
o.description = translate("早于开始时间代表跨天。")

function o.validate(self, value)
	if not value or value == "" then
		return nil, translate("结束时间不能为空！")
	end
	if not value:match("^([01]%d|2[0-3]):[0-5]%d$") then
		return nil, translate("结束时间格式错误，请输入标准的 24 小时制时间，例如 07:00！")
	end
	return value
end

o = s:option(Value, "up_kbit", translate("上传限速"))
o.placeholder = "256k 或 1M"
o:depends("mode", "limit")

function o.validate(self, value)
	if not value or value == "" then return "" end
	local parsed = parse_rate_value(value)
	if not parsed then
		return nil, translate("上传限速数值无效！支持填写数字（如 256）或带单位字符串（如 512k, 1M）。")
	end
	return tostring(parsed)
end

o = s:option(Value, "down_kbit", translate("下载限速"))
o.placeholder = "1024k 或 2M"
o:depends("mode", "limit")

function o.validate(self, value)
	if not value or value == "" then return "" end
	local parsed = parse_rate_value(value)
	if not parsed then
		return nil, translate("下载限速数值无效！支持填写数字（如 1024）或带单位字符串（如 1M, 2M）。")
	end
	return tostring(parsed)
end

return m
