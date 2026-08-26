# HE IPv6 Switch

一个交互式 Linux 脚本，用于在 **HE Tunnel Broker IPv6** 与 VPS 原生 IPv6 之间切换。

启用 HE 模式时，它会：

- 创建 IPv6-in-IPv4（SIT / IP 协议 41）隧道；
- 使用 HE 分配的 Routed `/48`（或 `/64`）中的一个地址作为 VPS 对外 IPv6；
- 禁用公网网卡上的原生 IPv6，从而让 IPv6 默认入站/出站使用 HE；
- 安装 systemd 服务，重启后自动恢复 HE 模式。

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

然后在 VPS 上运行：

```bash
sudo bash he-ipv6-switch.sh
```

按菜单选择“启用 / 重新配置 HE 独占 IPv6”。日后再次运行同一脚本，选择“恢复原生 IPv6”即可切回。

## 前置条件与注意事项

- 系统须为使用 systemd 和 iproute2 的 Linux（例如 Debian、Ubuntu）。
- VPS 的 IPv4 必须为固定的公网 IPv4，且与 HE 后台登记的 Client IPv4 完全一致。
- 云厂商安全组、VPS 防火墙和上游网络须允许 **IP 协议 41**；这不是 TCP/UDP 的 41 端口。
- 脚本不会放开 IPv6 防火墙。启用后，若你希望让 SSH、Web 等服务可从 IPv6 访问，需确保现有防火墙有相应的 IPv6 规则。
- HE SIT 隧道不是加密隧道。业务数据仍应使用 HTTPS、SSH、WireGuard 等端到端加密。
- 恢复原生 IPv6 后，SLAAC 或 DHCPv6 的地址和默认路由可能需要数秒出现。

## 安全边界

启用模式会禁用**当前 IPv4 默认路由所在公网网卡**的原生 IPv6。它不更改 IPv4，不重置网络配置，也不修改防火墙。若你的机器有多个公网 IPv6 网卡、复杂策略路由或容器网络，请先在测试 VPS 上验证。
