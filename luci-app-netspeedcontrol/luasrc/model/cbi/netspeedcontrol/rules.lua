local uci = require("luci.model.uci").cursor()
local nsc
local ok, m = pcall(require, "luci.model.cbi.netspeedcontrol.tools")
if ok then
	nsc = m
else
	nsc = require "luci.tools.netspeedcontrol"
end
local TypedSection = TypedSection or luci.cbi.TypedSection

local online_devices = nsc.load_online_devices()
local m, s, o

m = Map("netspeedcontrol", translate("设备上网控制 - 规则管理"))
m.description = translate("通过表格管理已有规则。点击右上角 [ + 新增控制规则 ] 按钮可通过弹窗进行规则添加。")

function m.on_after_commit(self)
	nsc.apply_now()
end

-- 顶部 Modal 弹窗 Header 组件
s_header = m:section(TypedSection, "globals")
s_header.anonymous = true

o_modal = s_header:option(DummyValue, "_rule_modal_panel")
o_modal.rawhtml = true
o_modal.template = "netspeedcontrol/rules_modal"

-- 主表格 Section 规则展示
s = m:section(TypedSection, "rule", translate("已配置规则"))
s.addremove = true
s.anonymous = true
s.template = "cbi/tblsection"

o = s:option(Flag, "enabled", translate("启用"))
o.rmempty = true

o = s:option(Value, "name", translate("规则名称"))
o.placeholder = "KidPhone"
o.rmempty = true

o = s:option(ListValue, "mac", translate("受控设备"))
o:value("", translate("请选择设备"))
o:value("CUSTOM", translate("[+] 手动填写 MAC..."))
o.rmempty = true

for _, device in ipairs(online_devices) do
	o:value(device.mac, nsc.device_label(device))
end

function o.cfgvalue(self, section)
	local current_mac = nsc.normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")
	if current_mac ~= "" then
		if not nsc.has_online_device(online_devices, current_mac) then
			nsc.ensure_option_value(self, current_mac, nsc.saved_device_label(current_mac))
		end
		return current_mac
	end
	return ""
end

function o.write(self, section, value)
	local custom_mac = nsc.normalize_mac(self.map:formvalue("cbid.netspeedcontrol." .. section .. "._custom_mac") or "")
	local selected_mac = nsc.normalize_mac(value or "")
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
	local current_mac = nsc.normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")
	if current_mac ~= "" and not nsc.has_online_device(online_devices, current_mac) then
		return current_mac
	end
	return ""
end

o = s:option(ListValue, "mode", translate("控制方式"))
o:value("block", translate("定时断网"))
o:value("limit", translate("定时限速"))
o.default = "block"
o.rmempty = true

o = s:option(ListValue, "target_scope", translate("控制范围"))
o:value("all", translate("全网流量"))
o:value("app", translate("指定应用"))
o:value("custom_domain", translate("自定义域名"))
o.default = "all"
o.rmempty = true

o = s:option(ListValue, "app_category", translate("应用分类"))
o:value("short_video", translate("短视频/直播"))
o:value("gaming", translate("网络游戏"))
o:value("video", translate("影视视频"))
o:value("social", translate("社交聊天"))
o.default = "short_video"
o:depends("target_scope", "app")

o = s:option(Value, "custom_domains", translate("自定义域名"))
o.placeholder = "例如: baidu.com tieba.baidu.com"
o:depends("target_scope", "custom_domain")

o = s:option(Value, "weekdays", translate("生效星期"))
o.placeholder = "1 2 3 4 5 6 7"
o.default = "1 2 3 4 5 6 7"

o = s:option(Value, "start_time", translate("开始时间"))
o.placeholder = "21:00"
o.default = "21:00"
o.rmempty = true

function o.cfgvalue(self, section)
	local v = uci:get("netspeedcontrol", section, "start_time")
	return (v and v ~= "") and v or "21:00"
end

function o.validate(self, value, section)
	if section and self.map:formvalue("cbi.del." .. self.config .. "." .. section) then
		return value
	end
	if not value or value == "" then
		return "21:00"
	end
	local v = value:gsub("^%s*(.-)%s*$", "%1")
	if v == "" then
		return "21:00"
	end
	if not v:match("^([01]%d|2[0-3]):[0-5]%d$") then
		return nil, translate("开始时间格式错误，请输入标准的 24 小时制时间，例如 21:00！")
	end
	return v
end

o = s:option(Value, "stop_time", translate("结束时间"))
o.placeholder = "07:00"
o.default = "07:00"
o.rmempty = true

function o.cfgvalue(self, section)
	local v = uci:get("netspeedcontrol", section, "stop_time")
	return (v and v ~= "") and v or "07:00"
end

function o.validate(self, value, section)
	if section and self.map:formvalue("cbi.del." .. self.config .. "." .. section) then
		return value
	end
	if not value or value == "" then
		return "07:00"
	end
	local v = value:gsub("^%s*(.-)%s*$", "%1")
	if v == "" then
		return "07:00"
	end
	if not v:match("^([01]%d|2[0-3]):[0-5]%d$") then
		return nil, translate("结束时间格式错误，请输入标准的 24 小时制时间，例如 07:00！")
	end
	return v
end

o = s:option(Value, "up_kbit", translate("上传限速"))
o.placeholder = "256k"
o:depends("mode", "limit")

function o.validate(self, value, section)
	if section and self.map:formvalue("cbi.del." .. self.config .. "." .. section) then
		return value
	end
	if not value or value == "" then return "" end
	local parsed = nsc.parse_rate_value(value)
	if not parsed then
		return nil, translate("上传限速数值无效！支持填写数字（如 256）或带单位字符串（如 512k, 1M）。")
	end
	return tostring(parsed)
end

o = s:option(Value, "down_kbit", translate("下载限速"))
o.placeholder = "1024k"
o:depends("mode", "limit")

function o.validate(self, value, section)
	if section and self.map:formvalue("cbi.del." .. self.config .. "." .. section) then
		return value
	end
	if not value or value == "" then return "" end
	local parsed = nsc.parse_rate_value(value)
	if not parsed then
		return nil, translate("下载限速数值无效！支持填写数字（如 1024）或带单位字符串（如 1M, 2M）。")
	end
	return tostring(parsed)
end

return m
