# netspeedcontrol

这是一个用于 ImmortalWrt/OpenWrt 的 LuCI 插件，用来按设备控制上网时间、断网和轻量限速。

插件源码在 `luci-app-netspeedcontrol/` 目录里。

## ⚡ 快速在线安装

在 OpenWrt 终端（SSH）执行以下命令即可自动完成最新版插件的下载与安装：

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/iamxiaojianzheng/netspeedcontrol/main/install.sh)"
```

## 📦 手动安装包

最新打包好的 IPK 文件位于 `dist/` 目录：

```sh
dist/luci-app-netspeedcontrol_0.1.0-31_all.ipk
```

把这个文件上传到路由器的 `/tmp` 目录后安装：

```sh
opkg install /tmp/luci-app-netspeedcontrol_0.1.0-31_all.ipk
```

如果 LuCI 菜单没有马上刷新，可以重启 LuCI Web 服务：

```sh
/etc/init.d/uhttpd restart
```

## ✨ 主要功能

- 中文 LuCI 管理界面。
- 支持从在线设备列表里选择设备。
- 默认按 MAC 地址控制设备。
- 支持按时间段断网。
- 支持轻量级上传/下载限速。
- 基于 firewall4/nftables 下发规则。
- 增加 prerouting/input/forward 多链拦截，尽量减少代理、OpenClash、长连接绕过。
- 支持可选中文拦截日志，并可直接在 LuCI 页面里查看。

## 🛠️ 本地打包

在本仓库目录下执行：

```sh
./build-ipk.sh
```

## ⚙️ CI/CD 自动化构建与 Release

本仓库已配置 GitHub Actions 自动化工作流（`.github/workflows/release.yml`）：
- **自动构建**：分支有 `push` / `pull_request` 时自动校验构建并存档 `.ipk` Artifact。
- **自动发布 Release**：当推送 `v*` 版本的 Tag（如 `v0.1.0`）或在 GitHub 上点击 **Run workflow** 时，会自动生成 Release 并附带编译好的 `.ipk` 包及 `sha256sums` 校验文件。

## ⚙️ SDK 编译

如果要放进 ImmortalWrt/OpenWrt SDK 编译，把 `luci-app-netspeedcontrol/` 目录放进 SDK 的 `package/` 目录，或者放进自定义 feed，然后在 SDK 里编译该包即可。

## 💡 说明与注意

- 当前限速是 nftables `limit ... drop` 轻量限流，不是完整 QoS 整形。
- MAC 规则需要路由器能从 DHCP、ARP 或 IPv6 邻居表解析出设备当前地址。
- 如果设备仍然能绕过限制，请检查路由器是否开启了流量分载、硬件分载或代理旁路规则。
