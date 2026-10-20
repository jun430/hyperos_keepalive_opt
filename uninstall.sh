#!/system/bin/sh
# ============================================================
# 澎湃内存管理优化 - uninstall.sh
# 模块卸载时全量回滚，恢复系统默认
# ============================================================
MODDIR=${0%/*}

# 1. 恢复 mimd 服务
start mimd-service2_0 2>/dev/null

# 2. 恢复 mi_reclaim 主动回收（enable 3 = global_reclaim + efficiency）
echo "enable 3" > /sys/kernel/mi_reclaim/info 2>/dev/null

# 3. 恢复 prop
resetprop persist.sys.miui.unfairMemory.enable true 2>/dev/null
resetprop persist.sys.memory_standard.enable true 2>/dev/null
resetprop persist.sys.memory_standard.appheap.enable true 2>/dev/null
resetprop persist.sys.mimd.reclaim.enable true 2>/dev/null

# 4. 停止 daemon 与 proc_monitor
for pf in /data/local/tmp/hkom_daemon.pid /data/local/tmp/hkom_monitor.pid; do
  if [ -f "$pf" ]; then
    kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
    rm -f "$pf"
  fi
done

# 5. 清理运行态（保留配置 hkom.conf 供重装复用，日志状态清掉）
rm -f /data/local/tmp/hkom.log /data/local/tmp/hkom.status 2>/dev/null

exit 0