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
m.description = translate("按分钟汇总记录受控设备的拦截流量日志。如需开启日志记录，请先在 [全局设置] 中勾选“记录拦截日志”。")
m.reset = false
m.submit = false

s = m:section(SimpleSection)

o = s:option(DummyValue, "_log_view", "")
o.rawhtml = true

function o.cfgvalue()
	local enabled = uci:get("netspeedcontrol", "globals", "log_enabled") or "0"
	if enabled ~= "1" then
		return "<div style=\"padding: 12px; background: #fffaf0; border: 1px solid #feebc8; border-radius: 6px; color: #c05621;\">"
			.. util.pcdata(translate("提示：当前未开启“记录拦截日志”。请前往 [全局设置] 勾选“记录拦截日志”并保存应用。"))
			.. "</div>"
	end

	local logs = load_recent_logs()
	local get_log_url = luci.dispatcher.build_url("admin", "network", "netspeedcontrol", "get_log")
	local clear_log_url = luci.dispatcher.build_url("admin", "network", "netspeedcontrol", "clear_log")

	local html = {}
	table.insert(html, "<style>")
	table.insert(html, ".nsc-log-toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; background: #edf2f7; padding: 8px 12px; border-radius: 6px 6px 0 0; border: 1px solid #cbd5e0; border-bottom: none; }")
	table.insert(html, ".nsc-log-controls { display: flex; align-items: center; gap: 8px; }")
	table.insert(html, ".nsc-log-search { padding: 4px 8px; border-radius: 4px; border: 1px solid #cbd5e0; font-size: 12px; width: 180px; }")
	table.insert(html, ".nsc-log-box { width: 100%; min-height: 380px; max-height: 560px; background: #1a202c; color: #e2e8f0; font-family: monospace; font-size: 12px; padding: 12px; border-radius: 0 0 6px 6px; border: 1px solid #cbd5e0; overflow-y: auto; white-space: pre-wrap; word-break: break-all; box-sizing: border-box; }")
	table.insert(html, "</style>")

	table.insert(html, "<div class=\"nsc-log-toolbar\">")
	table.insert(html, "  <div class=\"nsc-log-controls\">")
	table.insert(html, "    <button type=\"button\" class=\"cbi-button cbi-button-apply\" onclick=\"fetchNscLog()\">[ 手动刷新 ]</button>")
	table.insert(html, "    <label style=\"font-size: 12px; cursor: pointer; user-select: none;\"><input type=\"checkbox\" id=\"chk-auto-refresh\" onchange=\"toggleAutoRefresh(this)\"> 5秒自动轮询</label>")
	table.insert(html, "    <button type=\"button\" class=\"cbi-button cbi-button-action\" onclick=\"copyNscLog()\">[ 复制日志 ]</button>")
	table.insert(html, "    <button type=\"button\" class=\"cbi-button cbi-button-remove\" onclick=\"clearNscLog()\">[ 清空日志 ]</button>")
	table.insert(html, "  </div>")
	table.insert(html, "  <div>")
	table.insert(html, "    <input type=\"text\" id=\"nsc-log-filter\" class=\"nsc-log-search\" placeholder=\"检索过滤关键字...\" oninput=\"filterNscLog()\">")
	table.insert(html, "    <span id=\"nsc-log-status\" style=\"font-size:11px; color:#718096; margin-left:8px;\"></span>")
	table.insert(html, "  </div>")
	table.insert(html, "</div>")

	table.insert(html, string.format("<div id=\"nsc-log-content\" class=\"nsc-log-box\">%s</div>", util.pcdata(logs ~= "" and logs or translate("暂无拦截日志记录"))))

	table.insert(html, string.format([[
	<script type="text/javascript">
		var rawLogText = %q;
		var refreshTimer = null;

		function fetchNscLog() {
			var statusSpan = document.getElementById("nsc-log-status");
			if (statusSpan) statusSpan.innerHTML = "正在更新...";
			XHR.get('%s', null, function(x, data) {
				if (data && data.status === "ok") {
					rawLogText = data.log || "暂无拦截日志记录";
					filterNscLog();
					if (statusSpan) {
						var now = new Date();
						statusSpan.innerHTML = "最后更新: " + now.toTimeString().split(' ')[0];
					}
				}
			});
		}

		function filterNscLog() {
			var kw = (document.getElementById("nsc-log-filter").value || "").toLowerCase();
			var logBox = document.getElementById("nsc-log-content");
			if (!logBox) return;

			if (!kw) {
				logBox.innerText = rawLogText;
			} else {
				var lines = rawLogText.split('\n');
				var filtered = lines.filter(function(line) {
					return line.toLowerCase().indexOf(kw) !== -1;
				});
				logBox.innerText = filtered.length > 0 ? filtered.join('\n') : "未找到匹配关键字的内容";
			}
		}

		function toggleAutoRefresh(chk) {
			if (chk.checked) {
				fetchNscLog();
				refreshTimer = setInterval(fetchNscLog, 5000);
			} else {
				if (refreshTimer) clearInterval(refreshTimer);
			}
		}

		function copyNscLog() {
			var logBox = document.getElementById("nsc-log-content");
			if (!logBox) return;
			var txt = logBox.innerText;
			if (navigator.clipboard && navigator.clipboard.writeText) {
				navigator.clipboard.writeText(txt).then(function() {
					alert("日志内容已成功复制到剪贴板！");
				});
			} else {
				var ta = document.createElement("textarea");
				ta.value = txt;
				document.body.appendChild(ta);
				ta.select();
				document.execCommand("copy");
				document.body.removeChild(ta);
				alert("日志内容已成功复制！");
			}
		}

		function clearNscLog() {
			if (!confirm("确定要物理清空当前所有拦截日志吗？")) return;
			XHR.get('%s', null, function(x, data) {
				// 发送表单提交清空日志
				var form = document.querySelector("form");
				if (form) {
					var inputSubmit = document.createElement("input");
					inputSubmit.type = "hidden";
					inputSubmit.name = "cbi.submit";
					inputSubmit.value = "1";
					form.appendChild(inputSubmit);
					form.submit();
				} else {
					location.reload();
				}
			});
		}
	</script>
	]], logs ~= "" and logs or "暂无拦截日志记录", get_log_url, get_log_url))

	return table.concat(html, "\n")
end

return m

