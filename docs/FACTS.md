# AMG-AN00 适配事实核对表（实测，2026-11-06 17:00–17:35）

> 来源：宿主 adb 只读探测 + `team_executor` 真机侦察报告（含两处已纠正的误判）。
> 标 `[实测]` 的为命令输出直接证据；标 `[推断]` 的不作事实使用。

## 1. 设备与平台 [实测]

| 项 | 值 |
|---|---|
| 型号 | HONOR AMG-AN00（`AMG_AN00` / `HNAMG`） |
| 平台 | `ro.board.platform=pineapple`（骁龙 8 Gen 3 / SM8650），`ro.hardware=qcom` |
| 系统 | Android 16 / MagicOS 10.0.0.175（`AMG-AN00 10.0.0.175(C00E170R202P1)`） |
| SELinux 当前 | `Permissive`；但 `ro.boot.selinux=enforcing` → **重启必回 Enforcing** |
| 当前 shell | `uid=2000(shell)`，组内**无** 1000(system)；`scontext=u:r:shell:s0` |
| 充电状态 | `Discharging` / `usb/online=0` / `current_now≈-800mA` → **本次无充电态数据** |
| 充电服务 | `vendor.honor.hardware.power-service` pid=1982；**无 `power_if` 进程** |

## 2. 节点权限（全部 stat 实测）

### 临时 root（uid=0 + 补充组 1000/2000）可写候选

| 路径 | mode | owner | 可写依据 |
|---|---|---|---|
| `/sys/devices/system/cpu/cpufreq/policy{0,2,5,7}/scaling_max_freq` | 664 | system:system | **组 1000 写位** |
| 同上 `scaling_min_freq` | 664 | system:system | **组 1000 写位** |
| `/sys/class/hw_power/interface/iin_limit` | 660 | system:system | **组 1000 写位** |
| `/sys/class/hw_power/interface/enable_charger` | 660 | system:system | 组 1000 写位 |
| `/sys/kernel/msm_performance/parameters/cpu_max_freq` | 644 | root:root | **uid=0 即 owner** |
| 同上 `cpu_min_freq` | 644 | root:root | uid=0 即 owner |
| `/sys/devices/system/cpu/cpufreq/boost` | 644 | root:root | uid=0 即 owner（当前值 1） |
| `/proc/sys/kernel/sched_util_clamp_min` / `_max` / `_min_rt_default` | 644 | root:root | uid=0 即 owner |
| `/sys/class/hw_power/charger/direct_charger_hsc/{iin_thermal,ichg_control_enable,thermal_reason,dummy_vbat,...}` | 644 | root:root | uid=0 即 owner |
| `/sys/class/hw_power/interface/{enable,power_limit,batt_para_chk,esoc}` | 640 | root:root | uid=0 即 owner |
| `/sys/class/hw_power/interface/charge_enable_hz` | 220 | root:root | owner 只写 |

**⚠️ 全部前提：临时 root 必须带补充组 1000(system)。** 若开火后组里没有 1000，则所有 `660/664 system:system` 节点全部写不了（uid=0 不是 owner）。**此项未实测，是本方案最大的单点风险。**

### 写不了的

| 路径 | mode | owner | 原因 |
|---|---|---|---|
| `/sys/class/hw_power/adapter/*`（除 uevent） | 440 | system:system | 无组 1000 时读都读不到 |
| `/sys/class/hw_power/interface/iin_thermal`、`iin_thermal_all` | 220 | system:system | 只写，且需组 1000 |
| `/sys/fs/cgroup/cgroup.procs` | 775 | system:system | 组 system，临时 root 组 1000 若在则可写（未验证） |

## 3. 两处专家误判（已复核纠正）

| 误判 | 复核证据 | 正确结论 |
|---|---|---|
| 「`msm_performance` / `pnpmgr` / `perf_hint` / `sched_upmigrate` / `sched_downmigrate` 五个都不存在」 | `ls -ld /sys/kernel/msm_performance` 与 `/sys/module/msm_performance` 均存在；`cat parameters/cpu_max_freq` 返回 `0:2147483647 ...` | **`msm_performance` 存在且可读可写**；其余四个确实缺 |
| 「`scaling_*_freq` 是 664，other 有写位，连 shell 都能写」 | `stat` 显示 664 = owner rw / group rw / **other r--** | **other 无写位**；能写是靠**组 1000**，不是 other |

