#!/usr/bin/env bash
# HE IPv6 Switch: use a Hurricane Electric tunnel exclusively, then restore native IPv6.
# Requires: Linux, systemd, iproute2, root. Tested design target: Debian/Ubuntu VPS.
set -Eeuo pipefail

APP_NAME="HE IPv6 一键切换"
INSTALL_PATH="/usr/local/sbin/he-ipv6-switch"
CONFIG_FILE="/etc/he-ipv6-switch.conf"
UP_SCRIPT="/usr/local/lib/he-ipv6-switch/up"
DOWN_SCRIPT="/usr/local/lib/he-ipv6-switch/down"
SERVICE_FILE="/etc/systemd/system/he-ipv6-switch.service"
IFACE="he-ipv6"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  YELLOW='\033[1;33m'
  RED='\033[1;31m'
  RESET='\033[0m'
else
  YELLOW=''
  RED=''
  RESET=''
fi

say() { printf '%b%s%b\n' "$YELLOW" "$*" "$RESET"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
need_root() { [ "${EUID}" -eq 0 ] || die "请用 root 运行：sudo bash $0"; }
ask() {
  local label="$1" default="${2:-}" answer
  if [ -n "$default" ]; then
    printf '%b%s [%s]: %b' "$YELLOW" "$label" "$default" "$RESET" >&2
    read -r answer
    printf '%s' "${answer:-$default}"
  else
    printf '%b%s: %b' "$YELLOW" "$label" "$RESET" >&2
    read -r answer
    printf '%s' "$answer"
  fi
}
required() { [ -n "$1" ] || die "该项不能为空。"; }
valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "不是 IPv4 地址：$1"; }
valid_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] || die "不是 IPv6 地址：$1"; }
valid_cidr() {
  [[ "$1" == */* && "$1" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] || die "IPv6 地址或前缀格式错误：$1"
}
have_setup() { [ -f "$CONFIG_FILE" ] && [ -f "$SERVICE_FILE" ]; }

write_helpers() {
  install -d -m 0755 /usr/local/lib/he-ipv6-switch
  cat > "$UP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/he-ipv6-switch.conf

# Build the configured point-to-point SIT tunnel first. Native IPv6 is disabled
# only after the HE default route is usable, so a failed setup does not strand it.
ip tunnel del "$TUNNEL_IFACE" 2>/dev/null || true
ip tunnel add "$TUNNEL_IFACE" mode sit local "$CLIENT_IPV4" remote "$SERVER_IPV4" ttl 255
printf '0' > "/proc/sys/net/ipv6/conf/${TUNNEL_IFACE}/disable_ipv6"
ip link set "$TUNNEL_IFACE" up
ip -6 addr replace "$CLIENT_IPV6_CIDR" dev "$TUNNEL_IFACE"

# The routed /48 or /64 is the actual public address used by this VPS.
ip -6 addr replace "$HE_HOST_IPV6/128" dev lo
ip -6 route replace "$ROUTED_PREFIX" dev "$TUNNEL_IFACE" metric 25
ip -6 route replace default dev "$TUNNEL_IFACE" metric 25 src "$HE_HOST_IPV6"

# Removing IPv6 from the public NIC removes its addresses and native default route.
# IPv4 is untouched. The previous value is restored by the stop/recover action.
printf '1' > "/proc/sys/net/ipv6/conf/${NATIVE_IFACE}/disable_ipv6"
EOF

  cat > "$DOWN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/he-ipv6-switch.conf

# Tear down only resources created by this program, then re-enable the original
# IPv6 stack on the public NIC. DHCP/SLAAC may take a few seconds to repopulate.
ip -6 addr del "$HE_HOST_IPV6/128" dev lo 2>/dev/null || true
ip tunnel del "$TUNNEL_IFACE" 2>/dev/null || true
printf '%s' "$NATIVE_DISABLE_IPV6" > "/proc/sys/net/ipv6/conf/${NATIVE_IFACE}/disable_ipv6" 2>/dev/null || true
EOF
  chmod 0755 "$UP_SCRIPT" "$DOWN_SCRIPT"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=HE IPv6 exclusive tunnel switch
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$UP_SCRIPT
ExecStop=$DOWN_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

enable_he() {
  need_root
  command -v ip >/dev/null || die "未找到 ip 命令，请安装 iproute2。"
  command -v systemctl >/dev/null || die "本脚本需要 systemd。"

  local primary_iface detected_ipv4 native_disabled
  primary_iface="$(ip -o -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [ -n "$primary_iface" ] || die "无法找出 VPS 的 IPv4 默认网卡。"
  detected_ipv4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  native_disabled="$(cat "/proc/sys/net/ipv6/conf/${primary_iface}/disable_ipv6")"

  say ''
  say '请打开 HE Tunnel Details 页面，逐项照抄下列字段。'
  say '「Server IPv6 Address」仅用于核对，系统不需要把它当网关填写。'
  local server_ipv4 server_ipv6 client_ipv4 client_ipv6 routed64 routed48 choice routed_prefix he_host
  server_ipv4="$(ask 'Server IPv4 Address')"
  server_ipv6="$(ask 'Server IPv6 Address（仅核对，会保存）')"
  client_ipv4="$(ask 'Client IPv4 Address（必须与 HE 后台登记完全一致）' "$detected_ipv4")"
  client_ipv6="$(ask 'Client IPv6 Address（例如 2001:470:xxxx::2/64）')"
  routed64="$(ask 'Routed /64（HE 页面所示）')"
  routed48="$(ask 'Routed /48（没有就直接按回车）')"

  required "$server_ipv4"; valid_ipv4 "$server_ipv4"
  required "$server_ipv6"; valid_ipv6 "$server_ipv6"
  required "$client_ipv4"; valid_ipv4 "$client_ipv4"
  required "$client_ipv6"; valid_cidr "$client_ipv6"
  required "$routed64"; valid_cidr "$routed64"
  [ -z "$routed48" ] || valid_cidr "$routed48"

  if [ -n "$routed48" ]; then
    say ''
    say '1) 使用 Routed /48（推荐：地址空间大）'
    say '2) 使用 Routed /64'
    choice="$(ask '选择' '1')"
  else
    choice='2'
  fi
  case "$choice" in
    1) routed_prefix="$routed48" ;;
    2) routed_prefix="$routed64" ;;
    *) die '只能选择 1 或 2。' ;;
  esac
  he_host="$(ask "从 $routed_prefix 中选一个给 VPS 使用的 HE IPv6（不带 /长度，例如 ...::1）")"
  required "$he_host"; valid_ipv6 "$he_host"

  say ''
  say '将执行以下切换：'
  say "  • 隧道：$client_ipv4 → $server_ipv4"
  say "  • 业务 IPv6：$he_host（来自 $routed_prefix）"
  say "  • 禁用网卡 $primary_iface 上的原生 IPv6；所有 IPv6 默认流量改走 HE"
  say '  • IPv4 不会改动；防火墙规则不会被放开。'
  local confirm
  confirm="$(ask '确认启用 HE 独占 IPv6？输入 YES 继续')"
  [ "$confirm" = 'YES' ] || { say '已取消，未修改任何配置。'; return; }

  # If reconfiguring, first restore the last state so old resources cannot linger.
  if have_setup; then
    systemctl disable --now he-ipv6-switch.service 2>/dev/null || true
  fi

  umask 077
  {
    printf 'TUNNEL_IFACE=%q\n' "$IFACE"
    printf 'SERVER_IPV4=%q\n' "$server_ipv4"
    printf 'SERVER_IPV6=%q\n' "$server_ipv6"
    printf 'CLIENT_IPV4=%q\n' "$client_ipv4"
    printf 'CLIENT_IPV6_CIDR=%q\n' "$client_ipv6"
    printf 'ROUTED_PREFIX=%q\n' "$routed_prefix"
    printf 'HE_HOST_IPV6=%q\n' "$he_host"
    printf 'NATIVE_IFACE=%q\n' "$primary_iface"
    printf 'NATIVE_DISABLE_IPV6=%q\n' "$native_disabled"
  } > "$CONFIG_FILE"

  write_helpers
  write_service
  install -m 0755 "$0" "$INSTALL_PATH"
  systemctl daemon-reload
  systemctl enable --now he-ipv6-switch.service
  say ''
  say 'HE 独占 IPv6 已启用，并已设为开机自启。'
  say "当前 HE 业务地址：$he_host"
  say '日后重新运行本脚本，选择菜单 2，即可恢复原生 IPv6。'
}

restore_native() {
  need_root
  if ! have_setup; then
    say '没有发现本脚本创建的 HE 配置，无需恢复。'
    return
  fi
  local confirm
  say '这会停止 HE 隧道、删除 HE 路由，并重新启用原生 IPv6。IPv4 不受影响。'
  confirm="$(ask '确认恢复原生 IPv6？输入 YES 继续')"
  [ "$confirm" = 'YES' ] || { say '已取消。'; return; }
  systemctl disable --now he-ipv6-switch.service
  systemctl daemon-reload
  say '原生 IPv6 已重新启用。若依赖 SLAAC/DHCPv6，地址和默认路由可能需要数秒恢复。'
}

show_status() {
  say ''
  if have_setup; then
    . "$CONFIG_FILE"
    say "已保存的 HE 业务 IPv6：$HE_HOST_IPV6"
    say "路由前缀：$ROUTED_PREFIX"
    say "原生 IPv6 网卡：$NATIVE_IFACE"
    systemctl is-active --quiet he-ipv6-switch.service && say '状态：HE 独占 IPv6 已启用。' || say '状态：已保存配置，但 HE 服务未运行。'
  else
    say '状态：未配置 HE IPv6 Switch。'
  fi
}

main() {
  need_root
  say "========== $APP_NAME =========="
  say '1) 启用 / 重新配置 HE 独占 IPv6'
  say '2) 恢复原生 IPv6（关闭 HE）'
  say '3) 查看状态'
  say '0) 退出'
  local action
  action="$(ask '请选择' '1')"
  case "$action" in
    1) enable_he ;;
    2) restore_native ;;
    3) show_status ;;
    0) exit 0 ;;
    *) die '无效选项。' ;;
  esac
}

main "$@"
