local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local m, s, o

local APP_VERSION = sys.exec("opkg status luci-app-netspeedcontrol 2>/dev/null | awk '/Version:/ {print $2}' | head -n1 | tr -d '\n'")
if not APP_VERSION or APP_VERSION == "" then
	APP_VERSION = "0.2.3-20"
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
	
	-- 统计已配置规则数量
	local total_rules = 0
	local enabled_rules = 0
	uci:foreach("netspeedcontrol", "rule", function(sec)
		total_rules = total_rules + 1
		if sec.enabled == "1" then
			enabled_rules = enabled_rules + 1
		end
	end)

	local html = {}
	table.insert(html, "<style>")
	table.insert(html, ".nsc-hero-card { display: flex; flex-wrap: wrap; gap: 16px; margin: 6px 0; padding: 14px 18px; border: 1px solid #e2e8f0; border-radius: 8px; background: linear-gradient(135deg, #ffffff 0%, #f7fafc 100%); box-shadow: 0 1px 3px rgba(0,0,0,0.05); }")
	table.insert(html, ".nsc-hero-item { display: flex; align-items: center; min-width: 180px; }")
	table.insert(html, ".nsc-hero-icon-box { width: 40px; height: 40px; border-radius: 8px; display: flex; align-items: center; justify-content: center; font-weight: bold; font-size: 14px; margin-right: 12px; }")
	table.insert(html, ".nsc-hero-icon-green { background: #e6fffa; color: #234e52; border: 1px solid #b2f5ea; }")
	table.insert(html, ".nsc-hero-icon-red { background: #fff5f5; color: #742a2a; border: 1px solid #fed7d7; }")
	table.insert(html, ".nsc-hero-icon-blue { background: #ebf8ff; color: #2b6cb0; border: 1px solid #bee3f8; }")
	table.insert(html, ".nsc-hero-title { font-size: 11px; color: #718096; text-transform: uppercase; letter-spacing: 0.5px; }")
	table.insert(html, ".nsc-hero-value { font-size: 15px; font-weight: bold; color: #2d3748; margin-top: 1px; }")
	table.insert(html, ".nsc-status-indicator { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; }")
	table.insert(html, ".nsc-indicator-on { background-color: #38a169; box-shadow: 0 0 6px rgba(56,161,105,0.6); }")
	table.insert(html, ".nsc-indicator-off { background-color: #e53e3e; }")
	table.insert(html, "</style>")

	table.insert(html, "<div class=\"nsc-hero-card\">")

	if is_running then
		table.insert(html, string.format([[
			<div class="nsc-hero-item">
				<div class="nsc-hero-icon-box nsc-hero-icon-green"><span class="nsc-status-indicator nsc-indicator-on"></span>RUN</div>
				<div>
					<div class="nsc-hero-title">%s</div>
					<div class="nsc-hero-value" style="color:#276749;">%s (PID: %s)</div>
				</div>
			</div>
		]], translate("服务状态"), translate("运行中"), pid))
	else
		table.insert(html, string.format([[
			<div class="nsc-hero-item">
				<div class="nsc-hero-icon-box nsc-hero-icon-red"><span class="nsc-status-indicator nsc-indicator-off"></span>OFF</div>
				<div>
					<div class="nsc-hero-title">%s</div>
					<div class="nsc-hero-value" style="color:#9b2c2c;">%s</div>
				</div>
			</div>
		]], translate("服务状态"), translate("未运行")))
	end

	table.insert(html, string.format([[
		<div class="nsc-hero-item">
			<div class="nsc-hero-icon-box nsc-hero-icon-blue">VER</div>
			<div>
				<div class="nsc-hero-title">%s</div>
				<div class="nsc-hero-value">%s</div>
			</div>
		</div>
		<div class="nsc-hero-item">
			<div class="nsc-hero-icon-box nsc-hero-icon-blue">RULE</div>
			<div>
				<div class="nsc-hero-title">%s</div>
				<div class="nsc-hero-value">%d / %d</div>
			</div>
		</div>
	</div>
	]], translate("当前版本"), APP_VERSION, translate("生效规则数"), enabled_rules, total_rules))

	return table.concat(html, "\n")
end

o = s:option(DummyValue, "_update_panel", translate("版本与检查更新"))
o.rawhtml = true
o.cfgvalue = function()
	local check_url = luci.dispatcher.build_url("admin", "network", "netspeedcontrol", "check_update")
	local update_url = luci.dispatcher.build_url("admin", "network", "netspeedcontrol", "do_update")
	return string.format([[
	<div style="padding:6px 0;">
		<button type="button" class="cbi-button cbi-button-apply" id="btn-check-update" onclick="checkAppUpdate()">检查在线更新</button>
		<span id="update-msg" style="margin-left:12px; font-weight:bold; color:#555;"></span>
		<button type="button" class="cbi-button cbi-button-save" id="btn-do-update" style="display:none; margin-left:12px;" onclick="doAppUpdate()">立即在线升级</button>
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
						msg.innerHTML = "发现新版本: " + data.tag_name;
						upBtn.style.display = "inline-block";
					} else {
						msg.style.color = "#5cb85c";
						msg.innerHTML = "[最新] 当前已是最新版本 (" + currentVer + ")";
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
			msg.innerHTML = "[进行中] 正在下载并安装最新更新包，请稍候...";

			XHR.get('%s', { url: latestDownloadUrl }, function(x, data) {
				var isSuccess = false;
				if (data && data.status === "ok") {
					isSuccess = true;
				} else if (x && (x.status === 200 || x.status === 0)) {
					isSuccess = true;
				}

				if (isSuccess) {
					msg.style.color = "#5cb85c";
					msg.innerHTML = "[成功] " + ((data && data.message) ? data.message : "升级成功！页面即将在 2 秒后自动重新加载...");
					setTimeout(function() {
						location.reload();
					}, 2000);
				} else {
					upBtn.disabled = false;
					msg.style.color = "#d9534f";
					msg.innerHTML = "[失败] 升级失败: " + ((data && data.message) ? data.message : "请求无响应或网络异常");
				}
			});
		}
	</script>
	]], APP_VERSION, check_url, update_url)
end

o = s:option(Flag, "enabled", translate("启用服务"))
o.rmempty = false

o = s:option(Value, "github_proxy", translate("GitHub 加速代理"))
o.rmempty = true
o.placeholder = "https://ghfast.top/"
o.description = translate("留空表示直连。若国内环境在线检查或下载缓慢，可输入加速前缀（如 https://ghfast.top/），亦可在 /etc/profile 中导出 GITHUB_PROXY 环境变量。")
o:value("", translate("直连 (默认)"))
o:value("https://ghfast.top/", "https://ghfast.top/")
o:value("https://v4.gh-proxy.org/", "https://v4.gh-proxy.org/")
o:value("https://gh.xmly.dev/", "https://gh.xmly.dev/")

o = s:option(Flag, "log_enabled", translate("记录拦截日志"))
o.rmempty = false
o.default = "0"
o.description = translate("默认关闭。开启后会按分钟生成中文拦截日志，可以在“拦截日志”页签集中查看。")

return m