> 教训：子代理的「存在性判断」与「权限语义解读」都会出错，必须用 `stat` + `ls -ld` 双口径复核。

## 4. 上游仓库的事实（读码）

- 模块形态：Magisk/KernelSU，`/data/adb/modules` + `service.sh` 常驻 + `post-fs-data.sh` 早期钩子
- 充电：`echo "thermal <lane> <mA>" > /sys/class/hw_power/interface/iin_limit`，0.3s 轮询夺回，系统约 4.5s 重设
- 频率：`/proc/powerhal_cpu_ctrl/perfserv_freq` 写 `<slot 0-7> <min> <max>`（**本机无此节点**）
- 相机全家：MTK ISP（`libispfeature_mtkcam.v4l2.so`、`QRFUSION`）→ **本机无**
- 作者自述：「❌ 不适用：荣耀高通机型（充电栈不同）」「仅 MTK / MagicOS 架构；高通机型不适用」

## 4.5 移植时的三个「必须知道」的机制风险（来自解剖员，已核对源码）

1. **充电票驻留内核，进程退出 ≠ 票消失**。`thermal dcp 20000` 是一张**内核投票**，写进去就留在注册表里，`kill -9` 不会触发清理。原模块靠主循环进入 `do_release` 分支写回快照值来释放；被强杀就释放不了，票一直留到重启。
   → 我们的脚本**必须**：启动即快照、退出走 trap、并提供独立 `off` 命令兜底。
2. **`thermal dcp 0` 不是「撤销」，是「换下一个投票者」**。原机实测 `thermal dcp 0` 会让值从 1000 → 2500 且 21 秒无恢复，是**部分解锁**不是交还。
   → 释放只能用**快照写回**，绝不能用 0。
3. **本机没有 `/proc/device-tree/direct_charger*/temp_para`**（实测缺失）。原机靠这层内核温度阶梯（≥44°C 自动降到 6000/1700/0）兜底；本机**看不到这层兜底是否还在**。
   → 这意味着「20A 投票有没有内核安全阀」在本机**未验证**，充电写操作的风险等级要上调，必须小步验证。

## 5. 待实测（需主人同意后才动）

1. 开火后 `id` 的补充组是否含 `1000(system)`（**决定方案成败**）
2. `test -w /sys/class/hw_power/interface/iin_limit` 在临时 root 下是否为真
3. 写 `thermal dcp <mA>` 在本机是否被内核接受（会产生内核日志，有触发异常风险）
4. `msm_performance/parameters/cpu_max_freq` 写入语义（是硬上限还是 QoS 票）
5. 充电态（插电）下的 `iin_rt_current` 基线，用于对比解锁效果

## 6. 真机验证记录（2026-11-06 17:34）

**验证方式**：`cat hs-diag.sh | adb shell sh`（stdin 喂入，不落盘，零写操作）。

**结果**：脚本跑通，三态守卫正常（缺失/不可读/读取失败分别输出）。

**发现的 bug（必须修）**：
```
sh: <stdin>[90]: /system/bin/printf: Argument list too long
```
`hs-diag.sh:90` 把整份 `dmesg` 存进变量再用 `printf '%s\n' "$logs"` 传给管道，Android mksh 的参数列表上限直接被打爆。
**修法**：`dmesg 2>/dev/null | grep -E '...' | tail -n 30`（不落变量）。

**顺带确认的新事实**：
- `battery/uevent`: `POWER_SUPPLY_ONLINE=1` 但 `STATUS=Discharging`、`usb/online=0` → **ONLINE 字段不能当充电判据**
- `battery`: `CYCLE_COUNT=597`、`CHARGE_FULL=5091000` vs `CHARGE_FULL_DESIGN=5300000` → 健康度 ≈96%
- `usb/uevent`: `USB_TYPE=[Unknown] SDP DCP CDP ACA C PD PD_DRP PD_PPS BrickID` → **PD/PPS/BrickID 都在**（荣耀私有快充协议）
- `adapter/*`、`interface/iin_limit`、`interface/enable_charger` 在 shell 下**全部不可读**（需 root+组1000）
- `cpufreq` 四簇全部可读：policy5=cpu5-6(2956800)、policy7=cpu7(3302400)

