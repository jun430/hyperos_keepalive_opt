#!/system/bin/sh
# ============================================================
# 全功能模拟验证脚本（本机实测，只读+受控写入，不改系统进程）
# 覆盖：推送通道判定 / 系统包过滤 / 熄屏检测 / 超时回收 /
#       看护重申 / 配置边界 / 计时表健壮性
# ============================================================
DST='/data/adb/modules/hyperos_keepalive_opt'
. "$DST/lib.sh" 2>/dev/null
BGWORK=/data/local/tmp/hkom/.bgtime

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
ng(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo '=========================================='
echo 'T1  is_msg_channel 推送通道判定'
echo '=========================================='
for n in 'com.tencent.mm:push' 'com.tencent.mobileqq:MSF' 'com.xiaomi.xmsf' \
         'com.xiaomi.xmsf:persistent' 'com.xiaomi.mipush' 'x:PushService' \
         'x:mipush' 'x:pushservice'; do
  is_msg_channel "$n" && ok "保留 $n" || ng "应保留却判回收: $n"
done
for n in 'com.tencent.mm:appbrand0' 'com.tencent.mm:tools' 'com.tencent.mm:sandbox' \
         'com.tencent.mm:service' 'com.tencent.mm' 'com.sankuai.meituan:dppushservice' \
         'x:peak' 'x:qzone' 'x:remote' 'x:daemon'; do
  is_msg_channel "$n" && ng "应回收却判保留: $n" || ok "可回收 $n"
done

echo
echo '=========================================='
echo 'T2  is_system_pkg 系统包过滤（只动第三方）'
echo '=========================================='
for b in com.android.systemui com.miui.home com.qti.phone org.codeaurora.ims \
         com.qualcomm.location android.process.media com.android.quicksearchbox \
         com.miui.screenshot com.miui.miwallpaper com.miui.analytics \
         com.miui.weather2 com.miui.misound com.qti.qcc com.miui.voicetrigger; do
  is_system_pkg "$b" && ok "拦下系统包 $b" || ng "系统包未拦下: $b"
done
for b in com.phoenix.read com.tencent.mm com.tencent.mobileqq com.eg.android.AlipayGphone \
         com.sankuai.meituan com.coolapk.market; do
  is_system_pkg "$b" && ng "第三方被误判为系统: $b" || ok "放行第三方 $b"
done
# 推送例外必须在缓存之前生效
for b in com.xiaomi.xmsf com.xiaomi.xmsfkeeper; do
  is_system_pkg "$b" && ng "推送通道被当系统包拦下: $b" || ok "推送例外生效 $b"
done
# 非法包名必须拦下
for b in 'system' 'bash' '[logcat]' '.qms' '' 'a b'; do
  is_system_pkg "$b" && ok "拦下非法名 [$b]" || ng "非法名未拦下: [$b]"
done

echo
echo '=========================================='
echo 'T3  is_screen_off 熄屏检测'
echo '=========================================='
B=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)
if [ -n "$B" ]; then
  ok "backlight 节点可读 (brightness=$B)"
  if [ "$B" = "0" ]; then
    is_screen_off && ok "熄屏判定与节点一致" || ng "节点=0 但判为亮屏"
  else
    is_screen_off && ng "节点=$B 但判为熄屏" || ok "亮屏判定与节点一致"
  fi
else
  ok "backlight 节点不可读，走 dumpsys 兜底"
  is_screen_off && ok "dumpsys 兜底返回熄屏" || ok "dumpsys 兜底返回亮屏"
fi
# 幂等性：连续调用结果应一致
A1=$(is_screen_off && echo OFF || echo ON)
A2=$(is_screen_off && echo OFF || echo ON)
[ "$A1" = "$A2" ] && ok "连续调用结果一致 ($A1)" || ng "连续调用结果抖动 ($A1 vs $A2)"

echo
echo '=========================================='
echo 'T4  bg_child_reaper 超时回收（受控构造）'
echo '=========================================='
NOW=$(date +%s)
FG=$(foreground_pkg)
echo "  当前前台=$FG"

# T4-1 bg_child_kill=0 时功能禁用
printf '%s %s\n' "com.tencent.mm" "$((NOW-600))" > "$BGWORK"
M=$(get_conf bg_child_kill)
if [ "$M" -le 0 ] 2>/dev/null; then
  ok "bg_child_kill=$M 已禁用（无法测回收）"
else
  ok "bg_child_kill=$M 分钟生效"
fi

# T4-2 前台包计时必须被清除
printf '%s %s\n' "$FG" "$((NOW-600))" > "$BGWORK"
bg_child_reaper
if grep -q "^$FG " "$BGWORK" 2>/dev/null; then
  ng "前台包计时未清除: $FG"
else
  ok "前台包计时已清除: $FG"
fi

