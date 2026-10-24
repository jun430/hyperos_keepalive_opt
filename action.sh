#!/system/bin/sh
# ============================================================
# 澎湃内存管理优化 - action.sh（动作执行器）
# 由 WebUI / daemon 调用，执行单一动作并输出结果
# 用法: action.sh <command> [args]
# ============================================================
MODDIR=$(dirname "$0")
source "$MODDIR/lib.sh"

cmd="$1"
shift 2>/dev/null

case "$cmd" in
  # ---- 配置读写（WebUI 用）----
  get)
    get_conf "$1"
    ;;
  set)
    set_conf "$1" "$2"
    echo "ok"
    ;;
  list_conf)
    for k in $CONF_KEYS; do
      echo "$k=$(get_conf $k)"
    done
    ;;

  # ---- 一键应用当前配置 ----
  apply)
    apply_reclaim_off
    apply_lmk
    apply_zram
    apply_freezer
    apply_max_cached
    apply_keep_list
    log INF "配置应用完成"
    echo "applied"
    ;;

  # ---- 内存快照（WebUI 仪表盘）----
  snapshot)
    mem_snapshot
    echo "total=$MEM_TOTAL"
    echo "free=$MEM_FREE"
    echo "avail=$MEM_AVAIL"
    echo "cached=$MEM_CACHED"
    echo "avail_pct=$MEM_AVAIL_PCT"
    echo "used_pct=$MEM_USED_PCT"
    echo "zram_used_mb=$(zram_used_mb)"
    echo "zram_ratio=$(zram_ratio)"
    echo "psi300=$(psi_avg300)"
    echo "zram_algo=$(cat $ZRAM_ALGO 2>/dev/null)"
    echo "mimd=$(getprop init.svc.mimd-service2_0)"
    ;;

  # ---- 状态（daemon 写入的实时状态）----
  status)
    cat "$STATUS" 2>/dev/null
    ;;

  # ---- 手动清缓存 ----
  drop)
    lvl="${1:-$(get_conf drop_level)}"
    drop_cache "$lvl"
    log MEM "手动清理缓存 level=$lvl"
    echo "drop_caches=$lvl done"
    ;;

  # ---- 日志 ----
  log_tail)
    tail -n "${1:-100}" "$LOG" 2>/dev/null
    ;;
  log_clear)
    : > "$LOG" 2>/dev/null
    echo "log cleared"
    ;;

  # ---- 游戏白名单管理 ----
  game_list)
    cat "$GAMES" 2>/dev/null
    ;;
  game_add)
    pkg="$1"
    [ -z "$pkg" ] && { echo "usage: game_add <pkg>"; exit 1; }
    touch "$GAMES" 2>/dev/null
    if ! grep -qx "$pkg" "$GAMES" 2>/dev/null; then
      echo "$pkg" >> "$GAMES"
    fi
    echo "added $pkg"
    ;;
  game_del)
    pkg="$1"
    [ -z "$pkg" ] && { echo "usage: game_del <pkg>"; exit 1; }
    sed -i "/^${pkg}$/d" "$GAMES" 2>/dev/null
    echo "deleted $pkg"
    ;;

  # ---- 后台保活白名单管理 ----
  keep_list)
    cat "$KEEP_CONF" 2>/dev/null
    ;;
  keep_add)
    pkg="$1"
    [ -z "$pkg" ] && { echo "usage: keep_add <pkg>"; exit 1; }
    touch "$KEEP_CONF" 2>/dev/null
    if ! grep -qx "$pkg" "$KEEP_CONF" 2>/dev/null; then
      echo "$pkg" >> "$KEEP_CONF"
    fi
    apply_keep_list
    echo "added $pkg"
    ;;
  keep_del)
    pkg="$1"
    [ -z "$pkg" ] && { echo "usage: keep_del <pkg>"; exit 1; }
    sed -i "/^${pkg}$/d" "$KEEP_CONF" 2>/dev/null
    apply_keep_list
    echo "deleted $pkg"
    ;;
  keep_apply)
    apply_keep_list
    echo "keep list applied"
    ;;

  # ---- daemon 控制 ----
  daemon_start)
    nohup sh "$MODDIR/daemon.sh" >/dev/null 2>&1 &
    echo "daemon started pid=$!"
    ;;
  daemon_stop)
    if [ -f "$DAEMON_PID" ]; then
      kill "$(cat $DAEMON_PID 2>/dev/null)" 2>/dev/null
      rm -f "$DAEMON_PID"
    fi
    echo "daemon stopped"
    ;;

  # ---- 卸载恢复 ----
  revert)
    start mimd-service2_0 2>/dev/null
    echo "enable 3" > "$MI_RECLAIM" 2>/dev/null
    [ -n "$RP" ] && $RP persist.sys.miui.unfairMemory.enable true 2>/dev/null
    [ -n "$RP" ] && $RP persist.sys.memory_standard.enable true 2>/dev/null
    [ -n "$RP" ] && $RP persist.sys.memory_standard.appheap.enable true 2>/dev/null
    [ -n "$RP" ] && $RP persist.sys.mimd.reclaim.enable true 2>/dev/null
    echo "reverted"
    ;;

  *)
    echo "unknown command: $cmd"
    echo "commands: get set list_conf apply snapshot status drop log_tail log_clear game_list game_add game_del daemon_start daemon_stop revert"
    exit 1
    ;;
esac

exit 0