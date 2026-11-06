#!/system/bin/sh
# 依赖 interface/iin_limit、battery/status、usb/online；温控可选 battery/temp。
# 需要 uid=0 且补充组1000；不提权、不改权限。失败报错并停止重试写入。
# 状态仅在 /data/local/tmp/hs；无开机自启。TERM/INT/paused 恢复快照。
# MAX_IIN=20000 仅为原机实测值，本机未标定！建议从 MAX_IIN=2000 起步。
# 示例：MAX_IIN=2000 TEMP_GUARD=400 sh hs-charge.sh run（单位mA/0.1摄氏度）。
ST=/data/local/tmp/hs
NODE=/sys/class/hw_power/interface/iin_limit
TURBO=/sys/class/hw_power/interface/charge_turbo_enable
SNAP=$ST/iface.snap
PIDF=$ST/charge.pid
LOCK=$ST/charge.lock
# 默认值已按安全审查收紧：本机未标定，2000mA 起步，且默认开温度闸。
MAX_IIN=${MAX_IIN:-2000}
TEMP_GUARD=${TEMP_GUARD:-400}
CHARGE_TURBO=${CHARGE_TURBO:-0}
VERBOSE=${VERBOSE:-0}
fail() { echo "[错误] $*" >&2; }
uint() { case $1 in ''|*[!0-9]*) return 1 ;; esac; [ ${#1} -le 8 ]; }
root_check() {
    [ "$(id -u)" = 0 ] || { fail '需要临时 root+组1000；不会自动 su。'; return 1; }
    # 安全审查意见：只看 uid 不够 —— iin_limit 是 system:system 0660，
    # 没有补充组 1000(system) 时 uid=0 也不是属主，照样写不了。
    case " $(id -G 2>/dev/null) " in
        *" 1000 "*) return 0 ;;
        *) fail '当前 root 会话缺少补充组 1000(system)，iin_limit 写不进去'; return 1 ;;
    esac
}
read_dcp() {
    [ -r "$NODE" ] || return 1
    text=$(cat "$NODE" 2>/dev/null) || return 1
    printf '%s\n' "$text" | awk '$1=="dcp" && NF==2 {print $2; exit}'
}
log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$ST/charge.log"; }
# 不把0当成恢复默认；保存原值（包括0），恢复失败保留证据。
do_release() {
    result=0
    if [ -f "$SNAP" ]; then
        saved=$(cat "$SNAP" 2>/dev/null) || return 1
        uint "$saved" || { fail 'iface.snap 无效，拒绝猜测恢复值'; return 1; }
        if (printf 'thermal dcp %s\n' "$saved" > "$NODE") 2>/dev/null; then
            actual=$(read_dcp)
            if [ "$actual" = "$saved" ]; then
                rm -f "$SNAP" || return 1
            else
                fail "恢复写入已接受但读回=$actual，期望=$saved；保留快照"
                result=1
            fi
        else
            fail '恢复 iin_limit 失败；快照保留，需要 root+组1000'
            result=1
        fi
    fi
    if [ -f "$ST/turbo.snap" ]; then
        saved_turbo=$(cat "$ST/turbo.snap" 2>/dev/null)
        case $saved_turbo in 0|1) ;; *) fail 'turbo.snap 无效'; return 1 ;; esac
        if (printf '%s\n' "$saved_turbo" > "$TURBO") 2>/dev/null; then
            turbo_read=$(cat "$TURBO" 2>/dev/null | awk '{print $NF; exit}')
            if [ "$turbo_read" = "$saved_turbo" ]; then
                rm -f "$ST/turbo.snap" || return 1
            else
                fail 'turbo 恢复读回不一致，保留快照'; result=1
            fi
        else
            fail 'turbo 恢复失败，保留快照'; result=1
        fi
    fi
    return "$result"
}
status() {
    [ "$(id -u)" = 0 ] || echo '[提示] 非root：仅查看可见状态，无法确认root私有目录内的守护状态。'
    if [ -d "$LOCK" ]; then
        pid=$(cat "$PIDF" 2>/dev/null)
        if uint "$pid" && kill -0 "$pid" 2>/dev/null; then
            echo "[状态] 锁存在，PID=$pid 存活（仅表示进程存活）"
        else
            echo '[状态] 锁存在但进程不可确认；不自动删除，见 README 恢复流程'
        fi
    else
        echo '[状态] 无充电守护锁'
    fi
    [ ! -f "$SNAP" ] || echo '[状态] 存在待恢复 iface.snap'
    [ ! -f "$ST/turbo.snap" ] || echo '[状态] 存在待恢复 turbo.snap'
    [ ! -f "$ST/paused" ] || echo '[状态] paused 已设置'
    return 0
}
cmd=${1:-run}
case $cmd in status) status; exit 0 ;; esac
root_check || exit 1
umask 077
[ ! -L "$ST" ] || { fail '状态目录不能为符号链接'; exit 1; }
mkdir -p "$ST" || exit 1
[ "$(stat -c %u "$ST" 2>/dev/null)" = 0 ] || { fail '状态目录必须归root所有'; exit 1; }
case $cmd in
    stop)
        : > "$ST/paused" || exit 1
        n=0
        while [ -d "$LOCK" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n+1)); done
        [ ! -d "$LOCK" ] || { fail '仍有锁：未确认停止；不并发恢复、不强杀'; exit 1; }
        mkdir "$LOCK" 2>/dev/null || { fail '恢复锁竞争，稍后重试stop'; exit 1; }
        do_release; rc=$?
        rmdir "$LOCK" 2>/dev/null
        exit "$rc" ;;
    release)
        # 安全审查意见：kill -9 后锁会留下，导致 release/stop/off 全被卡死，只能手工 rmdir。
        # 允许在「占用进程已确认不存在」时回收陈旧锁（不凭 PID 猜，要求 kill -0 失败）。
        if [ -d "$LOCK" ]; then
            oldpid=$(cat "$PIDF" 2>/dev/null)
            if uint "$oldpid" && kill -0 "$oldpid" 2>/dev/null; then
                fail "锁仍被存活进程占用（pid=$oldpid），先 stop"; exit 1
            fi
            fail '检测到陈旧锁（占用进程已不存在），回收后继续 release'
            rmdir "$LOCK" 2>/dev/null || { fail '陈旧锁回收失败'; exit 1; }
            rm -f "$PIDF"
        fi
        mkdir "$LOCK" 2>/dev/null || exit 1
        do_release; rc=$?
        rmdir "$LOCK" 2>/dev/null
        exit "$rc" ;;
    run) ;;
    *) fail '用法：hs-charge.sh run|stop|status|release'; exit 2 ;;
