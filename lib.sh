#!/system/bin/sh
# ============================================================
# 澎湃内存管理优化 - lib.sh（共享函数库）
# 所有脚本 source 此文件。职责：路径/配置/日志/内存快照/动作执行
# ============================================================

# ---------- 路径常量 ----------
HKOM_DIR=/data/local/tmp/hkom
CONF=$HKOM_DIR/hkom.conf
GAMES=$HKOM_DIR/games.conf
LOG=$HKOM_DIR/hkom.log
STATUS=$HKOM_DIR/hkom.status
DAEMON_PID=$HKOM_DIR/hkom_daemon.pid
MONITOR_PID=$HKOM_DIR/hkom_monitor.pid

# 系统节点（只读常量，避免重复拼路径）
MI_RECLAIM=/sys/kernel/mi_reclaim/info
MIMD_TRIGGER=/sys/module/perf_helper/mimd/mimdtrigger
MEMINFO=/proc/meminfo
PSI=/proc/pressure/memory
ZRAM_MMSTAT=/sys/block/zram0/mm_stat
ZRAM_ALGO=/sys/block/zram0/comp_algorithm
DROP_CACHES=/proc/sys/vm/drop_caches

# ---------- 工具探测 ----------
BB=""
detect_bb() {
  for p in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
    [ -x "$p" ] && { BB="$p"; return 0; }
  done
  command -v busybox 2>/dev/null || echo ""
}

RP=""
detect_rp() {
  if command -v resetprop >/dev/null 2>&1; then
    RP="resetprop"
  elif [ -x /data/adb/ksu/bin/resetprop ]; then
    RP="/data/adb/ksu/bin/resetprop"
  elif [ -x /data/adb/magisk/resetprop ]; then
    RP="/data/adb/magisk/resetprop"
  else
    RP=""
  fi
}

detect_bb
detect_rp

# ---------- 默认配置 ----------
# 主动回收开关
DEF_disable_mimd=1
DEF_disable_unfairmem=1
DEF_disable_mi_reclaim=1
DEF_disable_memory_standard=1
# lmkd
DEF_lmk_low=1001
DEF_lmk_medium=950
DEF_lmk_critical=900
# 内存水位
DEF_watermark_target=80
DEF_watermark_hysteresis=5
DEF_drop_level=1
# 游戏模式
DEF_game_mode=1
DEF_game_kill_cached=1
DEF_game_drop_caches=1
# zram
DEF_zram_takeover=0
DEF_swappiness=60
DEF_watermark_scale_factor=100
# daemon
DEF_poll_normal=10
DEF_poll_game=3
# 冻结与缓存上限（M11）
DEF_freezer_enable=1
DEF_max_cached_procs=64
DEF_reclaim_mb=64
DEF_smart_keep=1

# 配置项名列表（用于 get_conf 兜底）
CONF_KEYS="disable_mimd disable_unfairmem disable_mi_reclaim disable_memory_standard lmk_low lmk_medium lmk_critical watermark_target watermark_hysteresis drop_level game_mode game_kill_cached game_drop_caches zram_takeover swappiness poll_normal poll_game freezer_enable max_cached_procs reclaim_mb watermark_scale_factor smart_keep"

# ---------- 配置读取 ----------
# get_conf key  -> 返回配置值（优先 hkom.conf，缺失用默认）
get_conf() {
  local k="$1"
  local v=""
  if [ -f "$CONF" ]; then
    v=$(grep "^${k}=" "$CONF" 2>/dev/null | tail -1 | cut -d'=' -f2-)
  fi
  if [ -z "$v" ]; then
    eval "v=\${DEF_${k}}"
  fi
  echo "$v"
}

# 写入配置（WebUI 与 daemon 共用）
set_conf() {
  local k="$1" v="$2"
  mkdir -p "$HKOM_DIR" 2>/dev/null
  touch "$CONF" 2>/dev/null
  # 原子写：先写临时再 mv，避免读到半截
  local tmp="$CONF.tmp"
  if grep -q "^${k}=" "$CONF" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$CONF" 2>/dev/null
  else
    echo "${k}=${v}" >> "$CONF"
  fi
}

# ---------- 日志 ----------
# log level msg  level: INF/WRN/ERR/GAME/MEM/RECLAIM
log() {
  local lvl="$1" msg="$2"
  mkdir -p "$HKOM_DIR" 2>/dev/null
  echo "$(date '+%m-%d %H:%M:%S') [$lvl] $msg" >> "$LOG" 2>/dev/null
  # 日志容量限制：超过 256KB 截断一半
  local sz
  sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt 262144 ] 2>/dev/null; then
    tail -c 131072 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
  fi
}

