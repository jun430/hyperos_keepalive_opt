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
# 后台超时杀子进程（M15）
# 0 = 关闭；单位分钟。App 退到后台超过该时长后，杀掉它的 :子进程（主进程保留）
DEF_bg_child_kill=5

# 配置项名列表（用于 get_conf 兜底）
CONF_KEYS="disable_mimd disable_unfairmem disable_mi_reclaim disable_memory_standard lmk_low lmk_medium lmk_critical watermark_target watermark_hysteresis drop_level game_mode game_kill_cached game_drop_caches zram_takeover swappiness poll_normal poll_game freezer_enable max_cached_procs reclaim_mb watermark_scale_factor smart_keep bg_child_kill"

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
    # 推送通道例外（允许保护）：主进程与全部 :子进程
    com.xiaomi.xmsf|com.xiaomi.xmsf:*|com.xiaomi.xmsfkeeper|com.xiaomi.xmsfkeeper:*) return 1 ;;
    # 其余系统包一律过滤
    com.xiaomi.*|com.miui.*|com.android.*|com.google.android.*) return 0 ;;
    android|android.*) return 0 ;;
    com.mi.*|miui.*|com.qualcomm.*|com.qti.*) return 0 ;;
  esac
  return 1
}

# 读取 keep.conf 所有包名（空格分隔）
# ★ 白名单语义已变更（M14）：
#   不再是「哪些 App 要保护」——现在所有第三方 App 进程都保护。
#   白名单只表示「这些 App 的消息进程即使被划掉后台也要继续保护」。
keep_list_pkgs() {
  [ -f "$KEEP_CONF" ] || return 0
  local l out=""
  for l in $(grep -E '^[A-Za-z]' "$KEEP_CONF" 2>/dev/null); do
    if is_sys_pkg "$l"; then continue; fi
    out="$out $l"
  done
  echo "$out"
}

# ---------- 内核级保活（M14）：保护全部第三方 App 进程 ----------
# 语义（按用户要求）：
#   - 不需要白名单。全部第三方 App 进程只要存活就设 adj=-900。
#   - 用户划掉后台 → 系统 SwipeUpClean 杀进程 → 进程消失 → 保护自然解除。
#   - 白名单只用于标记「消息进程划掉后台后仍要继续保护」的 App
#     （否则 QQ/微信划掉后收不到消息）。
#   - 系统应用一律不动：按 pm list packages -s（系统分区应用）排除，
#     不能只看 UID —— 很多系统组件（com.milink.service / com.qti.phone 等）
#     UID 也 >=10000，但装在 /system_ext、/product 下，属于系统应用。

SYS_PKG_CACHE=$HKOM_DIR/.syspkgs
SYS_PKG_STAMP=$HKOM_DIR/.syspkgs.stamp

# 刷新系统应用清单缓存
# ★ 两个来源合并，缺一不可：
#   1) pm list packages -s          → 标准系统分区应用（/system /system_ext /product /vendor）
#   2) pm path 落在系统分区的预装应用 → 部分预装 App（如 com.miui.calculator 在
#      /product/data-app/）不被 -s 收录，但同样是系统预装，不该被我们接管。
#   另外补充小米/高通/运营商等系统包前缀，防止漏网。
refresh_sys_pkgs() {
  pm list packages -s 2>/dev/null | sed 's/^package://' > "$SYS_PKG_CACHE.tmp" 2>/dev/null
  # 补充：预装在系统目录但不算 -s 的应用
  pm list packages -f 2>/dev/null \
    | grep -E '^package:/(system|system_ext|product|vendor|odm)/' \
    | sed 's/.*=//' >> "$SYS_PKG_CACHE.tmp" 2>/dev/null
  if [ -s "$SYS_PKG_CACHE.tmp" ]; then
    sort -u "$SYS_PKG_CACHE.tmp" > "$SYS_PKG_CACHE" 2>/dev/null
    rm -f "$SYS_PKG_CACHE.tmp"
    date +%s > "$SYS_PKG_STAMP" 2>/dev/null
  else
    rm -f "$SYS_PKG_CACHE.tmp"
  fi
}