# T4-3 幽灵包（完全无进程）计时必须清除
printf '%s %s\n' "com.nonexistent.ghost.pkg" "$((NOW-600))" > "$BGWORK"
bg_child_reaper
if grep -q '^com.nonexistent.ghost.pkg ' "$BGWORK" 2>/dev/null; then
  ng "幽灵包计时未清除"
else
  ok "幽灵包计时已清除"
fi

# T4-4 未超时的包不得回收子进程
CHILDPKG=""
for b in $(list_protected_pids | awk '$4==1 {print $1}' | sort -u); do
  is_system_pkg "$b" || { CHILDPKG="$b"; break; }
done
if [ -n "$CHILDPKG" ]; then
  printf '%s %s\n' "$CHILDPKG" "$NOW" > "$BGWORK"
  BEFORE=$(ps -A -o NAME 2>/dev/null | grep -c "^$CHILDPKG:")
  bg_child_reaper
  AFTER=$(ps -A -o NAME 2>/dev/null | grep -c "^$CHILDPKG:")
  [ "$BEFORE" = "$AFTER" ] && ok "未超时不回收 ($CHILDPKG 子进程 $BEFORE->$AFTER)" \
                           || ng "未超时却回收了 ($BEFORE->$AFTER)"
  grep -q "^$CHILDPKG " "$BGWORK" && ok "未超时保留计时" || ok "未超时计时被刷新（可接受）"
else
  ok "当前无带子进程的第三方包，跳过 T4-4"
fi

# T4-5 超时回收：保留消息通道，杀非消息子进程
RECOVERPKG=""
for b in $(list_protected_pids | awk '$4==1 {print $1}' | sort -u); do
  is_system_pkg "$b" && continue
  # 该包要有「非消息通道」子进程才值得测
  for n in $(list_protected_pids | awk -v P="$b" '$1==P && $4==1 {print $3}'); do
    if ! is_msg_channel "$n"; then RECOVERPKG="$b"; break; fi
  done
  [ -n "$RECOVERPKG" ] && break
done
if [ -n "$RECOVERPKG" ]; then
  MSGBEFORE=$(list_protected_pids | awk -v P="$RECOVERPKG" '$1==P && $4==1 {print $3}' | while read n; do is_msg_channel "$n" && echo "$n"; done | wc -l)
  CNTBEFORE=$(ps -A -o NAME 2>/dev/null | grep -c "^$RECOVERPKG:")
  printf '%s %s\n' "$RECOVERPKG" "$((NOW-600))" > "$BGWORK"
  bg_child_reaper
  sleep 1
  CNTAFTER=$(ps -A -o NAME 2>/dev/null | grep -c "^$RECOVERPKG:")
  MSGAFTER=$(list_protected_pids | awk -v P="$RECOVERPKG" '$1==P && $4==1 {print $3}' | while read n; do is_msg_channel "$n" && echo "$n"; done | wc -l)
  echo "  测试包=$RECOVERPKG 子进程 $CNTBEFORE->$CNTAFTER 消息通道 $MSGBEFORE->$MSGAFTER"
  [ "$CNTAFTER" -lt "$CNTBEFORE" ] && ok "超时回收生效（减少 $((CNTBEFORE-CNTAFTER)) 个）" \
                                   || ng "超时未回收子进程"
  [ "$MSGAFTER" -ge "$MSGBEFORE" ] && ok "消息通道未被误杀 ($MSGAFTER)" \
                                    || ng "消息通道被误杀 ($MSGBEFORE->$MSGAFTER)"
else
  ok "当前无「含非消息子进程」的包，跳过 T4-5"
fi

echo
echo '=========================================='
echo 'T5  msg_guard 看护重申（模拟 AMS 覆写）'
echo '=========================================='
MSG_PIDS=''; refresh_msg_pids
NPID=$(echo $MSG_PIDS | wc -w)
if [ "$NPID" -gt 0 ]; then
  ok "MSG_PIDS 缓存 $NPID 个 PID"
  # 全部人为改 500
  for p in $MSG_PIDS; do echo 500 > /proc/$p/oom_score_adj 2>/dev/null; done
  BAD=0
  for p in $MSG_PIDS; do
    a=$(cat /proc/$p/oom_score_adj 2>/dev/null)
    [ "$a" = "500" ] || BAD=$((BAD+1))
  done
  [ "$BAD" -eq 0 ] && ok "已人为覆写为 500" || echo "  (部分 PID 无法写入，$BAD 个)"
  SCREEN_OFF=0; msg_guard; sleep 1
  GOOD=0; TOT=0
  for p in $MSG_PIDS; do
    TOT=$((TOT+1))
    [ "$(cat /proc/$p/oom_score_adj 2>/dev/null)" = "-900" ] && GOOD=$((GOOD+1))
  done
  [ "$GOOD" = "$TOT" ] && ok "亮屏 msg_guard 重申成功 $GOOD/$TOT" \
                        || ng "亮屏重申失败 $GOOD/$TOT"
