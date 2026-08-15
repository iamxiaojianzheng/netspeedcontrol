local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local m, s, o

local APP_VERSION = sys.exec("opkg status luci-app-netspeedcontrol 2>/dev/null | awk '/Version:/ {print $2}' | head -n1 | tr -d '\n'")
if not APP_VERSION or APP_VERSION == "" then
	APP_VERSION = "0.2.0-1"
end

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

o = s:option(DummyValue, "_update_panel", translate("版本与更新"))
o.rawhtml = true
o.cfgvalue = function()
	local check_url = luci.dispatcher.build_url("admin", "network", "netspeedcontrol", "check_update")
	local update_url = luci.dispatcher.build_url("admin", "network", "netspeedcontrol", "do_update")
	return string.format([[
	<div style="padding:6px 0;">
		<button type="button" class="cbi-button cbi-button-apply" id="btn-check-update" onclick="checkAppUpdate()">🔍 %s</button>
		<span id="update-msg" style="margin-left:12px; font-weight:bold; color:#555;"></span>
		<button type="button" class="cbi-button cbi-button-save" id="btn-do-update" style="display:none; margin-left:12px;" onclick="doAppUpdate()">🚀 %s</button>
	</div>
	<script type="text/javascript">
		var latestDownloadUrl = "";
		var currentVer = "%s";

		function checkAppUpdate() {
			var btn = document.getElementById("btn-check-update");
			var msg = document.getElementById("update-msg");
			var upBtn = document.getElementById("btn-do-update");
			btn.disabled = true;
			msg.style.color = "#555";
			msg.innerHTML = "正在连接 GitHub 检查最新版本...";
			upBtn.style.display = "none";

			XHR.get('%s', null, function(x, data) {
				btn.disabled = false;
				if (data && data.status === "ok") {
					var remoteVer = data.tag_name ? data.tag_name.replace(/^v/, '') : '';
					latestDownloadUrl = data.download_url || '';
					if (remoteVer && remoteVer !== currentVer) {
						msg.style.color = "#d9534f";
						msg.innerHTML = "发现新版本: <strong>" + data.tag_name + "</strong>";
						upBtn.style.display = "inline-block";
					} else {
						msg.style.color = "#5cb85c";
						msg.innerHTML = "✔ 当前已是最新版本 (" + currentVer + ")";
					}
				} else {
					msg.style.color = "#f0ad4e";
					msg.innerHTML = "检查失败: " + ((data && data.message) ? data.message : "无法连接更新服务器");
				}
			});
		}

		function doAppUpdate() {
			if (!confirm("确定要立即在线升级到最新版本吗？升级过程中请勿关闭页面。")) return;
			var upBtn = document.getElementById("btn-do-update");
			var msg = document.getElementById("update-msg");
			upBtn.disabled = true;
			msg.style.color = "#0275d8";
			msg.innerHTML = "⌛ 正在下载并安装最新更新包，请稍候...";

			XHR.get('%s', { url: latestDownloadUrl }, function(x, data) {
				if (data && data.status === "ok") {
					msg.style.color = "#5cb85c";
					msg.innerHTML = "✔ " + data.message;
					setTimeout(function() { location.reload(); }, 3000);
				} else {
					upBtn.disabled = false;
					msg.style.color = "#d9534f";
					msg.innerHTML = "❌ 升级失败: " + ((data && data.message) ? data.message : "未知错误");
				}
			});
		}
	</script>
	]], translate("检查更新"), translate("一键在线升级"), APP_VERSION, check_url, update_url)
end

o = s:option(Flag, "enabled", translate("启用服务"))
o.rmempty = false

o = s:option(Value, "github_proxy", translate("GitHub 加速代理"))
o.rmempty = true
o.placeholder = "https://ghfast.top/"
o.description = translate("留空表示直连。若国内环境在线检查或下载缓慢，可输入加速前缀（如 https://ghfast.top/），亦可在 /etc/profile 中导出 GITHUB_PROXY 环境变量。")
o:value("", translate("直连 (默认)"))
o:value("https://ghfast.top/", "https://ghfast.top/ (推荐镜像 1)")
o:value("https://mirror.ghproxy.com/", "https://mirror.ghproxy.com/ (推荐镜像 2)")
o:value("https://ghproxy.net/", "https://ghproxy.net/ (推荐镜像 3)")

o = s:option(Flag, "log_enabled", translate("记录拦截日志"))
o.rmempty = false
o.default = "0"
o.description = translate("默认关闭。开启后会按分钟生成中文拦截日志，可以在“拦截日志”页签集中查看。")

return m


