#!/usr/bin/env bash
# Ubuntu WiFi 图标消失 / 找不到网卡 — 一键诊断与修复
# 自包含：拷到断网机器上即可运行。默认只做低风险修复，高风险项需确认。

set -u
# 诊断命令允许失败，不用 set -e

VERSION="1.0.0"

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "需要 Bash 4 或更高版本（Ubuntu 默认满足）。当前: ${BASH_VERSION}" >&2
  exit 1
fi

DRY_RUN=0
USE_GUI=1
FORCE_TTY=0
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/tmp/ubuntu-wifi-fix-${STAMP}.log"
BACKUP_DIR="/var/tmp/ubuntu-wifi-fix-${STAMP}"
PROGRESS_OPEN=0
KERNEL=""
DESKTOP=""

declare -A TAGS=()
declare -A CTX=()
declare -a MANUAL_STEPS=()
declare -a ACTIONS_DONE=()
declare -a TAGS_BEFORE=()

C_RESET="" C_BOLD="" C_YELLOW=""
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_YELLOW=$'\033[33m'
fi

usage() {
  cat <<'EOF'
用法: wifi-fix.sh [选项]

Ubuntu WiFi 图标消失 / 找不到网卡 的一键诊断与修复。
默认执行低风险自动修复；改 netplan、卸 DKMS、取消 blacklist 等需确认。

选项:
  --dry-run    只诊断，不改系统
  --no-gui     强制终端交互（不使用 zenity）
  -h, --help   显示本帮助
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --no-gui) FORCE_TTY=1; USE_GUI=0 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; usage; exit 2 ;;
    esac
    shift
  done
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

log_section() {
  {
    echo
    echo "======== $* ========"
  } >>"$LOG_FILE"
}

