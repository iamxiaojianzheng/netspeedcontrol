#!/bin/sh

set -e

REPO="iamxiaojianzheng/netspeedcontrol"
TMP_DIR="/tmp/netspeedcontrol_install"

echo "========================================="
echo " Installing/Updating luci-app-netspeedcontrol "
echo "========================================="

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请以 root 权限运行此脚本！" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
    echo "错误: 需要 curl 或 wget 工具，请先安装！" >&2
    exit 1
}

mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

echo "正在从 GitHub Release 获取最新版本..."
RELEASE_API="https://api.github.com/repos/${REPO}/releases/latest"

DOWNLOAD_URL=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_URL=$(curl -sL "$RELEASE_API" | grep "browser_download_url.*\.ipk" | head -n 1 | cut -d '"' -f 4 || true)
else
    DOWNLOAD_URL=$(wget -qO- "$RELEASE_API" | grep "browser_download_url.*\.ipk" | head -n 1 | cut -d '"' -f 4 || true)
fi

if [ -z "$DOWNLOAD_URL" ]; then
    echo "未能从 GitHub Releases 找不到 IPK 下载地址，尝试使用直链..."
    DOWNLOAD_URL="https://github.com/iamxiaojianzheng/netspeedcontrol/releases/latest/download/luci-app-netspeedcontrol_0.1.0-31_all.ipk"
fi

IPK_FILE="${TMP_DIR}/luci-app-netspeedcontrol.ipk"

echo "下载安装包: $DOWNLOAD_URL"
if command -v curl >/dev/null 2>&1; then
    curl -sL "$DOWNLOAD_URL" -o "$IPK_FILE"
else
    wget -qO "$IPK_FILE" "$DOWNLOAD_URL"
fi

echo "正在安装 luci-app-netspeedcontrol..."
opkg install "$IPK_FILE"

rm -rf "$TMP_DIR"

echo "刷新 LuCI 服务..."
if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi
if [ -x /etc/init.d/nginx ]; then
    /etc/init.d/nginx restart >/dev/null 2>&1 || true
fi

echo "========================================="
echo " 安装完成！请在 LuCI 菜单 [网络] -> [设备上网控制] 查看。"
echo "========================================="
