#!/system/bin/sh
# 依赖高通 msm_performance 的 cpu_max_freq/cpu_min_freq 与 policy0/2/5/7。
# show 可由shell读取；boost/restore 需要uid=0（root:root 0644属主写）。
# 缺失/拒绝写/等待失败均报错；退出尝试释放，失败要求手动restore。
# 高通专有接口：上限还是QoS票的语义尚未在本机验证，不保证实际满频。
# 首次先show，再手动boost短时观察；不设最小频率，不绕过热控。
# TODO：scroll_cap 依赖MTK/policy4；骁龙未标定，故不实现。
BASE=/sys/kernel/msm_performance/parameters
MAX=$BASE/cpu_max_freq
MIN=$BASE/cpu_min_freq
ST=/data/local/tmp/hs
LOCK=$ST/cpu.lock
PIDF=$ST/cpu.pid
CANCEL=$ST/cpu.cancel
SNAP=$ST/cpu.snap
FREE_MAX='0:2147483647 1:2147483647 2:2147483647 3:2147483647 4:2147483647 5:2147483647 6:2147483647 7:2147483647'
FREE_MIN='0:0 1:0 2:0 3:0 4:0 5:0 6:0 7:0'
BOOST_MAX='0:2265600 1:2265600 2:3148800 3:3148800 4:3148800 5:2956800 6:2956800 7:3302400'
fail() { echo "[错误] $*" >&2; }
show_node() {
    printf '\n--- %s ---\n' "$1"
    if [ ! -e "$1" ]; then echo '[缺失]'
    elif [ ! -r "$1" ]; then echo '[不可读] 当前权限不足'
    else cat "$1" 2>/dev/null || echo '[读取失败] 内核拒绝读取'; fi
}
restore_values() {
    result=0
    # 安全审查意见：不能无条件写常量——那会覆盖别人的票，也恢复不到 boost 前的状态。
    # 改为：boost 前存快照，这里写回快照；boost 从未改过 min，所以这里不写 min。
    if [ -f "$SNAP" ]; then
        saved=$(cat "$SNAP" 2>/dev/null)
        if [ -z "$saved" ]; then fail 'cpu 快照为空，拒绝猜测恢复值'; return 1; fi
        n=0
        cur=''
        while [ "$n" -lt 3 ]; do
            n=$((n+1))
            printf '%s\n' "$saved" > "$MAX" 2>/dev/null
            cur=$(cat "$MAX" 2>/dev/null)
            [ "$cur" = "$saved" ] && break
            sleep 1
        done
        if [ "$cur" = "$saved" ]; then
            rm -f "$SNAP"
        else
            fail "恢复读回不一致（实际=$cur 期望=$saved，重试${n}次），保留快照"; result=1
        fi
    fi
    return "$result"
}
cmd=${1:-show}
case $cmd in
    show)
        [ "$(id -u)" = 0 ] || echo '[提示] 非root：只读展示；boost/restore需要临时root。'
        echo '[未验证] 参数读回不等于实际频率；walt仍会自主调频。'
        show_node "$MAX"; show_node "$MIN"
        for p in 0 2 5 7; do
            show_node "/sys/devices/system/cpu/cpufreq/policy$p/scaling_cur_freq"
        done
        exit 0 ;;
    boost|restore) ;;
    *) fail '用法：hs-cpu.sh show|boost [秒数1..5，默认2=2000ms]|restore'; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { fail '需要临时root；不会自动su，不写节点。'; exit 1; }
for node in "$MAX" "$MIN"; do
    [ -e "$node" ] && [ -w "$node" ] || { fail "节点缺失或不可写：$node"; exit 1; }
done
umask 077
[ ! -L "$ST" ] || { fail '状态目录不能是符号链接'; exit 1; }
mkdir -p "$ST" || exit 1
[ "$(stat -c %u "$ST" 2>/dev/null)" = 0 ] || { fail '状态目录必须归root所有'; exit 1; }
if [ "$cmd" = restore ] && [ -d "$LOCK" ]; then
    : > "$CANCEL" || exit 1
    n=0
    while [ -d "$LOCK" ] && [ "$n" -lt 8 ]; do sleep 1; n=$((n+1)); done
    [ ! -d "$LOCK" ] || { fail 'cpu锁仍存在；停止状态未确认，不并发写入'; exit 1; }
fi
if [ "$cmd" = boost ]; then
    seconds=${2:-2}
    case $seconds in 1|2|3|4|5) ;; *) fail '秒数只接受1..5整数，默认2秒=2000ms'; exit 2 ;; esac
fi
mkdir "$LOCK" 2>/dev/null || { fail '已有CPU操作或遗留锁，拒绝并发'; exit 1; }
cleanup() {
    code=$?
    trap '' INT TERM
    trap - 0
    if ! restore_values; then code=1; fail '未完全释放，请保留临时root后手动cpu restore'; fi
    rm -f "$PIDF" "$CANCEL"
    rmdir "$LOCK" 2>/dev/null
    exit "$code"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$$" > "$PIDF" || exit 1
if [ "$cmd" = restore ]; then
    if [ -f "$SNAP" ]; then
        echo '[释放] 发现 boost 快照，写回原值'
    else
        echo '[释放] 无快照：没有待恢复的票，本次不做任何写入'
    fi
    exit 0
fi
rm -f "$CANCEL" || exit 1
# 安全审查意见：boost 前必须先存快照，否则 restore 只能猜常量、还可能覆盖别人的票。
if [ -f "$SNAP" ]; then
    fail '发现遗留 cpu 快照；先执行 cpu restore 确认，避免覆盖'; exit 1
fi
( set -C; printf '%s\n' "$(cat "$MAX" 2>/dev/null)" > "$SNAP" ) || { fail '无法保存 CPU 快照'; exit 1; }
echo "[未验证] 仅设置四簇上限，持续${seconds}秒，不保证升频；结束写回快照。"
(printf '%s\n' "$BOOST_MAX" > "$MAX") 2>/dev/null || { fail 'boost写入被拒绝'; exit 1; }
left=$seconds
while [ "$left" -gt 0 ]; do
    [ ! -f "$CANCEL" ] || exit 0
    sleep 1 || exit 1
    left=$((left-1))
done
exit 0
