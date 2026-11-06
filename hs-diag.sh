#!/system/bin/sh
# 只读诊断：依赖下列 sysfs/proc 节点与 Android 自带 cat/tr/grep/tail/dmesg。
# shell 可运行；无权读取逐项说明。root+补充组1000 才能读部分荣耀接口。
# 不写文件、不触发 adaptor_test（读该节点也可能启动协议探测）。
read_node() {
    printf '\n--- %s ---\n' "$1"
    if [ ! -e "$1" ]; then
        echo '[缺失]'
    elif [ ! -r "$1" ]; then
        case "$1" in
            */interface/iin_limit) echo '[不可读] 需要 root+组1000' ;;
            *) echo '[不可读] 当前身份无读取权限' ;;
        esac
    else
        if data=$(tr '\000' ' ' < "$1" 2>/dev/null); then
            printf '%s\n' "$data"
        else
            case "$1" in
                */interface/iin_limit) echo '[读取失败] 需要 root+组1000；也可能被内核拒绝' ;;
                *) echo '[读取失败] 节点存在但内核拒绝读取' ;;
            esac
        fi
    fi
}
echo '===== AMG-AN00 只读诊断 ====='
if [ "$(id -u)" != 0 ]; then
    echo '[提示] 当前不是 root；只读可见项，受限项会明确标注，不尝试提权。'
fi
read_node /sys/class/power_supply/battery/uevent
read_node /sys/class/power_supply/usb/uevent
ADP=/sys/class/hw_power/adapter
if [ -d "$ADP" ] && [ -r "$ADP" ] && [ -x "$ADP" ]; then
    for f in "$ADP"/*; do
        [ -e "$f" ] || { echo '[缺失] adapter/*'; break; }
        [ -d "$f" ] || read_node "$f"
    done
else
    echo '[缺失或不可读] adapter 目录'
fi
IFACE=/sys/class/hw_power/interface
for n in iin_limit enable_charger charge_turbo_enable vbus; do
    read_node "$IFACE/$n"
done
read_node /sys/class/hw_power/charger/charge_data/iin_rt_current
for n in target_aicr_uA input_current_limit current_max voltage_max; do
    read_node "/sys/class/power_supply/primary_chg/$n"
done
for d in /sys/class/hw_power/charger/direct_charger*; do
    if [ ! -d "$d" ]; then
        echo '[缺失或不可见] direct_charger*'
        continue
    fi
    for n in iin_thermal chg_mode direct_charge_succ iadapt; do
        read_node "$d/$n"
    done
done
for n in caps_info vbus_level pe_ready typec_role local_rp_level; do
    read_node "/sys/class/tcpc/type_c_port0/$n"
done
for n in pd_state src_power usb_state; do
    read_node "/sys/class/hw_typec/typec/$n"
done
for n in supports_usb_power_delivery type usb_power_delivery_revision; do
    read_node "/sys/class/typec/port0-partner/$n"
done
for n in power_role power_operation_mode; do
    read_node "/sys/class/typec/port0/$n"
done
for d in /proc/device-tree/direct_charger_*; do
    read_node "$d/temp_para"
done
for n in cpu_max_freq cpu_min_freq; do
    read_node "/sys/kernel/msm_performance/parameters/$n"
done
for p in 0 2 5 7; do
    for n in related_cpus scaling_governor scaling_cur_freq scaling_min_freq scaling_max_freq cpuinfo_max_freq; do
        read_node "/sys/devices/system/cpu/cpufreq/policy$p/$n"
    done
done
printf '\n--- 最近内核充电日志（最多30行） ---\n'
# 注意：不能把整份 dmesg 存进变量再 printf —— Android mksh 会报
# "printf: Argument list too long"（真机实测 2026-11-06）。先管道过滤到 ≤30 行。
logs_out=$(dmesg 2>/dev/null | grep -E 'power_if|aicr|adapter_prot_arbitration' | tail -n 30)
if [ -n "$logs_out" ]; then
    printf '%s\n' "$logs_out"
elif dmesg 2>/dev/null | head -n 1 | grep -q .; then
    echo '[无匹配] 当前环形缓冲区没有相关记录'
else
    echo '[不可读] dmesg 被权限/内核策略拒绝；uid=0 也不保证可读'
fi
