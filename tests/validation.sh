#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/he-ipv6-switch.sh"

run_function() {
  # shellcheck disable=SC1090
  bash -c 'source "$1"; shift; "$@"' -- "$SCRIPT" "$@"
}

expect_success() {
  "$@" >/dev/null || { printf '应成功，但失败：%s\n' "$*" >&2; exit 1; }
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    printf '应失败，但成功：%s\n' "$*" >&2
    exit 1
  fi
}

expect_success run_function valid_ipv4 216.66.22.2
expect_failure run_function valid_ipv4 999.66.22.2
expect_failure run_function valid_ipv4 216.66.22

expect_success run_function valid_ipv6 2001:470:1:62a::1
expect_success run_function valid_ipv6 2001:0470:0001:062a:0000:0000:0000:0001
expect_failure run_function valid_ipv6 2001:::1
expect_failure run_function valid_ipv6 2001:470:1:62a::1::2

expect_success run_function valid_cidr_length 2001:470:1:62a::2/64 64
expect_failure run_function valid_cidr_length 2001:470:1:62a::2/48 64
expect_success run_function valid_network_cidr 2001:470:abcd::/48 48
expect_failure run_function valid_network_cidr 2001:470:abcd::1/48 48
expect_success run_function ipv6_in_cidr 2001:470:abcd::1 2001:470:abcd::/48
expect_failure run_function ipv6_in_cidr 2001:470:abce::1 2001:470:abcd::/48

[ "$(run_function default_host_for_prefix 2001:470:abcd::/48)" = '2001:470:abcd::1' ] || {
  printf '默认 HE 地址错误。\n' >&2
  exit 1
}

printf 'HE IPv6 输入校验测试通过。\n'