esac
uint "$MAX_IIN" && [ "$MAX_IIN" -gt 0 ] && [ "$MAX_IIN" -le 20000 ] || { fail 'MAX_IIN 必须为1..20000十进制整数'; exit 2; }
uint "$TEMP_GUARD" || { fail 'TEMP_GUARD 必须为非负整数'; exit 2; }
# 安全审查意见：高电流必须配温度闸；本机没有内核 temp_para 可依赖。
if [ "$MAX_IIN" -gt 2000 ] && [ "$TEMP_GUARD" = 0 ]; then
    fail 'MAX_IIN>2000 时必须同时设置 TEMP_GUARD（如 TEMP_GUARD=400），拒绝裸跑'
    exit 2
fi
case $CHARGE_TURBO in 0|1) ;; *) fail 'CHARGE_TURBO 只能为0或1'; exit 2 ;; esac
[ ! -f "$ST/paused" ] || { fail 'paused 已存在；确认恢复后手动删除再启动'; exit 1; }
mkdir "$LOCK" 2>/dev/null || { fail '已有实例或遗留锁，拒绝重复启动'; exit 1; }
cleanup() {
    code=$?
    trap '' INT TERM
    trap - 0
    if ! do_release; then code=1; fi
    log "退出 rc=$code；恢复失败时快照保留"
    rm -f "$PIDF"
    rmdir "$LOCK" 2>/dev/null
    exit "$code"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
# adb 断开/终端关闭发的是 SIGHUP —— 这是最常见的非主动退出，必须拦，否则票会留在内核。
trap 'exit 129' HUP
trap 'exit 141' PIPE
printf '%s\n' "$$" > "$PIDF" || exit 1
[ ! -L "$ST/charge.log" ] || { fail '日志不能为符号链接'; exit 1; }
: >> "$ST/charge.log" || exit 1
# 安全审查意见：遗留快照绝不能在新会话里自动写回（那是上一内核会话的值）。
# 只报告，要求人工确认后显式 release；且此时必须取消 EXIT trap，否则 cleanup 会把旧值写回去。
if [ -e "$SNAP" ] || [ -e "$ST/turbo.snap" ]; then
    fail '发现上次会话遗留快照；本次不启动，也不会自动写回旧值。'
    fail '请人工确认后执行：sh hs-charge.sh release'
    trap - 0
    exit 1
fi
[ -r "$NODE" ] && [ -w "$NODE" ] || { fail 'iin_limit 不存在/不可读写，需要root+组1000'; exit 1; }
# 快照改到「首次真正投票前」才读（见主循环），启动时不再无条件落盘。
log "启动 MAX_IIN=$MAX_IIN TEMP_GUARD=$TEMP_GUARD（快照将在首次投票前读取）"
echo '[警告] 充电写入未经本机标定；前台守护运行，另一个同权限shell可 charge stop。'
turbo_done=0
active=0
while :; do
    [ ! -f "$ST/paused" ] || exit 0
    status_text=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
    charging=0
    case $status_text in Charging|Full) charging=1 ;; esac
    [ "$online" != 1 ] || charging=1
    guarded=0
    if [ "$TEMP_GUARD" -ne 0 ]; then
        temperature=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
        # 温度缺失/非数值/量纲异常时一律保守释放，不继续高票。
        if ! uint "$temperature"; then guarded=1
        elif [ "$temperature" -lt 100 ] || [ "$temperature" -gt 700 ]; then
            fail "temperature=$temperature 超出合理量纲(100..700 = 10.0..70.0C)，按保守释放处理"
            guarded=1
        elif [ "$temperature" -ge "$TEMP_GUARD" ]; then guarded=1; fi
    fi
    if [ "$charging" = 1 ] && [ "$guarded" = 0 ]; then
        # 安全审查意见：快照必须在「首次真正接管前」现读，且必须是系统自己的值。
        # 若读到的值恰好等于我们的目标，说明那是上次未清理的自己的票，拒绝覆盖。
        if [ ! -f "$SNAP" ]; then
            original=$(read_dcp) || { fail 'dcp 读取失败，拒绝写入'; exit 1; }
            uint "$original" || { fail '无法解析 dcp 原值，拒绝写入'; exit 1; }
            if [ "$original" = "$MAX_IIN" ]; then
                fail "快照值=$original 等于目标值，疑似上次残留的自己的票；拒绝写入，请先 release"
                exit 1
            fi
            ( set -C; printf '%s\n' "$original" > "$SNAP" ) || exit 1
            log "首次接管快照 dcp=$original"
        fi
        if [ "$CHARGE_TURBO" = 1 ] && [ "$turbo_done" = 0 ]; then
            [ -r "$TURBO" ] && [ -w "$TURBO" ] || { fail 'turbo不可读写'; exit 1; }
            turbo_original=$(cat "$TURBO" 2>/dev/null | awk '{print $NF; exit}')
            case $turbo_original in 0|1) ;; *) fail 'turbo格式未知，拒绝写'; exit 1 ;; esac
            ( set -C; printf '%s\n' "$turbo_original" > "$ST/turbo.snap" ) || exit 1
            (printf '1\n' > "$TURBO") 2>/dev/null || { fail 'turbo写入失败'; exit 1; }
            turbo_done=1
        fi
        current=$(read_dcp) || { fail 'dcp读取失败'; exit 1; }
        uint "$current" || { fail 'dcp格式变化，停止'; exit 1; }
        if [ "$current" != "$MAX_IIN" ]; then
            (printf 'thermal dcp %s\n' "$MAX_IIN" > "$NODE") 2>/dev/null || { fail '投票失败，停止'; exit 1; }
            after=$(read_dcp)
            [ "$after" = "$MAX_IIN" ] || { fail "写后读回=$after，不等于目标，停止刷写"; exit 1; }
            [ "$VERBOSE" != 1 ] || log "重投 dcp=$MAX_IIN"
        fi
        active=1
    elif [ "$active" = 1 ]; then
        do_release || exit 1
        log '停止充电或温控触发，已释放'
        active=0
    fi
    sleep 1 || exit 1
done