dump_cmd() {
  local title="$1"
  shift
  log_section "$title"
  if [[ $# -eq 0 ]]; then
    echo "(无命令)" >>"$LOG_FILE"
    return
  fi
  echo "\$ $*" >>"$LOG_FILE"
  "$@" >>"$LOG_FILE" 2>&1 || true
}

have() {
  command -v "$1" >/dev/null 2>&1
}

ensure_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi
  echo "需要管理员权限，正在通过 sudo 重新运行..."
  exec sudo -E "$0" "$@"
}

detect_gui() {
  if [[ "$FORCE_TTY" -eq 1 ]]; then
    USE_GUI=0
    return
  fi
  if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    USE_GUI=0
    return
  fi
  if ! have zenity; then
    USE_GUI=0
    return
  fi
  if ! zenity --version >/dev/null 2>&1; then
    USE_GUI=0
    return
  fi
  USE_GUI=1
}

ui_ask() {
  local text="$1"
  log "ASK: $text"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: 跳过确认（视为否）"
    return 1
  fi
  if [[ "$USE_GUI" -eq 1 ]]; then
    if zenity --question --title="需要确认" --width=520 \
      --ok-label="执行" --cancel-label="跳过" --default-cancel \
      --text="$text" 2>/dev/null; then
      return 0
    fi
    return 1
  fi
  printf '%s%s%s\n' "$C_YELLOW" "$text" "$C_RESET"
  printf '执行该操作? [y/N] '
  local ans=""
  read -r ans || true
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" || "$ans" == "YES" ]]
}

ui_report() {
  local file="$1"
  if [[ "$USE_GUI" -eq 1 ]]; then
    zenity --text-info --title="Ubuntu WiFi 修复报告" --width=680 --height=520 \
      --filename="$file" 2>/dev/null || cat "$file"
  else
    echo
    printf '%s======== 修复报告 ========%s\n' "$C_BOLD" "$C_RESET"
    cat "$file"
  fi
}

ui_progress_begin() {
  local text="$1"
  echo "==> $text"
  log "PROGRESS: $text"
  if [[ "$USE_GUI" -eq 1 ]]; then
    exec 3> >(zenity --progress --pulsate --auto-close --no-cancel --width=420 \
      --title="Ubuntu WiFi 修复" --text="$text" 2>/dev/null)
    echo "1" >&3 || true
    PROGRESS_OPEN=1
  fi
}

ui_progress_end() {
  if [[ "$PROGRESS_OPEN" -eq 1 ]]; then
    echo "100" >&3 || true
    exec 3>&- || true
    PROGRESS_OPEN=0
  fi
}

add_tag() {
  TAGS["$1"]=1
  log "TAG + $1"
}

has_tag() {
  [[ -n "${TAGS[$1]:-}" ]]
}

clear_tags() {
  TAGS=()
}

add_manual() {
  MANUAL_STEPS+=("$1")
  log "MANUAL: $1"
}

add_action() {
  ACTIONS_DONE+=("$1")
  log "ACTION: $1"
}

backup_file() {
  local src="$1"
  mkdir -p "$BACKUP_DIR"
  if [[ -f "$src" ]]; then
    cp -a "$src" "$BACKUP_DIR/"
    log "备份 $src -> $BACKUP_DIR/"
  fi
}

# ---------- 采集 ----------

collect_system() {
  KERNEL="$(uname -r)"
  DESKTOP="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}}"
  CTX[kernel]="$KERNEL"
  CTX[desktop]="$DESKTOP"
  dump_cmd "uname" uname -a
  if have lsb_release; then
    dump_cmd "lsb_release" lsb_release -a
  fi
  dump_cmd "os-release" cat /etc/os-release
}

collect_nm() {
  CTX[nm_active]="unknown"
  CTX[nm_radio]=""
  CTX[nm_net_enabled]=""
  CTX[nm_wifi_enabled]=""
  CTX[wifi_dev_count]="0"
  CTX[unmanaged_wifi]="0"

  if have systemctl; then
    dump_cmd "NetworkManager status" systemctl status NetworkManager --no-pager
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
      CTX[nm_active]="active"
    elif systemctl is-enabled --quiet NetworkManager 2>/dev/null; then
      CTX[nm_active]="inactive"
    elif have dpkg && dpkg -s network-manager >/dev/null 2>&1; then
      CTX[nm_active]="inactive"
    else
      CTX[nm_active]="missing"
    fi
  fi

  local state_file="/var/lib/NetworkManager/NetworkManager.state"
  if [[ -f "$state_file" ]]; then
    dump_cmd "NetworkManager.state" cat "$state_file"
    CTX[nm_net_enabled]="$(awk -F= '/^NetworkingEnabled=/{print $2}' "$state_file" | tr -d '\r')"
    CTX[nm_wifi_enabled]="$(awk -F= '/^WirelessEnabled=/{print $2}' "$state_file" | tr -d '\r')"
  fi

  if have nmcli; then
    dump_cmd "nmcli general" nmcli general status
    dump_cmd "nmcli device" nmcli device status
    dump_cmd "nmcli radio" nmcli radio
    CTX[nm_radio]="$(nmcli radio wifi 2>/dev/null || true)"
    local wifi_lines
    wifi_lines="$(nmcli -t -f TYPE,DEVICE,STATE device status 2>/dev/null | grep '^wifi:' || true)"
    if [[ -n "$wifi_lines" ]]; then
      CTX[wifi_dev_count]="$(printf '%s\n' "$wifi_lines" | wc -l | tr -d ' ')"
      if printf '%s\n' "$wifi_lines" | grep -q ':unmanaged$'; then
        CTX[unmanaged_wifi]="1"
      fi
    fi
  fi
}

collect_rfkill() {
  CTX[rfkill_soft]="0"
  CTX[rfkill_hard]="0"
  if have rfkill; then
    dump_cmd "rfkill" rfkill list
    local block
    block="$(rfkill list 2>/dev/null || true)"
    if echo "$block" | grep -A2 -i 'Wireless LAN\|wlan\|wifi' | grep -qi 'Soft blocked: yes'; then
      CTX[rfkill_soft]="1"
    fi
    if echo "$block" | grep -A2 -i 'Wireless LAN\|wlan\|wifi' | grep -qi 'Hard blocked: yes'; then
      CTX[rfkill_hard]="1"
    fi
  fi
}

collect_ifaces() {
  CTX[has_wifi_iface]="0"
  dump_cmd "ip link" ip -o link
  if ip -o link 2>/dev/null | grep -qE '^[0-9]+: (wlan|wlp|wlo|wlx|wifi)[a-zA-Z0-9_]*:'; then
    CTX[has_wifi_iface]="1"
  fi
  if have iw; then
    dump_cmd "iw dev" iw dev
  fi
}

# 解析 PCI 无线网卡：需要的模块、是否已绑定驱动、.ko 是否存在
collect_pci_wifi() {
  CTX[has_pci_wifi]="0"
  CTX[has_intel_wifi]="0"
  CTX[pci_modules]=""
  CTX[pci_in_use]=""
  CTX[missing_ko]=""
  CTX[not_loaded]=""
  CTX[unclaimed]="0"

  if ! have lspci; then
    log "lspci 不存在，跳过 PCI 采集"
    return
  fi
  dump_cmd "lspci -nnk" lspci -nnk

  local parsed
  parsed="$(
    lspci -nnk 2>/dev/null | awk '
      /^[0-9a-fA-F:.]+ / {
        flush()
        line=$0
        interesting = (line ~ /Network controller|Wireless|802\.11|Wi-Fi|WLAN/)
        inuse=""; mods=""
        next
      }
      interesting && /Kernel driver in use:/ {
        inuse=$NF
        next
      }
      interesting && /Kernel modules:/ {
        sub(/.*Kernel modules: /, "")
        mods=$0
        next
      }
      END { flush() }
      function flush() {
        if (!interesting) return
        print "DEV|" inuse "|" mods "|" line
        interesting=0
      }
    '
  )"
  echo "$parsed" >>"$LOG_FILE"

  local line inuse mods mod found any=0 missing="" not_loaded="" all_mods="" all_inuse=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    any=1
    inuse="$(echo "$line" | cut -d'|' -f2)"
    mods="$(echo "$line" | cut -d'|' -f3 | tr ',' ' ')"
    all_inuse="$all_inuse $inuse"
    all_mods="$all_mods $mods"
    echo "$line" | grep -qi 'Intel\|8086' && CTX[has_intel_wifi]="1"
    echo "$mods" | grep -q 'iwlwifi' && CTX[has_intel_wifi]="1"
    if [[ -z "$inuse" ]]; then
      CTX[unclaimed]="1"
    fi
    for mod in $mods; do
      mod="${mod//,/}"
      [[ -z "$mod" ]] && continue
      found="$(find "/lib/modules/$KERNEL" \( -name "${mod}.ko" -o -name "${mod}.ko.xz" -o -name "${mod}.ko.zst" -o -name "${mod}.ko.gz" \) 2>/dev/null | head -n 1 || true)"
      if [[ -z "$found" ]]; then
        missing="$missing $mod"
      elif [[ -z "$inuse" ]]; then
        not_loaded="$not_loaded $mod"
      fi
    done
  done <<<"$parsed"

  if [[ "$any" -eq 1 ]]; then
    CTX[has_pci_wifi]="1"
  fi
  CTX[pci_modules]="$(echo "$all_mods" | xargs echo 2>/dev/null || true)"
  CTX[pci_in_use]="$(echo "$all_inuse" | xargs echo 2>/dev/null || true)"
  CTX[missing_ko]="$(echo "$missing" | xargs echo 2>/dev/null || true)"
  CTX[not_loaded]="$(echo "$not_loaded" | xargs echo 2>/dev/null || true)"
}

