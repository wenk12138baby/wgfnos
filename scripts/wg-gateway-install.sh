#!/bin/bash
#
# WireGuard 中转网关 · VPS 一键部署脚本
#
# 用途：在用户自己的 VPS 上部署一个 WireGuard 网关，
#       供「打不了洞（无公网 IP / 严格 NAT）」的 NAS 用户做中转。
#
# 用法（用户在 VPS 终端粘贴执行）：
#   curl -fsSL <分发地址>/wg-gateway-install.sh | sudo bash
#
# 脚本会：
#   1. 安装 WireGuard
#   2. 生成网关密钥对
#   3. 开启 IP 转发 + NAT
#   4. 输出配置信息（用户复制回 NAS 管理页）
#
# 输出格式：末尾打印一段 JSON，包含公钥、IP、端口，供用户复制。
#
set -euo pipefail

# ============================================================
# 可配置项（可用环境变量覆盖）
# ============================================================
GATEWAY_PORT="${GATEWAY_PORT:-12137}"          # 网关监听端口（UDP）
VPN_NET="${VPN_NET:-10.9.0.0/24}"              # VPN 网段
VPN_GW="${VPN_GW:-10.9.0.1}"                   # 网关 IP
WG_IFACE="wg0"
WG_DIR="/etc/wireguard"

# ============================================================
# 输出辅助
# ============================================================
_RED='\033[0;31m'; _GRN='\033[0;32m'; _YLW='\033[1;33m'; _BLU='\033[0;36m'; _NC='\033[0m'
info()  { printf "${_BLU}[信息]${_NC} %s\n" "$*"; }
ok()    { printf "${_GRN}[成功]${_NC} %s\n" "$*"; }
warn()  { printf "${_YLW}[警告]${_NC} %s\n" "$*"; }
die()   { printf "${_RED}[错误]${_NC} %s\n" "$*" >&2; exit 1; }

# ============================================================
# 0. 前置检查
# ============================================================
[ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash $0"

# 检测系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    info "系统: ${PRETTY_NAME:-$ID}"
else
    die "无法识别系统"
fi

# ============================================================
# 1. 安装 WireGuard
# ============================================================
info "安装 WireGuard..."
if command -v wg >/dev/null 2>&1; then
    ok "WireGuard 已安装"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq wireguard wireguard-tools || die "安装失败"
    ok "WireGuard 安装完成"
fi

# 加载内核模块
modprobe wireguard 2>/dev/null || true
ok "内核模块就绪"

# ============================================================
# 2. 生成密钥
# ============================================================
info "生成网关密钥..."
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

if [ ! -f "$WG_DIR/gateway.key" ]; then
    umask 077
    wg genkey > "$WG_DIR/gateway.key"
    chmod 600 "$WG_DIR/gateway.key"
fi
GATEWAY_PRIV="$(cat "$WG_DIR/gateway.key")"
GATEWAY_PUB="$(echo "$GATEWAY_PRIV" | wg pubkey)"
echo "$GATEWAY_PUB" > "$WG_DIR/gateway.pub"
ok "网关公钥: $GATEWAY_PUB"

# ============================================================
# 3. 写配置（初始只有 Interface，peer 由 NAS 上报后添加）
# ============================================================
info "写入配置..."
cat > "$WG_DIR/${WG_IFACE}.conf" <<WGCONF
[Interface]
Address = ${VPN_GW}/24
ListenPort = ${GATEWAY_PORT}
PrivateKey = ${GATEWAY_PRIV}
WGCONF
chmod 600 "$WG_DIR/${WG_IFACE}.conf"
ok "配置已写入（端口 ${GATEWAY_PORT}）"

# ============================================================
# 4. 开启 IP 转发 + NAT
# ============================================================
info "开启 IP 转发..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null || true

# NAT：让 VPN 网段能访问外网（以及转发到其他 peer）
IFACE=$(ip -4 route | awk '/default/{print $5; exit}')
if [ -n "$IFACE" ]; then
    iptables -t nat -C POSTROUTING -s "$VPN_NET" -o "$IFACE" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$VPN_NET" -o "$IFACE" -j MASQUERADE
    ok "NAT 已配置（出口 $IFACE）"
else
    warn "未检测到默认网卡，NAT 可能需手动配置"
fi

# ============================================================
# 5. 启动接口
# ============================================================
info "启动接口..."
ip link del dev "$WG_IFACE" 2>/dev/null || true
ip link add dev "$WG_IFACE" type wireguard
wg setconf "$WG_IFACE" "$WG_DIR/${WG_IFACE}.conf"
ip address add "${VPN_GW}/24" dev "$WG_IFACE" 2>/dev/null || true
ip link set "$WG_IFACE" up
ok "接口已启动"

# ============================================================
# 6. 开机自启（写入 rc.local 或 systemd）
# ============================================================
info "配置开机自启..."
cat > /etc/systemd/system/wg-gateway.service <<SYSD
[Unit]
Description=WireGuard Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'ip link add dev ${WG_IFACE} type wireguard 2>/dev/null; wg setconf ${WG_IFACE} ${WG_DIR}/${WG_IFACE}.conf; ip address add ${VPN_GW}/24 dev ${WG_IFACE} 2>/dev/null; ip link set ${WG_IFACE} up'
ExecStop=/bin/bash -c 'ip link del dev ${WG_IFACE} 2>/dev/null'

[Install]
WantedBy=multi-user.target
SYSD
systemctl enable wg-gateway.service >/dev/null 2>&1 || true
ok "开机自启已配置"

# ============================================================
# 7. 获取公网 IP
# ============================================================
info "获取公网 IP..."
PUBLIC_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip"; do
    PUBLIC_IP="$(curl -fsS --max-time 6 "$url" 2>/dev/null || true)"
    [ -n "$PUBLIC_IP" ] && break
done
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="<请手动填写VPS公网IP>"
    warn "无法自动获取公网 IP"
fi
ok "公网 IP: $PUBLIC_IP"

# ============================================================
# 8. 输出配置（用户复制回 NAS 管理页）
# ============================================================
echo ""
echo "========================================================"
echo "  WireGuard 中转网关部署完成"
echo "========================================================"
echo ""
echo "  网关公钥: $GATEWAY_PUB"
echo "  公网 IP:  $PUBLIC_IP"
echo "  监听端口: $GATEWAY_PORT (UDP)"
echo "  VPN 网段: $VPN_NET"
echo "  网关 IP:  $VPN_GW"
echo ""
echo "  ⚠️  请在你的 VPS 防火墙/安全组放行 UDP ${GATEWAY_PORT} 端口"
echo ""
echo "  === 请复制下面这段，粘贴回 NAS 管理页面 === "
echo "-----BEGIN-WG-GATEWAY-----"
echo "{\"publicKey\":\"${GATEWAY_PUB}\",\"publicIP\":\"${PUBLIC_IP}\",\"listenPort\":${GATEWAY_PORT},\"vpnNet\":\"${VPN_NET}\",\"vpnGateway\":\"${VPN_GW}\"}"
echo "-----END-WG-GATEWAY-----"
echo ""
