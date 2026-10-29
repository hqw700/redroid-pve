# ReDroid/PVE IPv4 网络与 DHCP

运行脚本版本：1.1.0；接口：API 1。DHCP 镜像能力：network API 1。

## 职责与实现

- PVE 提供网桥、VLAN 和容器 `eth0`。`net0` 的 `ip=dhcp` 表示自动获取，不能同时设置静态 `gw`。
- 官方配置接口从 `net0` 推导 `androidboot.redroid_net_mode=dhcp`，移除 `host-managed`，避免同时运行两个 DHCP 客户端。
- Android 原生 Ethernet / IpClient / DhcpClient 获取地址、DNS 和路由，执行续租、重绑定、过期撤销和重新获取。
- 容器停止时，网络客户端与其他客体进程一同退出；PVE 删除 veth 和客体网络命名空间。宿主机不启动 dhclient，不写宿主 DNS 或默认路由。客体可能保留正常的租约缓存；缓存不表示该地址当前仍可用。
- 管理台以后只需选择网络模式、读取状态并展示进度。CloudPhone 管理台开发版本已接入此接口，正式使用需部署配套前后端。

管理台接入 DHCP 时，要同时确认运行脚本至少为 1.1.0，并在创建前调用官方模板能力检查。旧运行脚本也返回 `api=1`，不能只检查 API 数字。DHCP 模式不调用静态地址池分配和 ARP 预占流程；创建后按实例 ID 跟踪注册，再回读实际地址。后续 IP 变化不改变实例身份。

旧的 ipconfigstore 总会把启动时看到的地址写为 Android `STATIC` 配置。直接让宿主获取 DHCP，再把租约地址当静态地址交给 Android，会破坏续租和失效处理。PVE 的宿主 DHCP 回调写 Linux `resolv.conf`，也不能代替 Android netd 的 DNS 配置。因此 DHCP 生命周期由 Android 原生网络栈统一负责。

## 镜像补丁与升级

必须一起应用：

1. `0007-native-dhcp-ipconfigstore.patch`：明确区分 DHCP / STATIC，不把租约固化为静态地址；修复空接口地址、未初始化数据和配置文件打开失败的处理。
2. `0008-alarm-fallback-listener-delivery.patch`：在缺少内核闹钟驱动的容器中，备用 AlarmHandler 使用正常的投递路径，兼容 DHCP 的 IAlarmListener 闹钟并重新安排下一次闹钟；修正 elapsed realtime 与 Handler uptime 的时钟换算。

缺少第二项时，非特权容器可能在首次续租定时器触发时发生 system_server 空指针崩溃。仅看到首次拿到 IP 不能判定 DHCP 已可用。

在已有 Android 13 构建目录：

```bash
/path/to/redroid-pve/apply-patch.sh /path/to/aosp android-13
cd /path/to/aosp
source build/envsetup.sh
lunch redroid_x86_64-userdebug
m -j8 ipconfigstore services
# 发布完整模板前更新 system/vendor 镜像，再执行模板打包流程
m -j8 systemimage vendorimage
```

然后按仓库模板打包流程生成新的 `.tar.zst`。新的模板必须同时包含编译后的 `/vendor/bin/ipconfigstore` 和 `/system/framework/services.jar`。正常使用者下载新模板并更新宿主部署脚本即可，无需在管理台安装额外网络服务。

静态地址模式继续兼容已有镜像。DHCP 需要更新后的镜像；宿主脚本不能让旧二进制自动获得这项能力。

## 原生 PVE 用法

```bash
sudo ./deploy/install-hooks.sh
pve-configure-redroid --check-dhcp --template /var/lib/vz/template/cache/redroid-dhcp.tar.zst
pve-create-redroid 203 dhcp - 4 4096 0 32 /var/lib/vz/template/cache/redroid-dhcp.tar.zst
pve-configure-redroid 203 --network-status --wait-network 40
```

资源参数的位置不变；`-` 是 DHCP 模式下的网关占位符。`--storage`、`--bridge`、`--no-start` 均可继续使用。

PVE GUI 用户可先选择新版镜像创建停止的 CT，将 `net0` 设为 DHCP，再运行 `pve-configure-redroid <VMID> --json`。该命令只修改停止的 CT 配置；之后仍使用 PVE 的正常启动、重启、停止操作。

创建脚本在分配磁盘之前读取模板中的 ipconfigstore 能力标记；旧模板明确拒绝。挂载 Hook 再检查实际客体二进制，覆盖 GUI 创建和恢复旧模板的场景。此检查用于发现旧组件，正式发布仍须保证完整镜像中的两个补丁配套。