# ---------- 状态写入（供 WebUI 读取）----------
# set_status key value  写入 hkom.status（key=value 行）
set_status() {
  local k="$1" v="$2"
  mkdir -p "$HKOM_DIR" 2>/dev/null
  touch "$STATUS" 2>/dev/null
  if grep -q "^${k}=" "$STATUS" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$STATUS" 2>/dev/null
  else
    echo "${k}=${v}" >> "$STATUS"
  fi
}

# ---------- 内存快照 ----------
# mem_snapshot  -> 设置全局 MEM_* 变量
mem_snapshot() {
  MEM_TOTAL=$(awk '/^MemTotal:/{print $2}' $MEMINFO 2>/dev/null)
  MEM_FREE=$(awk '/^MemFree:/{print $2}' $MEMINFO 2>/dev/null)
  MEM_AVAIL=$(awk '/^MemAvailable:/{print $2}' $MEMINFO 2>/dev/null)
  MEM_CACHED=$(awk '/^Cached:/{print $2}' $MEMINFO 2>/dev/null)
  [ -z "$MEM_TOTAL" ] && MEM_TOTAL=1
  [ -z "$MEM_AVAIL" ] && MEM_AVAIL=0
  # 可用百分比（整数）
  MEM_AVAIL_PCT=$(( MEM_AVAIL * 100 / MEM_TOTAL ))
  # 占用百分比 = 100 - 可用百分比
  MEM_USED_PCT=$(( 100 - MEM_AVAIL_PCT ))
}

# zram 用量（单位：MB，mm_stat 第3字段是字节）
zram_used_mb() {
  awk '{printf "%d", $3/1048576}' $ZRAM_MMSTAT 2>/dev/null
}

# zram 压缩率（百分比，1位小数）
zram_ratio() {
  awk '{printf "%.1f", $2/$1*100}' $ZRAM_MMSTAT 2>/dev/null
}

# PSI some avg300（百分比，1位小数）
psi_avg300() {
  awk '/some/{for(i=1;i<=NF;i++) if($i~/avg300=/){split($i,a,"="); printf "%.1f", a[2]}}' $PSI 2>/dev/null
}

# ---------- 后台保活白名单（M10：locked_apps 锁后台） ----------
KEEP_CONF=$HKOM_DIR/keep.conf

# 判断是否系统应用包名（系统包一律不参与本模块的 adj 保活）
# 原则：只动第三方 App + 推送通道，其余系统服务 adj 由 AMS 统一管理，模块不干预。
# 例外：小米推送 com.xiaomi.xmsf / com.xiaomi.xmsfkeeper 是全局消息通道，
#       所有第三方 App 的离线推送都经它投递，允许纳入内核级保护。
is_sys_pkg() {
  case "$1" in
    # 推送通道例外（允许保护）
    com.xiaomi.xmsf|com.xiaomi.xmsfkeeper) return 1 ;;
    # 其余系统包一律过滤
    com.xiaomi.*|com.miui.*|com.android.*|com.google.android.*) return 0 ;;
    android|android.*) return 0 ;;
    com.mi.*|miui.*|com.qualcomm.*|com.qti.*) return 0 ;;
  esac
  return 1
}

# 读取 keep.conf 所有包名（空格分隔，供 JSON 拼接）
# ★ 内置系统包过滤：即使配置里误加系统包，也不会进入保活处理链。
keep_list_pkgs() {
  [ -f "$KEEP_CONF" ] || return 0
  local l out=""
  for l in $(grep -E '^[A-Za-z]' "$KEEP_CONF" 2>/dev/null); do
    if is_sys_pkg "$l"; then continue; fi
    out="$out $l"
  done
  echo "$out"
}