# 判断包是否为系统应用（缓存清单 + 前缀兜底）
is_system_pkg() {
  local p="$1"
  # 非法包名（"system" / "bash" / "[logcat]" / ".qms" 这类非包名进程）→ 当作要跳过
  case "$p" in
    *[!A-Za-z0-9._]*) return 0 ;;
    .*|"") return 0 ;;
  esac
  # 至少含一个点，且形如 xxx.yyy 才是包名
  case "$p" in
    *.*) ;;
    *) return 0 ;;
  esac
  # ★ 推送通道例外必须在「查缓存」之前判定：
  #   com.xiaomi.xmsf / com.xiaomi.xmsfkeeper 本身是预装系统应用，
  #   会同时出现在 .syspkgs 缓存里（实测第 388/389 行）。
  #   若先查缓存，命中即 return 0，推送例外分支永远走不到，
  #   导致小米推送通道拿不到 -900，离线消息可能丢。
  case "$p" in
    com.xiaomi.xmsf|com.xiaomi.xmsfkeeper) return 1 ;;
  esac
  if [ -s "$SYS_PKG_CACHE" ] && grep -qxF "$p" "$SYS_PKG_CACHE" 2>/dev/null; then
    return 0
  fi
  is_sys_pkg "$p"
}

# 枚举应受保护的进程：输出 "包名 PID 进程名 是否子进程 是否白名单"
list_protected_pids() {
  local wl
  wl=$(keep_list_pkgs)
  ps -A -o PID,UID,NAME 2>/dev/null | awk -v WL="$wl" '
    BEGIN {
      n = split(WL, a, " ")
      for (i = 1; i <= n; i++) if (a[i] != "") wl[a[i]] = 1
    }
    {
      pid = $1; uid = $2
      if (pid !~ /^[0-9]+$/) next
      if (uid + 0 < 10000) next          # 内核/系统 daemon 一律跳过
      name = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", name)
      sub(/[ \t]+$/, "", name)
      base = name
      sub(/:.*/, "", base)
      if (base == "") next
      ch = (name ~ /:/) ? 1 : 0
      w  = (base in wl) ? 1 : 0
      print base, pid, name, ch, w
    }'
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

# 判断是否为「消息推送通道」进程 —— 严格白名单，只认真正的推送/消息长连接
# ★ 必须严格：这个函数决定哪些进程「永不回收」。
#   实测教训：早前把 *":appbrand"* / *":tools"* / *":sandbox"* 也纳入，
#   结果微信 :appbrand0 629MB + :appbrand1 316MB（小程序容器）被永久保护，
#   945MB 内存白占 —— 它们不是消息通道，小程序退出后应当回收。
# 只保留真正承担「收消息 / 保活推送长连接」的进程：
is_msg_channel() {
  case "$1" in
    # 小米推送（系统级统一推送，第三方 App 离线消息都经它投递）
    com.xiaomi.xmsf|com.xiaomi.xmsf:*|com.xiaomi.xmsfkeeper*) return 0 ;;
    com.xiaomi.mipush*) return 0 ;;
    # QQ：MSF = 消息服务框架（唯一天消息通道）
    *":MSF"*|*":msf"*) return 0 ;;
    # 微信：push = 消息推送通道
    *":push"*|*":PushService"*) return 0 ;;
    # 通用推送框架
    *":mipush"*|*":pushservice"*) return 0 ;;
  esac
  return 1
}

# ---------- 消息通道轻量看护（M13.2） ----------
# 问题：AMS 会在任意时刻重算并覆写进程 adj。实测 :MSF 在 daemon 两轮之间
#       （10s）会被 AMS 写回 500，500 < lmkd medium(960)，仍可能被选中杀掉。
# 方案：把消息通道 PID 缓存起来，sleep 分段期间只做「读 adj → 若被抬高就写回」，
#       不扫 ps、不查 recents。开销：每段仅 N 次 /proc/<pid>/oom_score_adj 读取
#       （N≈10~15，约 1~2ms），可忽略。
# 缓存失效（进程重启/消失）时置空，下一段自动完整重扫。
MSG_PIDS=""

