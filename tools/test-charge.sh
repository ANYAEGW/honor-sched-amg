#!/system/bin/sh
# 充电写入验证（一次性）：写 -> 观察 -> 恢复，全部在同一次 root 会话内完成。
# 安全阀：温度 >= 42.0C 拒绝写入；恢复失败会大声报错。
NODE=/sys/class/hw_power/interface/iin_limit
RT=/sys/class/hw_power/charger/charge_data/iin_rt_current
BAT=/sys/class/power_supply/battery/current_now
TEMP=/sys/class/power_supply/battery/temp
TARGET=${1:-2000}

echo "=== hs-test 充电写入验证 ==="
[ "$(id -u)" = 0 ] || { echo "FATAL: 不是 root"; exit 1; }

ORIG=$(grep '^dcp ' "$NODE" 2>/dev/null | awk '{print $2}')
echo "ORIG_dcp=$ORIG"
[ -n "$ORIG" ] || { echo "FATAL: 读不到 dcp 原值，拒绝写入"; exit 1; }

T=$(cat "$TEMP" 2>/dev/null)
case $T in ''|*[!0-9]*) echo "WARN: 温度读不到，继续但危险"; T=0 ;; esac
if [ "$T" -ge 420 ]; then echo "FATAL: 温度 ${T}(0.1C) >= 42.0C，拒绝写入"; exit 1; fi

echo "--- 基线 ---"
echo "dcp_rows: $(cat "$NODE" | tr '\n' ' ')"
R0=$(cat "$RT" 2>/dev/null); B0=$(cat "$BAT" 2>/dev/null); T0=$(cat "$TEMP" 2>/dev/null)
echo "rt=$R0 bat=$B0 temp=$T0"

i=0
while [ "$i" -lt 3 ]; do
    i=$((i+1))
    printf 'thermal dcp %s\n' "$TARGET" > "$NODE" 2>/dev/null || { echo "FATAL: 写入失败 try$i"; break; }
    D=$(grep '^dcp ' "$NODE" 2>/dev/null | awk '{print $2}')
    R=$(cat "$RT" 2>/dev/null); B=$(cat "$BAT" 2>/dev/null); T2=$(cat "$TEMP" 2>/dev/null)
    echo "try$i wrote=$TARGET readback_dcp=$D rt=$R bat=$B temp=$T2"
    sleep 1
done

echo "--- 恢复 ---"
printf 'thermal dcp %s\n' "$ORIG" > "$NODE" 2>/dev/null
D=$(grep '^dcp ' "$NODE" 2>/dev/null | awk '{print $2}')
R=$(cat "$RT" 2>/dev/null); T3=$(cat "$TEMP" 2>/dev/null)
echo "final dcp=$D rt=$R temp=$T3"
if [ "$D" = "$ORIG" ]; then echo "RESTORE_OK"; else echo "RESTORE_FAIL 期望=$ORIG 实际=$D"; fi
echo "=== end ==="