collect_usb_wifi() {
  CTX[has_usb_wifi]="0"
  if ! have lsusb; then
    return
  fi
  dump_cmd "lsusb" lsusb
  if lsusb 2>/dev/null | grep -qiE 'Wireless|802\.11|Wi-Fi|WiFi|WLAN|802.11|RTL8[0-9].*802|MediaTek|Ralink|Atheros|Broadcom.*(802|Wireless)|Realtek.*802|TP-Link|Edimax|Netgear.*Wireless'; then
    CTX[has_usb_wifi]="1"
  fi
}

collect_blacklist() {
  CTX[blacklisted]=""
  local hits="" f
  shopt -s nullglob
  for f in /etc/modprobe.d/*.conf; do
    dump_cmd "modprobe.d $(basename "$f")" cat "$f"
    local needed mods
    mods="${CTX[pci_modules]}"
    [[ -z "$mods" ]] && continue
    for needed in $mods; do
      if grep -E "^[[:space:]]*blacklist[[:space:]]+${needed}([[:space:]]|$)" "$f" >/dev/null 2>&1; then
        hits="$hits ${needed}@${f}"
      fi
    done
  done
  shopt -u nullglob
  CTX[blacklisted]="$(echo "$hits" | xargs echo 2>/dev/null || true)"
}

collect_firmware() {
  CTX[firmware_missing]="0"
  CTX[firmware_files]=""
  local dmesg_out files
  dmesg_out="$(dmesg 2>/dev/null || true)"
  if [[ -z "$dmesg_out" ]] && have journalctl; then
    dmesg_out="$(journalctl -k -b --no-pager 2>/dev/null | tail -n 400 || true)"
  fi
  printf '%s\n' "$dmesg_out" | grep -iE 'firmware|iwlwifi|wlan|802\.11' >>"$LOG_FILE" 2>/dev/null || true
  if printf '%s\n' "$dmesg_out" | grep -qiE 'no suitable firmware|Direct firmware load .* failed|firmware: failed'; then
    CTX[firmware_missing]="1"
    files="$(printf '%s\n' "$dmesg_out" | grep -oE '[A-Za-z0-9._+-]+\.ucode' | sort -u | tr '\n' ' ')"
    CTX[firmware_files]="$files"
  fi
}

collect_netplan() {
  CTX[netplan_renderer]=""
  CTX[netplan_has_networkd]="0"
  CTX[netplan_has_nm]="0"
  local f
  shopt -s nullglob
  dump_cmd "netplan ls" ls -l /etc/netplan
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ -f "$f" ]] || continue
    dump_cmd "netplan $(basename "$f")" cat "$f"
    if grep -qE '^[[:space:]]*renderer:[[:space:]]*networkd' "$f"; then
      CTX[netplan_has_networkd]="1"
    fi
    if grep -qE '^[[:space:]]*renderer:[[:space:]]*NetworkManager' "$f"; then
      CTX[netplan_has_nm]="1"
    fi
  done
  shopt -u nullglob
  if [[ "${CTX[netplan_has_networkd]}" == "1" && "${CTX[netplan_has_nm]}" != "1" ]]; then
    CTX[netplan_renderer]="networkd"
  elif [[ "${CTX[netplan_has_nm]}" == "1" ]]; then
    CTX[netplan_renderer]="NetworkManager"
  fi
}

collect_dkms() {
  CTX[dkms_status]=""
  CTX[has_backport]="0"
  CTX[symbol_disagree]="0"
  CTX[dkms_failed]="0"
  if have dkms; then
    dump_cmd "dkms status" dkms status
    CTX[dkms_status]="$(dkms status 2>/dev/null || true)"
    if echo "${CTX[dkms_status]}" | grep -qiE 'error|failed'; then
      CTX[dkms_failed]="1"
    fi
    # 当前内核没有对应 installed 记录，但其它内核有无线 DKMS
    if echo "${CTX[dkms_status]}" | grep -qiE 'rtl|8821|8852|broadcom|wl/|btusb'; then
      if ! echo "${CTX[dkms_status]}" | grep -F "$KERNEL" | grep -qi 'installed'; then
        CTX[dkms_failed]="1"
      fi
    fi
  fi
  if have dpkg && dpkg -s backport-iwlwifi-dkms >/dev/null 2>&1; then
    CTX[has_backport]="1"
  fi
  if dmesg 2>/dev/null | grep -q 'disagrees about version of symbol'; then
    CTX[symbol_disagree]="1"
  fi
}

collect_secureboot() {
  CTX[secure_boot]="unknown"
  if have mokutil; then
    dump_cmd "mokutil" mokutil --sb-state
    if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
      CTX[secure_boot]="enabled"
    elif mokutil --sb-state 2>/dev/null | grep -qi 'disabled'; then
      CTX[secure_boot]="disabled"
    fi
  fi
  if dmesg 2>/dev/null | grep -qiE 'Lockdown:.*module|required key not available|module verification failed'; then
    CTX[module_key_reject]="1"
  else
    CTX[module_key_reject]="0"
  fi
}

collect_windows() {
  CTX[has_windows]="0"
  dump_cmd "efi listing" ls -la /boot/efi/EFI 2>/dev/null || true
  if [[ -d /boot/efi/EFI/Microsoft ]]; then
    CTX[has_windows]="1"
  elif have lsblk && lsblk -o NAME,FSTYPE,LABEL 2>/dev/null | grep -qiE 'ntfs|BitLocker'; then
    CTX[has_windows]="1"
  fi
}

collect_applet() {
  CTX[nm_applet]="0"
  if pgrep -x nm-applet >/dev/null 2>&1; then
    CTX[nm_applet]="1"
  fi
  dump_cmd "pgrep nm-applet" pgrep -a nm-applet
}

collect_all() {
  collect_system
  collect_nm
  collect_rfkill
  collect_ifaces
  collect_pci_wifi
  collect_usb_wifi
  collect_blacklist
  collect_firmware
  collect_netplan
  collect_dkms
  collect_secureboot
  collect_windows
  collect_applet
}

# ---------- 归类 ----------

is_gnome() {
  echo "${DESKTOP}" | grep -qi 'gnome'
}

classify() {
  clear_tags
  CTX[dkms_purge_backport]="0"

  if [[ "${CTX[nm_active]}" != "active" ]]; then
    add_tag nm_down
  fi
  if [[ "${CTX[nm_net_enabled]}" == "false" || "${CTX[nm_wifi_enabled]}" == "false" ]]; then
    add_tag nm_state_disabled
  fi
  if [[ "${CTX[nm_radio]}" == "disabled" ]]; then
    add_tag wifi_radio_off
  fi
  if [[ "${CTX[rfkill_soft]}" == "1" ]]; then
    add_tag rfkill_soft
  fi
  if [[ "${CTX[rfkill_hard]}" == "1" ]]; then
    add_tag rfkill_hard
  fi
  if [[ "${CTX[has_wifi_iface]}" != "1" ]]; then
    add_tag no_wifi_iface
  fi
  if [[ "${CTX[has_pci_wifi]}" != "1" && "${CTX[has_usb_wifi]}" != "1" && "${CTX[has_wifi_iface]}" != "1" ]]; then
    add_tag no_wifi_hardware
  fi
  if [[ -n "${CTX[missing_ko]}" ]]; then
    add_tag modules_extra_missing
  fi
  if [[ -n "${CTX[not_loaded]}" && -z "${CTX[blacklisted]}" ]]; then
    add_tag driver_not_loaded
  fi
  if [[ -n "${CTX[blacklisted]}" ]]; then
    add_tag module_blacklisted
  fi
  if [[ "${CTX[firmware_missing]}" == "1" ]]; then
    add_tag firmware_missing
  fi
  if [[ "${CTX[netplan_renderer]}" == "networkd" ]]; then
    add_tag netplan_not_nm
  fi
  if [[ "${CTX[unmanaged_wifi]}" == "1" ]]; then
    add_tag unmanaged
  fi
  if [[ "${CTX[has_backport]}" == "1" && "${CTX[has_intel_wifi]}" != "1" && ( "${CTX[symbol_disagree]}" == "1" || "${CTX[has_wifi_iface]}" != "1" ) ]]; then
    add_tag dkms_broken
    CTX[dkms_purge_backport]="1"
  elif [[ "${CTX[dkms_failed]}" == "1" || "${CTX[symbol_disagree]}" == "1" ]]; then
    add_tag dkms_broken
    CTX[dkms_purge_backport]="0"
  fi
  if [[ "${CTX[secure_boot]}" == "enabled" && "${CTX[module_key_reject]}" == "1" ]]; then
    add_tag secure_boot_dkms
  fi
  if [[ "${CTX[has_windows]}" == "1" && ( "${CTX[has_wifi_iface]}" != "1" || "${CTX[unclaimed]}" == "1" ) ]]; then
    add_tag windows_fast_startup_suspect
  fi
  if [[ "${CTX[has_wifi_iface]}" == "1" || "${CTX[wifi_dev_count]}" != "0" ]]; then
    if ! is_gnome && [[ "${CTX[nm_applet]}" != "1" && "${CTX[nm_active]}" == "active" ]]; then
      add_tag icon_only
    fi
  fi
}

# 根据最终标签生成人工说明。修复过程中的 add_manual 会保留。
advise_from_tags() {
  if has_tag rfkill_hard; then
    add_manual "WiFi 被硬件射频锁关闭。请按笔记本飞行模式键（常见 Fn+F2 / Fn+F12），或拨动机身无线开关后再运行本脚本。"
  fi
  if has_tag firmware_missing; then
    add_manual "内核找不到固件：${CTX[firmware_files]:-（见日志 dmesg）}。请从另一台能联网的机器安装/更新 linux-firmware，或把缺失的 .ucode 拷到 /lib/firmware/（Intel 新固件也可能在 /lib/firmware/intel/iwlwifi/），然后执行: sudo update-initramfs -u && sudo reboot"
  fi
  if has_tag windows_fast_startup_suspect; then
    add_manual "检测到 Windows 双系统迹象。请在 Windows 中关闭「快速启动」（控制面板 → 电源选项 → 选择电源按钮的功能），取消网卡「允许计算机关闭此设备以节约电源」，然后选择关机（不是重启），等待数秒再进 Ubuntu。"
  fi
  if has_tag secure_boot_dkms; then
    add_manual "Secure Boot 已开启，且有模块因签名被拒绝加载。不要让本脚本关 Secure Boot。可在 BIOS 中关闭 Secure Boot，或用 mokutil 导入 DKMS 密钥后再重启。"
  fi
  if has_tag no_wifi_hardware; then
    add_manual "PCI/USB 均未看到无线控制器。若是虚拟机，请直通/添加无线网卡；若是实体机，请冷关机（拔电或长按电源）后再开，排除硬件未上电。"
  fi
  if has_tag dkms_broken && [[ "${CTX[dkms_purge_backport]:-0}" != "1" ]]; then
    add_manual "第三方 DKMS 无线驱动未在当前内核 ${KERNEL} 上安装成功。可在 GRUB 的 Advanced options 里选上一个内核进入；不要从 GitHub 强行编译（新 HWE 内核经常编不过）。"
  fi
  if has_tag modules_extra_missing; then
    add_manual "若本机完全断网且 apt 缓存没有包，请重启进入 GRUB → Advanced options → 上一个内核，联网后执行: sudo apt-get install -y linux-modules-extra-${KERNEL} ，再重启回到当前内核。"
  fi
  if is_gnome && wifi_visible; then
    add_manual "GNOME 顶栏图标由系统壳层绘制。若网卡已恢复但仍无图标，请注销重新登录；X11 下也可 Alt+F2 输入 r 回车。"
  fi
}

tag_list() {
  if [[ ${#TAGS[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${!TAGS[@]}" | sort
}

in_before() {
  local x="$1" t
  for t in "${TAGS_BEFORE[@]+"${TAGS_BEFORE[@]}"}"; do
    [[ "$t" == "$x" ]] && return 0
  done
  return 1
}

wifi_visible() {
  [[ "${CTX[has_wifi_iface]}" == "1" || "${CTX[wifi_dev_count]}" != "0" ]]
}

# ---------- 低风险修复 ----------

fix_nm_service() {
  has_tag nm_down || return 0
  if [[ "${CTX[nm_active]}" == "missing" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      add_action "[演练] 安装 network-manager"
      return 0
    fi
    if DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager network-manager-gnome >>"$LOG_FILE" 2>&1; then
      add_action "安装 network-manager"
    else
      add_manual "未安装 NetworkManager，且当前无法通过 apt 安装。请用网线/USB 共享联网后执行: sudo apt-get install -y network-manager"
      return 0
    fi
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] 启动 NetworkManager"
    return 0
  fi
  systemctl unmask NetworkManager >>"$LOG_FILE" 2>&1 || true
  systemctl enable NetworkManager >>"$LOG_FILE" 2>&1 || true
  if systemctl start NetworkManager >>"$LOG_FILE" 2>&1; then
    add_action "启动 NetworkManager 服务"
  else
    add_manual "NetworkManager 启动失败，详见日志 $LOG_FILE"
  fi
}

fix_nm_state() {
  has_tag nm_state_disabled || return 0
  local state_file="/var/lib/NetworkManager/NetworkManager.state"
  [[ -f "$state_file" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] 恢复 NetworkManager.state 中的组网开关"
    return 0
  fi
  systemctl stop NetworkManager >>"$LOG_FILE" 2>&1 || true
  backup_file "$state_file"
  sed -i \
    -e 's/^NetworkingEnabled=.*/NetworkingEnabled=true/' \
    -e 's/^WirelessEnabled=.*/WirelessEnabled=true/' \
    "$state_file"
  grep -q '^NetworkingEnabled=' "$state_file" || echo 'NetworkingEnabled=true' >>"$state_file"
  grep -q '^WirelessEnabled=' "$state_file" || echo 'WirelessEnabled=true' >>"$state_file"
  systemctl start NetworkManager >>"$LOG_FILE" 2>&1 || true
  add_action "已把 NetworkManager.state 中的组网/无线开关改回 true（备份在 ${BACKUP_DIR}）"
}

