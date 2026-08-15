local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local TypedSection = TypedSection or luci.cbi.TypedSection
local TableSection = TableSection or TypedSection
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
	local name_str = device.name ~= "" and device.name or translate("未命名设备")
	local ip_str = device.ip ~= "" and device.ip or translate("未知 IP")
	return string.format("%s (%s / %s) [在线]", name_str, ip_str, device.mac)
end

local function saved_device_label(mac)
	return translate("已保存设备") .. " / " .. normalize_mac(mac)
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
m.description = translate("通过表格管理已有规则。点击右上角 [ + 新增控制规则 ] 按钮可通过弹窗进行规则添加。")

function m.on_after_commit(self)
	apply_now()
end

-- 顶部 Modal 弹窗触发 HTML 与模态框逻辑
s_header = m:section(TypedSection, "globals")
s_header.anonymous = true

o_modal = s_header:option(DummyValue, "_rule_modal_panel")
o_modal.rawhtml = true
o_modal.cfgvalue = function()
	local html = {}
	table.insert(html, "<style>")
	table.insert(html, ".nsc-modal-overlay { display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.5); z-index:9999; align-items:center; justify-content:center; }")
	table.insert(html, ".nsc-modal-dialog { background:#ffffff; border-radius:8px; width:520px; max-width:92%; padding:20px 24px; box-shadow:0 10px 25px rgba(0,0,0,0.2); position:relative; }")
	table.insert(html, ".nsc-modal-title { font-size:16px; font-weight:bold; color:#2d3748; padding-bottom:12px; border-bottom:1px solid #e2e8f0; margin-bottom:16px; display:flex; justify-content:space-between; align-items:center; }")
	table.insert(html, ".nsc-modal-close { font-size:18px; cursor:pointer; color:#a0aec0; }")
	table.insert(html, ".nsc-modal-close:hover { color:#e53e3e; }")
	table.insert(html, ".nsc-form-group { margin-bottom:12px; }")
	table.insert(html, ".nsc-form-label { display:block; font-size:12px; font-weight:bold; color:#4a5568; margin-bottom:4px; }")
	table.insert(html, ".nsc-form-control { width:100%; padding:6px 10px; border:1px solid #cbd5e0; border-radius:4px; box-sizing:border-box; font-size:13px; }")
	table.insert(html, ".nsc-btn-group { display:flex; justify-content:flex-end; gap:10px; margin-top:20px; padding-top:12px; border-top:1px solid #e2e8f0; }")
	table.insert(html, ".nsc-preset-btn { padding:3px 8px; font-size:11px; margin-right:6px; border-radius:4px; border:1px solid #cbd5e0; background:#f7fafc; cursor:pointer; }")
	table.insert(html, ".nsc-preset-btn:hover { background:#edf2f7; border-color:#cbd5e0; }")
	table.insert(html, "</style>")

	table.insert(html, [[
	<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
		<span style="font-weight:bold; color:#4a5568;">控制规则列表</span>
		<button type="button" class="cbi-button cbi-button-add" style="padding:6px 14px; font-weight:bold;" onclick="openAddRuleModal()">[ + 新增控制规则 ]</button>
	</div>

	<!-- NSC Modal 模态弹窗 -->
	<div id="nscModalOverlay" class="nsc-modal-overlay">
		<div class="nsc-modal-dialog">
			<div class="nsc-modal-title">
				<span>新增设备控制规则</span>
				<span class="nsc-modal-close" onclick="closeAddRuleModal()">&times;</span>
			</div>
			
			<div class="nsc-form-group">
				<label class="nsc-form-label">规则名称</label>
				<input type="text" id="modal_rule_name" class="nsc-form-control" placeholder="如：KidPhone" value="KidPhone">
			</div>

			<div class="nsc-form-group">
				<label class="nsc-form-label">受控设备</label>
				<select id="modal_rule_mac" class="nsc-form-control" onchange="toggleModalCustomMac(this)">
					<option value="">-- 请选择在线设备 --</option>
	]])

	for _, dev in ipairs(online_devices) do
		table.insert(html, string.format([[<option value="%s">%s</option>]], util.pcdata(dev.mac), util.pcdata(device_label(dev))))
	end

	table.insert(html, [[
					<option value="CUSTOM">[+] 手动填写 MAC 地址...</option>
				</select>
			</div>

			<div class="nsc-form-group" id="modal_custom_mac_group" style="display:none;">
				<label class="nsc-form-label">手动 MAC 地址</label>
				<input type="text" id="modal_custom_mac" class="nsc-form-control" placeholder="AA:BB:CC:DD:EE:FF">
			</div>

			<div class="nsc-form-group" style="display:flex; gap:12px;">
				<div style="flex:1;">
					<label class="nsc-form-label">控制方式</label>
					<select id="modal_rule_mode" class="nsc-form-control">
						<option value="block" selected>设定时间内断网</option>
						<option value="limit">设定时间内限速</option>
					</select>
				</div>
				<div style="flex:1;">
					<label class="nsc-form-label">控制范围</label>
					<select id="modal_rule_scope" class="nsc-form-control" onchange="toggleModalScopeOptions(this)">
						<option value="all" selected>全网流量 (所有访问)</option>
						<option value="app">指定应用分类</option>
						<option value="custom_domain">自定义域名</option>
					</select>
				</div>
			</div>

			<div class="nsc-form-group" id="modal_app_cat_group" style="display:none;">
				<label class="nsc-form-label">应用分类</label>
				<select id="modal_rule_app_cat" class="nsc-form-control">
					<option value="short_video">短视频与直播 (抖音/快手/B站)</option>
					<option value="gaming">网络游戏 (腾讯/网易/米哈游/Steam)</option>
					<option value="video">影视视频 (爱奇艺/腾讯视频/优酷)</option>
					<option value="social">社交聊天 (微信/QQ/微博)</option>
				</select>
			</div>

			<div class="nsc-form-group" id="modal_custom_domain_group" style="display:none;">
				<label class="nsc-form-label">自定义域名</label>
				<input type="text" id="modal_rule_domains" class="nsc-form-control" placeholder="baidu.com tieba.baidu.com">
			</div>

			<div class="nsc-form-group">
				<label class="nsc-form-label">快捷场景预设时间</label>
				<div>
					<button type="button" class="nsc-preset-btn" onclick="applyModalTimePreset('night')">夜间防沉迷 (22:00-06:00)</button>
					<button type="button" class="nsc-preset-btn" onclick="applyModalTimePreset('study')">学习工作 (08:00-17:00)</button>
					<button type="button" class="nsc-preset-btn" onclick="applyModalTimePreset('allday')">全天生效 (00:00-23:59)</button>
				</div>
			</div>

			<div class="nsc-form-group" style="display:flex; gap:12px;">
				<div style="flex:1;">
					<label class="nsc-form-label">开始时间 (24小时制)</label>
					<input type="text" id="modal_rule_start" class="nsc-form-control" value="21:00" placeholder="21:00">
				</div>
				<div style="flex:1;">
					<label class="nsc-form-label">结束时间 (跨天自动兼容)</label>
					<input type="text" id="modal_rule_stop" class="nsc-form-control" value="07:00" placeholder="07:00">
				</div>
			</div>

			<div class="nsc-btn-group">
				<button type="button" class="cbi-button cbi-button-reset" onclick="closeAddRuleModal()">[ 取消 ]</button>
				<button type="button" class="cbi-button cbi-button-save" onclick="submitModalAddRule()">[ 确定添加规则 ]</button>
			</div>
		</div>
	</div>

	<script type="text/javascript">
		function openAddRuleModal() {
			var overlay = document.getElementById("nscModalOverlay");
			if (overlay) overlay.style.display = "flex";
		}

		function closeAddRuleModal() {
			var overlay = document.getElementById("nscModalOverlay");
			if (overlay) overlay.style.display = "none";
		}

		function toggleModalCustomMac(sel) {
			var group = document.getElementById("modal_custom_mac_group");
			if (group) group.style.display = (sel.value === "CUSTOM") ? "block" : "none";
		}

		function toggleModalScopeOptions(sel) {
			var appGroup = document.getElementById("modal_app_cat_group");
			var domainGroup = document.getElementById("modal_custom_domain_group");
			if (appGroup) appGroup.style.display = (sel.value === "app") ? "block" : "none";
			if (domainGroup) domainGroup.style.display = (sel.value === "custom_domain") ? "block" : "none";
		}

		function applyModalTimePreset(type) {
			var startInput = document.getElementById("modal_rule_start");
			var stopInput = document.getElementById("modal_rule_stop");
			if (!startInput || !stopInput) return;
			if (type === 'night') { startInput.value = "22:00"; stopInput.value = "06:00"; }
			else if (type === 'study') { startInput.value = "08:00"; stopInput.value = "17:00"; }
			else if (type === 'allday') { startInput.value = "00:00"; stopInput.value = "23:59"; }
		}

		function submitModalAddRule() {
			var macSel = document.getElementById("modal_rule_mac").value;
			var customMac = document.getElementById("modal_custom_mac").value;
			var finalMac = (macSel === "CUSTOM" || !macSel) ? customMac : macSel;
			
			if (!finalMac) {
				alert("请选择一个在线设备或填写有效的 MAC 地址！");
				return;
			}

			sessionStorage.setItem("nsc_modal_mac", finalMac);
			sessionStorage.setItem("nsc_modal_name", document.getElementById("modal_rule_name").value || "KidPhone");
			sessionStorage.setItem("nsc_modal_mode", document.getElementById("modal_rule_mode").value || "block");
			sessionStorage.setItem("nsc_modal_scope", document.getElementById("modal_rule_scope").value || "all");
			sessionStorage.setItem("nsc_modal_app", document.getElementById("modal_rule_app_cat").value || "short_video");
			sessionStorage.setItem("nsc_modal_domains", document.getElementById("modal_rule_domains").value || "");
			sessionStorage.setItem("nsc_modal_start", document.getElementById("modal_rule_start").value || "21:00");
			sessionStorage.setItem("nsc_modal_stop", document.getElementById("modal_rule_stop").value || "07:00");

			// 触发 CBI 原生的 Add 按钮添加一行
			var addBtn = document.querySelector("input.cbi-button-add[name='cbi.cts.netspeedcontrol.rule']");
			if (addBtn) {
				addBtn.click();
			} else {
				var altBtn = document.querySelector("input[name^='cbi.cts.netspeedcontrol.rule']");
				if (altBtn) altBtn.click();
			}
		}

		// 页面重新渲染后，写入 Modal 暂存的值
		window.addEventListener("DOMContentLoaded", function() {
			var pendingMac = sessionStorage.getItem("nsc_modal_mac");
			if (pendingMac) {
				sessionStorage.removeItem("nsc_modal_mac");
				
				// 定位新建行的表单项并赋值
				var macSelects = document.querySelectorAll("select[id^='cbid.netspeedcontrol.'][id$='.mac']");
				if (macSelects && macSelects.length > 0) {
					var lastMacSelect = macSelects[macSelects.length - 1];
					var found = false;
					for (var i = 0; i < lastMacSelect.options.length; i++) {
						if (lastMacSelect.options[i].value.toUpperCase() === pendingMac.toUpperCase()) {
							lastMacSelect.selectedIndex = i;
							found = true;
							break;
						}
					}
					if (!found) {
						lastMacSelect.value = "CUSTOM";
					}
				}

				var nameInputs = document.querySelectorAll("input[id^='cbid.netspeedcontrol.'][id$='.name']");
				if (nameInputs && nameInputs.length > 0) {
					nameInputs[nameInputs.length - 1].value = sessionStorage.getItem("nsc_modal_name") || "KidPhone";
					sessionStorage.removeItem("nsc_modal_name");
				}

				var startInputs = document.querySelectorAll("input[id^='cbid.netspeedcontrol.'][id$='.start_time']");
				if (startInputs && startInputs.length > 0) {
					startInputs[startInputs.length - 1].value = sessionStorage.getItem("nsc_modal_start") || "21:00";
					sessionStorage.removeItem("nsc_modal_start");
				}

				var stopInputs = document.querySelectorAll("input[id^='cbid.netspeedcontrol.'][id$='.stop_time']");
				if (stopInputs && stopInputs.length > 0) {
					stopInputs[stopInputs.length - 1].value = sessionStorage.getItem("nsc_modal_stop") || "07:00";
					sessionStorage.removeItem("nsc_modal_stop");
				}
			}
		});
	</script>
	]])

	return table.concat(html, "\n")
