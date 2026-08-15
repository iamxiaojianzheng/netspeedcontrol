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
	entry({"admin", "network", "netspeedcontrol", "clear_log"}, call("action_clear_log")).leaf = true
	entry({"admin", "network", "netspeedcontrol", "add_rule"}, call("action_add_rule")).leaf = true
end

function action_clear_log()
	local sys = require "luci.sys"
	local http = require "luci.http"
	sys.exec("/usr/bin/netspeedcontrol.sh clear_log >/dev/null 2>&1")
	http.prepare_content("application/json")
	http.write('{"status":"ok"}')
end

function action_add_rule()
	local uci = require("luci.model.uci").cursor()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local name = http.formvalue("name") or "KidPhone"
	local mac = (http.formvalue("mac") or ""):upper()
	local mode = http.formvalue("mode") or "block"
	local target_scope = http.formvalue("target_scope") or "all"
	local app_category = http.formvalue("app_category") or "short_video"
	local custom_domains = http.formvalue("custom_domains") or ""
	local weekdays = http.formvalue("weekdays") or "1 2 3 4 5 6 7"
	local start_time = http.formvalue("start_time") or "21:00"
	local stop_time = http.formvalue("stop_time") or "07:00"
	local up_kbit = http.formvalue("up_kbit") or ""
	local down_kbit = http.formvalue("down_kbit") or ""

	http.prepare_content("application/json")

	if mac == "" then
		http.write('{"status":"error","message":"MAC 地址不能为空！"}')
		return
	end

	local section_id = uci:section("netspeedcontrol", "rule", nil, {
		enabled = "1",
		name = name,
		mac = mac,
		target_type = "mac",
		mode = mode,
		target_scope = target_scope,
		app_category = app_category,
		custom_domains = custom_domains,
		weekdays = weekdays,
		start_time = start_time,
		stop_time = stop_time,
		up_kbit = up_kbit,
		down_kbit = down_kbit
	})

	if section_id then
		local auto_commit = http.formvalue("commit")
		if auto_commit == "1" then
			uci:commit("netspeedcontrol")
			sys.call("rm -rf /tmp/.uci/netspeedcontrol* 2>/dev/null")
			sys.call("/etc/init.d/netspeedcontrol reload >/dev/null 2>&1 || /usr/bin/netspeedcontrol.sh apply >/dev/null 2>&1")
		else
			uci:save("netspeedcontrol")
		end
		http.write('{"status":"ok"}')
	else
		http.write('{"status":"error","message":"写入 UCI 配置失败！"}')
	end
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
		sys.call("(sleep 2 && (/etc/init.d/uhttpd restart || /etc/init.d/nginx restart)) >/dev/null 2>&1 &")
		http.write('{"status":"ok","message":"升级成功，页面即将在 2 秒后自动重新加载..."}')
	else
		local err_msg = (res or "升级失败"):gsub("\r\n", " "):gsub("\n", " "):gsub("\\", "\\\\"):gsub("\"", "\\\"")
		http.write(string.format('{"status":"error","message":"%s"}', err_msg))
	end
end



