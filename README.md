
# QEMU Labs (ARM-first) — Zephyr + MCUboot 实验脚手架

这个仓库用于在 **QEMU** 上快速做各种实验。当前默认实验是 **MCUboot + mcumgr (smp_svr)**，
以后你只需改 1 个文件就能切到其它 Zephyr 示例或你自研应用。默认板卡：`qemu_cortex_a53`（ARM64）。

## 0) 先决条件（建议在 Linux/WSL2）
- Python3 / CMake / Ninja / git
- Go（用于安装 `mcumgr` CLI）
- QEMU：建议使用 `west sdk install` 安装 Zephyr SDK（自带合适的 QEMU）

## 1) 初始化（一次性）
```bash
# 在仓库根目录执行
west init -l .
west update
west zephyr-export
# 可选但推荐：安装 Zephyr SDK（含 QEMU）
west sdk install
```

安装 mcumgr：
```bash
# 需要 Go 环境
go install github.com/apache/mynewt-mcumgr-cli/mcumgr@latest
echo 'export PATH="$PATH:$(go env GOPATH)/bin"' >> ~/.bashrc
source ~/.bashrc
```

## 2) 启动 QEMU 以太网（用于 UDP 传输）
```bash
./scripts/net_up.sh
# 保持该终端运行；或者后台运行（自行加 nohup/screen/tmux）
```

## 3) 构建并运行（MCUboot + smp_svr，ARM：qemu_cortex_a53 + UDP）
```bash
./scripts/build.sh -b qemu_cortex_a53 -t udp
./scripts/run.sh
```

另开终端，用 mcumgr 连接（默认 `192.0.2.2:1337`）：
```bash
./scripts/mcumgr.sh list
```

## 4) 演示升级（A/B + 测试切换/确认）
```bash
# 修改版本号（仅演示；真正版本策略按你的应用实现）
echo 2.0.0 > labs/mcuboot/app.version

./scripts/build.sh -b qemu_cortex_a53 -t udp
./scripts/mcumgr.sh upload        # 上传 build/zephyr/zephyr.signed.bin
./scripts/mcumgr.sh list
./scripts/mcumgr.sh test <hash>   # 将 <hash> 换为上一条命令打印的新镜像哈希
./scripts/mcumgr.sh reset         # 复位后进入测试镜像
./scripts/mcumgr.sh confirm       # 确认镜像，防止下次回滚
```

## 5) 切换实验/板卡/传输
- **换实验应用**：编辑 `labs/mcuboot/app_path.txt`，写入 Zephyr 树内应用路径（如 `samples/hello_world`）或你的应用路径。
- **换板卡**：`-b qemu_cortex_m3`（Cortex-M3）等。
- **串口传输**（无需网桥）：`-t serial` 后，按提示在 `scripts/mcumgr.sh` 中设置 `SERIAL_DEV=/dev/pts/N`，然后用 `serial-*` 子命令。

## 6) 关闭网络桥
```bash
./scripts/net_down.sh
```

## 常见问题
- `mcumgr` 连接超时：确认 `net_up.sh` 正在运行，虚机 IP 一般是 `192.0.2.2`（如不同，修改 `scripts/mcumgr.sh` 中 `UDP_ADDR`）。
- 未生成 `zephyr.signed.bin`：确保使用了 `--sysbuild` 且启用了 `CONFIG_BOOTLOADER_MCUBOOT=y`（脚本已默认）。

---
参考：Zephyr 文档中的 `qemu_cortex_a53` 板与 `smp_svr`（UDP）示例。
