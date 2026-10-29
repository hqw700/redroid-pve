# redroid-pve 文档

本仓库交付 Android 13 的 PVE 原生容器适配、模板打包工具和官方运行脚本。原生用户不需要部署 Web 管理台或远程控制 Agent。

## 按角色阅读

| 场景 | 入口 |
| --- | --- |
| 下载模板并在 PVE 使用 | [项目 README](../README.md)、[运行与排障](operations.md) |
| 理解运行时、Hook 和 Android 补丁 | [架构与职责](architecture.md) |
| 调用官方命令、检查 JSON 和错误 | [运行接口](runtime-api.md) |
| 使用 DHCP、升级对应镜像 | [网络与 DHCP](networking.md) |
| 接入 CloudPhone 或其他管理台 | [集成契约](integrations.md) |
| 修改、构建、测试和发布 | [开发与发布](development.md) |
| AI 编程代理接手 | [AGENTS.md](../AGENTS.md) |

## 三类版本

| 类型 | 当前状态与依据 |
| --- | --- |
| 运行接口 | API 1；`pve-configure-redroid --version` |
| 宿主运行脚本 | 1.1.1；`deploy/VERSION` 与 Python `RUNTIME_VERSION` |
| Android 镜像 | 单独构建和发布；DHCP 要求 network API 1 与 0007、0008 配套补丁 |

API 1 的旧运行时可能没有 DHCP 接口，接入方还要检查运行时版本和实际镜像能力。旧的静态网络镜像不会因升级宿主脚本而自动支持 DHCP。

README 中 v0.0.1 下载示例属于旧镜像路径，不是 DHCP 镜像承诺。当前 DHCP 候选镜像、构建组件和真实测试范围记录在 [网络说明](networking.md) 与 [证据清单](evidence/manifest.json)；候选产物不等同于已公开发布的 Release。

## 当前验收范围

仓库记录了 Android 13 x86_64 在 i9 / PVE 9.1.1 / 内核 6.17.2-1-pve 的非特权 DHCP 与静态网络验收，覆盖获取、DNS、续租、过期、恢复、重启和停止清理。

更多 Android 版本、ARM64、其他 GPU、PVE 版本和自定义网络组合，应分别验证；README 的规划表不表示这些组合已经交付。容器 running、Android 开机、网络 ready 和远程画面是不同的验收项。

1.1.1 的 [n100 BinderFS 恢复](evidence/binder-n100-2026-10-29.json)记录 PVE 9.1.1 同版内核已有模块但未加载的情况，以及官方宿主准备、pre-start、Android 开机、DHCP 地址和 Intel ADL-N 渲染的实际验证。此次未重启宿主，也未在 n100 重复完整租约生命周期矩阵。

## 接手原则

1. 先确认修改属于官方 Android/PVE 运行规则，还是某个管理台的集成功能。
2. 以源码和命令实际结果为准；保留历史证据，不把旧实验环境的地址、VMID 或构建路径当成默认值。
3. 运行脚本与镜像变化分别记录来源和摘要，测试通过后再交付消费方同步。
4. 原生用户路径必须独立可用；集成不能增加对 CloudPhone 配置或 Agent 的强制依赖。
