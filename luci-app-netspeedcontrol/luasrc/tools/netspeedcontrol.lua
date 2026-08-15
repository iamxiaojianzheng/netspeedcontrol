local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"

local M = {}

function M.normalize_mac(mac)
	if not mac then return "" end
	return tostring(mac):upper()
end

function M.parse_rate_value(val)
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

function M.add_device(devices, seen, mac, ip, name)
	mac = M.normalize_mac(mac)
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

function M.load_online_devices()
	local devices = {}
	local seen = {}
	local fp

	fp = io.open("/tmp/dhcp.leases", "r")
	if fp then
		for line in fp:lines() do
			local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
			M.add_device(devices, seen, mac, ip, name)
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
					M.add_device(devices, seen, mac, ip, "")
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

function M.device_label(device)
	local name_str = device.name ~= "" and device.name or "未命名设备"
	local ip_str = device.ip ~= "" and device.ip or "未知 IP"
	return string.format("%s (%s / %s) 在线", name_str, ip_str, device.mac)
end

function M.saved_device_label(mac)
	return "已保存设备 / " .. M.normalize_mac(mac)
end

function M.has_online_device(online_devices, mac)
	mac = M.normalize_mac(mac)
	if mac == "" then return false end
	for _, item in ipairs(online_devices or {}) do
		if item.mac == mac then return true end
	end
	return false
end

function M.ensure_option_value(option, value, label)
	if not value or value == "" then return end
	for _, key in ipairs(option.keylist or {}) do
		if key == value then return end
	end
	option:value(value, label)
end

function M.apply_now()
	sys.call("uci commit netspeedcontrol >/dev/null 2>&1")
	sys.call("/etc/init.d/netspeedcontrol reload >/tmp/netspeedcontrol.log 2>&1 || /usr/bin/netspeedcontrol.sh apply >/tmp/netspeedcontrol.log 2>&1")
end

return M
