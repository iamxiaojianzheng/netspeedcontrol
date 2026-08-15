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
end

