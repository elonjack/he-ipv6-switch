#!/usr/bin/env bash
# HE IPv6 Switch: use a Hurricane Electric tunnel exclusively, then restore native IPv6.
# Requires: Linux, systemd, iproute2, root. Tested design target: Debian/Ubuntu VPS.
set -Eeuo pipefail

APP_NAME="HE IPv6 一键切换"
INSTALL_PATH="/usr/local/sbin/he-ipv6-switch"
CONFIG_FILE="/etc/he-ipv6-switch.conf"
UP_SCRIPT="/usr/local/lib/he-ipv6-switch/up"
DOWN_SCRIPT="/usr/local/lib/he-ipv6-switch/down"
FIREWALL_HELPER="/usr/local/lib/he-ipv6-switch/firewall"
SERVICE_FILE="/etc/systemd/system/he-ipv6-switch.service"
IFACE="he-ipv6"
BOOTSTRAP_FIREWALL_CONFIG="/etc/vps-security/nftables.conf"
BOOTSTRAP_FIREWALL_LOADER="/usr/local/sbin/vps-security-load-firewall"
BOOTSTRAP_FIREWALL_TABLE="vps_security_bootstrap"
BOOTSTRAP_FIREWALL_RULE_FILE="/etc/vps-security/he-protocol41.nft"
BOOTSTRAP_FIREWALL_LEGACY_EXTENSION_DIR="/etc/vps-security/nftables-input.d"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  YELLOW='\033[1;33m'
  RESET='\033[0m'
else
  YELLOW=''
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
valid_ipv4() {
  local candidate=$1 octet
  local -a octets
  IFS=. read -r -a octets <<< "$candidate"
  [ "${#octets[@]}" -eq 4 ] || die "不是 IPv4 地址：$candidate"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$octet))" -le 255 ] || die "不是 IPv4 地址：$candidate"
  done
}

