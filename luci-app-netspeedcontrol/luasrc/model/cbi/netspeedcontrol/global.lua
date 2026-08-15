local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local m, s, o
local APP_VERSION = "0.1.0-31"

local function apply_now()
	sys.call("uci commit netspeedcontrol >/dev/null 2>&1")
	sys.call("/etc/init.d/netspeedcontrol reload >/tmp/netspeedcontrol.log 2>&1 || /usr/bin/netspeedcontrol.sh apply >/tmp/netspeedcontrol.log 2>&1")
end

m = Map("netspeedcontrol", translate("设备上网控制 - 全局设置"))
m.description = translate("定时设备网络控制插件，基于 nftables/firewall4 提供按 MAC 地址的定时断网与限速功能。")

function m.on_after_commit(self)
	apply_now()
end

s = m:section(TypedSection, "globals", translate("运行状态与设置"))
s.anonymous = true

o = s:option(DummyValue, "_status", translate("服务运行状态"))
o.rawhtml = true
o.cfgvalue = function()
	-- 先尝试 pgrep（快速路径），回退到 /proc 遍历（兼容无 pgrep 的精简固件）
	local pid = sys.exec("pgrep -f 'netspeedcontrol.sh daemon' 2>/dev/null | head -n1 | tr -d '\n'") or ""
	if pid == "" then
		local proc_list = sys.exec("ls /proc 2>/dev/null") or ""
		for dir in proc_list:gmatch("%d+") do
			local fp = io.open("/proc/" .. dir .. "/cmdline", "r")
			if fp then
				local cmd = fp:read("*a") or ""
				fp:close()
				if cmd:find("netspeedcontrol.sh", 1, true) and cmd:find("daemon", 1, true) then
					pid = dir
					break
				end
			end
		end
	end

	local is_running = (pid ~= "")
	local status_html


	if is_running then
		status_html = "<span style=\"color:green; font-weight:bold;\">✔ " .. translate("运行中") .. " (PID: " .. pid .. ")</span>"
	else
		status_html = "<span style=\"color:red; font-weight:bold;\">✘ " .. translate("已停止") .. "</span>"
	end

	return "<div style=\"padding:4px 0;\">" .. status_html .. "<span style=\"margin-left:15px; font-weight:normal;\">" .. translate("当前版本：") .. "<strong>" .. APP_VERSION .. "</strong></span></div>"
end

o = s:option(Flag, "enabled", translate("启用服务"))
o.rmempty = false

o = s:option(Flag, "log_enabled", translate("记录拦截日志"))
o.rmempty = false
o.default = "0"
o.description = translate("默认关闭。开启后会按分钟生成中文拦截日志，可以在“拦截日志”页签集中查看。")

return m
