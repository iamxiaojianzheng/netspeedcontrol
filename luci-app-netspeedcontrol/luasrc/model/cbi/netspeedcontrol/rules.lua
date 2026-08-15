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
m.apply_on_parse = true

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

-- 1. 编辑操作列 (放在行开头)
o = s:option(DummyValue, "_edit_btn", translate("编辑"))
o.rawhtml = true
function o.cfgvalue(self, section)
	local name = uci:get("netspeedcontrol", section, "name") or ""
	local mac = uci:get("netspeedcontrol", section, "mac") or ""
	local mode = uci:get("netspeedcontrol", section, "mode") or "block"
	local scope = uci:get("netspeedcontrol", section, "target_scope") or "all"
	local app = uci:get("netspeedcontrol", section, "app_category") or "short_video"
	local doms = uci:get("netspeedcontrol", section, "custom_domains") or ""
	local w = uci:get("netspeedcontrol", section, "weekdays") or "1 2 3 4 5 6 7"
	local start_t = uci:get("netspeedcontrol", section, "start_time") or "21:00"
	local stop_t = uci:get("netspeedcontrol", section, "stop_time") or "07:00"
	local up = nsc.format_rate_display(uci:get("netspeedcontrol", section, "up_kbit"))
	local down = nsc.format_rate_display(uci:get("netspeedcontrol", section, "down_kbit"))

	return string.format([[
		<button type="button" class="cbi-button cbi-button-edit" style="padding: 2px 8px;"
			data-sid="%s" data-name="%s" data-mac="%s" data-mode="%s"
			data-scope="%s" data-app="%s" data-domains="%s" data-weekdays="%s"
			data-start="%s" data-stop="%s" data-up="%s" data-down="%s"
			onclick="openEditRuleModal(this)">
			%s
		</button>
	]], section, pcdata(name), pcdata(mac), pcdata(mode),
	    pcdata(scope), pcdata(app), pcdata(doms), pcdata(w),
	    pcdata(start_t), pcdata(stop_t), pcdata(up), pcdata(down),
	    translate("修改"))
end

-- 2. 状态开关
o = s:option(Flag, "enabled", translate("状态"))
o.rmempty = true

-- 3. 规则名称
o = s:option(DummyValue, "name", translate("规则名称"))
function o.cfgvalue(self, section)
	return uci:get("netspeedcontrol", section, "name") or "未命名"
end

-- 受控设备
o = s:option(DummyValue, "mac", translate("受控设备"))
function o.cfgvalue(self, section)
	local mac = nsc.normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")
	if mac == "" then return "未知设备" end
	for _, dev in ipairs(online_devices) do
		if dev.mac == mac then
			return nsc.device_label(dev)
		end
	end
	return nsc.saved_device_label(mac)
end

-- 控制方式
o = s:option(DummyValue, "mode", translate("控制方式"))
o.rawhtml = true
function o.cfgvalue(self, section)
	local mode = uci:get("netspeedcontrol", section, "mode") or "block"
	if mode == "block" then
		return '<span style="color:#e53e3e; font-weight:bold;">[ 定时断网 ]</span>'
	else
		return '<span style="color:#3182ce; font-weight:bold;">[ 定时限速 ]</span>'
	end
end

-- 控制范围
o = s:option(DummyValue, "target_scope", translate("控制范围"))
function o.cfgvalue(self, section)
	local scope = uci:get("netspeedcontrol", section, "target_scope") or "all"
	if scope == "all" then
		return "全网流量"
	elseif scope == "app" then
		local app = uci:get("netspeedcontrol", section, "app_category") or "short_video"
		local app_names = { short_video="短视频/直播", gaming="网络游戏", video="影视视频", social="社交聊天" }
		return "指定应用 (" .. (app_names[app] or app) .. ")"
	elseif scope == "custom_domain" then
		local doms = uci:get("netspeedcontrol", section, "custom_domains") or ""
		return "自定义域名 (" .. (doms ~= "" and doms or "未设置") .. ")"
	end
	return "全网流量"
end

-- 生效时间
o = s:option(DummyValue, "time_range", translate("生效时间"))
function o.cfgvalue(self, section)
	local start_t = uci:get("netspeedcontrol", section, "start_time") or "21:00"
	local stop_t = uci:get("netspeedcontrol", section, "stop_time") or "07:00"
	local w = uci:get("netspeedcontrol", section, "weekdays") or "1 2 3 4 5 6 7"
	local day_map = { ["1"]="一", ["2"]="二", ["3"]="三", ["4"]="四", ["5"]="五", ["6"]="六", ["7"]="日" }
	local days = {}
	for d in w:gmatch("%d") do
		table.insert(days, day_map[d] or d)
	end
	local day_str = (#days > 0) and ("周" .. table.concat(days, "/")) or "每日"
	return string.format("%s (%s-%s)", day_str, start_t, stop_t)
end

-- 限速数据
o = s:option(DummyValue, "rate_limit", translate("限速数据"))
function o.cfgvalue(self, section)
	local mode = uci:get("netspeedcontrol", section, "mode") or "block"
	if mode ~= "limit" then return "-" end
	local up = nsc.format_rate_display(uci:get("netspeedcontrol", section, "up_kbit"))
	local down = nsc.format_rate_display(uci:get("netspeedcontrol", section, "down_kbit"))
	return string.format("↑ %s / ↓ %s", up ~= "" and up or "无限制", down ~= "" and down or "无限制")
end

return m