fix_radio() {
  has_tag wifi_radio_off || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] nmcli radio wifi on"
    return 0
  fi
  if have nmcli && nmcli radio wifi on >>"$LOG_FILE" 2>&1; then
    add_action "已打开 WiFi 电台 (nmcli radio wifi on)"
  fi
}

fix_rfkill_soft() {
  has_tag rfkill_soft || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] rfkill unblock wifi"
    return 0
  fi
  rfkill unblock wifi >>"$LOG_FILE" 2>&1 || true
  rfkill unblock all >>"$LOG_FILE" 2>&1 || true
  add_action "已解除 rfkill 软封锁"
}

fix_modules_extra() {
  has_tag modules_extra_missing || return 0
  local pkg="linux-modules-extra-${KERNEL}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] 安装 $pkg"
    return 0
  fi
  local ok=0
  if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-download "$pkg" >>"$LOG_FILE" 2>&1; then
    ok=1
  elif DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1; then
    ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then
    add_action "已安装 $pkg"
    local mod
    for mod in ${CTX[missing_ko]}; do
      modprobe "$mod" >>"$LOG_FILE" 2>&1 || true
    done
  else
    log "无法安装 $pkg（可能断网且无缓存）"
  fi
}

fix_modprobe() {
  has_tag driver_not_loaded || has_tag modules_extra_missing || return 0
  local mod
  local targets="${CTX[not_loaded]} ${CTX[missing_ko]}"
  [[ -z "$(echo "$targets" | xargs echo 2>/dev/null || true)" ]] && return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] modprobe ${targets}"
    return 0
  fi
  for mod in $targets; do
    [[ -z "$mod" ]] && continue
    if modprobe "$mod" >>"$LOG_FILE" 2>&1; then
      add_action "已加载内核模块 $mod"
    else
      log "modprobe $mod 失败"
    fi
  done
}

