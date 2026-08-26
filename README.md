# HE IPv6 Switch

一个交互式 Linux 脚本，用于在 **HE Tunnel Broker IPv6** 与 VPS 原生 IPv6 之间切换。

启用 HE 模式时，它会：

- 创建 IPv6-in-IPv4（SIT / IP 协议 41）隧道；
- 使用 HE 分配的 Routed `/48`（或 `/64`）中的一个地址作为 VPS 对外 IPv6；
- 禁用公网网卡上的原生 IPv6，从而让 IPv6 默认入站/出站使用 HE；
- 安装 systemd 服务，重启后自动恢复 HE 模式。

若系统已经启用 `vps-security-bootstrap` v1.3.8 或更新版本的 nftables 防火墙，脚本会自动识别它，并仅放行当前 HE `Server IPv4 Address` 发来的 IPv4 协议 41（SIT）流量。换 HE 节点时会先加入新端点、成功后删除旧端点；恢复原生 IPv6 时会删除本脚本创建的该白名单。未检测到兼容且已启用的防火墙时，脚本不会修改任何防火墙规则。

这条自动规则只写入 `/etc/vps-security/nftables-input.d/50-he-ipv6-switch.nft`，不会改 SSH、TCP/UDP 放行端口或其他规则。没有使用 Bootstrap 的 VPS 不会因此出现新端口、新协议或额外防火墙策略；HE 脚本会仅配置隧道，并由你现有的防火墙/云安全组决定协议 41 是否可通过。

选择“恢复原生 IPv6”时，它会停用 HE 隧道并将该网卡恢复至之前的 IPv6 开关状态。IPv4 不会被修改。
即使 HE 服务此前异常停止，恢复操作也会再次执行清理，避免原生 IPv6 保持误禁用。

## 使用