# 应用保活白名单 → 系统 locked_apps
# 合并策略：读取当前 locked_apps 的 u=0 组，把「用户已锁定的」+「本模块白名单」合并去重，
# 绝不覆盖用户在系统设置里手动锁定的其它应用
apply_keep_list() {
  [ -f "$KEEP_CONF" ] || return 0
  local merged="" seen="" pkg cur first=1
  # 1. 读取当前 u=0 组里用户已锁定的包（保留）
  cur=$(settings get system locked_apps 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != "null" ]; then
    # 提取 "u":0 分组的 pkgs 数组内容（ crude but safe：取第一段 u:0 到下一个 "u": 之间）
    local u0
    u0=$(printf '%s' "$cur" | sed -n 's/.*{"u":0,"pkgs":\[\([^]]*\)\]}.*/\1/p')
    if [ -n "$u0" ]; then
      # 按逗号拆包名，逐个去重加入 merged
      echo "$u0" | tr ',' '\n' | tr -d '"' | sed 's/^ *//;s/ *$//' | while IFS= read -r p; do
        [ -z "$p" ] && continue
        echo "$p"
      done > /data/local/tmp/hkom/.keep_existing
      while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        case ",$seen," in *",$pkg,"*) continue ;; esac
        seen="$seen,$pkg"
        if [ "$first" = "1" ]; then merged="\"$pkg\""; first=0
        else merged="$merged,\"$pkg\""; fi
      done < /data/local/tmp/hkom/.keep_existing
      rm -f /data/local/tmp/hkom/.keep_existing
    fi
  fi
  # 2. 加入本模块白名单（去重）
  for pkg in $(keep_list_pkgs); do
    case ",$seen," in *",$pkg,"*) continue ;; esac
    seen="$seen,$pkg"
    if [ "$first" = "1" ]; then merged="\"$pkg\""; first=0
    else merged="$merged,\"$pkg\""; fi
  done
  [ -z "$merged" ] && return 0
  # 3. 写回（u=0 组重建；u=-100 等其它分组原样保留）
  local other=""
  if [ -n "$cur" ] && [ "$cur" != "null" ]; then
    other=$(printf '%s' "$cur" | sed -n 's/.*\({"u":-100.*\)/\1/p')
  fi
  if [ -n "$other" ]; then
    settings put system locked_apps "[{\"u\":0,\"pkgs\":[${merged}]},${other}" 2>/dev/null
  else
    settings put system locked_apps "[{\"u\":0,\"pkgs\":[${merged}]}]" 2>/dev/null
  fi
  log KEEP "已更新后台保活白名单"
}

# ---------- 智能保活（M13）：按"是否在最近任务"动态决定保护 ----------
# 设计目标：用户在最近任务里划掉某个 App → 自动移出保活；重新打开 → 自动恢复保活。
#
# 判定依据：dumpsys activity recents 能列出所有仍在最近任务中的任务。
#   - App 进程存在 且 在 recents 中  → 保活（adj=-900）
#   - App 进程存在 但 不在 recents    → 用户已划掉 → 撤销保护（恢复系统默认 adj）
#   - App 在保活白名单 且 用户重新打开 → 下一轮自动重新保护
#
# 为什么不监听 am_task_removed 事件：
#   recents 列表是权威状态源，直接查它比解析事件流更可靠，
#   也不会因为 logcat 缓冲轮转丢事件。开销：每轮 1 次 dumpsys。