## 状态与失败处理

`--network-status` 只读查询实际容器网络命名空间中的 IPv4 和路由；DHCP DNS 从 Android Ethernet 服务读取。停止的容器返回 `running=false`、`ready=false`，不会把历史租约当成当前地址。

```json
{"vmid":203,"mode":"dhcp","provider":"android","running":true,"ready":true,"ipv4":["192.0.2.50/24"],"gateway":"192.0.2.1","dns":["192.0.2.1"]}
```

`ready` 表示已经观察到实际 IPv4 地址，不代替 Android 开机、互联网连通性或投屏验收。`--wait-network 40` 最多等待 40 秒；超时返回非零并保留诊断 JSON，不擅自分配静态地址。DHCP 租约可在后台继续尝试。

检查顺序：镜像能力 → `net0` 的模式和实际网桥/VLAN → DHCP 服务可达 → `dumpsys ethernet` / DhcpClient 日志 → Android DNS 与路由。当前只覆盖 `net0/eth0` 的 IPv4 DHCP，不把 DHCPv6、SLAAC 或多网卡策略视为已实现。

## 验收方式

单元测试：`python3 -m unittest discover -s tests -v`。另在真实 PVE 使用独立网桥和独立服务端网络命名空间，通过 `tests/dhcp_fixture.py` 提供 60 秒租约和测试 DNS；不在生产网桥启动 DHCP 服务。

验收必须包含首次获取、DNS 解析、同一 Android 网络进程的续租、服务器暂时不可达后的重绑定/过期撤销、恢复获取、重启和停止清理。对比验收前后的正式运行时文件校验和、宿主 DNS 与路由，确认没有修改；测试结束删除测试 CT、网桥、服务端进程及临时 Hook。

### 2026-10-29 验收记录

在 i9 / PVE 9.1.1 / 内核 6.17.2-1-pve 上，用非特权 Android 13 CT 完成：

| 项目 | 结果 |
| --- | --- |
| Linux 主机单元测试 | 15 项通过，包含安装器保留原存储 content |
| 新模板获取 IPv4、网关和 DHCP DNS | 通过，192.0.2.50/24，网关/DNS 192.0.2.1 |
| Android 通过域名访问测试网关 | 通过，pve-dhcp.test 解析并收到 ICMP 响应 |
| 60 秒租约续租 | 通过，客户端使用已分配地址发送 DHCPREQUEST |
| 暂停 DHCP 服务，租约过期撤销 | 通过，实际 IPv4、默认路由及 DNS 变为空 |
| 恢复 DHCP 服务 | 通过，重新获取地址与 DNS |
| PVE reboot 后重新获取 | 通过，客体进程已替换 |
| 停止清理 | 通过，旧客体进程消失，状态为 stopped，无宿主 DHCP 客户端 |
| 静态网络回归 | 通过，192.0.2.60/24 保持 STATIC 配置，Android 开机并访问网关 |
| 旧模板能力检查 | 明确拒绝；新模板返回 network API 1 |
| 清理与隔离 | 测试 CT/网桥/Hook 已删除，正式运行时及宿主 DNS/路由校验一致 |

证据：[DHCP 生命周期](evidence/dhcp-2026-10-29.json)、[DHCP 客户端日志](evidence/dhcp-2026-10-29.log)、[静态网络](evidence/static-2026-10-29.json)、[构建和文件校验清单](evidence/manifest.json)。

本次验收镜像由此前已验证的 v0.0.2 模板替换新编译的 `ipconfigstore` 和 `services.jar` 后重新打包，移除了旧的 services 预编译缓存。镜像保存在构建机 `pve-build:/home/aosp/source/redroid13-pve/release/candidates/redroid13_x86_64_pve_template_network-api1_20261029.tar.zst`，配有同名 `.sha256` 文件。SHA256：`a24146e814beb7a27e5ae2094a76d2fb09bf326c6715639c820321378ef3747a`。这是验收候选产物，尚未发布为公开镜像，也没有替换既有模板或 `latest` 链接。

English summary: DHCP is owned by Android's native networking stack. Apply both patches 0007 and 0008, build ipconfigstore and services, and publish a matching image. The isolated PVE acceptance covered acquisition, DNS, renewal, expiry, recovery, reboot, stop cleanup and static IPv4 compatibility. Updating host scripts alone does not add DHCP support to an old image. The CloudPhone development tree now consumes these interfaces; deploy its matching backend and frontend separately.