先在 [HE Tunnel Broker](https://tunnelbroker.net/) 创建隧道。运行时从 Tunnel Details 页面依次填写：

- Server IPv4 Address
- Server IPv6 Address（脚本保存作核对）
- Client IPv4 Address
- Client IPv6 Address
- Routed /64
- Routed /48（若 HE 已分配）

### 直接在 VPS 下载并运行

以 `root` 登录 VPS 后，复制**整行**执行。它会先下载脚本，再立即打开中文交互菜单；`&&` 确保下载失败时不会继续执行：

```bash
curl -fsSLo /root/he-ipv6-switch.sh https://github.com/elonjack/he-ipv6-switch/releases/latest/download/he-ipv6-switch.sh && bash /root/he-ipv6-switch.sh
```

若系统没有 `curl`，可使用：

```bash
wget -O /root/he-ipv6-switch.sh https://github.com/elonjack/he-ipv6-switch/releases/latest/download/he-ipv6-switch.sh && bash /root/he-ipv6-switch.sh
```

已下载过脚本时，直接运行：

```bash
bash /root/he-ipv6-switch.sh
```

按菜单选择“启用 / 重新配置 HE 独占 IPv6”。日后再次运行同一脚本，选择“恢复原生 IPv6”即可切回。

当脚本提示“从 Routed 前缀中选一个给 VPS 使用的 HE IPv6”时，直接按回车即可。脚本会默认使用该前缀内的 `::1` 地址；也可以手动输入该前缀内的其他未使用地址。

## HE 页面字段对照

在 HE 的 **Tunnel Details** 页面照抄下表字段。脚本会在写入前校验 IPv4、IPv6、前缀长度和所选业务地址归属，填错不会继续执行。

| 脚本提示 | 应填写的 HE 字段 | 格式 |
| --- | --- | --- |
| `Server IPv4 Address` | Server IPv4 Address | 纯 IPv4，例如 `216.66.x.x`。 |
| `Server IPv6 Address（仅核对，会保存）` | Server IPv6 Address | 纯 IPv6，**不带** `/64`；不作为网关使用。 |
| `Client IPv4 Address` | Client IPv4 Address | 默认自动探测 IPv4，必须与 HE 后台登记值完全一致。 |
| `Client IPv6 Address` | Client IPv6 Address | 例如 `2001:470:xxxx::2/64`，必须带 `/64`，不能填 `/48`。 |
| `Routed /64` | Routed /64 | 网络前缀，例如 `2001:470:xxxx:62a::/64`。 |
| `Routed /48` | Routed /48 | 有就填写，例如 `2001:470:abcd::/48`；没有直接回车。 |

有 `/48` 时默认推荐选 `/48`。业务地址提示处直接回车即可取该前缀的第一个地址（通常为 `…::1`）；手填时必须是该 Routed 前缀中尚未使用的 IPv6。

## Bootstrap 防火墙联动（可选）

推荐在新 VPS 上先运行最新版 [vps-security-bootstrap](https://github.com/elonjack/vps-security-bootstrap) 并启用其防火墙，再运行本脚本。已安装较早 Bootstrap 的机器，应先升级 Bootstrap，并在其防火墙菜单选择 `4` 重新启用/生成规则，之后 HE 脚本会自动识别；不需要额外输入 nft 命令。

检测到兼容且正在运行的 Bootstrap 防火墙后，本脚本会：

1. 仅允许 `HE Server IPv4` 的 IPv4 **IP 协议 41** 入站；这不是 TCP/UDP 41 端口。
2. 换 HE 节点时，先临时允许旧、新两个 HE 端点，新的隧道启动成功后收敛为新端点。
3. 重启后通过 Bootstrap 的持久化规则入口继续生效。
4. 选择“恢复原生 IPv6”时，只删除本脚本自己的协议 41 白名单。

未检测到 Bootstrap 时，脚本不会猜测或改写其他防火墙。请自行确认云安全组、厂商网络和本机防火墙允许 IP 协议 41。

## 启用后验证

```bash
systemctl status he-ipv6-switch --no-pager
ip -6 addr show dev he-ipv6
ip -6 route show
curl -6 https://ifconfig.co
```

已启用 Bootstrap 联动时，可额外核对严格白名单：

```bash
cat /etc/vps-security/nftables-input.d/50-he-ipv6-switch.nft
nft list table inet vps_security_bootstrap
```

若服务启动失败（例如 HE 参数错误或协议 41 被拦截），脚本会清理本次隧道、HE 路由和本脚本的白名单，并重新启用原生 IPv6；IPv4 不会改变。

## 前置条件与注意事项

- 系统须为使用 systemd 和 iproute2 的 Linux（例如 Debian、Ubuntu）。
- VPS 的 IPv4 必须为固定的公网 IPv4，且与 HE 后台登记的 Client IPv4 完全一致。
- 云厂商安全组、VPS 防火墙和上游网络须允许 **IP 协议 41**；这不是 TCP/UDP 的 41 端口。
- 脚本不会放开 IPv6 防火墙。启用后，若你希望让 SSH、Web 等服务可从 IPv6 访问，需确保现有防火墙有相应的 IPv6 规则。
- HE SIT 隧道不是加密隧道。业务数据仍应使用 HTTPS、SSH、WireGuard 等端到端加密。
- 恢复原生 IPv6 后，SLAAC 或 DHCPv6 的地址和默认路由可能需要数秒出现。
- 通过 IPv4 SSH 连接时，启用 HE 不会改 IPv4 地址、路由或 SSH；若你当前只通过原生 IPv6 SSH，请保留厂商控制台或另一个 IPv4 会话。
- HE 地址段的“干净度”不能保证，且 HE 延迟取决于 VPS 到所选 HE 节点的实际路径，可能优于也可能劣于原生 IPv6。

## 安全边界

启用模式会禁用**当前 IPv4 默认路由所在公网网卡**的原生 IPv6。它不更改 IPv4，不重置网络配置；只有在检测到兼容且已启用的 Bootstrap 防火墙时，才会管理上述单条协议 41 白名单。原生 IPv6 被关闭不代表 IPv6 服务自动安全：仍应使用 IPv6 防火墙并仅放行需要的服务。若机器有多个公网 IPv6 网卡、复杂策略路由或容器网络，请先在测试 VPS 上验证。
