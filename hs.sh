#!/system/bin/sh
# 总入口：依赖同目录三个脚本、/system/bin/sh 与 /data/local/tmp/hs 状态。
# diag/cpu show/charge status允许shell只读；写操作需要临时root。
# 不调用su、不后台化、不安装服务；启动失败保留子脚本错误与退出码。
case $0 in
    */*) DIR=${0%/*} ;;
    *) DIR=. ;;
esac
run_script() {
    script=$1
    shift
    [ -r "$DIR/$script" ] || { echo "[错误] 缺少同目录脚本：$script" >&2; return 1; }
    /system/bin/sh "$DIR/$script" "$@"
}
need_root() {
    [ "$(id -u)" = 0 ] || {
        echo '[错误] 此操作需要已有临时root；充电还需要补充组1000。不自动su。' >&2
        return 1
    }
}
case ${1:-help} in
    diag) run_script hs-diag.sh; exit $? ;;
    charge)
        case ${2:-status} in
            start) need_root && run_script hs-charge.sh run; exit $? ;;
            stop) need_root && run_script hs-charge.sh stop; exit $? ;;
            release) need_root && run_script hs-charge.sh release; exit $? ;;
            status) run_script hs-charge.sh status; exit $? ;;
            *) echo '用法：sh hs.sh charge start|stop|release|status' >&2; exit 2 ;;
        esac ;;
    cpu)
        case ${2:-show} in
            show) run_script hs-cpu.sh show; exit $? ;;
            boost) need_root && run_script hs-cpu.sh boost "${3:-2}"; exit $? ;;
            restore) need_root && run_script hs-cpu.sh restore; exit $? ;;
            *) echo '用法：sh hs.sh cpu show|boost [秒数1..5]|restore' >&2; exit 2 ;;
        esac ;;
    off)
        need_root || exit 1
        rc=0
        run_script hs-charge.sh stop || rc=1
        run_script hs-cpu.sh restore || rc=1
        [ "$rc" != 0 ] || echo '[释放] 两个子脚本均报告完成；请diag/cpu show核对。'
        exit "$rc" ;;
    *)
        echo '用法：sh hs.sh diag | charge start|stop|release|status | cpu show|boost [秒数]|restore | off'
        echo 'charge start 前台运行；默认 MAX_IIN=2000 且 TEMP_GUARD=400（已按安全审查收紧）。'
        exit 2 ;;
esac
