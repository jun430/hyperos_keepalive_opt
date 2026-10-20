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
DEF_swappiness=80
# daemon
DEF_poll_normal=10
DEF_poll_game=3

# 配置项名列表（用于 get_conf 兜底）
CONF_KEYS="disable_mimd disable_unfairmem disable_mi_reclaim disable_memory_standard lmk_low lmk_medium lmk_critical watermark_target watermark_hysteresis drop_level game_mode game_kill_cached game_drop_caches zram_takeover swappiness poll_normal poll_game"

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

# 读取 keep.conf 所有包名（空格分隔，供 JSON 拼接）
keep_list_pkgs() {
  [ -f "$KEEP_CONF" ] || return 0
  grep -E '^[A-Za-z]' "$KEEP_CONF" 2>/dev/null | tr '\n' ' '
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
drop_cache() {
  local lvl="$1"
  [ -z "$lvl" ] && lvl=$(get_conf drop_level)
  echo "$lvl" > "$DROP_CACHES" 2>/dev/null
}

# 应用 zram 配置（M5，可选接管）
apply_zram() {
  if [ "$(get_conf zram_takeover)" = "1" ]; then
    local sw
    sw=$(get_conf swappiness)
    echo "$sw" > /proc/sys/vm/swappiness 2>/dev/null
    log MEM "已应用 swappiness=$sw（换页积极性）"
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