# Convert a conventional IPv6 literal to 32 lowercase hexadecimal digits.
# HE's Tunnel Details fields are IPv6 literals (not IPv4-embedded forms), so
# deliberately accepting only this unambiguous form keeps generated commands safe.
ipv6_to_hex() {
  local candidate=$1 left right part missing output=''
  local -a left_parts=() right_parts=() parts=()
  [[ "$candidate" == *:* && "$candidate" != *':::'* ]] || return 1

  if [[ "$candidate" == *'::'* ]]; then
    left=${candidate%%::*}
    right=${candidate#*::}
    [[ "$right" != *'::'* ]] || return 1
    [ -z "$left" ] || IFS=: read -r -a left_parts <<< "$left"
    [ -z "$right" ] || IFS=: read -r -a right_parts <<< "$right"
    [ "$(( ${#left_parts[@]} + ${#right_parts[@]} ))" -lt 8 ] || return 1
    missing=$((8 - ${#left_parts[@]} - ${#right_parts[@]}))
    parts=("${left_parts[@]}")
    for ((part = 0; part < missing; part++)); do parts+=(0); done
    parts+=("${right_parts[@]}")
  else
    IFS=: read -r -a parts <<< "$candidate"
    [ "${#parts[@]}" -eq 8 ] || return 1
  fi

  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    printf -v part '%04x' "$((16#$part))"
    output+=$part
  done
  printf '%s' "$output"
}

valid_ipv6() { ipv6_to_hex "$1" >/dev/null || die "不是 IPv6 地址：$1"; }
valid_cidr() {
  local candidate=$1 address prefix
  [[ "$candidate" == */* && "${candidate#*/}" != */* ]] || die "IPv6 地址或前缀格式错误：$candidate"
  address=${candidate%/*}
  prefix=${candidate#*/}
  [[ "$prefix" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$prefix))" -le 128 ] || die "IPv6 前缀长度必须在 0 到 128 之间：$candidate"
  valid_ipv6 "$address"
}
valid_cidr_length() {
  local candidate=$1 expected_length=$2
  valid_cidr "$candidate"
  [ "${candidate#*/}" = "$expected_length" ] || die "该地址必须使用 /$expected_length：$candidate"
}
valid_network_cidr() {
  local candidate=$1 expected_length=$2 address prefix hex first_host_nibble remaining
  valid_cidr_length "$candidate" "$expected_length"
  address=${candidate%/*}
  prefix=${candidate#*/}
  hex=$(ipv6_to_hex "$address")
  first_host_nibble=$((prefix / 4))
  remaining=$((prefix % 4))
  if [ "$remaining" -eq 0 ]; then
    [[ "${hex:first_host_nibble}" =~ ^0*$ ]] || die "路由前缀的主机位必须为 0：$candidate"
  else
    [ "$((16#${hex:first_host_nibble:1} & ((1 << (4 - remaining)) - 1)))" -eq 0 ] &&
      [[ "${hex:first_host_nibble+1}" =~ ^0*$ ]] || die "路由前缀的主机位必须为 0：$candidate"
  fi
}
ipv6_in_cidr() {
  local address=$1 cidr=$2 prefix network_hex address_hex full_nibbles remaining
  prefix=${cidr#*/}
  network_hex=$(ipv6_to_hex "${cidr%/*}") || return 1
  address_hex=$(ipv6_to_hex "$address") || return 1
  full_nibbles=$((prefix / 4))
  remaining=$((prefix % 4))
  [ "${address_hex:0:full_nibbles}" = "${network_hex:0:full_nibbles}" ] || return 1
  [ "$remaining" -eq 0 ] || [ "$((16#${address_hex:full_nibbles:1} >> (4 - remaining)))" -eq "$((16#${network_hex:full_nibbles:1} >> (4 - remaining)))" ]
}
default_host_for_prefix() {
  local prefix=$1 base hex
  base=${prefix%/*}
  if [[ "$base" == *'::' ]]; then
    printf '%s1' "$base"
    return
  fi
  hex=$(ipv6_to_hex "$base") || return 1
  printf '%s:%s:%s:%s:%s:%s:%s:1' \
    "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}" \
    "${hex:16:4}" "${hex:20:4}" "${hex:24:4}"
}
have_setup() { [ -f "$CONFIG_FILE" ] && [ -f "$SERVICE_FILE" ]; }
bootstrap_firewall_rule_file() {
  [ -x "$BOOTSTRAP_FIREWALL_LOADER" ] &&
    [ -f "$BOOTSTRAP_FIREWALL_CONFIG" ] &&
    systemctl is-active --quiet nftables &&
    nft list table inet "$BOOTSTRAP_FIREWALL_TABLE" >/dev/null 2>&1 || return 1
  if grep -Fq "include \"$BOOTSTRAP_FIREWALL_RULE_FILE\"" "$BOOTSTRAP_FIREWALL_CONFIG" &&
    [ -f "$BOOTSTRAP_FIREWALL_RULE_FILE" ] && [ ! -L "$BOOTSTRAP_FIREWALL_RULE_FILE" ]; then
    printf '%s' "$BOOTSTRAP_FIREWALL_RULE_FILE"
  elif grep -Fq "include \"$BOOTSTRAP_FIREWALL_LEGACY_EXTENSION_DIR/*.nft\"" "$BOOTSTRAP_FIREWALL_CONFIG" &&
    [ -d "$BOOTSTRAP_FIREWALL_LEGACY_EXTENSION_DIR" ]; then
    printf '%s/50-he-ipv6-switch.nft' "$BOOTSTRAP_FIREWALL_LEGACY_EXTENSION_DIR"
  else
    return 1
  fi
}
bootstrap_firewall_active() {
  bootstrap_firewall_rule_file >/dev/null
}

write_helpers() {
  install -d -m 0755 /usr/local/lib/he-ipv6-switch
  cat > "$FIREWALL_HELPER" <<'EOF'
#!/usr/bin/env bash
# Manage only HE IPv6 Switch's protocol-41 firewall fragment.
set -Eeuo pipefail
. /etc/he-ipv6-switch.conf

CONFIG=/etc/vps-security/nftables.conf
LOADER=/usr/local/sbin/vps-security-load-firewall
TABLE=vps_security_bootstrap
RULE_FILE=/etc/vps-security/he-protocol41.nft
LEGACY_RULE_FILE=/etc/vps-security/nftables-input.d/50-he-ipv6-switch.nft

is_ipv4() {
  local candidate=$1 a b c d extra
  IFS=. read -r a b c d extra <<< "$candidate"
  [ -z "${extra:-}" ] && [ -n "${a:-}" ] && [ -n "${b:-}" ] && [ -n "${c:-}" ] && [ -n "${d:-}" ] || return 1
  for value in "$a" "$b" "$c" "$d"; do
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -le 255 ] || return 1
  done
}

active_rule_file() {
  [ "${BOOTSTRAP_FIREWALL:-0}" = 1 ] &&
    [ -x "$LOADER" ] && [ -f "$CONFIG" ] &&
    systemctl is-active --quiet nftables &&
    nft list table inet "$TABLE" >/dev/null 2>&1 || return 1
  if grep -Fq "include \"$RULE_FILE\"" "$CONFIG" && [ -f "$RULE_FILE" ] && [ ! -L "$RULE_FILE" ]; then
    printf '%s' "$RULE_FILE"
  elif grep -Fq 'include "/etc/vps-security/nftables-input.d/*.nft"' "$CONFIG" && [ -d "${LEGACY_RULE_FILE%/*}" ]; then
    printf '%s' "$LEGACY_RULE_FILE"
  else
    return 1
  fi
}

render_rule() {
  local sources=$1 source nft_sources='' seen=','
  local -a values
  IFS=, read -r -a values <<< "$sources"
  [ "${#values[@]}" -gt 0 ] || return 1
  for source in "${values[@]}"; do
    is_ipv4 "$source" || { printf '无效 HE Server IPv4：%s\n' "$source" >&2; return 1; }
    case "$seen" in *",$source,"*) continue ;; esac
    seen+="$source,"
    nft_sources+="${nft_sources:+, }$source"
  done
  [ -n "$nft_sources" ] || return 1
  printf '# Managed by HE IPv6 Switch. Do not edit; this file is emptied when HE is disabled.\n'
  if [[ "$nft_sources" == *,* ]]; then
    printf 'ip saddr { %s } ip protocol 41 accept comment "HE IPv6 SIT tunnel"\n' "$nft_sources"
  else
    printf 'ip saddr %s ip protocol 41 accept comment "HE IPv6 SIT tunnel"\n' "$nft_sources"
  fi
}

apply_rule() {
  local sources=$1 temporary backup='' active_rule rule_dir
  active_rule=$(active_rule_file) || {
    printf 'vps-security-bootstrap 防火墙未处于兼容且启用的状态，未修改防火墙。\n' >&2
    return 1
  }
  rule_dir=${active_rule%/*}
  install -d -o root -g root -m 0700 "$rule_dir"
  temporary=$(mktemp "$rule_dir/.he-ipv6-switch.nft.XXXXXX")
  render_rule "$sources" > "$temporary"
  chmod 0600 "$temporary"
  if [ -e "$active_rule" ]; then
    backup=$(mktemp "$rule_dir/.he-ipv6-switch.backup.XXXXXX")
    cp -a "$active_rule" "$backup"
  fi
  mv -f "$temporary" "$active_rule"
  if ! "$LOADER"; then
    if [ -n "$backup" ]; then mv -f "$backup" "$active_rule"; else rm -f "$active_rule"; fi
    "$LOADER" 2>/dev/null || true
    printf 'HE 协议 41 白名单重载失败，已恢复原防火墙片段。\n' >&2
    return 1
  fi
  [ -z "$backup" ] || rm -f "$backup"
  # After migration to the fixed rule file, the old path is no longer loaded.
  [ "$active_rule" != "$RULE_FILE" ] || rm -f "$LEGACY_RULE_FILE"
}

remove_rule() {
  local active_rule='' rule_file backup_dir backup_file removed=0
  active_rule=$(active_rule_file || true)
  backup_dir=$(mktemp -d /etc/vps-security/.he-ipv6-switch.remove.XXXXXX) || return 1
  for rule_file in "$RULE_FILE" "$LEGACY_RULE_FILE"; do
    [ -e "$rule_file" ] || continue
    [ -f "$rule_file" ] && [ ! -L "$rule_file" ] || { rm -rf -- "$backup_dir"; return 1; }
    backup_file="$backup_dir/$(basename "$rule_file")"
    cp -a "$rule_file" "$backup_file" || { rm -rf -- "$backup_dir"; return 1; }
    if [ "$rule_file" = "$RULE_FILE" ]; then
      # Bootstrap always includes this exact file; keep it as an empty,
      # root-only file when HE is disabled so a firewall reload stays valid.
      : > "$rule_file"
      chmod 0600 "$rule_file"
    else
      rm -f "$rule_file"
    fi
    removed=1
  done
  [ "$removed" = 1 ] || { rm -rf -- "$backup_dir"; return 0; }
  if [ -n "$active_rule" ]; then
    if ! "$LOADER"; then
      for rule_file in "$RULE_FILE" "$LEGACY_RULE_FILE"; do
        backup_file="$backup_dir/$(basename "$rule_file")"
        [ ! -e "$backup_file" ] || mv -f "$backup_file" "$rule_file"
      done
      "$LOADER" 2>/dev/null || true
      printf '移除 HE 协议 41 白名单失败，已恢复原防火墙片段。\n' >&2
      rm -rf -- "$backup_dir"
      return 1
    fi
  fi
  rm -rf -- "$backup_dir"
}

case "${1:-}" in
  apply) apply_rule "${2:-}" ;;
  remove) remove_rule ;;
  *) printf '用法：%s {apply <HE_Server_IP[,HE_Server_IP]>|remove}\n' "$0" >&2; exit 2 ;;
esac
EOF

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

# If the companion VPS Security Bootstrap firewall is active, install the
# exact HE endpoint's protocol-41 allow rule before removing native IPv6.
if [ "${BOOTSTRAP_FIREWALL:-0}" = 1 ]; then
  /usr/local/lib/he-ipv6-switch/firewall apply "$SERVER_IPV4"
fi

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
  chmod 0755 "$FIREWALL_HELPER" "$UP_SCRIPT" "$DOWN_SCRIPT"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=HE IPv6 exclusive tunnel switch
Wants=network-online.target
After=network-online.target nftables.service

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

  local primary_iface detected_ipv4 native_disabled firewall_backend old_server_ipv4='' old_firewall_backend=0
  primary_iface="$(ip -o -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [ -n "$primary_iface" ] || die "无法找出 VPS 的 IPv4 默认网卡。"
  detected_ipv4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"

  say ''
  say '请打开 HE Tunnel Details 页面，逐项照抄下列字段。'
  say '「Server IPv6 Address」仅用于核对，系统不需要把它当网关填写。'
  local server_ipv4 server_ipv6 client_ipv4 client_ipv6 routed64 routed48 choice routed_prefix default_he_host he_host
  server_ipv4="$(ask 'Server IPv4 Address')"
  server_ipv6="$(ask 'Server IPv6 Address（仅核对，会保存）')"
  client_ipv4="$(ask 'Client IPv4 Address（必须与 HE 后台登记完全一致）' "$detected_ipv4")"
  client_ipv6="$(ask 'Client IPv6 Address（例如 2001:470:xxxx::2/64）')"
  routed64="$(ask 'Routed /64（HE 页面所示）')"
  routed48="$(ask 'Routed /48（没有就直接按回车）')"

  required "$server_ipv4"; valid_ipv4 "$server_ipv4"
  required "$server_ipv6"; valid_ipv6 "$server_ipv6"
  required "$client_ipv4"; valid_ipv4 "$client_ipv4"
  required "$client_ipv6"; valid_cidr_length "$client_ipv6" 64
  required "$routed64"; valid_network_cidr "$routed64" 64
  [ -z "$routed48" ] || valid_network_cidr "$routed48" 48

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
  # The first usable address is a sensible default and avoids manual typo risk.
  # Usually HE displays it as ...::1; a fully expanded but identical address is
  # used only if the pasted prefix was written without a trailing ::.
  default_he_host="$(default_host_for_prefix "$routed_prefix")"
  he_host="$(ask "从 $routed_prefix 中选一个给 VPS 使用的 HE IPv6（直接回车使用默认地址）" "$default_he_host")"
  required "$he_host"; valid_ipv6 "$he_host"
  ipv6_in_cidr "$he_host" "$routed_prefix" || die "该 HE IPv6 不属于所选 Routed 前缀：$he_host"

  if bootstrap_firewall_active; then
    firewall_backend=1
  else
    firewall_backend=0
  fi

  say ''
  say '将执行以下切换：'
  say "  • 隧道：$client_ipv4 → $server_ipv4"
  say "  • 业务 IPv6：$he_host（来自 $routed_prefix）"
  say "  • 禁用网卡 $primary_iface 上的原生 IPv6；所有 IPv6 默认流量改走 HE"
  if [ "$firewall_backend" = 1 ]; then
    say "  • 已检测到 vps-security-bootstrap：将仅允许 $server_ipv4 的协议 41。"
  else
    say '  • 未检测到已启用的兼容防火墙：不会修改防火墙。'
  fi
  local confirm
  confirm="$(ask '确认启用 HE 独占 IPv6？输入 YES 继续')"
  [ "$confirm" = 'YES' ] || { say '已取消，未修改任何配置。'; return; }

  # Add the new HE source before stopping an old tunnel, so an endpoint change
  # never leaves the protocol-41 firewall rule absent during the handover.
  if have_setup; then
    . "$CONFIG_FILE"
    old_server_ipv4="${SERVER_IPV4:-}"
    old_firewall_backend="${BOOTSTRAP_FIREWALL:-0}"
    if [ "$old_firewall_backend" = 1 ] && [ "$firewall_backend" = 1 ]; then
      write_helpers
      "$FIREWALL_HELPER" apply "$old_server_ipv4,$server_ipv4" || die '无法预先添加新 HE 节点的协议 41 白名单，已取消切换。'
    fi
  fi

  # When reconfiguring, restore the previous state first. Reading disable_ipv6
  # afterwards preserves the actual pre-HE value instead of saving HE's "1".
  if have_setup; then
    systemctl disable --now he-ipv6-switch.service 2>/dev/null || true
    "$DOWN_SCRIPT" 2>/dev/null || true
    if [ "$old_firewall_backend" = 1 ] && [ "$firewall_backend" != 1 ]; then
      "$FIREWALL_HELPER" remove || die 'HE 隧道已停止，但移除旧协议 41 白名单失败。'
    fi
  fi
  native_disabled="$(cat "/proc/sys/net/ipv6/conf/${primary_iface}/disable_ipv6")"

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
    printf 'BOOTSTRAP_FIREWALL=%q\n' "$firewall_backend"
  } > "$CONFIG_FILE"

  write_helpers
  write_service
  install -m 0755 "$0" "$INSTALL_PATH"
  systemctl daemon-reload
  if ! systemctl enable --now he-ipv6-switch.service; then
    # Leave the VPS reachable through its pre-existing network if the new
    # tunnel cannot be brought up (for example, protocol 41 is blocked).
    systemctl disable --now he-ipv6-switch.service 2>/dev/null || true
    "$DOWN_SCRIPT" 2>/dev/null || true
    if [ "$firewall_backend" = 1 ]; then
      "$FIREWALL_HELPER" remove 2>/dev/null || true
    fi
    die 'HE 隧道启动失败，已清理隧道、HE 路由和本脚本的协议 41 白名单；原生 IPv6 已重新启用。请检查 HE 参数、云防火墙及 IP 协议 41。'
  fi
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
  . "$CONFIG_FILE"
  # Refresh helpers first so a newer downloaded script can also clean up a
  # firewall fragment created by an older release.
  write_helpers
  local confirm
  say '这会停止 HE 隧道、删除 HE 路由，并重新启用原生 IPv6。IPv4 不受影响。'
  confirm="$(ask '确认恢复原生 IPv6？输入 YES 继续')"
  [ "$confirm" = 'YES' ] || { say '已取消。'; return; }
  systemctl disable --now he-ipv6-switch.service || true
  # If the unit had already failed, systemd may skip ExecStop; run the
  # idempotent cleanup helper once more to guarantee native IPv6 is restored.
  "$DOWN_SCRIPT" || true
  if [ "${BOOTSTRAP_FIREWALL:-0}" = 1 ]; then
    "$FIREWALL_HELPER" remove || die 'HE 隧道已关闭，但移除协议 41 白名单失败；请勿删除该文件并检查 nftables。'
  fi
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
    [ "${BOOTSTRAP_FIREWALL:-0}" = 1 ] && say "防火墙联动：已启用（仅允许 $SERVER_IPV4 的协议 41）" || say '防火墙联动：未启用'
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