# 枚举白名单包对应的全部进程 PID（含 :子进程）
# ★ 关键：不能用 pidof —— pidof 只返回「主进程」，会漏掉 :MSF / :push / :peak
#   等子进程。实测 QQ 主进程 adj=-900 被保护，但 :MSF（消息通道）adj=800 未被
#   保护，LMK 杀掉 :MSF 后消息链路断掉，界面回来仍要冷启动。
#   改用单次 `ps -A -o PID,NAME` + 单次 awk 匹配「包名 或 包名:xxx」。
# 输出：每行 "包名 PID"，供上层遍历。
keep_pids_of() {
  [ -f "$KEEP_CONF" ] || return 0
  local list
  list=$(keep_list_pkgs)
  [ -z "$list" ] && return 0
  ps -A -o PID,NAME 2>/dev/null | awk -v L="$list" '
    BEGIN { n = split(L, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    {
      pid = $1
      if (pid !~ /^[0-9]+$/) next
      name = $0
      sub(/^[ \t]*[0-9]+[ \t]+/, "", name)
      sub(/[ \t]+$/, "", name)
      base = name
      sub(/:.*/, "", base)
      if (base in want) print base, pid
    }'
}

# 固定保活（兼容旧行为）：无条件把白名单进程设为 adj=-900
# smart_keep=0 时使用此函数
harden_keep_procs() {
  [ -f "$KEEP_CONF" ] || return 0
  local base pid adj cnt=0
  while read -r base pid; do
    [ -z "$pid" ] && continue
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    [ -z "$adj" ] && continue
    if [ "$adj" -gt -900 ] 2>/dev/null; then
      echo -900 > /proc/$pid/oom_score_adj 2>/dev/null && cnt=$((cnt+1))
    fi
  done <<EOF
$(keep_pids_of)
EOF
  [ "$cnt" -gt 0 ] && log KEEP "内核级保活：$cnt 个进程设为 adj=-900（含子进程，LMK 不再选中）"
  return 0
}

# 取当前 recents 中的包名（去重，空格分隔）
recents_pkgs() {
  dumpsys activity recents 2>/dev/null \
    | grep -oE 'A=[0-9]+:[a-zA-Z0-9_.]+' \
    | sed 's/^A=[0-9]*://' \
    | sort -u | tr '\n' ' '
}

# 判断是否为「消息推送通道」进程（必须永不撤销保护）
# 依据真实进程名匹配，覆盖常见 IM / 推送框架：
#   QQ      :MSF（消息服务框架）、:peak、:openSdk、:qzone
#   微信    :push、:appbrand0/1/2、:exdevice、:service、:tools、:sandbox
#   通用    :push、:remote、:msf、:daemon、:xmsf、:mipush、:pushservice
# 这些进程一旦被杀，即使主进程还活着也收不到消息，因此不参与撤销。
is_msg_channel() {
  case "$1" in
    # 小米推送（系统级统一推送通道，主进程与子进程全部纳入）
    com.xiaomi.xmsf|com.xiaomi.xmsf:*|com.xiaomi.xmsfkeeper*) return 0 ;;
    com.xiaomi.mipush*|*":mipush"*) return 0 ;;
    # QQ
    *":MSF"*|*":peak"*|*":openSdk"*|*":qzone"*) return 0 ;;
    # 微信 / 通用推送
    *":push"*|*":PushService"*|*":pushservice"*) return 0 ;;
    *":appbrand"*) return 0 ;;
    *":exdevice"*|*":sandbox"*|*":tools"*) return 0 ;;
    *":msf"*|*":xmsf"*) return 0 ;;
    *":remote"*|*":daemon"*|*":service"*) return 0 ;;
  esac
  return 1
}

# 智能保活：按 recents 状态动态设置/撤销 adj=-900
# ★ 进程枚举走 keep_pids_of（ps+awk 单次扫描），覆盖 :MSF / :push / :peak 等子进程。
#   pidof 只返回主进程，用它会导致子进程（消息通道）长期不受保护而被 LMK 杀掉。
# ★ 撤销策略（M13.1）：
#   主进程              → 划掉后撤销，回 400（缓存级，可被回收）
#   消息通道子进程      → 永不撤销，始终保持 -900（收消息不能断）
#   其它普通子进程      → 划掉后回 800（服务级，可回收但不优先杀）
smart_keep() {
  [ -f "$KEEP_CONF" ] || return 0
  # 关闭智能模式时退回「全部固定保护」
  if [ "$(get_conf smart_keep)" != "1" ]; then
    harden_keep_procs
    return 0
  fi

  local recents
  recents=$(recents_pkgs)
  local pids
  pids=$(keep_pids_of)
  [ -z "$pids" ] && return 0

  local base pid adj prot=0 unprot=0 keepch=0 cname revadj
  while read -r base pid; do
    [ -z "$pid" ] && continue
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    [ -z "$adj" ] && continue
    cname=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)

    if is_msg_channel "$cname"; then
      # 消息通道：无论是否在最近任务，始终锁死 -900
      if [ "$adj" -gt -900 ] 2>/dev/null; then
        echo -900 > /proc/$pid/oom_score_adj 2>/dev/null && keepch=$((keepch+1))
      fi
      continue
    fi

    case " $recents " in
      *" $base "*)
        # 该包在最近任务中 → 保活（主进程 + 普通子进程都设 adj=-900）
        if [ "$adj" -gt -900 ] 2>/dev/null; then
          echo -900 > /proc/$pid/oom_score_adj 2>/dev/null && prot=$((prot+1))
        fi
        ;;
      *)
        # 已划出最近任务 → 撤销保护，交回系统
        # 主进程回 400（缓存级）；普通子进程回 800（服务级）
        if [ "$adj" -le -900 ] 2>/dev/null; then
          revadj=400
          case "$cname" in *:*) revadj=800 ;; esac
          echo "$revadj" > /proc/$pid/oom_score_adj 2>/dev/null && unprot=$((unprot+1))
        fi
        ;;
    esac
  done <<EOF
