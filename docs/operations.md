# 原生 PVE 使用与排障

返回 [文档入口](README.md)。完整参数见 [运行接口](runtime-api.md)，DHCP 见 [网络说明](networking.md)。

## 安装前核对

1. 确认当前终端是目标 PVE 宿主机、节点及存储正确，并具备所需 root 权限。
2. 准备用户自行下载、已核对摘要且匹配架构的 `.tar.zst`。DHCP 镜像需同时包含 0007、0008，旧版下载示例不表示支持 DHCP。
3. 读取集群已有 VMID、rootdir 存储、模板存储、网桥/VLAN。示例编号和地址不是自动预留资源。
4. 静态地址由用户规划，排除 DHCP 和其他分配器的占用；DHCP 要求目标广播域存在可用服务。
5. 宿主默认渲染节点是 `/dev/dri/renderD128`；无合适 GPU 时显式使用 guest，避免默认 host 模式失败。

只读检查示例：

```bash
pvesh get /nodes --output-format json
pvesh get /cluster/resources --type vm --output-format json
pvesm status
ip -br link
ls -l /dev/dri
```

## 安装官方运行时

在目标 PVE 上，从已核对的仓库版本执行：

```bash
bash deploy/install-hooks.sh
pve-configure-redroid --version
pve-configure-redroid --check-host --json
```

安装器会更新共享命令和 Hook，并向 `local` 目录存储 content 增加 snippets，保留其原有内容。执行前记录共享文件及存储配置；它不下载镜像、不创建 CT。

安装完成后确认命令、`/usr/local/share/redroid-pve/VERSION`、`local:snippets/redroid-hook.sh` 和 `/usr/share/lxc/hooks/redroid-pve-hook.sh` 实际存在。只看到 PVE API 可连不代表运行环境完整。

1.1.1 起安装器会加载 `binder_linux`、验证 BinderFS 并配置开机加载，每次 PVE pre-start 也会复查。若 `--check-host` 返回 `ready=false`，先在宿主运行 `pve-configure-redroid --prepare-host --json`。模块找不到时核对 `uname -r`、`modinfo binder_linux` 和匹配内核模块；不要直接假定需要额外 DKMS 驱动。无需为单纯未加载模块而重启 PVE。

## PVE GUI 创建路径

1. 上传匹配模板，在目标节点创建 CT，选择资源、系统盘存储、网桥和静态 IPv4 或 DHCP。默认推荐非特权；创建后先保持停止。
2. DHCP 不填静态网关，使用 `net0` / `eth0`；确认镜像能力和 DHCP 服务可达。
3. 在宿主对停止 CT 应用官方配置，先 dry-run 检查，再正式写入。
4. 回到 PVE GUI 正常启动、停止、重启和查看任务，不需要 CloudPhone。

官方创建命令显式使用 `ostype=unmanaged`。GUI 导入结果也应保持该语义；如果当前 GUI 无法完成模板识别或相关选择，可先用官方创建命令加 `--no-start` 建立 CT，再回到 PVE 面板管理，不必增加 Web 管理台依赖。

```bash
# 示例 201 必须替换为本次实际创建的 CT
pve-configure-redroid 201 --gpu-mode guest --width 720 --height 1280 --dpi 320 --fps 60 --dry-run --json
pve-configure-redroid 201 --gpu-mode guest --width 720 --height 1280 --dpi 320 --fps 60 --json
```

修改显示/GPU 配置也应先停止实例，再完整传入希望保留的参数。不要在运行中直接编辑官方管理块，或通过修改 unprivileged 标志进行未验证的模式迁移。

## 分层确认就绪

```bash
pct status 201
pct exec 201 -- /system/bin/getprop sys.boot_completed
pve-configure-redroid 201 --network-status
pct exec 201 -- /system/bin/sh -c 'dumpsys SurfaceFlinger | grep GLES:'
```

按需在有权限的客户端执行 `adb connect <实际IP>:5555`，再用 scrcpy 验证画面与输入；占位地址需替换为当前观察值。网络 ready 不是互联网、Android 或投屏的完整健康结论。

## 启动失败先读任务日志

`startup for container failed` 是汇总结果，具体原因在对应 UPID 的任务日志中。先在 PVE 任务窗口读取；需要更细 LXC 日志时，在确认实例和影响后使用目标 CT 的调试启动。

```bash
pct config 201
pct status 201
# 调试启动会实际启动该 CT，仅在本次已授权的故障实例上执行
pct start 201 --debug
```

不能因为任务失败就删除并重建相同 VMID。创建中途可能已经分配磁盘或留下可恢复 CT，先查实际配置、状态和失败环节。

| 现象 | 检查与处理 |
| --- | --- |
| `pve-configure-redroid: No such file` | 在实际目标 PVE 安装官方运行时，核对命令和 Hook；不要在管理台临时拼接替代配置 |
| Binder driver could not be opened / `/dev/binder` 不存在 | 在宿主检查 BinderFS 和 `binder_linux`；使用官方宿主准备命令，不能只在客体 mknod。CT running 不代表 Android 已启动 |
| CT must be stopped / configuration locked | 停止 CT，检查 PVE 任务和锁的实际来源；不直接清锁来跳过仍在运行的任务 |
| GPU render node 不存在 | 核对节点、设备及选定 GPU；无 GPU 使用显式 guest，不把路径不存在误认为镜像损坏 |
| custom PVE hookscript detected | 先保存并审查既有 Hook，设计链接方式；不静默覆盖 |
| DHCP 镜像能力失败 | 检查实际模板与配套 0007/0008 组件；仅升级宿主脚本不能补齐旧镜像 |
| DHCP 获得 IP 后 system_server 崩溃 | 检查 0008 的 listener 闹钟回退是否进入 services.jar，继续做完整租约验收 |
| DHCP 等待超时 | 查网桥/VLAN、服务端、DhcpClient 和 Android Ethernet；不静态固化某次租约作为修复 |
| `safe_mount Permission denied` 指向第三方配置 | 核对挂载源父目录搜索权限、文件读取权限和实际 ID 映射；由配置生产者修复，不在官方 Hook 放宽全部目录 |
| Android 未完成启动 | 区分 LXC、init、zygote/system_server、GPU/APEX/BPF 等阶段，读取针对性日志；不凭单个属性或进程判断全部正常 |
| 同 VMID 容器与旧记录不一致 | 确认节点、集群与实际归属。VMID 可复用，不凭旧记录停止或销毁现有资源 |

## 升级与回退

- 脚本升级记录旧命令/Hook/版本和存储 content；镜像升级另外记录模板与数据备份。
- 配置器保留快照，不表示旧快照自动兼容新镜像或新网络能力。恢复后重新核对模式和组件。
- 无法用管理服务 JSON 恢复客体磁盘。数据回退走 PVE 备份/快照流程，并核对实例归属。
- 回退共享文件前，确认其他现存 CT 的依赖；不整体覆盖 `/etc/pve`，也不清理其他管理台的 Agent/config。
- 清理的是本次临时资源，不能把用户已需要的正式运行时删除。

原始故障日志按需脱敏，保留任务编号、组件版本和真实检查结果；不要把令牌、私钥或含密钥的集成配置放入问题单和公共仓库。