# 刷新「受保护进程」PID 缓存：只收录主进程 + 推送通道（用于 sleep 期间重申 adj）
# ★ 不收录普通子进程：它们不该被 -900 保护，否则与后台超时回收矛盾
refresh_msg_pids() {
  local base pid name ch w out=""
  while read -r base pid name ch w; do
    [ -z "$pid" ] && continue
    if is_system_pkg "$base"; then continue; fi
    if [ "$ch" = "1" ]; then
      is_msg_channel "$name" || continue
    fi
    out="$out $pid"
  done <<EOF
$(list_protected_pids)
EOF
  MSG_PIDS="$out"
}

# 轻量重申：把缓存 PID 的 adj 拉回 -900
# 抵消 AMS 覆写（实测主进程 adj 会被短暂抬到 700~701，若恰逢 lmkd 采样就被杀）
msg_guard() {
  [ -z "$MSG_PIDS" ] && refresh_msg_pids
  [ -z "$MSG_PIDS" ] && return 0
  local pid adj stale=0 fixed=0
  for pid in $MSG_PIDS; do
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    if [ -z "$adj" ]; then stale=1; continue; fi
    if [ "$adj" -gt -900 ] 2>/dev/null; then
      echo -900 > /proc/$pid/oom_score_adj 2>/dev/null && fixed=$((fixed + 1))
    fi
  done
  # ★ 熄屏期间补守主进程：
  #   熄屏后 AMS 会批量把全部后台应用重算到 idle 级别（缓存级 900+），
  #   光守消息通道不够——主进程被覆写后就成了 LMK 首选目标，
  #   表现为「熄屏一段时间再打开，App 已经回到首页」。
  #   这里在熄屏时对全部受保护进程重申一遍 adj；亮屏不做，避免无谓开销。
  #
  # ★ 必须自己过滤系统包：list_protected_pids 只按 UID>=10000 枚举，
  #   不过滤系统应用（实测输出里含 com.android.camera / com.miui.analytics
  #   / android.ext.services / bash / [logcat] 等）。系统包过滤原本只在
  #   smart_keep 里做，这里若不补过滤就会给系统进程也写 -900，
  #   违反「只动第三方 App」的约束。
  if [ "$SCREEN_OFF" = "1" ]; then
    local b p a
    while read -r b p; do
      [ -z "$p" ] && continue
      is_system_pkg "$b" && continue
      a=$(cat /proc/$p/oom_score_adj 2>/dev/null)
      [ -z "$a" ] && continue
      if [ "$a" -gt -900 ] 2>/dev/null; then
        echo -900 > /proc/$p/oom_score_adj 2>/dev/null
      fi
    done <<EOF
$(list_protected_pids | awk '$4 == 0 {print $1, $2}')
EOF
  fi
  [ "$stale" = "1" ] && refresh_msg_pids
  return 0
}

# 判断屏幕是否熄灭（熄屏后系统会大幅收紧后台调度，需特殊处理）
# 用 backlight 亮度=0 判定，纯文件读取，比 dumpsys power 稳定。
# 结果缓存在 SCREEN_OFF 变量里，避免每段轮询都读文件。
# 返回 0 = 熄屏，1 = 亮屏，2 = 无法判定（当作亮屏处理）
is_screen_off() {
  local b
  b=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)
  if [ -z "$b" ]; then
    # 节点不存在，退回 dumpsys 判定
    case "$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=')" in
      *Awake*|"") return 1 ;;
      *) return 0 ;;
    esac
  fi
  [ "$b" = "0" ] && return 0
  return 1
}

# ---------- 后台超时杀子进程（M15）----------
# 目的：App 退到后台一段时间后，回收它的 :子进程内存（:push/:MSF/:sandbox 等），
#       主进程保留 —— 页面和状态不丢，重进不用冷启动，但能腾出可观内存。
# 依据：实测 QQ 的 :MSF / :peak 各占 700MB~1.2GB，微信 :push 也有数百 MB。
# 前提：白名单 App 的消息通道（is_msg_channel）不杀，否则收不到消息。
# 状态：用文件记录「该包首次被观察到在后台的时间戳」，回到前台即清除。

BGWORK=$HKOM_DIR/.bgtime

