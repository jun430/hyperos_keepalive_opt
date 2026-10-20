#!/system/bin/sh
# ============================================================
# 澎湃内存管理优化 - post-fs-data.sh
# 时机：Zygote 之前，越早关闭主动回收越好，减少开机期预判性回收
# ============================================================
MODDIR=${0%/*}

# 1. 停 mimd 内存守护进程
stop mimd-service2_0 2>/dev/null

# 2. 关闭 mimd trigger（-1 = 禁用）
echo -1 > /sys/module/perf_helper/mimd/mimdtrigger 2>/dev/null

# 3. 关闭 mi_reclaim 主动回收（HyperOS3 命令式接口）
echo "enable 0" > /sys/kernel/mi_reclaim/info 2>/dev/null

exit 0