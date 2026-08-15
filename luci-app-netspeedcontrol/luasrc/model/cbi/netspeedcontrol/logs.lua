local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local m, s, o

local function load_recent_logs()
	local data = sys.exec("sed '1!G;h;$!d' /tmp/netspeedcontrol-events.log 2>/dev/null")
	data = data or ""
	data = data:gsub("\r\n", "\n")
	return data
end

m = SimpleForm("netspeedcontrol_log", translate("设备上网控制 - 拦截日志"))
m.description = translate("按分钟汇总记录受控设备的拦截流量日志。如需开启日志记录，请先在[全局设置]中开启“记录拦截日志”。")
m.reset = false
m.submit = translate("清空拦截日志")

function m.handle(self, state, data)
	if state == FORM_VALID then
		sys.call("/usr/bin/netspeedcontrol.sh clear_log >/dev/null 2>&1")
		m.message = translate("拦截日志已成功清空！")
	end
	return true
end

s = m:section(SimpleSection)

o = s:option(DummyValue, "_log_view", "")
o.rawhtml = true

function o.cfgvalue()
	local enabled = uci:get("netspeedcontrol", "globals", "log_enabled") or "0"
	if enabled ~= "1" then
		return "<em>" .. util.pcdata(translate("当前未开启“记录拦截日志”。请前往[全局设置]勾选“记录拦截日志”并保存应用。")) .. "</em>"
	end

	local logs = load_recent_logs()
	if logs == "" then
		return "<em>" .. util.pcdata(translate("暂时还没有拦截日志。受控设备尝试上网并触发拦截后将按分钟自动生成日志。")) .. "</em>"
	end

	return "<div style=\"width:100%; overflow-x:auto;\">"
		.. "<textarea class=\"cbi-input-textarea\" style=\"display:block; width:100%; min-width:980px; min-height:360px; box-sizing:border-box; font-family:monospace;\" readonly=\"readonly\">"
		.. util.pcdata(logs)
		.. "</textarea></div>"
end

return m