## 7. dmesg 关键证据（2026-11-06 17:38，真机，修复 diag bug 后取得）

```
[5269:thermal-core-th][I/power_if] sysfs_set=iin_thermal user=thermal type=dcp value=3#1000
[5269:thermal-core-th][I/power_if] sysfs_set=iin_thermal user=thermal type=sc  value=0#3500
[5269:thermal-core-th][I/power_if] sysfs_set=iin_thermal user=thermal type=hsc value=0#3500
[5269:thermal-core-th][I/power_if] sysfs_set=iin_thermal user=thermal type=wl_sc value=0#1500
[10634:tr][I/power_if] get charge turbo enable=0
```

**推论（有证据，非纯推断）**：
1. `power_if` 是**内核日志标签**（`[I/power_if]`），不是用户态进程 —— 侦察员「没有 power_if 进程」是伪命题。
2. **`thermal-core-th`（pid 5269）是持续写票的对手**，与上游 README 所述「iAware 进程内 PowerGennie 的 thermal-core-th」**完全一致**。
3. 本机同样在投 `type=dcp` 的票（`value=3#1000`），**投票机制与上游同源** → 充电解锁的移植前提成立（但「写入能否改变实际工作点」仍需插电实测）。
4. `charge_turbo_enable` 由 `tr` 线程读取，当前 enable=0。
5. 本机日志里 `iin_thermal` 是写入口名，type= 才是 lane —— 与上游「`interface/iin_limit` 写 `thermal <lane> <mA>`」的对应关系待插电时验证。

**仍未验证**：`thermal dcp 20000` 在本机是否真被接受并改变 `iin_rt_current`（需插电 + 写操作）。

## 8. 真机写入验证（2026-11-06 17:44–17:55，主人已授权）

### 已验证成立

| 项 | 证据 |
|---|---|
| 临时 root 带补充组 1000(system) | `groups=0(root),1000(system),...,2000(shell)` [实测] |
| `iin_limit` 可写 | `test -w` = WRITABLE [实测] |
| `iin_limit` 的 dcp 行 = 实际输入电流 | `dcp 1000` ↔ `iin_rt_current 1000` [实测] |
| `msm_performance/cpu_max_freq` 可写 | boost 写入被接受，`exit status=0` [实测] |
| `INT_MAX` 可写入（撤销票） | 写后读回 `0:2147483647 ...` [实测] |

### 发现的真问题

1. **`hs-cpu.sh` 的 restore 偶发不落地**：第一次 boost 后读回仍是 BOOST_MAX（2265600/3148800/2956800/3302400），说明 cleanup 的恢复没生效。已改为「写后读回校验 + 最多重试 3 次 + 失败报错」。
2. **`cpu_max_freq` 是多写入者共享节点**：恢复后 `cpu0-4=INT_MAX`，但 `cpu5/6=2899200`、`cpu7=2438400` —— 这两个值是**系统热控**写的（充电中 41°C 降频），不是我们的残留。含义：**boost 效果会被系统热控覆盖**，`restore` 写 INT_MAX 只撤销自己的票，不代表回到 OEM 策略。
3. **`root_amg.sh run` 的引号陷阱**：命令含 `$`/引号/`$()` 会被远端 shell 先展开，实测出现 `>` 续行提示、命令被截断。**正确做法：把逻辑写进脚本文件再 `run "sh <脚本>"`**，不要传复杂内联命令。

### 充电写入：被安全阀主动拦下

手机实测时正在充电，温度从 40.0°C 一路升到 **42.0°C**，触发脚本内设的安全阀（`>= 420` 即 42.0°C 拒绝写入）。
**本次没有执行任何充电写入**，`dcp` 全程保持 `1000` 未变（多次读回确认）。
→ 这不是失败，是安全阀按设计工作；充电写入验证需等温度回落后再做。

### 当前设备状态（验证结束）

