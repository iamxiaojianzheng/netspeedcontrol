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

PROXY="${GITHUB_PROXY:-}"
if [ -n "$PROXY" ]; then
    PROXY="${PROXY%/}/"
    echo "使用 GitHub 加速代理: $PROXY"
fi

echo "正在从 GitHub Release 获取最新版本信息..."
RELEASE_API="https://api.github.com/repos/${REPO}/releases/latest"

RAW_DOWNLOAD_URL=""
if command -v curl >/dev/null 2>&1; then
    RAW_DOWNLOAD_URL=$(curl -sL --connect-timeout 8 "$RELEASE_API" | grep "browser_download_url.*\.ipk" | head -n 1 | cut -d '"' -f 4 || true)
else
    RAW_DOWNLOAD_URL=$(wget -qO- --timeout=8 "$RELEASE_API" | grep "browser_download_url.*\.ipk" | head -n 1 | cut -d '"' -f 4 || true)
fi

if [ -n "$RAW_DOWNLOAD_URL" ]; then
    DOWNLOAD_URL="${PROXY}${RAW_DOWNLOAD_URL}"
else
    echo "警告: 无法获取最新 Release 下载地址，尝试使用直链..."
    DOWNLOAD_URL="${PROXY}https://github.com/iamxiaojianzheng/netspeedcontrol/releases/download/v0.2.3-22/luci-app-netspeedcontrol_0.2.3-22_all.ipk"
fi

IPK_FILE="${TMP_DIR}/luci-app-netspeedcontrol.ipk"

echo "正在下载安装包: $DOWNLOAD_URL"
if command -v curl >/dev/null 2>&1; then
    curl -sL "$DOWNLOAD_URL" -o "$IPK_FILE"
else
    wget -qO "$IPK_FILE" "$DOWNLOAD_URL"
fi

# 检验下载文件是否有效（非 HTML 报错页面且非空）
if [ ! -s "$IPK_FILE" ] || grep -qi "<html" "$IPK_FILE" 2>/dev/null; then
    echo "错误: 下载安装包失败！下载的文件为错误页面或为空。" >&2
    echo "提示: 请检查当前加速代理是否可用，或去掉 GITHUB_PROXY 环境变量后重试。" >&2
    rm -rf "$TMP_DIR"
    exit 1
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