fix_applet() {
  has_tag icon_only || return 0
  if is_gnome; then
    add_manual "GNOME 下托盘图标由 gnome-shell 负责。可注销重新登录，或按 Alt+F2 输入 r 回车（仅 X11）重启 Shell。"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] 重启 nm-applet"
    return 0
  fi
  local user="${SUDO_USER:-}"
  killall nm-applet >>"$LOG_FILE" 2>&1 || true
  if [[ -n "$user" && "$user" != "root" ]] && have runuser; then
    runuser -u "$user" -- env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
      nm-applet --indicator >>"$LOG_FILE" 2>&1 &
    add_action "已用用户 $user 重启 nm-applet --indicator"
  elif have nm-applet; then
    nm-applet --indicator >>"$LOG_FILE" 2>&1 &
    add_action "已重启 nm-applet --indicator"
  else
    add_manual "未找到 nm-applet。可安装: sudo apt-get install -y network-manager-gnome"
  fi
}

fix_nm_restart() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] 重启 NetworkManager"
    return 0
  fi
  if have systemctl; then
    systemctl restart NetworkManager >>"$LOG_FILE" 2>&1 || true
    add_action "已重启 NetworkManager"
  fi
}

fix_safe_all() {
  log_section "低风险修复"
  fix_nm_service
  fix_nm_state
  fix_radio
  fix_rfkill_soft
  fix_modules_extra
  fix_modprobe
  fix_applet
  fix_nm_restart
}

