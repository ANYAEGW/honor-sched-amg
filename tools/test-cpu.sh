#!/system/bin/sh
# 恢复 CPU 上限到「不限制」并验证写入是否被内核接受。
MAX=/sys/kernel/msm_performance/parameters/cpu_max_freq
MIN=/sys/kernel/msm_performance/parameters/cpu_min_freq
FREE_MAX='0:2147483647 1:2147483647 2:2147483647 3:2147483647 4:2147483647 5:2147483647 6:2147483647 7:2147483647'
FREE_MIN='0:0 1:0 2:0 3:0 4:0 5:0 6:0 7:0'

echo "=== before ==="
echo "max: $(cat "$MAX" 2>&1)"
echo "min: $(cat "$MIN" 2>&1)"

printf '%s\n' "$FREE_MAX" > "$MAX" 2>/dev/null
echo "max_write_rc=$?"
printf '%s\n' "$FREE_MIN" > "$MIN" 2>/dev/null
echo "min_write_rc=$?"

echo "=== after ==="
echo "max: $(cat "$MAX" 2>&1)"
echo "min: $(cat "$MIN" 2>&1)"

M=$(cat "$MAX" 2>/dev/null)
case $M in
    *2147483647*) echo 'VERDICT: INT_MAX 可写，恢复成功' ;;
    *) echo 'VERDICT: INT_MAX 写入未生效（内核拒绝或另有语义）' ;;
esac
