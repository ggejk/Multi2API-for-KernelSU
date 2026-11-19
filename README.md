# Multi2API for KernelSU

在 Android 手机上把 2API 后端作为 KernelSU 模块运行。当前只接入了 [opencode2api v1.5.0](https://github.com/jasonxu114514/opencode2api/releases/tag/v1.5.0)；`capy2api` 尚未接入。模块不挂载或修改系统文件。

## 构建与安装

**不需要本地编译。** GitHub Actions 在推送到 `main`、推送 `v*` 标签或手动触发时，使用 Go 和 Android NDK 构建 **Android arm64** 安装包（Android 9+、需已安装 KernelSU）。不同于原 Linux 静态构建，原生版本使用 Android 系统 DNS，不需要修改系统或硬编码 DNS 地址。

1. 打开 [Actions → Build Android KernelSU module](https://github.com/ggejk/Multi2API-for-KernelSU/actions/workflows/build.yml) 最新成功的构建。
2. 下载并解压 artifact `Multi2API-KernelSU-android-arm64`，找到里面的 `Multi2API-for-Kernelsu-v0.1.0-android-arm64.zip`。
3. 在 KernelSU 管理器中选择这个**内层 ZIP** 安装，不要刷 Recovery。

## 配置与使用

首次安装只会初始化 `/data/adb/Multi2API-for-Kernelsu/config.json`，不会覆盖已有配置。重启前（或重启后手工 `restart` 前）用 root 编辑它：

- `server_keys`：填一个足够长的随机本地 API Key，客户端用它调用手机上的服务。
- `zen_keys` / `go_keys`：至少填一个自己的上游 Key；只有明确要使用上游匿名服务时才改为 `"anonymous": true`。不要把本地 API Key 填到上游数组里。
- 新装默认监听 `127.0.0.1:3101`，WebUI 关闭。已有配置的监听和 WebUI 设置会原样保留；如果曾监听 `0.0.0.0`，升级后请检查是否仍需要对局域网开放。不要将 API 或后台直接暴露到公网。

同手机客户端的 OpenAI 兼容 Base URL 为 `http://127.0.0.1:3101/v1`。可用 `GET /v1/models` 检查连通性：

```sh
curl -H "Authorization: Bearer $MULTI2API_LOCAL_KEY" http://127.0.0.1:3101/v1/models
```

模块在开机完成后启动服务。也可在手机的 **root shell** 手动操作：

```sh
cd /data/adb/modules/Multi2API-for-Kernelsu
export ASH_STANDALONE=1
/data/adb/ksu/bin/busybox sh ./ctl.sh status
/data/adb/ksu/bin/busybox sh ./ctl.sh restart
/data/adb/ksu/bin/busybox sh ./ctl.sh logs
```

`ctl.sh` 支持 `start`、`stop`、`restart`、`status`、`logs`，可在命令末尾指定后端，默认是 `opencode2api`。`status` 只检查进程身份，不代表 API 或上游已就绪；进程退出后不会自动反复重启。更改配置后用 `restart` 生效。首次启动失败时先检查本地 Key 和上游配置，再查看日志。

日志位于 `/data/adb/Multi2API-for-Kernelsu/logs/opencode2api.log`；启动时超过 5 MiB 则轮转一份。升级和卸载会保留数据目录（含配置与日志）；想彻底清理，请先备份所需数据，在管理器卸载并重启后再删除此目录。需要立即停止当前进程时，先手动 `stop`，不要只依赖禁用模块。

仓库根目录如有 `config.json`，它是历史本地配置，不会被打进 ZIP；**不要提交它或分享运行配置、日志中的密钥**。

## 接入新后端

通用的进程、日志和锁管理集中在 `ctl.sh`。例如未来接入 `capy2api` 时：

1. 增加 `backends/capy2api.sh`，定义 `BIN`、`CONFIG`、`CONFIG_EXAMPLE`、`WORK_DIR` 和 `backend_exec()`。最后用 `exec` 启动实际的前台可执行文件，不要自行后台化。配置和工作目录建议置于 `$DATA_DIR/capy2api/`，监听端口不要和现有后端冲突；运行目录需在初始化时创建（如同配置文件目录）。
2. 将后端 ID 加到 `ctl.sh` 的白名单，补上配置模板、Android 二进制、安装权限和 `scripts/package.py` 的打包清单。
3. 需要默认随系统启动时，再修改 `boot-completed.sh`；在此之前可先用 `ctl.sh start capy2api` 单独验证。

开发机可运行 `python3 -m unittest discover -s tests -v` 验证生命周期、并发启动、配置保护和 ZIP 内容。上游版本、源码和许可见 [`licenses/README.md`](licenses/README.md)。