# ---------- 高风险修复 ----------

fix_netplan() {
  has_tag netplan_not_nm || return 0
  if ! ui_ask "检测到 Netplan 使用 systemd-networkd，桌面环境通常应由 NetworkManager 管理。\n\n将备份 /etc/netplan 并把 renderer 改为 NetworkManager。\n\n是否执行？"; then
    add_manual "已跳过修改 Netplan。若设置里显示「找不到适配器」但 ip link 能看到网卡，可手动把 /etc/netplan 中 renderer 改为 NetworkManager 后执行 sudo netplan apply。"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  mkdir -p "$BACKUP_DIR/netplan"
  local f changed=0
  shopt -s nullglob
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ -f "$f" ]] || continue
    cp -a "$f" "$BACKUP_DIR/netplan/"
    if grep -qE '^[[:space:]]*renderer:' "$f"; then
      sed -i 's/^[[:space:]]*renderer:.*/  renderer: NetworkManager/' "$f"
      changed=1
    fi
  done
  shopt -u nullglob
  if [[ ! -f /etc/netplan/01-network-manager-all.yaml ]]; then
    cat >/etc/netplan/01-network-manager-all.yaml <<'YAML'
network:
  version: 2
  renderer: NetworkManager
YAML
    changed=1
  fi
  if [[ "$changed" -eq 1 ]]; then
    netplan generate >>"$LOG_FILE" 2>&1 || true
    netplan apply >>"$LOG_FILE" 2>&1 || true
    add_action "已将 Netplan renderer 改为 NetworkManager（备份在 ${BACKUP_DIR}/netplan）"
  fi
}

