#!/system/bin/sh
# ============================================================
# 澎湃内存管理优化 - daemon.sh（主循环）
# 职责：惰性轮询（常态10s/游戏3s），水位判定+清缓存+游戏腾内存+兜底关回收
# 纪律：pidof 精确检测不扫 /proc；单次 awk 全解析；自身开销近零
# ============================================================
MODDIR=${0%/*}
source "$MODDIR/lib.sh"

# 单实例保护（service.sh 已 lock，这里再兜底一次）
if ! lock_instance "$DAEMON_PID"; then
  exit 0
fi

# ★ 自身提权（熄屏存活关键）：
# 实测熄屏后 daemon 的 sleep 1 会被拉长，心跳间隔从配置的 300s 膨胀到
# 468~547s（7.8~9.1 分钟）。原因是 daemon 以普通 oom_score_adj=50 运行在
# /top-app cgroup，熄屏后系统把后台 CPU 预算收紧、timer slack 放大，
# sleep 精度下降，导致 AMS 覆写 adj 后长时间无人补写，应用被 LMK 杀掉。
# 对策：把 daemon 自身设为 -1000（不可回收级），只要内核活着它就不被杀。
echo -1000 > /proc/$$/oom_score_adj 2>/dev/null

log INF "守护进程启动 pid=$$"
set_status daemon "running"

# 内部状态
prev_drop=0          # 上一次是否因水位清过缓存（迟滞用）
  game_active=0        # 当前游戏态
  prev_game=0          # 上一轮游戏态（用于检测游戏进入/退出沿）
  reclaim_guard=0      # 主动回收兜底计数器（每 N 轮执行一次，降开销）
  bg_guard=0           # 后台超时杀子进程计数器（每 6 轮一次）
  beat=0               # 心跳计数器

# 检查游戏进程是否存活
# 优化：原实现对白名单逐个跑 pidof（53 次 fork），改为一次 ps 扫描 + grep 比对，
#       子进程数从 ~53 降到 2，daemon 系统态 CPU 显著下降。
#       注意：NAME 列是完整包名且带 :子进程 后缀，需先剥掉后缀再比对。
check_game_alive() {
  [ -f "$GAMES" ] || return 1
  local running gp stamp
  gp="$HKOM_DIR/.gamepkgs"
  stamp="$HKOM_DIR/.gamepkgs.stamp"
  # 白名单包名清单带缓存：仅当 games.conf 变化时才重建（避免每轮都 grep+sort）
  if [ ! -s "$gp" ] || [ "$(stat -c %Y "$GAMES" 2>/dev/null)" != "$(cat "$stamp" 2>/dev/null)" ]; then
    grep -E '^[A-Za-z]' "$GAMES" 2>/dev/null | sort -u > "$gp"
    stat -c %Y "$GAMES" 2>/dev/null > "$stamp"
  fi
  [ -s "$gp" ] || return 1
  # 一次取全部进程名（剥 :子进程 后缀），一次 grep -Fxf 精确交集
  running=$(ps -A -o NAME 2>/dev/null | sed 's/:.*//' | sort -u)
  [ -z "$running" ] && return 1
  printf '%s\n' "$running" | grep -Fxf "$gp" -q 2>/dev/null && return 0
  return 1
}

