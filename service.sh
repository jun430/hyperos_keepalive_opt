#!/system/bin/sh
# ============================================================
# 澎湃内存管理优化 - service.sh
# 开机完成后延迟执行：兜底关主动回收 + 应用配置 + 拉起 daemon + 事件监听
# ============================================================
MODDIR=${0%/*}
source "$MODDIR/lib.sh"

# 等待开机完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 5
done
sleep 20

mkdir -p "$HKOM_DIR" 2>/dev/null
log INF "========== service.sh 开始 =========="

# 0. 首次运行：复制配置模板到运行时目录
if [ ! -f "$CONF" ] && [ -f "$MODDIR/config/default.conf" ]; then
  cp "$MODDIR/config/default.conf" "$CONF" 2>/dev/null
  log INF "已从模板初始化配置文件"
fi
if [ ! -f "$GAMES" ] && [ -f "$MODDIR/config/games.conf" ]; then
  cp "$MODDIR/config/games.conf" "$GAMES" 2>/dev/null
  log INF "已从模板初始化游戏白名单"
fi
if [ ! -f "$KEEP_CONF" ] && [ -f "$MODDIR/config/keep.conf" ]; then
  cp "$MODDIR/config/keep.conf" "$KEEP_CONF" 2>/dev/null
  log INF "已从模板初始化后台保活白名单"
fi

# 1. 门禁检查：关键节点是否存在（不存在则记录告警，不 abort，避免影响开机）
[ -f "$MI_RECLAIM" ] || log WRN "mi_reclaim 节点不存在"
[ -f "$MIMD_TRIGGER" ] || log WRN "mimdtrigger 节点不存在"
[ -f "$DROP_CACHES" ] || log WRN "drop_caches 节点不存在"

# 2. 应用当前配置（M1+M2+M5+M10）
apply_reclaim_off
apply_lmk
apply_zram
apply_keep_list
log INF "配置已应用"

# 3. 写入初始状态
set_status mode "normal"
set_status daemon "starting"
set_status applied_at "$(date '+%F %T')"

# 4. 拉起 daemon（daemon 自己负责单实例锁，这里只做「是否已在跑」判断）
daemon_alive=0
if [ -f "$DAEMON_PID" ]; then
  old=$(cat "$DAEMON_PID" 2>/dev/null)
  [ -n "$old" ] && kill -0 "$old" 2>/dev/null && daemon_alive=1
fi
if [ "$daemon_alive" = "0" ]; then
  rm -f "$DAEMON_PID" 2>/dev/null
  nohup sh "$MODDIR/daemon.sh" >/dev/null 2>&1 &
  log INF "守护进程已启动 pid=$!"
else
  log INF "守护进程已在运行 (pid=$old)，跳过"
fi

# 5. 拉起 proc_monitor（游戏事件监听）
monitor_alive=0
if [ -f "$MONITOR_PID" ]; then
  oldm=$(cat "$MONITOR_PID" 2>/dev/null)
  [ -n "$oldm" ] && kill -0 "$oldm" 2>/dev/null && monitor_alive=1
fi
if [ "$(get_conf game_mode)" = "1" ]; then
  if [ "$monitor_alive" = "0" ]; then
    rm -f "$MONITOR_PID" 2>/dev/null
    nohup sh "$MODDIR/proc_monitor.sh" >/dev/null 2>&1 &
    log INF "游戏事件监听已启动 pid=$!"
  else
    log INF "游戏事件监听已在运行 (pid=$oldm)，跳过"
  fi
fi

log INF "========== service.sh 结束 =========="
exit 0