fix_unmanaged() {
  has_tag unmanaged || return 0
  if ! ui_ask "检测到无线网卡处于 unmanaged（NetworkManager 未接管），GNOME 会显示找不到适配器。\n\n将备份并修改 NetworkManager.conf（managed=true），必要时创建空的 10-globally-managed-devices.conf。\n\n是否执行？"; then
    add_manual "已跳过 unmanaged 修复。可检查 /etc/NetworkManager/NetworkManager.conf 的 [ifupdown] managed=true。"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local conf="/etc/NetworkManager/NetworkManager.conf"
  backup_file "$conf"
  if [[ -f "$conf" ]] && grep -q '^\[ifupdown\]' "$conf"; then
    if grep -q '^managed=' "$conf"; then
      sed -i 's/^managed=.*/managed=true/' "$conf"
    else
      sed -i '/^\[ifupdown\]/a managed=true' "$conf"
    fi
  else
    printf '\n[ifupdown]\nmanaged=true\n' >>"$conf"
  fi
  mkdir -p /etc/NetworkManager/conf.d
  local g="/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"
  if [[ ! -f "$g" ]]; then
    : >"$g"
    add_action "已创建空文件 $g"
  fi
  systemctl restart NetworkManager >>"$LOG_FILE" 2>&1 || true
  add_action "已设置 NetworkManager 接管设备（managed=true）"
}

fix_dkms_conflict() {
  has_tag dkms_broken || return 0
  [[ "${CTX[dkms_purge_backport]:-0}" == "1" ]] || return 0
  if ! ui_ask "检测到 backport-iwlwifi-dkms，且本机不像 Intel 无线网卡。该包常与其它驱动的 cfg80211 冲突，导致无线符号版本不一致。\n\n将卸载 backport-iwlwifi-dkms。\n\n是否执行？"; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if DEBIAN_FRONTEND=noninteractive apt-get purge -y backport-iwlwifi-dkms >>"$LOG_FILE" 2>&1; then
    add_action "已卸载 backport-iwlwifi-dkms"
    systemctl restart NetworkManager >>"$LOG_FILE" 2>&1 || true
  else
    add_manual "卸载 backport-iwlwifi-dkms 失败（可能断网）。可稍后执行: sudo apt-get purge -y backport-iwlwifi-dkms"
  fi
}

fix_blacklist() {
  has_tag module_blacklisted || return 0
  if ! ui_ask "检测到无线驱动被 /etc/modprobe.d 拉黑：\n${CTX[blacklisted]}\n\n这常见于旧 DKMS 脚本在内核升级后仍拉黑 in-tree 驱动。将注释对应 blacklist 行并重新 modprobe。\n\n是否执行？"; then
    add_manual "已跳过取消 blacklist。涉及: ${CTX[blacklisted]}"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local item mod f
  for item in ${CTX[blacklisted]}; do
    mod="${item%%@*}"
    f="${item#*@}"
    [[ -f "$f" ]] || continue
    backup_file "$f"
    sed -i -E "s/^([[:space:]]*blacklist[[:space:]]+${mod})([[:space:]].*)?$/#\\1\\2/" "$f"
    add_action "已注释 $f 中的 blacklist $mod"
    modprobe "$mod" >>"$LOG_FILE" 2>&1 || true
  done
  systemctl restart NetworkManager >>"$LOG_FILE" 2>&1 || true
}

wifi_visible_now() {
  if have nmcli && nmcli -t -f TYPE,STATE device status 2>/dev/null | grep -q '^wifi:'; then
    return 0
  fi
  if ip -o link 2>/dev/null | grep -qE '^[0-9]+: (wlan|wlp|wlo|wlx|wifi)[a-zA-Z0-9_]*:'; then
    return 0
  fi
  return 1
}