# 清理无关缓存进程（游戏模式：只杀 CACHED adj 的非白名单进程）
# 用 am kill 优雅回收，避免 kill -9 粗暴中断
kill_unrelated_cached() {
  local pkg uid killed=0
  for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    [ -z "$adj" ] && continue
    [ "$adj" -lt 900 ] 2>/dev/null && continue
    pkg=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | cut -d' ' -f1)
    [ -z "$pkg" ] && continue
    # 跳过白名单游戏
    if grep -qx "$pkg" "$GAMES" 2>/dev/null; then
      continue
    fi
    # 跳过后台保活白名单（M10：永不清理的锁后台应用）
    if grep -qx "$pkg" "$KEEP_CONF" 2>/dev/null; then
      continue
    fi
    # 跳过系统关键进程（uid<10000 的 system app 不杀）
    uid=$(cat /proc/$pid/status 2>/dev/null | grep '^Uid:' | awk '{print $2}')
    [ -n "$uid" ] && [ "$uid" -lt 10000 ] 2>/dev/null && continue
    # 用 am kill 优雅回收（走 AMS 正常清理流程）
    am kill "$pkg" >/dev/null 2>&1
    killed=$((killed+1))
  done
  [ "$killed" -gt 0 ] && log GAME "已回收 $killed 个缓存后台进程"
}