end

-- 主表格 Section 列表展示
s = m:section(TypedSection, "rule", translate("已配置规则"))
s.addremove = true
s.anonymous = true
s.template = "cbi/tblsection"

o = s:option(Flag, "enabled", translate("启用"))
o.rmempty = false

o = s:option(Value, "name", translate("规则名称"))
o.placeholder = "KidPhone"
o.rmempty = false

o = s:option(ListValue, "mac", translate("受控设备"))
o:value("", translate("请选择设备"))
o:value("CUSTOM", translate("[+] 手动填写 MAC..."))
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
	local final_mac = (selected_mac == "CUSTOM" or selected_mac == "") and custom_mac or selected_mac

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

o = s:option(Value, "_custom_mac", translate("手动 MAC"))
o.datatype = "macaddr"
o.placeholder = "AA:BB:CC:DD:EE:FF"
o:depends("mac", "CUSTOM")

function o.cfgvalue(self, section)
	local current_mac = normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")
	if current_mac ~= "" and not has_online_device(current_mac) then
		return current_mac
	end
	return ""
end

o = s:option(ListValue, "mode", translate("控制方式"))
o:value("block", translate("定时断网"))
o:value("limit", translate("定时限速"))
o.default = "block"
o.rmempty = false

o = s:option(ListValue, "target_scope", translate("控制范围"))
o:value("all", translate("全网流量"))
o:value("app", translate("指定应用"))
o:value("custom_domain", translate("自定义域名"))
o.default = "all"
o.rmempty = false

