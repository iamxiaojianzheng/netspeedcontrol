module("luci.controller.netspeedcontrol", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/netspeedcontrol") then
		return
	end

	local page = entry({"admin", "network", "netspeedcontrol"}, alias("admin", "network", "netspeedcontrol", "global"), _("设备上网控制"), 91)
	page.dependent = true

	entry({"admin", "network", "netspeedcontrol", "global"}, cbi("netspeedcontrol/global"), _("全局设置"), 10).leaf = true
	entry({"admin", "network", "netspeedcontrol", "rules"}, cbi("netspeedcontrol/rules"), _("规则管理"), 20).leaf = true
	entry({"admin", "network", "netspeedcontrol", "logs"}, cbi("netspeedcontrol/logs"), _("拦截日志"), 30).leaf = true

	entry({"admin", "network", "netspeedcontrol", "check_update"}, call("action_check_update")).leaf = true
	entry({"admin", "network", "netspeedcontrol", "do_update"}, call("action_do_update")).leaf = true
	entry({"admin", "network", "netspeedcontrol", "get_log"}, call("action_get_log")).leaf = true
end

function action_get_log()
	local sys = require "luci.sys"
	local http = require "luci.http"
	local util = require "luci.util"
	local logs = sys.exec("sed '1!G;h;$!d' /tmp/netspeedcontrol-events.log 2>/dev/null") or ""
	http.prepare_content("application/json")
	
	-- 使用简易 string format 输出 JSON，消除对第三方 jsonc 的强依赖
	local safe_log = logs:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\r\n", "\n"):gsub("\n", "\\n")
	http.write(string.format('{"status":"ok","log":"%s"}', safe_log))
end

function action_check_update()
	local sys = require "luci.sys"
	local http = require "luci.http"
	local res = sys.exec("/usr/bin/netspeedcontrol.sh check_update 2>/dev/null")
	http.prepare_content("application/json")
	http.write(res or '{"status":"error","message":"解析失败"}')
end

function action_do_update()
	local sys = require "luci.sys"
	local http = require "luci.http"
	local url = http.formvalue("url") or ""
	local cmd = "/usr/bin/netspeedcontrol.sh do_update"
	if url ~= "" then
		cmd = cmd .. " '" .. url:gsub("'", "") .. "'"
	end
	local res = sys.exec(cmd .. " 2>&1")
	http.prepare_content("application/json")
	if res and res:find("SUCCESS") then
		http.write('{"status":"ok","message":"升级成功，页面正在重新加载..."}')
	else
		http.write('{"status":"error","message":"' .. (res or "升级失败"):gsub("\n", " ") .. '"}')
	end
end