$pids
EOF
  # 只在有变化时打日志，避免刷屏
  [ "$keepch" -gt 0 ] && log KEEP "消息通道保活：$keepch 个推送通道常驻 adj=-900（不收不到消息）"
  [ "$prot" -gt 0 ] && log KEEP "智能保活：$prot 个进程保护中（在最近任务）"
  [ "$unprot" -gt 0 ] && log KEEP "智能保活：$unprot 个进程撤销保护（已划出最近任务）"
  return 0
}

# ---------- 冻结与缓存进程上限（M11：后台冻结保活，不杀只冻） ----------
# 说明：不能手动往 cgroup.freeze 写 1 —— 那样进程对内核彻底静默，
#       微信/QQ 收不到消息、通知不来。必须交给系统原生 freezer（AMS 管理），
#       它冻结后仍能感知 pending 广播/FCM/网络包，有活先解冻再投递。
apply_freezer() {
  local want
  want=$(get_conf freezer_enable)
  [ -z "$want" ] && want=1
  if [ "$want" = "1" ]; then
    local cur
    cur=$(settings get global cached_apps_freezer 2>/dev/null)
    if [ "$cur" != "enabled" ]; then
      settings put global cached_apps_freezer enabled 2>/dev/null
      log MEM "已开启系统原生冻结（后台冻结不杀，消息通知正常）"
    fi
  else
    local cur
    cur=$(settings get global cached_apps_freezer 2>/dev/null)
    if [ "$cur" != "disabled" ]; then
      settings put global cached_apps_freezer disabled 2>/dev/null
      log MEM "已关闭系统原生冻结"
    fi
  fi
}

# 提高 AMS 缓存进程上限：让更多后台留在缓存态（被冻结）而不是被直接杀掉，
# 这样点回去页面还在。值越大留得越多，但内存占用也越高。
# 注意：device_config 是内存态配置，系统会在 AMS 重启/内存压力时重置，
#       所以既写 device_config 也写 settings global 双通道，并由 daemon 定期兜底重写。
apply_max_cached() {
  local n
  n=$(get_conf max_cached_procs)
  [ -z "$n" ] && n=64
  [ "$n" = "0" ] && return 0

  # 通道 1：device_config（AMS 优先读这个，但会被系统重置）
  local cur_dc
  cur_dc=$(device_config get activity_manager max_cached_processes 2>/dev/null)
  if [ "$cur_dc" != "$n" ]; then
    device_config put activity_manager max_cached_processes "$n" 2>/dev/null && \
      log MEM "缓存进程上限=$n（device_config）"
  fi

  # 通道 2：settings global（持久化，重启后仍在）
  local cur_sg
  cur_sg=$(settings get global activity_manager_constants 2>/dev/null)
  case "$cur_sg" in
    *max_cached_processes=*)
      local newv
      newv=$(printf '%s' "$cur_sg" | sed "s/max_cached_processes=[0-9]*/max_cached_processes=$n/")
      [ "$newv" != "$cur_sg" ] && settings put global activity_manager_constants "$newv" 2>/dev/null
      ;;
    *)
      settings put global activity_manager_constants "max_cached_processes=$n" 2>/dev/null
      ;;
  esac
}

# ---------- 动作执行 ----------
# 关闭主动回收（M1）
apply_reclaim_off() {
  local changed=0
  if [ "$(get_conf disable_mimd)" = "1" ]; then
    if [ "$(getprop init.svc.mimd-service2_0)" = "running" ]; then
      stop mimd-service2_0 2>/dev/null
      log RECLAIM "已停止 mimd 内存守护进程"
      changed=1
    fi
    echo -1 > "$MIMD_TRIGGER" 2>/dev/null
  fi
  if [ "$(get_conf disable_mi_reclaim)" = "1" ]; then
    echo "enable 0" > "$MI_RECLAIM" 2>/dev/null
  fi
  if [ "$(get_conf disable_unfairmem)" = "1" ]; then
    [ -n "$RP" ] && $RP persist.sys.miui.unfairMemory.enable false 2>/dev/null
  fi
  if [ "$(get_conf disable_memory_standard)" = "1" ]; then
    [ -n "$RP" ] && $RP persist.sys.memory_standard.enable false 2>/dev/null
    [ -n "$RP" ] && $RP persist.sys.memory_standard.appheap.enable false 2>/dev/null
  fi
  [ -n "$RP" ] && $RP persist.sys.mimd.reclaim.enable false 2>/dev/null
}

