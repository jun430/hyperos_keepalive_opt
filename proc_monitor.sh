#!/system/bin/sh
# ============================================================
# 澎湃内存管理优化 - proc_monitor.sh（游戏事件监听）
# 职责：监听 am_proc_start 事件，检测游戏白名单主包的前台切换，
#       命中则写状态文件唤醒 daemon。事件驱动，零轮询开销。
# 纪律：只匹配主包名（排除 :子进程）；不 logcat -c；事件只做唤醒。
# ============================================================
MODDIR=${0%/*}
source "$MODDIR/lib.sh"

# 写 pid 文件
echo $$ > "$MONITOR_PID"

log INF "游戏事件监听启动 pid=$$"

# 当前游戏状态（0=非游戏 1=游戏），初始读取既有状态
cur_game=0
[ "$(grep '^game=' "$STATUS" 2>/dev/null | cut -d'=' -f2)" = "1" ] && cur_game=1

# 匹配白名单主包：读 games.conf，命中返回 0
is_game_pkg() {
  local pkg="$1"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [ "$line" = "$pkg" ] && return 0
  done < "$GAMES"
  return 1
}

# 主循环：直读 logcat events
logcat -b events -s am_proc_start 2>/dev/null | while IFS= read -r line; do
  # 解析进程名（第4字段）与 hostingType（第5字段）
  # 格式: [user,pid,uid,process,hostingType,{component}]
  pkg=$(printf '%s' "$line" | sed -n 's/.*\[[^,]*,[^,]*,[^,]*,\{1\}\([^,]*\),.*/\1/p')
  host=$(printf '%s' "$line" | sed -n 's/.*\[[^,]*,[^,]*,[^,]*,[^,]*,\{1\}\([^,]*\),.*/\1/p')

  # 排除空 / 子进程（含冒号）
  [ -z "$pkg" ] && continue
  case "$pkg" in
    *:*|"") continue ;;
  esac

  # 只关心前台切换事件
  case "$host" in
    top-activity|next-top-activity) ;;
    *) continue ;;
  esac

  # 游戏白名单命中 → 唤醒
  if is_game_pkg "$pkg"; then
    if [ "$cur_game" = "0" ]; then
      cur_game=1
      set_status game "1"
      set_status game_pkg "$pkg"
      log GAME "进入游戏: $pkg"
    fi
  fi
done

log WRN "游戏事件监听退出"
rm -f "$MONITOR_PID" 2>/dev/null
exit 0