# redroid-pve 文档

本仓库交付 Android 13 的 PVE 原生容器适配、模板打包工具和官方运行脚本。原生用户不需要部署 Web 管理台或远程控制 Agent。

## 按角色阅读

| 场景 | 入口 |
| --- | --- |
| 下载模板并在 PVE 使用 | [项目 README](../README.md)、[运行与排障](operations.md) |
| 理解运行时、Hook 和 Android 补丁 | [架构与职责](architecture.md) |
| 调用官方命令、检查 JSON 和错误 | [运行接口](runtime-api.md) |
| 使用 DHCP、升级对应镜像 | [网络与 DHCP](networking.md) |
| 排查 WebView / X 浏览器启动崩溃 | [memfd 原因、修复与部署记录](webview-memfd.md) |
| 接入 CloudPhone 或其他管理台 | [集成契约](integrations.md) |
| 修改、构建、测试和发布 | [开发与发布](development.md) |
| v0.0.3 镜像、校验和与已知限制 | [中文发布说明](releases/v0.0.3.zh-CN.md)、[English release notes](releases/v0.0.3.en.md) |
| AI 编程代理接手 | [AGENTS.md](../AGENTS.md) |

## 三类版本

| 类型 | 当前状态与依据 |
| --- | --- |
| 运行接口 | API 1；`pve-configure-redroid --version` |
| 宿主运行脚本 | 1.1.1；`deploy/VERSION` 与 Python `RUNTIME_VERSION` |
| Android 镜像 | 单独构建和发布；DHCP 要求 network API 1 与 0007、0008 配套补丁 |

API 1 的旧运行时可能没有 DHCP 接口，接入方还要检查运行时版本和实际镜像能力。旧的静态网络镜像不会因升级宿主脚本而自动支持 DHCP。

README 下载入口已更新为 v0.0.3，包含配套 DHCP 与 WebView memfd 补丁。镜像摘要与本轮整镜像验收见 [v0.0.3 记录](evidence/release-v0.0.3-2026-11-02.json)。此前 DHCP 候选镜像与测试仍保留在 [网络说明](networking.md) 和 [历史证据清单](evidence/manifest.json)，不改写其当时的发布状态。

## 当前验收范围

v0.0.3 完整模板已在 PVE 9.1.1 / Intel Meteor Lake / 720×1280 的全新非特权与特权 CT 上验证开机、网络和 memfd。特权组合通过 WebView 页面和 JavaScript 画面核验；默认非特权映射下 WebView 沙箱 GID 超出范围，页面渲染未通过。另有图形和蓝牙启动崩溃记录，详见发布说明的已知限制，不能将该版本理解为所有组合均已通过。

仓库记录了 Android 13 x86_64 在 i9 / PVE 9.1.1 / 内核 6.17.2-1-pve 的非特权 DHCP 与静态网络验收，覆盖获取、DNS、续租、过期、恢复、重启和停止清理。

更多 Android 版本、ARM64、其他 GPU、PVE 版本和自定义网络组合，应分别验证；README 的规划表不表示这些组合已经交付。容器 running、Android 开机、网络 ready 和远程画面是不同的验收项。

1.1.1 的 [n100 BinderFS 恢复](evidence/binder-n100-2026-10-29.json)记录 PVE 9.1.1 同版内核已有模块但未加载的情况，以及官方宿主准备、pre-start、Android 开机、DHCP 地址和 Intel ADL-N 渲染的实际验证。此次未重启宿主，也未在 n100 重复完整租约生命周期矩阵。

## 接手原则

1. 先确认修改属于官方 Android/PVE 运行规则，还是某个管理台的集成功能。
2. 以源码和命令实际结果为准；保留历史证据，不把旧实验环境的地址、VMID 或构建路径当成默认值。
3. 运行脚本与镜像变化分别记录来源和摘要，测试通过后再交付消费方同步。
4. 原生用户路径必须独立可用；集成不能增加对 CloudPhone 配置或 Agent 的强制依赖。