o = s:option(ListValue, "app_category", translate("应用分类"))
o:value("short_video", translate("短视频/直播"))
o:value("gaming", translate("网络游戏"))
o:value("video", translate("影视视频"))
o:value("social", translate("社交聊天"))
o.default = "short_video"
o:depends("target_scope", "app")

o = s:option(Value, "custom_domains", translate("自定义域名"))
o.placeholder = "baidu.com"
o:depends("target_scope", "custom_domain")

o = s:option(Value, "weekdays", translate("生效星期"))
o.placeholder = "1 2 3 4 5 6 7"
o.default = "1 2 3 4 5 6 7"

o = s:option(Value, "start_time", translate("开始时间"))
o.placeholder = "21:00"
o.default = "21:00"
o.rmempty = false

function o.validate(self, value)
	if not value or value == "" then
		return "21:00"
	end
	if not value:match("^([01]%d|2[0-3]):[0-5]%d$") then
		return nil, translate("开始时间格式错误，请输入标准的 24 小时制时间，例如 21:00！")
	end
	return value
end

o = s:option(Value, "stop_time", translate("结束时间"))
o.placeholder = "07:00"
o.default = "07:00"
o.rmempty = false

function o.validate(self, value)
	if not value or value == "" then
		return "07:00"
	end
	if not value:match("^([01]%d|2[0-3]):[0-5]%d$") then
		return nil, translate("结束时间格式错误，请输入标准的 24 小时制时间，例如 07:00！")
	end
	return value
end

o = s:option(Value, "up_kbit", translate("上传限速"))
o.placeholder = "256k"
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
o.placeholder = "1024k"
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