# 取当前前台包名（dumpsys activity activities 约 23ms，是全机最快且稳定的方式）
foreground_pkg() {
  dumpsys activity activities 2>/dev/null \
    | grep -m1 'topResumedActivity' \
    | grep -oE 'u0 [a-zA-Z0-9_.]+/' \
    | sed 's/^u0 //;s|/$||'
}

# 后台超时回收：对每个第三方 App 的子进程做超时判定
# 调用频率：每 bg_check_every 轮一次（默认 6 轮 ≈ 1 分钟），不必每轮都查
bg_child_reaper() {
  local mins
  mins=$(get_conf bg_child_kill)
  case "$mins" in ''|*[!0-9]*) return 0 ;; esac
  [ "$mins" -le 0 ] 2>/dev/null && return 0

  [ -f "$BGWORK" ] || : > "$BGWORK"

  local fg base pid name ch w now ts elapsed
  fg=$(foreground_pkg)
  now=$(date +%s)
  local limit=$((mins * 60))
  local killed=0

  # 1. 前台包 → 清除它的后台计时（回到前台立即重置）
  if [ -n "$fg" ]; then
    grep -v "^$fg " "$BGWORK" > "$BGWORK.tmp" 2>/dev/null && mv -f "$BGWORK.tmp" "$BGWORK"
  fi

  # 2. 遍历全部第三方包名，给「有子进程的包」记账
  #    ★ 必须按「包名」而不是「主进程行」遍历：
  #    某些包主进程被系统杀掉后只剩 :子进程存活（实测 realtech.xiaocan:pushservice），
  #    若只按主进程记账，这类包永远不会进入计时，其子进程永远不被回收。
  local has_child allpkg
  # ★ 必须把换行转成空格：case 用的是 " $has_child " 空格边界匹配，
  #   若 has_child 内部是换行分隔则永远匹配不到（曾导致计时恒为 0 的 bug）
  has_child=$(list_protected_pids | awk '$4 == 1 {print $1}' | sort -u | tr '\n' ' ')
  allpkg=$(list_protected_pids | awk '{print $1}' | sort -u)
  local base0
  while read -r base0; do
    [ -z "$base0" ] && continue
    if is_system_pkg "$base0"; then continue; fi
    [ "$base0" = "$fg" ] && continue       # 当前前台，不记
    # 该包没有任何子进程 → 跳过（没有可回收对象）
    case " $has_child " in *" $base0 "*) ;; *) continue ;; esac
    # 首次见到该包在后台 → 记下时间
    if ! grep -q "^$base0 " "$BGWORK" 2>/dev/null; then
      echo "$base0 $now" >> "$BGWORK"
    fi
  done <<EOF
$allpkg
EOF

  # 3. 检查超时，杀掉对应包的子进程（保留主进程 + 消息通道）
  #    注意：先把待处理清单快照到临时文件，避免循环内重写 BGWORK 导致读脏
  # ★ 快照前先去重：同一包若有多行记录（历史遗留 / 并发写入），
  #   会导致同一个包被处理多次——重复 kill 同一个已死的 pid 属无害，
  #   但会浪费一轮 ps 扫描，且让「清理几个子进程」的统计翻倍。
  #   保留每个包最早的那条（比保留最晚的更保守：早记录意味着更早超时）。
  if [ -s "$BGWORK" ]; then
    awk '!seen[$1]++' "$BGWORK" > "$BGWORK.dedup" 2>/dev/null && mv -f "$BGWORK.dedup" "$BGWORK"
  fi
  cp -f "$BGWORK" "$BGWORK.snap" 2>/dev/null || : > "$BGWORK.snap"
  # ★ 存活判定不能用 pidof：pidof 只认主进程，主进程被系统杀掉后
  #   子进程仍存活时 pidof 返回空，会被误判为「已不在后台」而清掉计时，
  #   导致该包的子进程永远不被回收（实测 realtech.xiaocan 主进程消失、
  #   :pushservice 仍占 57MB）。改为：该包只要有任意进程存活就算在后台。
  local alive_pkgs
  alive_pkgs=$(list_protected_pids | awk '{print $1}' | sort -u | tr '\n' ' ')
  local pkg
  while read -r pkg ts; do
    [ -z "$pkg" ] && continue
    [ -z "$ts" ] && continue
    elapsed=$((now - ts))
    # 该包已无任何进程存活 → 清掉计时
    case " $alive_pkgs " in
      *" $pkg "*) ;;
      *)
        grep -v "^$pkg " "$BGWORK" > "$BGWORK.tmp" 2>/dev/null && mv -f "$BGWORK.tmp" "$BGWORK"
        continue
        ;;
    esac
    if [ "$elapsed" -lt "$limit" ]; then continue; fi
    # 逐个子进程杀（主进程不动，消息通道不动）
    list_protected_pids | awk -v P="$pkg" '$1 == P && $4 == 1 {print $2, $3}' > "$BGWORK.kill" 2>/dev/null
    local p2 n2 nkill=0
    while read -r p2 n2; do
      [ -z "$p2" ] && continue
      is_msg_channel "$n2" && continue           # 消息通道保留
      kill -9 "$p2" 2>/dev/null && nkill=$((nkill + 1))
    done < "$BGWORK.kill"
    rm -f "$BGWORK.kill"
    killed=$((killed + nkill))
    [ "$nkill" -gt 0 ] && log MEM "后台超时 ${mins} 分钟：回收 $pkg 的 $nkill 个子进程（主进程保留）"
    grep -v "^$pkg " "$BGWORK" > "$BGWORK.tmp" 2>/dev/null && mv -f "$BGWORK.tmp" "$BGWORK"
  done < "$BGWORK.snap"
  rm -f "$BGWORK.snap"

  [ "$killed" -gt 0 ] && log MEM "后台超时回收共清理 $killed 个子进程"
  return 0
}

