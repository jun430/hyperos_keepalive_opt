#!/system/bin/sh
# ============================================================
# 澎湃内存管理优化 - customize.sh（安装交互）
# 音量上键 = 完整安装（安装时禁用四层主动回收服务 + 生成默认配置）
# 音量下键 = 轻量安装（不禁用服务，仅装 WebUI 与默认配置）
# 10 秒无操作 = 默认完整安装
# ============================================================

SKIPUNZIP=0

ui_print "==============================="
ui_print "  澎湃内存管理优化 v2.1.0"
ui_print "  HyperOS Memory Optimizer"
ui_print "==============================="
ui_print "  音量上键 = 完整安装"
ui_print "  （禁用小米主动回收四件套）"
ui_print "  音量下键 = 轻量安装"
ui_print "  （不禁用服务，仅装配置与界面）"
ui_print "  10秒无操作 = 完整安装"
ui_print "==============================="

MODE="full"
# 捕获音量键（KEY_VOLUMEUP=115 / KEY_VOLUMEDOWN=114）
key=$(timeout 10 getevent -qlc 1 2>/dev/null | awk '{print $3}' | head -1)
case "$key" in
  KEY_VOLUMEUP)   MODE="full";  ui_print " > 已选择：完整安装" ;;
  KEY_VOLUMEDOWN) MODE="light"; ui_print " > 已选择：轻量安装" ;;
  *)              MODE="full";  ui_print " > 未按键，默认完整安装" ;;
esac

# ---------- 0. 生成默认配置（安装时立即生效，不等开机）----------
HKOM_DIR=/data/local/tmp/hkom
mkdir -p "$HKOM_DIR" 2>/dev/null

if [ -f "$MODDIR/config/default.conf" ]; then
  cp -f "$MODDIR/config/default.conf" "$HKOM_DIR/hkom.conf" 2>/dev/null
  if [ "$MODE" = "light" ]; then
    # 轻量安装：不禁用小米四层主动回收（保留系统原行为）
    sed -i -e 's/^disable_mimd=.*/disable_mimd=0/' \
           -e 's/^disable_unfairmem=.*/disable_unfairmem=0/' \
           -e 's/^disable_mi_reclaim=.*/disable_mi_reclaim=0/' \
           -e 's/^disable_memory_standard=.*/disable_memory_standard=0/' \
           "$HKOM_DIR/hkom.conf" 2>/dev/null
  fi
  ui_print " - 已生成内存水位等默认配置"
fi

[ -f "$MODDIR/config/games.conf" ] && \
  cp -f "$MODDIR/config/games.conf" "$HKOM_DIR/games.conf" 2>/dev/null && \
  ui_print " - 已生成游戏白名单（53个主流手游）"

[ -f "$MODDIR/config/keep.conf" ] && \
  cp -f "$MODDIR/config/keep.conf" "$HKOM_DIR/keep.conf" 2>/dev/null && \
  ui_print " - 已生成后台保活白名单"

chmod 644 "$HKOM_DIR"/*.conf 2>/dev/null

# ---------- 1. 打包解压完成后提示 ----------
ui_print " - 模块文件已安装"
if [ "$MODE" = "full" ]; then
  ui_print " - 重启后将自动：停 mimd、关 mi_reclaim、"
  ui_print "   关 unfairmem、关 memory_standard"
else
  ui_print " - 重启后不会改动系统回收行为"
  ui_print "   （可在 WebUI 保活页手动开启）"
fi
ui_print " - WebUI 配置入口：KernelSU 管理器 → 模块 → 打开"
ui_print "==============================="
ui_print "  安装完成，重启后生效"
ui_print "==============================="
exit 0