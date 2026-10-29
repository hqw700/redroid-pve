# 开发、构建与发布

返回 [文档入口](README.md)。协作规则见 [AGENTS.md](../AGENTS.md)。

## 修改前先分类

| 变更 | 工作与验证范围 |
| --- | --- |
| 纯文档 | 链接、命令、版本与源码一致；不部署或重启 |
| 配置器/创建/Hook | Python 回归、Shell 语法、对应真实 PVE 启动与回归 |
| DHCP | 同时检查宿主运行时和 Android 组件，完整租约生命周期验收 |
| AOSP 补丁 | 子项目补丁检查、组件/镜像构建、真实 Android 行为 |
| 打包工具 | 提取结果、权限、归档成员、校验和、latest 与分发目标 |
| 管理台集成 | 官方接口保持可用；接入方另验资源、归属、Agent/配置挂载 |

## 当前维护环境与可移植性

本次维护使用过以下环境，供接手定位；它们不是安装或发布默认值：

| 工作区 | 位置 |
| --- | --- |
| redroid-pve 源码 | 本地 `/Volumes/m2/code/redroid-pve` |
| CloudPhone 消费方 | 本地 `/Volumes/m2/code/cloudphone` |
| Android 构建树 | `pve-build:/home/aosp/source/redroid13-pve` |

构建树是 AOSP `.repo` 多项目工作区。PVE 宿主是另一种执行环境；不能因为构建机能 SSH 登录，就在其中运行宿主安装器。实际 PVE 目标、API 凭据、VMID、存储和网桥从当前任务配置读取，不写进公共默认逻辑。

## AOSP 补丁流程

在已准备上游 ReDroid/AOSP 的 Android 13 工作区：

```bash
/path/to/redroid-pve/apply-patch.sh /path/to/aosp android-13
```

应用脚本支持已应用补丁跳过和 `-R` 反向操作。不要把 `-R` 当成通用工作区清理命令；它会改动实际源码。缺失子项目会警告并跳过，需读完整结果。

修改目标子项目后，检查该项目自己的 Git 状态，将本次变更导出到相同目录下的补丁。针对干净对应基线检查 `git apply --check`；针对已应用状态可检查 `git apply --reverse --check`。保留用户其他改动，不在 AOSP 根目录执行假定单仓的 reset/clean。

DHCP 的已确认增量目标：

```bash
cd /path/to/aosp
source build/envsetup.sh
lunch redroid_x86_64-userdebug
m -j8 ipconfigstore services
m -j8 systemimage vendorimage
```

其他模块变更按其真实构建依赖选择目标；需要完整系统验证时执行完整构建。只编译一个二进制、只复制源码或只替换宿主脚本，都不能代表完整镜像已更新。

## 模板打包的当前行为

`build/mk-pve-template.sh` 根据**脚本所在目录**及其父目录推断 AOSP 路径；`OUT` 只选择输入镜像目录，不改变推断出的 release 目录。直接从 AOSP 根目录调用外部仓库 `build/` 中的脚本，不保证推断正确。

当前可将脚本副本放到实际 AOSP 根目录，以便检测 `build/make/core/main.mk`：

```bash
cd /path/to/aosp
install -m 0755 /path/to/redroid-pve/build/mk-pve-template.sh ./mk-pve-template.sh
```

先检查下列副作用，再决定是否执行打包：

- 重建 `OUT_DIR/.tmp_pve_rootfs`，结束时删除该临时目录。
- 写入 AOSP `release/` 下的归档和 `.sha256`，更新本地 `redroid13_pve_template_latest.tar.zst`。
- 如果 SSH 可以访问 `pve-155h` 的模板目录，自动 scp 并更新远端 `redroid13_intel_latest.tar.zst`。
- 当前没有 `--no-sync` 或显式 AOSP 根目录选项；隔离候选打包需先准备并审阅不包含分发步骤的工作副本，或使用没有该分发目标的隔离环境。不要用正式 latest 验证候选镜像。

只有任务明确覆盖这些输出和分发目标时，才执行对应副本：

```bash
OUT=/path/to/aosp/out/target/product/redroid_x86_64 bash ./mk-pve-template.sh redroid13_x86_64_pve_candidate.tar.zst
```

脚本使用 debugfs 提取 system/vendor，补齐挂载点、init 入口和部分兼容内容，再用 tar/zstd 打包。部分提取命令采用容错处理，打包返回成功不代表输入镜像或提取内容完整。交付前至少检查 `/init`、`/vendor/bin/ipconfigstore`、`/system/framework/services.jar`、权限与实际启动；DHCP 还需能力检查和租约测试。

## 回归与真机验收

```bash
python3 -m unittest discover -s tests -v
for redroid_script in apply-patch.sh build/mk-pve-template.sh deploy/*.sh; do
    bash -n "$redroid_script" || exit 1
done
python3 deploy/pve-configure-redroid.py --version
git diff --check -- . ':!patches/**' ':!docs/evidence/**'
```

当前测试覆盖配置幂等、快照和第三方挂载保留、特权模式、参数/Hook 冲突、VMID 防覆盖、no-start、版本、设备权限及 DHCP 关键行为。安装器测试在非 Linux 上跳过，应明确报告跳过项。

真实 PVE 验收按变更选取：

1. 记录 PVE/内核/GPU、运行时来源、模板摘要、特权模式、存储和网桥；分配已确认空闲的测试资源。
2. 安装前备份共享命令、Hook、版本文件、权限和 storage content；记录原本不存在的文件。
3. 验证 CT 启动、`sys.boot_completed=1`、实际资源和所选 GPU 渲染器。
4. 网络变更分别回归静态 IPv4 和 DHCP。DHCP 包含 DNS、短租约续租、失效撤销、恢复、重启、停止和宿主网络未改变。
5. 使用 ADB/scrcpy 或已授权的集成验证实际画面与输入，不能只看 Agent 在线或解码器创建成功。
6. 清理临时 CT、网桥、网络命名空间、服务端进程和测试 Hook；恢复范围按本轮备份与任务约定执行。用户正式需要的已部署运行时不能当成临时垃圾删除。

`tests/dhcp_fixture.py` 绑定 DHCP/DNS 端口并提供测试地址，仅在独立测试服务端网络命名空间运行，不能接入现网广播域。

## 发布顺序

1. 固化补丁、运行脚本、测试和文档；版本变化同时更新 `deploy/VERSION` 与 `RUNTIME_VERSION`。纯文档不增加运行版本。
2. 从可追溯的 AOSP 子项目提交与补丁生成镜像，记录 system/vendor 组件和归档 SHA-256。
3. 完成目标组合真机验收，保存脱敏原始证据与构建摘要。候选文件与已公开 Release 分开标记。
4. 提交上游代码，再由消费方同步固定提交/文件摘要。运行时与镜像按各自变更升级；不要把 API 1 当成所有 1.x 功能都已安装。
5. 用户明确要求发布后，再上传镜像、校验文件与说明。更新 latest 和分发目标作为显式发布动作，保留可回退产物。

现有 [网络证据](evidence/manifest.json) 描述当时的测试组合，不因后续提交改变而改写其历史指标。新组合新增记录。

## 后续开发优先项

- 打包器增加显式 AOSP 根目录、禁用分发、候选/latest 分离以及提取失败检查。
- Hook 关键保护步骤输出可核对的执行结果，区分容错与安全隔离确实生效。
- 扩充 PVE/内核、非特权、自定义 ID 映射和 GPU 的真实验收矩阵，再声明支持范围。
- 新 Android 版本、ARM64、多网卡和 IPv6 各自建立补丁与测试范围，不在现有 API 上默认宣称已支持。
