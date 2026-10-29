# redroid-pve 维护约定

本文件适用于整个仓库。先阅读 [文档入口](docs/README.md)、[架构](docs/architecture.md) 和 [开发发布流程](docs/development.md)，再按任务修改相应组件。

## 项目目标与边界

- 原生 PVE 用户下载匹配镜像、安装官方运行时后，应能直接创建、启停和管理 Android CT，不依赖 CloudPhone、WebRTC 或 Agent。
- Android 补丁、基础设备、GPU、网络、FUSE/电源保护、启动兼容规则由本仓库维护。新增规则应修改上游源码和测试，不能只修消费方生成目录或某台机器上的脚本。
- 第三方管理台通过 PVE 管理资源和任务，调用本仓库的配置接口，仅维护自身 Agent、连接配置及挂载权限。参见 [管理台接入](docs/integrations.md)。
- 当前运行接口为 API 1，运行脚本版本为 1.1.1；以 `deploy/VERSION` 和实际 `--version` 为准。镜像、运行时与管理台版本分别记录，不把脚本升级等同于镜像升级。

## 修改入口

| 需求 | 修改位置 |
| --- | --- |
| 官方配置、参数校验、配置迁移、状态接口 | `deploy/pve-configure-redroid.py` |
| 原生创建、存储/网桥选择、启动等待 | `deploy/pve-create-redroid.sh` |
| 官方命令与 Hook 安装 | `deploy/install-hooks.sh` |
| PVE 生命周期和静态网络准备 | `deploy/redroid-hook.sh` |
| LXC 挂载阶段、设备与宿主保护 | `deploy/redroid-pve-hook.sh` |
| Android 行为、用户命名空间兼容、DHCP | `patches/android-13/<AOSP 项目>/` |
| 补丁应用、模板打包 | `apply-patch.sh`、`build/mk-pve-template.sh` |
| 回归测试、隔离网络夹具 | `tests/` |

## 必须保持的契约

1. `pve-configure-redroid` 的配置路径只操作已有、停止、未锁定的 CT。只读版本/镜像/网络/宿主查询维持各自语义。宿主准备必须显式使用 `--prepare-host`，不修改 CT。配置命令不能隐式创建、启动、停止或删除 CT。
2. 原生创建默认 `unprivileged=1`、GPU 默认 `host`。保留已有位置参数及 `--no-start`、`--storage`、`--bridge`；不要悄悄改变这些默认值。第三方管理台可以有不同的显式默认配置。
3. 已存在 VMID 必须拒绝创建，不自动停止或销毁。示例中的编号不表示当前环境可用，真实测试先查询集群资源。
4. 配置渲染必须幂等，保留无关挂载、资源参数及快照区段。其他 PVE hookscript 明确报错，不能静默覆盖。
5. Android/PVE 运行键由官方接口管理。对不兼容的参数或模式明确失败，不偷偷改成另一种 GPU、特权或网络模式。
6. DHCP 由 Android IpClient/DhcpClient 负责获取、续租、失效、DNS 和路由。不得另起宿主 DHCP 客户端，也不能把租约地址写成 Android 静态配置。
7. DHCP 镜像必须包含配套的 0007、0008 补丁。能力检查读取实际模板；能力标记不能替代对完整镜像的启动与续租验收。
8. `--network-status` 返回实际观察值，停止时不得展示历史租约为当前地址。检查目标网络命名空间，不能回退到宿主命名空间。
9. 保留参数校验和无 Shell 执行的调用方式。额外启动参数只允许声明的 `androidboot.*` / `ro.boot.*` 键值，不允许覆盖从 `net0` 推导的网络模式。
10. 遵守 pmxcfs 语义；不要把本地普通文件的 rename 写入方式直接套到 `/etc/pve`。不整体覆盖集群配置做回退。

## AOSP 与补丁

- AOSP 根目录通常是 `.repo` 工作区，不是一个 Git 仓库；在实际子项目中检查和生成补丁。
- 每个补丁放在与 AOSP 子项目对应的目录，保留补丁编号、上下文及许可证。已有补丁不能仅因空白检查报错而批量清理上下文空格。
- 修改构建机源码后，必须把对应变更导回本仓库的补丁文件。不能把“构建机已经修好”作为交付终点。
- 应用脚本会跳过缺失的项目，也会跳过已应用的补丁；退出成功不等于所有目标模块都已覆盖。检查输出及各目标项目的正向/反向 `git apply --check`。
- DHCP 涉及 `vendor/redroid` 的 ipconfigstore 和 `frameworks/base` 的 services，不能只替换其中一个组件后宣称功能完整。

## 验证

文档变更检查链接和命令与源码的一致性，不为文档验证安装 Hook、打包镜像或重启服务。

运行时或补丁逻辑变更至少执行：

```bash
python3 -m unittest discover -s tests -v
for redroid_script in apply-patch.sh build/mk-pve-template.sh deploy/*.sh; do
    bash -n "$redroid_script" || exit 1
done
git diff --check -- . ':!patches/**' ':!docs/evidence/**'
```

- 非 Linux 上安装器测试会跳过；不能把此结果说成已完成 Linux/PVE 全项验收。
- 参数、网络、Hook、设备或镜像补丁变更按 [开发流程](docs/development.md) 补充真实 PVE 验收；单元测试不能证明 Android 开机、GPU 或投屏可用。
- 真实测试使用空闲 VMID、隔离网络和明确的资源清单。`tests/dhcp_fixture.py` 只能运行在测试服务端的独立网络命名空间，不能连接到现网 DHCP 广播域。
- 保留真实日志和摘要；不修改原始证据来制造“通过”，也不提交令牌、私钥或含密钥的集成配置。

## 部署、打包与交付

- 安装器会更新宿主共享 Hook 和命令。先记录原文件、校验和、权限及 `local` 存储 content；只在任务已授权的目标执行。
- `build/mk-pve-template.sh` 会重建临时目录、更新本地 `latest`；能够访问 `pve-155h` 时还会自动分发并更新远端模板别名。运行前阅读脚本和 [打包说明](docs/development.md)，不能把它当成无副作用的测试命令。
- 不覆盖用户 CT、正式模板或 latest 来完成隔离验收。不因任务结束就恢复为“缺少运行时文件”的旧状态；恢复范围以该次测试的备份和约定为准。
- 同步修改 `deploy/VERSION` 与 `RUNTIME_VERSION`（发生运行时版本变更时）。文档变更不需要增加运行版本或重启服务。
- 中文与英文 README 的公共入口、默认值和兼容要求保持一致；详细维护文档可以使用中文。
- 消费方应固定已提交的上游运行快照与摘要。需要调整运行规则时先修这里，再由消费方的同步器生成，不能手工修改其 vendor 目录。
- 用户任务已有的授权持续有效；例行检查和可回滚修改不重复请求确认。涉及超出授权的实例、共享文件或发布目标时，先说明具体影响。
- 除非用户要求，完成修改后不自动推送、发布镜像或更新公开 Release。