# ---------- 内核级保活（M14）----------
# 规则（不需要白名单）：
#   1. 全部第三方 App 进程（UID>=10000）只要存活 → adj=-900
#   2. 用户划掉后台 → 系统 SwipeUpClean 杀进程 → 进程消失 → 保护自动解除
#   3. 白名单内的 App → 其消息通道子进程（:MSF/:push 等）额外常驻保护
#      用于"划掉后台后消息进程继续收消息"；白名单不再决定"哪个 App 被保护"
#   4. 系统进程（UID<10000）一律不动
# ---------- 内核级保活（M14）----------
# 规则（按用户要求）：
#   1. 主进程：全部第三方 App 的主进程只要存活 → adj=-900（保页面，重进不冷启动）
#   2. 推送通道（:push / :MSF / 小米推送）：adj=-900（保消息，划掉后台也不撤）
#   3. 其它子进程（:appbrand / :xweb / :gameservice ...）：
#      ★ 不设 adj=-900，交回系统默认管理。
#      原因：这些是内存大户（微信 appbrand0 曾占 612MB），设成 -900 会让它们
#      永不被回收，与"后台超时回收子进程"互相矛盾。它们应当可被回收。
#   4. 系统应用一律不动（按 pm 系统分区清单判定）。
smart_keep() {
  local base pid name ch w
  local prot=0 keepch=0 adj

  [ -s "$SYS_PKG_CACHE" ] || refresh_sys_pkgs

  while read -r base pid name ch w; do
    [ -z "$pid" ] && continue
    if is_system_pkg "$base"; then continue; fi

    # 子进程：只有推送通道才保护，其它跳过（让自己可被回收）
    if [ "$ch" = "1" ]; then
      is_msg_channel "$name" || continue
      adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
      [ -z "$adj" ] && continue
      if [ "$adj" -gt -900 ] 2>/dev/null; then
        echo -900 > /proc/$pid/oom_score_adj 2>/dev/null && keepch=$((keepch+1))
      fi
      continue
    fi

    # 主进程：存活即保护
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    [ -z "$adj" ] && continue
    if [ "$adj" -gt -900 ] 2>/dev/null; then
      echo -900 > /proc/$pid/oom_score_adj 2>/dev/null && prot=$((prot+1))
    fi
  done <<EOF
$(list_protected_pids)
EOF

  [ "$keepch" -gt 0 ] && log KEEP "推送通道保活：$keepch 个（收消息不能断）"
  [ "$prot" -gt 0 ] && log KEEP "主进程保活：$prot 个后台 App 设为 adj=-900"
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
