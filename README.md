# AMG-AN00 临时 root 手动调度实验脚本

> 衍生自 [mengwuzhuanshou/HonorSchedulerUnlock](https://github.com/mengwuzhuanshou/HonorSchedulerUnlock)（MIT）。
> 目标设备：**HONOR AMG-AN00**（骁龙 8 Gen 3 / SM8650，Android 16，MagicOS 10），
> 运行在**临时受限 root** 下（无 Magisk、无持久化、重启即失效），不是模块。
>
> **已在真机验证**：只读诊断、CPU 上限写入、充电 `dcp` 投票（1000→2000 生效并成功恢复）。
> **未验证**：更高电流档位、低电量窗口下的真实提升、长期电池影响。详见 [docs/FACTS.md](docs/FACTS.md)。
>
> ⚠️ 上游作者自述「高通机型不适用」，但本机实测 `dcp` lane 投票链路可用 —— 结论以实测为准，不以自述为准。

## 文件

| 文件 | 作用 |
|---|---|
| `hs.sh` | 总入口：`diag` / `charge start\|stop\|release\|status` / `cpu show\|boost\|restore` / `off` |
| `hs-charge.sh` | 充电投票守护（快照恢复、温度闸、遗留检测） |
| `hs-cpu.sh` | CPU 上限（`msm_performance`，boost 前快照、退出写回） |
| `hs-diag.sh` | 纯只读诊断 |
| `tools/test-charge.sh` | 一次性充电写入验证（写→观察→恢复，自带温度闸） |
| `tools/test-cpu.sh` | CPU 恢复/写入验证 |
| `docs/FACTS.md` | 实测事实核对表（含两处已纠正的误判） |
| `docs/OPTIMIZATION-REPORT.md` | 本机优化方案报告 |

## 许可证

MIT，见 [LICENSE](LICENSE)。原始版权归 `mengwuzhuanshou`；本适配部分版权归 `ANYAEGW`。

## 证据与范围

已核对本地上游：`service.sh` 300–419、1334–1413 行，`action.sh` 全文、`tools/freqgov.sh` 全文、`state.sh` 全文及上游 README 的相关章节。
设备事实均由任务提供，按既定事实设计；没有再次探测，也不把上游机型测值当作本机结论。
只保留只读诊断、dcp 充电票和手动短时 CPU 上限实验；不含 FCM、VoLTE、相机、LSPosed、自动应用启动监听或滑动降频。

## 差异矩阵

| 项目 | 上游 | AMG-AN00 本次处理 |
|---|---|---|
| 平台 | 天玑/MTK | pineapple / qcom，SM8650，Android 16，MagicOS 10.0.0.175 |
| 权限 | Magisk/KernelSU 模块 | 临时受限 root；不用 magisk/ksud，不自动提权 |
| 能力 | 可借模块管理器启动 | CapBnd=0x8000c0，仅 SETGID/SETUID/SYS_NICE；无 SYS_ADMIN/DAC_OVERRIDE/CHOWN |
| 充电写入 | thermal dcp mA | 仅投 dcp；先快照、读后比较；本机作用未验证 |
| 充电权限 | 模块 root | iin_limit 属 system:system 0660，依赖补充组1000，uid=0 本身不够 |
| direct_charger*/iin_thermal | 上游已发现钳位无效 | 只读，不移植写入 |
| enable_charger | 上游写入被拒绝 | 只读，绝不盲写协议 |
| charge_turbo_enable | 上游协议触发时写 | 默认不写；显式开启后一次写1，保存0/1供释放 |
| CPU | perfserv_freq，policy0/4/7 | msm_performance，policy0/2/5/7，CPU0..7逐个赋值 |
| cgroup逃逸 | 为避免应用缓存冻结 | 不移植；cgroup.procs不可写，adb启动不在/apps/ |
| 生命周期 | 开机服务 | 手动前台启动；无持久提权、无自启、重启后不自动恢复运行 |
| shell | 上游有非POSIX写法 | /system/bin/sh；不使用数组、local、双中括号或ANSI-C引号 |

## 文件职责

- `hs-diag.sh`：纯只读，逐节点存在性/可读性守卫；不写诊断文件，不读取会触发探测的 adaptor_test。shell身份能看多少就输出多少，缺失/无权读取明确提示。
- `hs-charge.sh`：充电守护；原子 mkdir 锁配合 pidfile；每秒检查充电态，仅读回不同才写。TERM/INT、paused、断充、温控触发会恢复快照。异常写入/读回不符即停止，避免持续刷内核错误。
- `hs-cpu.sh`：show / boost / restore；boost只写上限，不把下限钉满。退出恢复全部上限2147483647、下限0，不是恢复OEM之前的票。
- `hs.sh`：统一入口，写命令先检查uid；不后台化、不调用su。

运行状态只放在 `/data/local/tmp/hs`：charge.log、iface.snap、turbo.snap、charge.pid/charge.lock、paused、cpu.pid/cpu.lock/cpu.cancel。目录必须归root所有，不能为符号链接；umask为077。请勿让不可信进程改动该目录。
这不是防恶意本地root的安全边界，也不保证处理人为制造的文件链接/竞态。
日志默认仅启动、释放和退出；VERBOSE=1 才逐次记录重投。日志不自动清空，长期实验请自行观察大小。

## 第一次按此顺序试

先由有手机连接权限的人员，把四个脚本完整放到同一目录（例如 `/data/local/tmp/amg-sched`）。无需chmod，直接sh运行。
下面命令在手机端执行；这里只提供命令，未执行。脚本不提供获取临时root的方法。

1. 普通 adb shell 先只读：

   ```sh
   cd /data/local/tmp/amg-sched
   sh hs.sh diag
   sh hs.sh cpu show
   ```

2. 在已获得临时root的 adb 启动shell中（保留补充组1000/2000），再次 `cpu show`。再用第二个可读shell观察四簇 scaling_cur_freq：

   ```sh
   sh hs.sh cpu boost 1
   sh hs.sh cpu show
   ```

   boost参数单位为秒，只接受1..5，省略默认2秒=2000ms。不使用小数sleep，避免把Android工具扩展当作POSIX保证。实际等待还受调度延迟影响。
   上限映射：CPU0–1=2265600、2–4=3148800、5–6=2956800、7=3302400 kHz。设上限不是强制满频；需要在等待窗口内另一个shell观察，事后show不能证明峰值。

3. 确认CPU实验可恢复、无异常后，最后才考虑充电写入。先保守尝试，勿据上游结果推断本机安全：

   ```sh
   MAX_IIN=2000 TEMP_GUARD=400 sh hs.sh charge start
   ```

   MAX_IIN单位mA，允许1..20000。**默认已改为 2000**（安全审查后收紧，原机 20000 仅作上限参考）。本机实测 dcp lane 上限就是 2000，写 4000 会被内核钳回 2000。
   TEMP_GUARD单位0.1°C，**默认已改为 400（40.0°C）**。温度缺失/量纲异常/超阈值都会停止投票并释放。阈值未在本机标定，不取代系统与硬件保护。
   Charging/Full 或 usb/online=1 均被视为充电态；即使Full仍可投票。两项均读不到时保守认为未充电。每秒读取，不采用上游0.3秒对抗。
   另一个**同样保有临时root**的shell停止：

   ```sh
   sh hs.sh charge status
   sh hs.sh charge stop
   sh hs.sh off
   ```

   start前台阻塞。只有一个临时root shell时，可通过TERM/INT退出；不要为后台守护假定root能脱离原进程存活。
   stop通过paused合作退出，最多等待10秒；CPU restore通过cpu.cancel合作取消，最多等待8秒。不会根据可能复用的PID盲杀。
   stop/off留下paused，防止意外重新启动。确认恢复完成后，在已有临时root的shell中手动 `rm /data/local/tmp/hs/paused` 才能再次启动。

4. 可选项（**首次不要开启**）：`CHARGE_TURBO=1 MAX_IIN=2000 TEMP_GUARD=400 sh hs.sh charge start`。
   仅在首次充电且未触发温控时保存charge_turbo_enable末列0/1，再写一次1。释放时尝试写回原0/1并读回核对。若发生断充/温控释放，同一进程后续不再主动重启turbo，需重新启动；该接口写语义本机未验证。

## 恢复机制与异常处理

- 启动在首次充电写入前保存dcp原值到iface.snap，恢复用同一语法 `thermal dcp 原值`，不是随便写0。原值为0时也保留并尝试恢复；0可能表示撤票，读回可能变成其他投票者的值，因此“写回原读数”不等于恢复原始投票者状态。
- 恢复读回与快照不符或内核拒绝时保留快照并返回错误。不要删快照掩盖失败，也不要把读回一致当作硬件工作点已恢复的证明。
- 遗留快照会使run拒绝继续并尝试恢复，避免覆盖原始证据。无锁时可运行 `sh hs-charge.sh release`。
- mkdir锁拒绝并发；不自动回收遗留锁，宁可阻塞也不凭PID猜测所有权。SIGKILL、root过期、终端被杀或断电无法保证执行trap。
- 若报告遗留锁：由设备操作人员结合pidfile与 `/proc/<pid>/cmdline` 核对**原进程已不存在**后，才手工删除对应空锁目录（rmdir），不要运行中的时候删锁。然后保留root执行charge release / cpu restore，再diag/show。无法确认时停止操作，交由设备负责人恢复。
- off并非事务：分别尝试释放充电与CPU，任一失败返回非0。锁无法释放、root已失效、sysfs卡死都可能阻止恢复，不承诺“必定一键恢复”。
- 重新开机不自动启动脚本，但 `/data/local/tmp/hs` 文件可能仍在；遗留快照属于旧内核会话，不能认定其数值仍适合新会话。重启后先只读核对，由设备人员判断旧快照处置，禁止盲目复用。

## 已知限制与风险

1. 临时root无CAP_SYS_ADMIN，不能mount/bind mount；无DAC_OVERRIDE/CHOWN，不能越过文件DAC、改属主或修改系统分区。本实现不做mount/umount、不改系统文件权限、不写/system、不改cgroup、不改SELinux、不注册自启。root会话退出后不能指望再次获得权限或释放此前的票。
2. SELinux已为Permissive是任务给定状态，不是脚本设置的。该状态削弱系统隔离，DAC仍生效；脚本不负责或承诺恢复SELinux策略。
3. 充电票、turbo写语义及温控阈值均未经本机标定。可能过热、加速电池老化、充电异常、内核异常/崩溃/重启；不要无人值守、不要取消硬件温控。上游MTK安全值不构成本机安全担保。
4. msm_performance是高通专有接口，其“上限还是QoS票”、按CPU聚合、其他服务覆盖行为均未在本机验证。restore不限值并非恢复OEM原始策略。walt和热控可能继续限频；boost不保证性能提升。
5. 无永久root、无持久化配置、无开机自启；存在进程时才轮询。**温度闸默认已开启（400=40.0°C）**；`MAX_IIN>2000` 且未设 `TEMP_GUARD` 时脚本会直接拒绝启动。
6. dmesg可能因能力不足而不可读；Android工具stat/awk等可用性未在手机核对。诊断读项也不能证明协议/电流实际生效。

## 已核对 / 未验证 / 未取到证据

- **已核对**：本地上游上述范围与本次源代码；节点映射、禁止写族与不相关功能裁剪采用题设。交付后做文件读回，不运行手机测试。
- **未验证**：设备行为、充电安全、CPU语义、信号退出/并发/恢复的真实运行、Android命令兼容性。
- **未取到证据**：sh -n机器语法检查输出。当前移植工程师角色有“不得执行命令”的上级硬限制，未调用命令执行器；人工阅读不等于sh -n通过。请由有执行权限的集成人员在发布/上机前对四个脚本逐个运行 `sh -n <脚本路径>`。
- 未调用任何子代理或审核代理；本角色不得再开子代理，因此未运行dev_duo审计。此交付是待集成验证的实验脚本，不是已验收设备方案。

## 集成验证记录（2026-11-06 17:35–17:40，集成方补做）

| 项 | 方法 | 结果 |
|---|---|---|
| 四个脚本语法 | `adb shell sh -n -s < 脚本`（Android mksh 自身解析） | **全部通过**，无输出 |
| bash 专有语法扫描 | grep `[[ / local / 数组 / $'...'` | **未发现** |
| `hs-diag.sh` 真机运行 | `cat hs-diag.sh \| adb shell sh` | **跑通**（exit 0），三态守卫正常 |
| `hs-cpu.sh show` 真机运行 | `adb shell sh -s show < hs-cpu.sh` | **跑通**，四簇频率正常输出 |
| `hs.sh` 无参 | `adb shell sh -s < hs.sh` | 正常打印用法 |
| 非 root `charge run` | 同上 | **exit 1** + 明确报错，不静默 |
| 非 root `cpu boost` | 同上 | **exit 1** + 明确报错 |
| 非 root `charge status` | 同上 | exit 0（只读，符合预期） |

**发现并已修复的真机 bug**：原 `hs-diag.sh:81–87` 把整份 `dmesg` 存入变量后 `printf '%s\n' "$logs"`，在 Android mksh 下报
`printf: Argument list too long`。已改为先管道过滤到 ≤30 行再输出，并区分「无匹配 / dmesg 不可读」两态；**修复后在真机复跑通过**。

**修复时顺带取得的 dmesg 证据**（非本脚本功能，但影响方案判断）：
```
[5269:thermal-core-th][I/power_if] sysfs_set=iin_thermal user=thermal type=dcp value=3#1000
[10634:tr][I/power_if] get charge turbo enable=0
```
→ `power_if` 是内核日志标签；`thermal-core-th` 是持续写票的对手，与上游描述一致；本机同在投 `type=dcp` 票。

> 以上验证**只覆盖只读路径与拒绝路径**。所有**写入**路径（`thermal dcp <mA>`、`msm_performance` 写入、turbo）**一次都没有在真机上执行过**，其行为仍属未验证。

## 真机写入验证（2026-11-06 17:44–17:55，主人授权后补做）

| 项 | 结果 |
|---|---|
| 临时 root 补充组 | ✅ 含 `1000(system)`，`test -w iin_limit` = WRITABLE |
| `iin_limit` 语义 | ✅ `dcp 1000` ↔ `iin_rt_current 1000` 完全对应 |
| `msm_performance` 写入 | ✅ boost 被内核接受（exit 0） |
| `INT_MAX` 撤销票 | ✅ 可写入，读回 `0:2147483647 …` |
| **充电写入** | ⚠️ **未执行**——手机充电中温度升到 42.0°C，触发脚本安全阀主动拒绝 |
| 验证后残留 | ✅ 无。`iin_limit` 与验证前一致；`cpu_min_freq` 全 0 |

### 这次验证发现并修掉的问题

1. **restore 偶发不落地**（已修）：第一次 boost 后读回仍是 BOOST_MAX，说明 cleanup 的恢复没生效。`restore_values` 已改为「写后读回校验 + 最多重试 3 次 + 失败大声报错」。
2. **`cpu_max_freq` 是多写入者共享节点**（认知修正）：恢复后 `cpu0-4` 是 `INT_MAX`，但 `cpu5/6=2899200`、`cpu7=2438400` —— 这是**系统热控**在充电时降频写的，不是本脚本残留。含义：**boost 可能被系统热控覆盖**；`restore` 只是撤销自己的票，不等于回到 OEM 策略。
3. **`root_amg.sh run` 的引号陷阱**（操作经验）：命令里的 `$`/引号/`$()` 会被远端 shell 先展开，实测出现 `>` 续行、命令被截断。**必须把逻辑写进脚本文件再 `run "sh <脚本>"`**。
