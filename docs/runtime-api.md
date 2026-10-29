# 官方运行接口

返回 [文档入口](README.md)。本文对应 API 1 / 运行时 1.1.1，以命令 `--help` 和 `--version` 为准。所有 VMID、网桥、地址与模板名称都是示例，执行前先核对当前环境。

## 版本与安装

在目标 PVE 宿主机，以 root 执行已核对来源的仓库版本：

```bash
bash deploy/install-hooks.sh
pve-configure-redroid --version
```

版本结果：

```json
{"api":1,"version":"1.1.1"}
```

安装需要 PVE、Python 3 和名为 `local` 的目录存储。已有 content 会保留并增加 snippets。当前安装位置不是任意 hookscript 存储参数；系统盘则可另选 rootdir 存储。

## 宿主 BinderFS 检查与准备

```bash
# 只读，不加载模块、不写文件；ready=false 仍返回 JSON，调用方必须检查 ready
pve-configure-redroid --check-host --json
# root 执行，加载内核自带 binder_linux 并配置开机加载，不修改或启停 CT
pve-configure-redroid --prepare-host --json
```

这两个接口从 1.1.1 提供。安装器和 PVE pre-start Hook 调用官方准备流程；管理台用只读接口判断是否可开通。模块已加载或内建 BinderFS 时不会重复 modprobe。准备成功后 `/etc/modules-load.d/redroid-pve.conf` 包含 `binder_linux`，保留原有内容；模块加载失败或加载后 BinderFS 仍不可用时非零退出，不把安装视为成功。不会自动安装 DKMS、切换内核或重启宿主机。

检查响应包含 `api`、`version`、`kernel`、`ready`、`binderfs`、`details`。`ready` 仅代表 BinderFS 前提，不代表 GPU、Android 开机或 DHCP 已就绪。宿主操作不能与 VMID、dry-run、镜像或网络查询组合。

## 配置已有 CT

```bash
pve-configure-redroid 201 --gpu-mode guest --width 720 --height 1280 --dpi 320 --fps 60 --dry-run --json
pve-configure-redroid 201 --gpu-mode guest --width 720 --height 1280 --dpi 320 --fps 60 --json
```

配置操作要求已有 CT 停止且没有配置锁，不执行启停。dry-run 返回完整拟写配置；它仍检查 CT 状态和配置合法性，但跳过部分安装文件与 GPU 节点检查，不能代替环境验收。

| 参数 | 默认 / 范围 |
| --- | --- |
| `VMID` | 100..999999999，配置与网络查询时必填 |
| `--gpu-mode` | `host`；可选 `host` / `guest` |
| `--gpu-node` | `/dev/dri/renderD128`；格式 `/dev/dri/renderD<number>` |
| `--width` / `--height` | 1080 / 1920；1..16384 |
| `--dpi` | 320；1..2000 |
| `--fps` | 60；1..240 |
| `--output-mode` | `headless`；可选 `headless` / `hdmi` |
| `--device-id` | 可选技术标识，ASCII 字母、数字、`_`、`.`、`-`，最多 128 字符 |
| `--extra-boot-args` | 单独的 `androidboot.*=value` 或 `ro.boot.*=value` 参数 |
| `--dry-run` | 不写配置，JSON 中增加 `config` |
| `--json` | 配置结果使用 JSON |

每次调用会按参数重新渲染官方配置；省略显示参数会使用默认值，不是“保留上次设置”。接入方修改单项时也应传入希望保留的完整显示配置。

配置结果示例：

```json
{"api":1,"version":"1.1.1","vmid":201,"changed":true,"started":false}
```

`--device-id` 写入 Android 启动参数，不负责设置 PVE hostname 或控制台显示名称。网络模式从 `net0` 推导，禁止通过 extra boot args 覆盖。

## 原生创建

```text
pve-create-redroid VMID IP/CIDR|dhcp [GATEWAY|-] [CORES] [MEMORY_MB] [SWAP_MB] [DISK_GB] [TEMPLATE] [UNPRIVILEGED] [GPU_MODE] [--no-start] [--storage STORAGE] [--bridge BRIDGE]
```

| 项目 | 缺省值 |
| --- | --- |
| VMID、静态 IP、网关 | 201、192.168.100.201/24、192.168.100.1；实际使用应显式填写 |
| CPU / 内存 / swap / 磁盘 | 8 核 / 4096 MiB / 1024 MiB / 32 GiB |
| 特权模式 | `UNPRIVILEGED=1`，`0` 为特权 |
| GPU | `host` |
| 系统盘存储 | `REDROID_PVE_STORAGE` 或 `local-lvm`，命令参数优先 |
| 网桥 | `REDROID_PVE_BRIDGE` 或 `vmbr0`，命令参数优先 |
| 模板 | 优先默认路径 `redroid13_intel_latest.tar.zst`，缺省文件不存在时搜索最新 redroid 模板；正式使用应显式指定 |

示例：

```bash
# 留在停止状态，便于调用方检查或添加集成挂载
pve-create-redroid 201 192.168.100.201/24 192.168.100.1 4 4096 1024 32 /var/lib/vz/template/cache/redroid-static.tar.zst 1 guest --no-start --storage local-lvm --bridge vmbr0

# DHCP 的网关位置使用 - 占位
pve-create-redroid 203 dhcp - 4 4096 0 32 /var/lib/vz/template/cache/redroid-dhcp.tar.zst 1 host --storage local-lvm --bridge vmbr0
```

脚本不下载模板、不建立静态地址池，也不替用户规划地址冲突。已有 CT 会拒绝创建。没有 `--no-start` 时会启动，轮询 Android 开机状态；DHCP 还会等待实际地址。超时或后续步骤失败不代表前面分配的 CT/磁盘已经撤销，不能据此盲目重复创建。

## DHCP 镜像检查

```bash
pve-configure-redroid --check-dhcp --template /var/lib/vz/template/cache/redroid-dhcp.tar.zst
```

读取归档中的 ipconfigstore 标记，不创建 CT、不解包到工作目录。成功输出包括：

```json
{"api":1,"version":"1.1.1","dhcp4":true,"provider":"android","image_network_api":1}
```

旧镜像会失败。发布方仍需保证 ipconfigstore 与 services.jar 的配套构建，详见 [网络说明](networking.md)。

## 查询实际网络

```bash
pve-configure-redroid 203 --network-status
pve-configure-redroid 203 --network-status --wait-network 40
```

`--wait-network` 为 0..120 秒，只能与网络查询一起使用。停止实例返回 running/ready 为 false；等待超时会输出诊断 JSON，再以非零状态退出，不分配静态回退地址。

```json
{"vmid":203,"mode":"dhcp","provider":"android","running":true,"ready":true,"ipv4":["192.0.2.50/24"],"gateway":"192.0.2.1","dns":["192.0.2.1"]}
```

mode 可能为 dhcp、static、manual；provider 为 android 或 redroid-hook。mode=manual 只是对现有 `net0` 的观察分类，不表示本项目已实现独立的 manual 自动联网流程。

## 错误处理

Python 接口成功返回 0；当前错误统一返回 1，诊断写入 stderr，没有稳定的细分错误码协议。接入方应保留 stdout/stderr 和 PVE 任务 UPID，不依赖翻译后的整段报错匹配来执行删除或特权降级。

关键失败包括 CT 未停止/有锁、其他 hookscript、非法参数、运行时缺失、GPU 节点缺失、DHCP 静态网关冲突、旧镜像和实际地址获取超时。版本、镜像检查与网络查询各有独立语义，不能拿网络 ready 替代配置成功。