fix_clear_connections() {
  local conn_dir="/etc/NetworkManager/system-connections"
  shopt -s nullglob
  local files=("$conn_dir"/*)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi
  if wifi_visible_now; then
    return 0
  fi
  if ! ui_ask "仍未出现可用无线网卡。可以备份并清空已保存的 NetworkManager 连接配置（之后需要重新输入 WiFi 密码）。\n\n是否清空已保存连接？"; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "[演练] 清空 system-connections"
    return 0
  fi
  mkdir -p "$BACKUP_DIR/system-connections"
  cp -a "$conn_dir"/. "$BACKUP_DIR/system-connections/" 2>/dev/null || true
  rm -f "$conn_dir"/*
  systemctl restart NetworkManager >>"$LOG_FILE" 2>&1 || true
  add_action "已清空已保存连接（备份在 ${BACKUP_DIR}/system-connections）"
}

fix_risky_all() {
  log_section "高风险修复（需确认）"
  fix_netplan
  fix_unmanaged
  fix_dkms_conflict
  fix_blacklist
  fix_clear_connections
}

# ---------- 报告 ----------

tag_zh() {
  case "$1" in
    nm_down) echo "NetworkManager 未运行" ;;
    nm_state_disabled) echo "NetworkManager 状态文件关闭了组网/无线" ;;
    wifi_radio_off) echo "WiFi 电台已关闭" ;;
    rfkill_soft) echo "rfkill 软封锁" ;;
    rfkill_hard) echo "rfkill 硬封锁（物理开关）" ;;
    no_wifi_iface) echo "没有无线网络接口" ;;
    no_wifi_hardware) echo "未检测到无线硬件" ;;
    modules_extra_missing) echo "当前内核缺少 linux-modules-extra / 驱动 .ko" ;;
    driver_not_loaded) echo "驱动模块存在但未加载" ;;
    module_blacklisted) echo "无线驱动被 blacklist" ;;
    firmware_missing) echo "缺少固件 firmware" ;;
    netplan_not_nm) echo "Netplan 未交给 NetworkManager" ;;
    unmanaged) echo "网卡 unmanaged" ;;
    dkms_broken) echo "DKMS 驱动异常" ;;
    secure_boot_dkms) echo "Secure Boot 拒绝未签名模块" ;;
    icon_only) echo "设备在，但托盘图标进程未运行" ;;
    windows_fast_startup_suspect) echo "疑似 Windows 快速启动占用网卡" ;;
    *) echo "$1" ;;
  esac
}

write_report() {
  local report="$1"
  local t
  {
    echo "Ubuntu WiFi 修复报告"
    echo "时间: $(date '+%F %T')"
    echo "内核: $KERNEL"
    echo "桌面: ${DESKTOP:-未知}"
    echo "模式: $([[ "$DRY_RUN" -eq 1 ]] && echo 仅诊断 || echo 修复)"
    echo "日志: $LOG_FILE"
    echo "备份: $BACKUP_DIR"
    echo
    echo "---- 修复前识别 ----"
    if [[ ${#TAGS_BEFORE[@]} -eq 0 ]]; then
      echo "未打上问题标签。若图标仍没有，请查看日志中的 lspci / nmcli 输出。"
    else
      for t in "${TAGS_BEFORE[@]}"; do
        echo "- $(tag_zh "$t") [$t]"
      done
    fi
    echo
    echo "---- 复查 ----"
    local still=0
    if [[ ${#TAGS_BEFORE[@]} -gt 0 ]]; then
      for t in "${TAGS_BEFORE[@]}"; do
        if has_tag "$t"; then
          echo "- 仍存在: $(tag_zh "$t")"
          still=1
        else
          echo "- 已处理: $(tag_zh "$t")"
        fi
      done
    fi
    if [[ ${#TAGS[@]} -gt 0 ]]; then
      for t in $(tag_list); do
        if ! in_before "$t"; then
          echo "- 复查新出现: $(tag_zh "$t")"
          still=1
        fi
      done
    fi
    if [[ ${#TAGS_BEFORE[@]} -eq 0 && ${#TAGS[@]} -eq 0 ]]; then
      echo "未见常见故障标签。"
    fi
    echo
    echo "---- 已执行操作 ----"
    if [[ ${#ACTIONS_DONE[@]} -eq 0 ]]; then
      echo "（无）"
    else
      local a
      for a in "${ACTIONS_DONE[@]}"; do
        echo "- $a"
      done
    fi
    echo
    echo "---- 需要人工处理 ----"
    if [[ ${#MANUAL_STEPS[@]} -eq 0 ]]; then
      echo "（无额外步骤，若无线仍不可用请重启后再看图标）"
    else
      local i=1 step
      # 去重
      local seen=""
      for step in "${MANUAL_STEPS[@]}"; do
        echo "$seen" | grep -Fqx "$step" && continue
        seen="$seen"$'\n'"$step"
        echo "$i. $step"
        i=$((i + 1))
      done
    fi
    echo
    echo "若刚刚安装了内核模块或固件，建议重启一次。"
    echo "复查命令: nmcli device status ; rfkill list ; ip -o link"
  } >"$report"
}

# ---------- main ----------

main() {
  parse_args "$@"
  detect_gui
  ensure_root "$@"

  mkdir -p "$(dirname "$LOG_FILE")"
  : >"$LOG_FILE"
  log "wifi-fix.sh $VERSION start dry_run=$DRY_RUN gui=$USE_GUI"
  mkdir -p "$BACKUP_DIR"

  ui_progress_begin "正在采集诊断信息..."
  collect_all
  classify
  ui_progress_end

  local report_pre="/tmp/ubuntu-wifi-fix-${STAMP}-pre.txt"
  {
    echo "诊断完成。内核 $KERNEL"
    echo
    echo "识别到的问题:"
    if [[ ${#TAGS[@]} -eq 0 ]]; then
      echo "未发现常见故障标签。"
    else
      local t
      for t in $(tag_list); do
        echo "• $(tag_zh "$t")"
      done
    fi
  } >"$report_pre"

  if [[ "$USE_GUI" -eq 1 ]]; then
    zenity --info --title="诊断完成" --width=500 --text="$(cat "$report_pre")" 2>/dev/null || true
  else
    echo
    cat "$report_pre"
    echo
  fi

  TAGS_BEFORE=()
  local t
  if [[ ${#TAGS[@]} -gt 0 ]]; then
    for t in "${!TAGS[@]}"; do
      TAGS_BEFORE+=("$t")
    done
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "仅诊断模式，未修改系统"
  else
    ui_progress_begin "正在执行低风险修复..."
    fix_safe_all
    ui_progress_end

    collect_all
    classify

    fix_risky_all

    collect_all
    classify
  fi

  advise_from_tags

  local report="/tmp/ubuntu-wifi-fix-${STAMP}-report.txt"
  write_report "$report"
  cp -a "$report" "$BACKUP_DIR/report.txt" 2>/dev/null || true
  ui_report "$report"
  echo
  echo "日志: $LOG_FILE"
  echo "报告: $report"
}

main "$@"
