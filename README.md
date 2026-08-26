# Ubuntu WiFi 一键修复

自包含脚本，用于处理 Ubuntu **顶栏网络图标消失**、设置里 **找不到 WiFi 适配器**、更新内核后 **网卡 UNCLAIMED** 等常见问题。

目标是驱动 / NetworkManager / 射频 / 管理器没起来这一类故障。  
**不能**用来修「图标还在、能扫到热点，但某个 WiFi 密码/DHCP/企业认证连不上」。

把 `wifi-fix.sh` 拷到出问题的机器上即可运行，不依赖网络、不拆多文件。

## 用法

```bash
chmod +x wifi-fix.sh
./wifi-fix.sh              # 安全自动修 + 高风险询问
./wifi-fix.sh --dry-run    # 只诊断，不改系统
./wifi-fix.sh --no-gui     # 强制终端（无桌面、SSH、或不想用 zenity）
```

需要管理员权限，脚本会通过 `sudo -E` 重新执行（保留图形环境变量，以便弹窗）。Ubuntu 自带 Bash 4+，请在出问题的 Ubuntu 上运行，不要用 macOS 自带的 Bash 3。

- 有 `DISPLAY`/`WAYLAND_DISPLAY` 且已安装 `zenity` 时走图形进度条和确认框。
- 否则自动退回终端彩色输出；高风险项默认 **否**（输入 `y` 才执行）。

## 会自动修（低风险）

- NetworkManager 未运行 / 被关掉
- `/var/lib/NetworkManager/NetworkManager.state` 里组网或无线被写成 `false`
- `nmcli radio wifi` 关闭
- `rfkill` **软**封锁
- 当前内核缺少 `linux-modules-extra`（先尝试本地 apt 缓存，再尝试联网安装）
- `lspci` 已声明驱动模块但未加载 → `modprobe`
- 非 GNOME 桌面下重启 `nm-applet --indicator`

## 先询问再修（高风险）

- Netplan `renderer` 不是 NetworkManager
- 网卡 `unmanaged`
- 冲突的 `backport-iwlwifi-dkms`（且不像 Intel 网卡）
- `/etc/modprobe.d` 里把当前网卡需要的驱动拉黑了
- 仍无无线网卡时，备份并清空已保存的 WiFi 连接

改动前会备份到 `/var/tmp/ubuntu-wifi-fix-时间戳/`。

## 只诊断、给出下一步（不自动改）

- `rfkill` 硬封锁（飞行模式键 / 机身开关）
- Windows 快速启动占用网卡（双系统）
- Intel `iwlwifi` 固件 `.ucode` 缺失或版本不够
- Secure Boot 拒绝未签名 DKMS 模块
- Realtek / Broadcom 第三方 DKMS 在新 HWE 内核上编不过
- PCI/USB 完全看不到无线控制器（虚拟机未直通，或硬件未上电）
- 缺 `linux-modules-extra` 且 apt 缓存也没有：需进 GRUB 上一个内核联网后再装

## 日志

每次运行会写：

| 文件 | 说明 |
|---|---|
| `/tmp/ubuntu-wifi-fix-时间戳.log` | 完整命令输出 |
| `/tmp/ubuntu-wifi-fix-时间戳-report.txt` | 中文报告（修复前标签、复查、已执行、人工步骤） |
| `/var/tmp/ubuntu-wifi-fix-时间戳/` | 配置备份和报告副本 |

若刚装了内核模块或固件，报告会建议重启一次。

## 覆盖边界

社区里「图标没了 / No Wi-Fi Adapter Found / 更新后 UNCLAIMED」的高频原因，多数能自动处理或给出可执行下一步。不断网机器上无法独自完成「缺内核模块且缓存里没有包」；也不会从 GitHub 拉第三方驱动，也不会关闭 Secure Boot 或改 BIOS。
