# WebView 启动崩溃与 memfd 尺寸保护

后续更新：v0.0.3 已完成完整 system/vendor 模板打包及隔离整镜像验收，见 [2026-11-02 记录](evidence/release-v0.0.3-2026-11-02.json)与[发布说明](releases/v0.0.3.zh-CN.md)。下文保留 2026-10-30 组件验证和原实例部署的当时状态。新验收发现默认非特权 GID 映射不覆盖 WebView 沙箱 GID；此问题不属于 memfd seals 修复，非特权页面渲染仍未通过。

返回 [文档入口](README.md)。构建命令见 [开发流程](development.md#webview-与-memfd-兼容)，结构化结果见 [2026-10-30 验收记录](evidence/webview-memfd-2026-10-30.json)。

## 问题与确认原因

2026-10-30，在 Android 13 x86_64、PVE 9.1.1、内核 `6.17.2-1-pve` 上，
X 浏览器 `com.mmbox.xbrowser` 5.6.4（1092）启动后立即退出。
崩溃发生在系统 WebView `com.android.webview` 156.0.8078.47 的
`libwebviewchromium.so + 0x3bab603`，信号为 `SIGILL`。

设备已设置 `sys.use_memfd=1`，VNDK 为 33。没有 `/dev/ashmem` 时，
`ASharedMemory_create()` 经 Android `libcutils` 创建 memfd。
Android 13 的 `memfd_create_region()` 原实现只创建文件并调用 `ftruncate()`
设置大小，没有禁止后续改变大小。

[该 WebView 版本对应的 Chromium 源码](https://chromium.googlesource.com/chromium/src/+/156.0.8078.47/base/android/linker/ashmem.cc)
在 `IsMemfdFd()` 中要求文件同时具有 `F_SEAL_GROW` 与 `F_SEAL_SHRINK`。
这样可以保证接收方使用共享内存时，另一进程不能通过改变区域大小制造检查与使用之间的竞态。
缺少任一标志，文件就不能通过 memfd 校验。

本次故障链为：

1. X 浏览器实例化系统 WebView。
2. Android 创建没有尺寸 seals 的 memfd，实测 `F_GET_SEALS=0x0`。
3. WebView 拒绝该共享内存描述符，保护属性查询返回失败。
4. 后续初始化失败路径触发 trap，进程以 `SIGILL` 退出。

因此，修复位置是 Android 共享内存创建实现。最初报告将错误直接归因为
“缺少 ashmem 模块，对 memfd 执行 ashmem ioctl”并不准确：源码中只有
`IsAshmemFd()` 成功后才会执行该 ioctl，错误日志显示的 errno 可能是前面的
系统调用留下的值。单独的 `ENOTTY` 日志不足以证明 ioctl 调用发生过。

## 具体修改

新增 [0009 补丁](../patches/android-13/system/core/0009-seal-memfd-region-size.patch)，
对应 AOSP 子项目 `system/core`。保留既有 0002 补丁及其他构建树改动。

| 文件或位置 | 修改内容 |
| --- | --- |
| `libcutils/ashmem-dev.cpp` | `memfd_create_region()` 在 `ftruncate()` 成功后，调用 `fcntl(fd, F_ADD_SEALS, F_SEAL_GROW \| F_SEAL_SHRINK)` |
| 同一函数的失败路径 | 添加 seals 失败时记录错误并返回 `-1`，由 `unique_fd` 关闭描述符，不交付不满足要求的区域 |
| `libcutils/ashmem_test.cpp` | 添加 `MemfdSizeSeals` 和 `MemfdSizeSealsAllowReadOnlyConversion` 两项回归测试 |
| 本仓库维护文档 | 更新补丁职责表、构建与测试说明、验收记录及本文 |

修复后 seals 为 `0x6`，同时禁止增大和缩小区域。没有添加 `F_SEAL_SEAL`
或直接禁止写入，后续仍可用 `F_SEAL_FUTURE_WRITE` 完成只读转换；已有可写映射
仍可使用，新建可写映射被拒绝。正常共享读写和跨进程使用继续由测试验证。

源码改动已同步到构建机，并导出到本仓库补丁，供后续镜像重建使用。
宿主运行脚本没有修改，运行时版本仍为 `1.1.1`。没有安装外部 ashmem 模块、
替换 WebView APK、修改宿主 IPC 或改变原实例的特权/GPU 模式。

## 验证结果与边界

使用临时 CT、无物理上联的隔离网桥和测试网段，先验证原库，再验证补丁库。
测试组合为特权 CT、host GPU、720×1280；原目标使用相同组合。

| 检查 | 原库 | 修复后 |
| --- | --- | --- |
| NDK `ASharedMemory_create()` 探针 | seals `0x0` | seals `0x6` |
| 两项新增 memfd 回归，64 位 | 2 项失败 | 2 项通过，包含在下述 6 项中 |
| memfd、基本读写、fork、文件操作定向集合 | — | 64 位 6/6、32 位 6/6 通过 |
| X 浏览器启动 | 相同 PC、相同 WebView BuildId 的 `SIGILL` | 两次冷启动正常，进程存活，显示首次使用协议 |
| WebView shell | — | 本地 data URL 页面渲染正常，JavaScript 成功更新 PASS 文本 |

新增测试覆盖零尺寸、非页对齐尺寸、禁止增大/缩小、重复描述符和只读转换。
32 位测试需要在临时目录提供 `libjsoncpp.so`；32 位原库对照因缺少该依赖未能运行，
故原库负向对照以 64 位结果为准。过早执行的一轮测试因 Android 尚未就绪而失败，
原始记录保留，就绪后重跑通过。

最初临时 CT 在 1080×1920 下出现另一处 gralloc `SIGFPE`，特权和非特权均有发生。
使用与目标一致的分辨率后完成上述特权组合验收。该图形故障未由本补丁解决，
本记录也不代表已验收非特权组合、其他分辨率、互联网访问或完整浏览器功能。

本地 Python 回归运行 19 项，其中 1 项安装器测试在 macOS 跳过；Shell 语法和
差异空白检查通过。新补丁正向检查通过，构建树全部九个补丁反向检查通过。
`libcutils`、`libcutils_test`、`systemimage`、`vendorimage` 均构建成功。
完整新镜像未做启动验收，也未打包、分发或更新正式模板及 latest。

## 原实例部署结果

隔离验证通过后，经用户明确授权，对原目标 CT 214 做组件部署：

1. 记录原 CT 配置、网络、两份库的摘要、所有者和权限，并保存原库。
2. 停止 CT，只替换 `/system/lib64/libcutils.so` 和 `/system/lib/libcutils.so`，保留所有者及权限。
3. 启动 CT，核对库摘要及 CT 配置，后者与部署前一致。
4. 验证 `sys.boot_completed=1`、Android DHCP ready、地址仍为 `192.168.100.132/24`。
5. 验证 NDK seals `0x6`；X 浏览器冷启动返回 `Status: ok`，耗时 407 ms，进程持续存活。
   新 crash buffer 未出现原 X 浏览器 `SIGILL`，画面停在首次使用协议，未代用户接受。

这是已有实例的组件更新，没有覆盖其数据或替换整套镜像。
临时验收 CT、磁盘和网桥已清理；原始日志、截图、备份位置及恢复步骤保存在本地私有工作区。
本文中的 VMID、地址和日期仅指此次记录，不能作为其他环境可直接使用的部署参数。

## 后续复用与回退

后续镜像应从带 0009 补丁的源码重建，并按开发流程重新完成整镜像启动验收。
重新下载旧模板或重新创建 CT 不会自动获得本次组件修复。

若此次部署需要回退，应先核对备份与原实例的对应关系和文件摘要，在 CT 停止时
恢复原两份库及其元数据，再启动并检查。无需整体覆盖 `/etc/pve` 配置。
恢复旧库会同时恢复原 WebView 兼容性问题；私有部署记录包含本轮备份的精确位置。