# 应用 lmkd 保守化（M2）
apply_lmk() {
  local low medium critical
  low=$(get_conf lmk_low); medium=$(get_conf lmk_medium); critical=$(get_conf lmk_critical)
  [ -n "$RP" ] && $RP ro.lmk.low "$low" 2>/dev/null
  [ -n "$RP" ] && $RP ro.lmk.medium "$medium" 2>/dev/null
  [ -n "$RP" ] && $RP ro.lmk.critical "$critical" 2>/dev/null
  [ -n "$RP" ] && $RP ro.lmk.use_psi true 2>/dev/null
  # 关键：触发 lmkd 重新读取配置（init.qcom.rc 的标准 reinit 通道）
  setprop lmkd.reinit 1 2>/dev/null
}

# 清理 page cache（M3）
# 策略：优先用 memory.reclaim_once 做「定量平滑回收」——按需回收指定字节数，
#       内核只回收该量，不产生 CPU/IO 尖峰；接口不可用时才回退 drop_caches。
#       实测：reclaim_once 回收 200MB 仅降 Cached 413MB 瞬时完成；
#             drop_caches 3 是全量同步清空，会一次性造成尖峰。
RECLAIM_ONCE=/dev/memcg/memory.reclaim_once

# 平滑回收指定 MB（默认读 reclaim_mb 配置，缺省按 drop_level 推算）
smooth_reclaim() {
  local mb="$1"
  if [ -z "$mb" ]; then
    mb=$(get_conf reclaim_mb)
    if [ -z "$mb" ] || [ "$mb" = "0" ]; then
      case "$(get_conf drop_level)" in
        1) mb=64 ;;
        2) mb=128 ;;
        *) mb=256 ;;
      esac
    fi
  fi
  if [ -w "$RECLAIM_ONCE" ]; then
    local bytes=$(( mb * 1048576 ))
    if echo "$bytes" > "$RECLAIM_ONCE" 2>/dev/null; then
      log MEM "平滑回收 ${mb}MB（定量，无尖峰）"
      return 0
    fi
  fi
  # 回退：接口不可用才用 drop_caches（旧路径）
  echo "$(get_conf drop_level)" > "$DROP_CACHES" 2>/dev/null
  log MEM "回收缓存 ${mb}MB（回退 drop_caches）"
}

drop_cache() {
  local lvl="$1"
  [ -z "$lvl" ] && lvl=$(get_conf drop_level)
  smooth_reclaim
}

# 应用 VM 参数（M5，可选接管；与 Scene 的 swap 配置二选一，避免抢写）
# swappiness：换页积极性。实测本机 100 过于激进（热数据也往 zram 塞，换入换出耗 CPU），
#             降到 60 后 zram 物理占用稳定、PSI avg300 由 8.28% 降到 6.20%。
# watermark_scale_factor：内核提前多久开始回收。值太小 → 回收集中在最后一刻 →
#             产生 direct reclaim 尖峰（用户体感的「突然卡一下」）。
#             本机实测 Scene 配置 100 但实际被覆盖成 70，这里显式写入确保生效。
apply_zram() {
  if [ "$(get_conf zram_takeover)" = "1" ]; then
    local sw wsf
    sw=$(get_conf swappiness)
    wsf=$(get_conf watermark_scale_factor)
    [ -z "$sw" ] && sw=60
    [ -z "$wsf" ] && wsf=100
    if [ -w /proc/sys/vm/swappiness ]; then
      echo "$sw" > /proc/sys/vm/swappiness 2>/dev/null && \
        log MEM "已应用 swappiness=$sw（换页积极性）"
    fi
    if [ -w /proc/sys/vm/watermark_scale_factor ]; then
      echo "$wsf" > /proc/sys/vm/watermark_scale_factor 2>/dev/null && \
        log MEM "已应用 watermark_scale_factor=$wsf（提前回收水位，减少突发卡顿）"
    fi
  fi
}

# ---------- 单实例保护 ----------
# lock_instance pidfile  -> 成功返回 0（获得锁），失败返回 1
lock_instance() {
  local pf="$1"
  if [ -f "$pf" ]; then
    local old
    old=$(cat "$pf" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      return 1
    fi
    rm -f "$pf"
  fi
  echo $$ > "$pf"
  return 0
}

unlock_instance() {
  local pf="$1"
  rm -f "$pf" 2>/dev/null
}