- `cpu_max_freq`: cpu0-4 = `2147483647`（已撤销），cpu5-6 = 2899200、cpu7 = 2438400（**系统热控值**，非本脚本残留）
- `cpu_min_freq`: 全 `0`（干净）
- `iin_limit`: `dcp 1000 / lvc 1500 / sc 2500 / hsc 2500`，与验证前一致，**无残留**
- 充电中，68%，41.0°C

## 9. 充电写入端到端验证成功（2026-11-06 17:52）

**条件**：插电充电中，电池 38.0°C，`usb_online=1`，开火后实测 37.0°C。

**脚本**：`_test_charge.sh 2000`（写→观察→恢复，一次 root 会话内完成）

```
ORIG_dcp=1000
基线:   dcp 1000        rt=1000  bat=2557  temp=370
try1:   wrote=2000  readback=2000  rt=2000  bat=2557  temp=370
try2:   wrote=2000  readback=2000  rt=2000  bat=2708  temp=370
try3:   wrote=2000  readback=2000  rt=2000  bat=2762  temp=370
恢复:   final dcp=1000  rt=1000  temp=370
RESTORE_OK
```

**结论（已核对，非推断）**：
1. `thermal dcp 2000` **被本机内核接受**，读回 2000。
2. **实际输入电流跟随**：`iin_rt_current` 1000 → **2000**（这是关键，之前一直没验成的）。
3. 电池侧电流随之上升：2557 → 2708 → 2762 mA。
4. 温度**未上升**（37.0°C 稳定）。
5. 恢复成功：dcp 回 1000、rt 回 1000，**无残留**。

→ **充电解锁在 AMG-AN00 上端到端可用**。上游「高通机型不适用」的结论在本机被实测推翻（至少 dcp lane 这一条成立）。

**仍未验证**：更高档位（>2000）的电流/温升曲线、持续对抗时厂商 47s 覆盖在本机的实际时间、长期电池影响。

## 10. 4000mA 档位测试：被内核钳到 2000（2026-11-06 17:53）

```
基线:   dcp 1000        rt=1000  bat=1753  temp=390
try1:   wrote=4000  readback_dcp=2000  rt=2000  bat=1753  temp=390
try2:   wrote=4000  readback_dcp=2000  rt=2000  bat=2073  temp=390
try3:   wrote=4000  readback_dcp=2000  rt=2000  bat=2233  temp=390
恢复:   final dcp=1000  rt=1000  RESTORE_OK
```

**结论**：本机 `dcp` lane 的**实际上限是 2000mA**（写 4000 被内核钳到 2000，读回就是 2000）。
与上游 MT6379 平台不同（上游 dcp 可到 20000）。原因**未确定**，候选：适配器当前档位、充电 IC 限流、厂商温度策略。
温度 39.0°C 未上升。

→ **本机充电优化的天花板**：输入限流 1000 → 2000（翻倍），电池侧功率提升有限（前测约 +8%）。
→ 若想再快，需走 `sc`/`hsc`（SCP/UFCS 高压通道，当前系统投 3500），但那是另一套 lane，**未验证且风险更高**。

## 11. 安全审查 5 项问题已修复（2026-11-06 17:56–17:59）

| # | 问题 | 修复 |
|---|---|---|
| 1 🔴 | 裸跑即 `MAX_IIN=20000` + `TEMP_GUARD=0`（零温度保护） | 默认改 `2000`/`400`；`MAX_IIN>2000` 且 `TEMP_GUARD=0` 直接拒绝；温度量纲校验 100..700 |
| 2 🟠 | 启动时无条件快照，可能存成过期值 | 改为首次投票前现读；读到值等于目标时拒绝（疑似自己的残留票） |
| 3 🟠 | 陈旧锁卡死 release/stop/off；未拦 SIGHUP | release 允许回收已死进程的陈旧锁；加 `trap HUP/PIPE`；`hs.sh` 增 `charge release` |
| 4 🟠 | 重启后遗留快照被自动写回新内核会话 | 只报告、不自动写回；并 `trap - 0` 防止 cleanup 误写 |
| 5 🟠 | `hs-cpu.sh` restore 写常量、且写从未改过的 min | boost 前存快照、restore 写回快照；不再写 min |

另修：`hs.sh` 退出码被掩盖成 0 → 各分支显式 `exit $?`（实测非 root `charge start` 现在正确返回 1）。