# 主循环
while :; do
  # ---- 游戏态判定（结合事件状态 + 进程存活）----
  event_game=$(grep '^game=' "$STATUS" 2>/dev/null | cut -d'=' -f2)
  if [ "$event_game" = "1" ]; then
    # 事件说在游戏，复核进程是否还活着
    if check_game_alive; then
      game_active=1
    else
      game_active=0
      set_status game "0"
      set_status game_pkg ""
    fi
  else
    # 事件没触发，直接以进程存活为准
    if check_game_alive; then
      game_active=1
    else
      game_active=0
    fi
  fi

  if [ "$game_active" = "1" ]; then
    set_status mode "game"
    # 游戏开始时执行一次腾内存
    if [ "$prev_game" != "1" ]; then
      log GAME "游戏模式开始"
      if [ "$(get_conf game_kill_cached)" = "1" ]; then
        kill_unrelated_cached
      fi
      if [ "$(get_conf game_drop_caches)" = "1" ]; then
        drop_cache 3
        log MEM "游戏模式清理缓存 drop_caches=3"
      fi
    fi
    prev_game=1
  else
    set_status mode "normal"
    if [ "$prev_game" = "1" ]; then
      log GAME "游戏模式结束"
    fi
    prev_game=0
  fi

  # ---- 水位判定（M3：提前主动清理，但定量渐进，避免 CPU/IO 尖峰）----
  mem_snapshot
  target=$(get_conf watermark_target)
  hyst=$(get_conf watermark_hysteresis)
  stop_at=$(( target - hyst ))

  if [ "$game_active" != "1" ]; then
    # 常态：占用达到 target 就开始清理，且清理后不一次性清到底，
    # 每轮只定量回收一小块（smooth_reclaim 按 drop_level 定 64/128/256MB），
    # 直到占用降到 stop_at 以下才停。这样把回收摊平到多轮，无尖峰。
    if [ "$MEM_USED_PCT" -ge "$target" ]; then
      psiv=$(psi_avg300)
      # PSI 已经很高说明系统真有压力 → 加大单次回收量；否则温和回收
      if [ "${psiv%%.*}" -ge 10 ] 2>/dev/null; then
        smooth_reclaim 256
        log MEM "内存 ${MEM_USED_PCT}% 达水位 ${target}%，PSI ${psiv}% 偏高，回收 256MB"
      else
        smooth_reclaim
        log MEM "内存 ${MEM_USED_PCT}% 达水位 ${target}%，平稳回收（PSI ${psiv}%）"
      fi
      prev_drop=1
    elif [ "$MEM_USED_PCT" -le "$stop_at" ]; then
      # 降到 stop_at 以下，退出清理状态
      prev_drop=0
    fi
  fi

  # ---- 智能保活（M13）：按"是否在最近任务"动态决定 adj=-900 ----
  # 在最近任务中 → 保护；用户划掉 → 撤销保护。AMS 会覆写 adj，需每轮重申。
  smart_keep

  # ---- 后台超时杀子进程（M15）：每 6 轮检查一次（约 1 分钟）----
  # 只杀 :子进程，主进程保留，页面不丢；白名单 App 的消息通道不杀。
  bg_guard=$(( bg_guard + 1 ))
  if [ "$bg_guard" -ge 6 ]; then
    bg_guard=0
    bg_child_reaper
  fi

  # ---- 兜底：每 N 轮检查系统级配置是否被重置 ----
  reclaim_guard=$(( reclaim_guard + 1 ))
  if [ "$reclaim_guard" -ge 5 ]; then
    reclaim_guard=0
    apply_reclaim_off
    # 缓存进程上限兜底：device_config 会被系统重置，定期重写保证生效
    apply_max_cached
    # 冻结开关兜底：同样是持久化项，防止被系统改回
    apply_freezer
  fi

  # ---- 心跳日志（每 30 轮一条，常态约 5 分钟/游戏态约 90 秒，证明 daemon 存活且在工作）----
  beat=$(( beat + 1 ))
  if [ $(( beat % 30 )) -eq 0 ]; then
    log INF "心跳 内存${MEM_USED_PCT}% 可用${MEM_AVAIL_PCT}% zram$(zram_used_mb)MB 压缩率$(zram_ratio)% PSI$(psi_avg300)% 模式=${game_active}游戏"
  fi

  # ---- 写实时状态（供 WebUI 读取）----
  set_status used_pct "$MEM_USED_PCT"
  set_status avail_pct "$MEM_AVAIL_PCT"
  set_status zram_mb "$(zram_used_mb)"
  set_status zram_ratio "$(zram_ratio)"
  set_status psi300 "$(psi_avg300)"
  set_status updated_at "$(date '+%F %T')"

  # ---- 惰性轮询间隔（分段 sleep，期间轻量看护消息通道 adj）----
  # AMS 会在两轮之间覆写消息通道 adj（实测 :MSF 被写回 500），
  # 把 sleep 切成 1 秒一段、每段重申一次，把空窗期从 10s 缩短到 ~1s。
  # 每段只做「读缓存 PID 的 adj → 若被抬高则写回」，不扫 ps，开销 1~2ms。
  #
  # ★ 时间基准改为 date 绝对值（熄屏关键）：
  #   原实现用 slept 计数器累加，`sleep 1` 实际会被系统拉长（熄屏后 timer slack
  #   放大到数秒），计数器按「次数」算而不管真实耗时 → 一轮远超 nap 秒。
  #   实测心跳间隔从配置的 300s 膨胀到 468~547s。
  #   改为记录起始时间戳，用真实经过秒数判定，无论 sleep 被拉长多少，
  #   这一轮循环一定在 nap 秒左右结束（误差 ≤ 一次 sleep 的实际值）。
  if [ "$game_active" = "1" ]; then
    nap=$(get_conf poll_game)
  else
    nap=$(get_conf poll_normal)
  fi
  [ "$nap" -lt 2 ] 2>/dev/null && nap=2
  # ★ 熄屏期间把轮询间隔压到 3 秒：
  #   熄屏后 AMS 会批量把后台应用 adj 重算到 idle 级别（缓存级 900+），
  #   同时系统收紧 CPU / timer slack，若仍按 10 秒轮询，
  #   覆写窗口内应用已可能被 LMK 选中杀掉——这正是「熄屏一段时间后台就没了」的原因。
  #   压到 3 秒把窗口缩小 3 倍，代价只是熄屏时多几次 /proc 读取（每次 <1ms）。
  SCREEN_OFF=0
  if is_screen_off; then
    SCREEN_OFF=1
    [ "$nap" -gt 3 ] && nap=3
  fi
  nap_start=$(date +%s)
  while :; do
    msg_guard
    # 每段只睡 1 秒；若被系统拉长，下一轮用真实耗时判断就能及时退出
    sleep 1
    nap_now=$(date +%s)
    [ $((nap_now - nap_start)) -ge "$nap" ] && break
  done
done

# 不应到达这里
unlock_instance "$DAEMON_PID"
log WRN "守护进程退出"
exit 0