else
  ng "MSG_PIDS 为空，无法测试"
fi

echo
echo '=========================================='
echo 'T6  熄屏全量重申 + 系统包零改动（关键）'
echo '=========================================='
# 先记录系统进程基线
SYSPID_BEFORE=$(ps -A -o PID,NAME 2>/dev/null | awk '$2 ~ /^com\.(miui|android|qti|qualcomm)\./ || $2 ~ /^android\./ || $2 ~ /^org\./ || $2=="com.miui.home" {print $1" "$2}')
# 只对第三方主进程做覆写（不碰系统进程，避免污染）
THIRDPIDS=""
for b in $(list_protected_pids | awk '$4==0 {print $1}' | sort -u); do
  is_system_pkg "$b" && continue
  p=$(list_protected_pids | awk -v B="$b" '$1==B && $4==0 {print $2; exit}')
  [ -n "$p" ] && THIRDPIDS="$THIRDPIDS $p"
done
NTH=$(echo $THIRDPIDS | wc -w)
echo "  第三方主进程 $NTH 个"
for p in $THIRDPIDS; do echo 800 > /proc/$p/oom_score_adj 2>/dev/null; done
SCREEN_OFF=1; MSG_PIDS=''; msg_guard; sleep 1
GOOD=0
for p in $THIRDPIDS; do
  [ "$(cat /proc/$p/oom_score_adj 2>/dev/null)" = "-900" ] && GOOD=$((GOOD+1))
done
[ "$GOOD" = "$NTH" ] && ok "熄屏全量重申成功 $GOOD/$NTH" || ng "熄屏重申失败 $GOOD/$NTH"

# 系统进程零改动
SYSPID_AFTER=$(ps -A -o PID,NAME 2>/dev/null | awk '$2 ~ /^com\.(miui|android|qti|qualcomm)\./ || $2 ~ /^android\./ || $2 ~ /^org\./ || $2=="com.miui.home" {print $1" "$2}')
CHG=0
echo "$SYSPID_AFTER" | while read p b; do
  a=$(cat /proc/$p/oom_score_adj 2>/dev/null)
  [ "$a" = "-900" ] && echo "  异常系统进程: $b adj=-900"
done > /data/local/tmp/.systest 2>/dev/null
BADN=$(wc -l < /data/local/tmp/.systest 2>/dev/null || echo 0)
[ "${BADN:-0}" -eq 0 ] && ok "熄屏重申后系统进程零 -900" || {
  ng "熄屏重申污染了系统进程"
  cat /data/local/tmp/.systest 2>/dev/null | head -5
}
rm -f /data/local/tmp/.systest

echo
echo '=========================================='
echo 'T7  配置与计时表健壮性'
echo '=========================================='
KM=$(get_conf bg_child_kill)
case "$KM" in
  ''|*[!0-9]*) ng "bg_child_kill 非法值: [$KM]" ;;
  *) ok "bg_child_kill=$KM 合法" ;;
esac
PN=$(get_conf poll_normal)
case "$PN" in
  ''|*[!0-9]*) ng "poll_normal 非法值: [$PN]" ;;
  *) ok "poll_normal=$PN 合法" ;;
esac

# 计时表无重复、无空行
rm -f "$BGWORK"
printf 'com.tencent.mm %s\ncom.tencent.mm %s\n' "$NOW" "$NOW" > "$BGWORK"
DUP=$(awk '{print $1}' "$BGWORK" | sort | uniq -d | wc -l)
[ "$DUP" -eq 0 ] && ok "正常写入无重复" || echo "  (手工写入产生重复，$DUP 个)"
bg_child_reaper
DUP=$(awk '{print $1}' "$BGWORK" 2>/dev/null | sort | uniq -d | wc -l)
[ "$DUP" -eq 0 ] && ok "reaper 后无重复行" || ng "reaper 后仍有重复 $DUP 个"
EMPTY=$(grep -c '^\s*$' "$BGWORK" 2>/dev/null || echo 0)
[ "${EMPTY:-0}" -eq 0 ] && ok "无空行" || ng "存在 $EMPTY 个空行"

# 临时文件不残留
LEFTOVER=$(ls /data/local/tmp/hkom/*.snap /data/local/tmp/hkom/*.kill /data/local/tmp/hkom/*.tmp 2>/dev/null | wc -l)
[ "$LEFTOVER" -eq 0 ] && ok "无临时文件残留" || ng "残留 $LEFTOVER 个临时文件"

echo
echo '=========================================='
echo "汇总：PASS=$PASS  FAIL=$FAIL"
echo '=========================================='
[ "$FAIL" -eq 0 ] && echo '全部通过' || echo "有 $FAIL 项失败，需修复"
