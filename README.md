# DTBO 有线充电限制解锁（KernelSU 模块 · 仅小米 17）

> [!WARNING]
> **本模块只针对小米 17（cancún / SM8850，A/B 双槽）。其他机型一律未测试，请勿直接使用。**
>
> `ref/patch.sed` 里的改写规则是从**小米 17 的原厂 dtbo** 提取出来的，
> 节点名、属性名和取值含义都只对这台机器负责。换到别的机型上，有两种结果：
>
> * 目标节点/属性不存在 → 校验报 `MISSING` / `MISMATCH` 并中止，分区不动（**这是好的情况**）；
> * 节点结构相似但参数含义不同 → 能刷进去，但改出来的东西未必是对的（**这是坏的情况**）。
>
> 后者可能让充电行为异常，甚至开不了机。仓库里对多种镜像布局（大端 DTBO 表、
> 紧凑条目排列、裸 DTB 串接）的支持，说的是**解析能力**，不代表已在对应机型上验证过。
> 除小米 17 外，本模块**没有任何机型的实机测试记录**。
>
> 想移植到别的机型：先用 `dump.sh` 导出自己的原厂 dtbo，确认目标节点与属性确实存在
> 且语义一致，再改 `ref/patch.list` 用 `gen_ref.py` / `gen_sed.py` 重新生成规则。
> 动手前务必备份原分区。

> [!IMPORTANT]
> ## 装之前先改系统温控，否则改了也白改
>
> 这个模块只改 `dtbo` 里的**充电 IC 自己的温度限制**（JEITA 分段表 +
> `mca_charger_thermal` 节点）。**系统层还有一套温控**（Qualcomm thermal HAL /
> 各家 thermal-engine），它会按整机温度、壳温、SoC 温度去压充电电流，
> 优先级在 `dtbo` 之上。
>
> 所以：**不先处理系统温控，刷完这个模块充电速度可能一点变化都没有**，
> 尤其是在室温偏高或边充边用的时候。
>
> 正确做法（按顺序）：
>
> 1. 先装 [Scene](https://github.com/helloklf/vtools)（第三方工具，非本项目提供）；
> 2. 在 Scene 里把**温控等级改为「丧心病狂」**（不同版本可能在
>    「性能 / 温控」或「充电」相关页面里）；
> 3. 再装本模块、重启。
>
> 「丧心病狂」等于基本关掉系统温控限流。**这会显著增加发热和电池风险**，
> 边充边玩、车里暴晒、捂着手机充电这些场景请自己注意。
> 只想稳妥一点的话，安装时选**安全档**（音量下键，0~48℃ 全速）。

**在安装过程中**就直接完成「提取 → 解包 → 改写 → 打包 → 校验 → 刷入」，
装完重启即生效，不需要等开机再跑。

> [!IMPORTANT]
> **只在安装时改，安装之后不会自动再改。**
>
> 模块**不会**在每次开机时自己刷 `dtbo`。系统更新（OTA）之后，`dtbo` 分区会被
> 系统换回原厂版本，改出来的效果就没了 —— 这时候需要**你手动跑一次**：
> * KernelSU 模块页的 **「操作」按钮**，或
> * 打开模块的 **WebUI**，点 **「运行修改」**（会二次确认）。
>
> 两处跑的是同一个 `action.sh`。WebUI 里如果「分区一致」显示
> **否（已被覆盖）**、状态显示 **需重新应用**，就是在提示你该跑一次了。

它对**当前系统所在槽位**的 `dtbo` 分区做三件事：

* 把有线充电的 JEITA / 温度分段表改成目标值，使 **0~48 ℃（安全档）或
  0~56 ℃（极限档）区间全程全速充电**，安装时用音量键选；
* 把 `mca_charger_thermal` 节点置为 `status = "disabled"`，不再因整机温度限制充电功率；
* 只动有线充电相关节点，无线充电、电池模型等节点保持原样。

---

## 一、它是怎么做的

```
安装时（customize.sh）
  识别 A/B 槽位 → 读 dtbo 分区 → 识别镜像格式 → dtc 反编译成 dts
        ↓
  按 ref/patch.sed 改写有线充电参数
        ↓
  dtc 重新打包 → 再反编译 → 逐条比对 174 项参数
        ↓
  备份原分区 → 写回 → 回读比对 sha256
        ↓
  重启 → 新 dtbo 生效
```

* **执行时机**：只有两个入口会写分区 ——
  1. `customize.sh`（安装阶段）调用 `run_main`，安装界面实时打印每一步；
  2. 手动触发：KernelSU 模块页的「操作」按钮（`action.sh`）或 WebUI
     的「运行修改」。

  `post-fs-data.sh` **不刷写任何东西**，只做只读判断：收掉已确认的 pending、
  统计「刷写后还没确认开机」的次数、必要时回滚。所以 OTA 之后需要手动跑一次。
* **镜像格式**：自动识别两种，都能处理——
  * **DTBO 表**（`0xd7b7ab1e` 魔数）：解析 `dt_table_header` 与 `dt_table_entry`，
    逐个条目改写，再按原镜像的布局风格重新排布。
    * **字节序**两种都认：官方 `mkdtimg` 是小端（文件头字节 `1e ab b7 d7`），
      也有厂商用大端（文件头字节 `d7 b7 ab 1e`，小米 17 就是这种）。
    * **条目布局**两种都复现：标准做法按 `page_size` 对齐；也有设备（同上）
      条目之间完全不填充、紧挨着排。重打包时按原样复现，表结构才和原厂一致。
    * 条目的 `id` / `rev` / `custom` 字段原样保留，条目顺序不变。
  * **裸 DTB 串接**（少数老设备 / 早期方案）：按 `d00dfeed` 头依次切分。
* **多条目处理**：DTBO 表里通常有多个板型条目，只有当前机型那个含充电节点。
  改写后与原文件完全相同的条目视为「不含目标节点」，原样保留；
  若**所有**条目都不含目标节点，直接中止并提示参考表不匹配，不碰分区。
* **槽位识别**：依次读 `ro.boot.slot_suffix`、`ro.boot.slot`、`/proc/cmdline`，
  确定目标是 `dtbo_a` 还是 `dtbo_b`。**绝不会去写另一个槽位。**
  识别不出时可 `config.conf` 里 `FORCE_SLOT=a` 或 `b` 强制指定。
* **分区定位**：在 `/dev/block/by-name/`、`/dev/block/bootdevice/by-name/` 下找节点，
  并用 `/sys/class/block/<dev>/uevent` 里的 `PARTNAME` 二次确认，防止刷错分区。
* **改写方式**：`ref/patch.sed` 是构建时从参考 dts 生成的 sed 脚本，
  按「节点 + 属性名」精确替换取值。不依赖 `awk`、不依赖 `busybox`。
* **解包工具**：模块自带静态链接的 aarch64 `dtc`（1.8.1），无需额外安装。
* **校验**：刷写前把新镜像重新反编译，逐条比对 174 项充电参数；
  再把新镜像重新拆一遍，确认每个 DTB 都能原样取出。
  任何一步不一致就中止，分区保持原样。

## 二、安装与使用

1. **先按上面那节把 Scene 温控改成「丧心病狂」**，否则装了也不一定有效。
2. 用 KernelSU（或 Magisk）安装 `dtbo_charge_unlock-v1.7.0.zip`。
   **安装过程中就会刷写**，安装界面能看到完整过程与结果。
3. 安装过程中会让你选档位（见下），选完继续。
4. 安装完成 → 重启手机 → 新 `dtbo` 生效。

### 安装时选档位（音量键）

安装脚本会停下来等 10 秒，让你用音量键选一个温度档位：

| 按键 | 档位 | 全速区间 | 说明 |
| --- | --- | --- | --- |
| **音量下** | 安全档 | 0~48 ℃ | 更早开始降功率，发热和电池压力小一些 |
| **音量上** | 极限档 | 0~56 ℃ | 原来的行为，全速区间最长 |
| 不按（10 秒后） | 保持现有 | `config.conf` 里的值 | 默认是极限档 0~56 ℃ |

两个档位改的都是同一套 JEITA / `ffc_temp_high` 分段表，区别只是
**全速段的高温边界**落在 48 还是 56 ℃。48 ℃ 以上两个档位都会开始降功率，
只是安全档降得更早。

选择结果会**直接写回 `config.conf` 的 `FFC_TEMP_HIGH`**，作为唯一事实来源，
之后每次重跑（手动触发）用的都是同一个档位，不会两边对不上。

如果读不到音量键（例如设备没给 `getevent` 权限），会打印一行提示并保持
`config.conf` 当前设置，安装继续，不会卡住。

不想用按键、想固定档位，就在 `config.conf` 里填 `FORCE_TIER=safe` 或 `max`，
安装时会跳过按键等待。

> 换档位改的是分区里的 `dtbo`，不是运行时可调参数，所以**必须重新刷一次**：
> 改好 `config.conf` 的 `FFC_TEMP_HIGH`，再点「操作」按钮或 WebUI 的
> 「运行修改」。模块会发现档位和上次刷入的不一样，自动重新刷写；
> 什么都没改的话它会直接跳过，不会白刷一遍。

想先只看看不写分区，把 `config.conf` 里的 `DRY_RUN` 改成 `1` 再安装，
安装界面会走到「复核通过」但跳过写入，产物在 `/dev/dtbo_charge_unlock/new.img`。

装好之后随时可以手动重跑（会打印全过程）：

```sh
su -c "sh /data/adb/modules/dtbo_charge_unlock/action.sh"
```

### 系统更新（OTA）之后要做什么

**需要手动跑一次**，否则 `dtbo` 是原厂的，充电限制照旧。

1. 先正常完成 OTA 更新并重启；
2. 打开 KernelSU → 本模块 → 点 **「操作」**；或点进模块打开 **WebUI →「运行修改」**；
3. 看到刷写成功后**再重启一次**，新 `dtbo` 才生效。

WebUI 会帮你判断：状态显示 **需重新应用**、「分区一致」显示
**否（已被覆盖）**，就说明当前分区不是本模块写的了。

模块不会在开机时偷偷帮你改回去 —— 这是有意的：写分区是需要你知道的操作。

### 在 KernelSU 里看充电状态（WebUI）

模块带一个网页界面。装好后在 KernelSU 管理器的模块详情页点「打开」，
或从模块卡片进入，即可实时查看：

* 电量、功率、电流、电压、电池温度
* 充电状态与供电来源（USB/PD/无线，含握手电压与电流上限）
* **全速充电温度窗口**：`config.conf` 里的目标区间（安全档 0~48℃ / 极限档 0~56℃），
  以及当前温度落在窗口内还是越界
* 功率与温度的实时曲线（最近 5 分钟）
* 电池/充电/PMIC 相关温度区
* 模块自身状态：是否已应用、上次刷写时间、是否在等开机确认、备份情况
* **是否还是本模块写入的那份**（「分区一致」）—— 系统更新后这里会变成
  **否（已被覆盖）**，状态也会提示 **需重新应用**

页面上的采集是**只读**的：只用 `ksu.exec` 跑 `monitor.sh` 读 `/sys`、`/proc`
和模块自己的 `state/`，不写分区、不改配置。

唯一的写操作是 **「运行修改」按钮**：点了会先弹确认框，确认后执行模块自带的
`action.sh`，由它完成「解包 → 改写 → 备份 → 刷入 → 回读校验」，并把过程和
退出码回显在页面上。页面本身不直接写分区，也不会在你没点的情况下刷写。

温度窗口那条只是「目标值」，实际充电功率还受充电器、线材、SoC 温度等影响，
页面不会把这些混为一谈。

## 三、安全机制

| 机制 | 说明 |
| --- | --- |
| 只手动触发 | 只有安装时、以及手动点「操作」/「运行修改」时才写分区；开机阶段绝不自动刷写 |
| 备份 | 刷写前把整个分区备份到 `backup/dtbo_a_YYYYmmdd-HHMMSS.img`，并校验备份完整 |
| 刷前复核 | 新镜像必须能反编译回来，且 174 项参数逐条匹配，否则中止 |
| 刷后回读 | 写入后回读分区比对 sha256，不一致立刻回滚 |
| 开机确认 | 每次刷写生成一个一次性令牌；下次开机走到 `service.sh`（开机后期）即记为确认 |
| 自动回滚 | 刷写后连续 3 次开机都没走到开机后期，判定新 dtbo 有问题，自动写回备份并停用模块 |
| 重复运行不白刷 | 镜像和档位都没变时直接跳过；只改了档位会自动重刷 |
| 安装失败不阻断 | 安装阶段刷写失败（例如分区只读）时模块照常装好，可手动再跑一次；想直接中止可设 `ABORT_ON_INSTALL_FAIL=1` |

> 自动回滚是唯一会在开机阶段写分区的动作，而且只在「刷完连续 3 次起不来」
> 这种已经出事的情况下才动手。它是用来把人从变砖循环里救出来的，
> 不是常规的自动刷写。

> **不检查 bootloader 锁定状态。** KernelSU 会伪造 `ro.boot.flash.locked` /
> `ro.boot.verifiedbootstate`（例如报成 `green`），按它们判断只会把正常设备
> 误判成「已锁定」而拒绝刷写。实际能不能写，由 `dd` 的返回值和回读校验说了算。

> 为什么不用「距刷写已过 N 分钟」当兜底判据？安装阶段刷写时，系统正跑在**旧**
> `dtbo` 上，运行时长完全不能证明新 `dtbo` 可用。用时间兜底会把「刷完就起不来」
> 误判成成功，反而丢掉自动回滚保护。所以判据只有一条：**能不能走到开机后期**。

手工回滚：

```sh
su -c "sh /data/adb/modules/dtbo_charge_unlock/restore.sh"
```

紧急情况下也可以用 fastboot 刷回备份：

```sh
fastboot flash dtbo backup/dtbo_a_YYYYmmdd-HHMMSS.img
```

> 注意：`fastboot flash dtbo` 会刷到当前活动槽位；若要指定槽位用
> `fastboot flash dtbo_a` / `dtbo_b`。

## 四、配置（`config.conf`）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `FFC_TEMP_LOW` | `0` | 全速充电温度下限（℃） |
| `FFC_TEMP_HIGH` | `56` | 全速充电温度上限（℃）。安装时选档会写这里：安全档写 `48`、极限档写 `56`。设成 `55` 就是完全照抄参考表；留空表示不调整 |
| `FORCE_TIER` | 空 | 固定档位、跳过音量键选择：`safe`（0~48℃）/ `max`（0~56℃）；留空 = 安装时按键选 |
| `FFC_REF_HIGH` | `55` | 参考表里实际使用的高温边界，用于换算 |
| `FORCE` | `0` | `1` = 忽略「已刷过」判断，强制重刷 |
| `DRY_RUN` | `0` | `1` = 只解包/改写/打包/校验，不写分区 |
| `FORCE_SLOT` | 空 | 强制槽位 `a` / `b`；留空自动识别 |
| `ABORT_ON_INSTALL_FAIL` | `0` | `1` = 安装阶段刷写失败时直接中止安装 |

## 五、目录结构

```
dtbo_charge_unlock/
├── module.prop           模块信息
├── customize.sh          安装时执行：权限 + 立刻刷写
├── config.conf           用户配置
├── common.sh             核心逻辑（槽位/分区/改写/校验/刷写）
├── post-fs-data.sh       开机早期：确认/回滚（不刷写）
├── service.sh            开机后期：确认「新 dtbo 能正常开机」
├── action.sh             KernelSU「操作」按钮 / 手动执行
├── restore.sh            手工回滚
├── dump.sh               只读导出：拆出每个 DTB 存成 .dtb/.dts，并生成参数汇总
├── monitor.sh            只读采集充电状态（WebUI 用，输出 key=value）
├── uninstall.sh          卸载时把备份留存到 /sdcard/Download（不改分区）
├── bin/dtc-aarch64       静态链接的 aarch64 dtc 1.8.1
├── webroot/              WebUI 页面（KernelSU 从这里加载）
│   ├── index.html        页面入口
│   ├── style.css         样式
│   └── app.js            逻辑（解析 monitor.sh 输出、画曲线）
├── ref/
│   ├── patch.sed         改写脚本（含温度占位符）
│   ├── patch.list        改写规则原始表（节点/属性/取值）
│   └── expect/*.txt      校验用的期望属性行
├── state/                运行状态（刷写哈希、pending 标记等）
├── backup/               原始分区备份
└── logs/                 日志（安装阶段单独一份 install-*.log）
```

## 六、改写了哪些节点

| 节点 | 作用 |
| --- | --- |
| `mca_buckchg_jeita` | 主 JEITA 温度-电流表（含 FFC 表） |
| `mca_buckchg_jeita_second_para` | 第二组 JEITA 参数 |
| `mca_buckchg_jeita_gbl_para` | 全局 JEITA 参数 |
| `mca_buckchg_jeita_tmp_para` | 温度分段参数 |
| `mca_strategy_buckchg_class` | 充电策略类别（含 `ffc_temp_low/high`） |
| `mca_strategy_quick_charge` | 快充策略与分段表 |
| `mca_quick_charge_batt_para_gbl` | 快充全局电池参数 |
| `mca_charger_thermal` | 整机温度限制表 → 置为 `disabled` |

`phandle` / `linux,phandle` 一律不改写（由 dtc 在编译时重新分配），
避免打断跨节点引用。

## 七、已知限制

* **只验证过小米 17（cancún / SM8850）这一台机器**，实机测试也仅此一台。
  其他机型未测试，`ref/patch.sed` 的规则不保证适用——强行用在别的机型上，
  轻则校验中止，重则刷入错误的参数。
* 需要 root（KernelSU / Magisk）。能否写分区由 `dd` 的返回值和回读校验决定，
  模块本身不做 bootloader 状态判断。
* 改写是「按属性名精确替换」，如果某个目标属性在原厂 `dtbo` 里不存在，
  校验会报 `MISMATCH`/`MISSING` 并中止——这是有意的保守行为。
* 校验通过只能证明「改出来的值符合规则表」，**不能证明这些值对你的机型是安全的**。
  规则正确不等于取值合适，这台机器上能用也不代表别的机器上能用。
* `mca_charger_thermal` 被禁用后，整机高温时不再降功率，
  请自行注意散热，尤其是边充边玩、车内暴晒等场景。
* **本模块管不到系统层温控。** 它只改 `dtbo` 里充电 IC 自己的温度限制；
  Qualcomm thermal HAL / 厂商 thermal-engine 的限流优先级更高，
  不把 Scene 的温控等级改成「丧心病狂」，很可能看不到任何提速。
* 档位只能在**安装时**选（或改 `FORCE_TIER` 后重跑）；它改的是分区里的
  `dtbo`，不是运行时可调参数。两个档位都只是把全速段的边界往后推，
  上限仍然是**充电 IC 自己的硬件保护**，那部分改不掉也不该改。
* 刷入后 `dtbo` 的 sha256 会变；如果系统开启了 dm-verity / AVB 严格校验，
  可能影响 OTA，恢复原镜像即可。

## 八、开发与自测（PC 端）

```sh
# 1) 生成假分区镜像
#    产出 ref.dtb / stock.dtb / other.dtb
#         part_stock.img（裸 DTB 单段）、part_two.img（裸 DTB 双段）
#         part_dtbo.img（DTBO 表 3 条目，小端，页对齐）
#         part_dtbo1.img（单条目）
#         part_dtbo_mixed.img（混合板型）、part_dtbo_none.img（均不含节点）
#         part_dtbo_be.img（大端 + 条目紧凑排列，按小米 17 的实际布局构造）
python tools/mkfixtures.py . /path/to/dtc

# 2) 各测试
sh tools/test_load.sh      . /path/to/dtc build/sb_load
sh tools/test_install.sh   . build/part_dtbo.img  /path/to/dtc build/sb_inst
sh tools/test_lifecycle.sh . build/part_dtbo.img  /path/to/dtc build/sb_life
sh tools/test_rollback.sh  . build/part_dtbo.img  /path/to/dtc build/sb_rb
sh tools/test_edge.sh      . build/part_dtbo.img  /path/to/dtc build/sb_edge
sh tools/test_module.sh    . build/part_dtbo.img  /path/to/dtc build/sandbox

# 2b) 「只在安装时改」这条约定
sh tools/test_manual.sh    . build/part_dtbo.img  /path/to/dtc build/sb_manual
                           # 原厂分区 + 无状态时开机脚本不许动手；
                           # 手动 action.sh 才刷；刷完开机仍不许动

# 2c) 档位与音量键
sh tools/test_key.sh     . build/sb_key          # 事件行解析 + tier_pick 各分支
sh tools/test_tier.sh    . build/part_dtbo.img /path/to/dtc build/tier
                         # 两个档位真的写进 dtbo：ffc_temp_high = <0x30> / <0x38>

# 2d) WebUI 采集脚本自测（造一棵假 sysfs，检查每个输出字段）
sh tools/test_monitor.sh   . build/sb_mon

# 3) 重新生成改写规则（换了参考 dts 才需要）
python tools/gen_ref.py  <参考.dts> ref
python tools/gen_sed.py  ref/patch.list ref

# 4) 打包（内置编码检查，有 CRLF / BOM 会直接拒绝）
python tools/package.py  . dist/dtbo_charge_unlock-v1.7.0.zip
```

WebUI 的页面逻辑也可以在 PC 上验证，不需要设备。做法是造一个假的 `ksu`
桥接，把 `monitor.sh` 的真实输出喂进去，再用无头 Chromium 跑一遍并断言：

```sh
# 5) 先采一份 monitor.sh 的输出当数据源
#    带 --full 才会顺便算出「当前分区是否仍是刷入的那份」
mkdir -p build/sb_mon/mod/state
SYSFS_ROOT=build/sb_mon/sys MODDIR=build/sb_mon/mod sh monitor.sh --full \
  > build/monitor_sample.txt

# 6) 渲染 + 断言（需要一个 Chromium 内核浏览器的路径）
python tools/mkwebui_harness.py . build/webui build/monitor_sample.txt
<浏览器> --headless=new --virtual-time-budget=24000 \
         --dump-dom "file:///<绝对路径>/build/webui/index.html" > build/dom.html

# 7) 状态分支：充电中 / 放电 / 已充满 / 过热越界 / 低于下限 / 已停用 / 无电池节点
python tools/webui_scenarios.py . build/wsc "<浏览器路径>" build/monitor_sample.txt
```

页面里的断言会检查：有没有 JS 异常、各字段是否真的填上了数值、
电量环是否绘制、两条曲线是否有像素、温度标记是否越界变红、
以及有没有横向溢出。这样 UI 改动不必靠肉眼确认。

| 测试 | 覆盖内容 |
| --- | --- |
| `test_load.sh` | `common.sh` 能被正常 source，所有函数都定义齐全 |
| `test_install.sh` | 模拟安装器跑 `customize.sh`：安装阶段即完成刷写、备份、状态落盘 |
| `test_lifecycle.sh` | 安装 → 重启确认 → 再次开机清理状态；每一步都比对分区 sha256，确认**开机没有改动分区**；最后模拟 OTA 换回原厂，确认开机**不会**自动重新应用 |
| `test_manual.sh` | 「只手动触发」约定：原厂分区 + 无状态时开机脚本不许动手；手动 `action.sh` 才刷；刷完开机仍不许动；重复运行跳过；`last_head` 与分区开头一致 |
| `test_rollback.sh` | 连续 3 次开机未确认 → 自动回滚 → 写 `halted` → 后续跳过 |
| `test_edge.sh` | 令牌匹配/不匹配、同一次开机内刷写不计数、校验器正反两向、`FORCE_SLOT` |
| `test_module.sh` | DTBO 表（3 条目 / 单条目 / 混合板型 / **大端+紧凑布局**）、裸 DTB 单段与双段、已刷过跳过、只换档位会重刷、演练模式、A/B 与单分区槽位 |
| `test_monitor.sh` | WebUI 采集脚本：电池/电源/温度区字段、模块状态四态、无电池节点时降级、`--full` 时的分区头部比对 |
| `test_key.sh` | 音量键解析（按下/抬起/无关事件/多行）与 `tier_pick` 各分支：音量下→48、音量上→56、不按、`FORCE_TIER` 合法/乱填、`TIER_PROMPT=0` |
| `test_tier.sh` | 逐个档位跑完整安装，再把刷好的分区拆出来反编译，确认 `ffc_temp_high = <0x30>/<0x38>` 与 JEITA 高温边界真的是 48/56，**并确认另一个档位的取值没有残留**（防止只改了一半） |

辅助脚本：

| 脚本 | 用途 |
| --- | --- |
| `tools/inspect_dtbo.py` | 打印 dtbo 镜像的表头与条目（两种字节序都试），定位结构问题 |
| `tools/verify_real.py` | 独立校验产物：字节序/id/rev/custom/重叠/尾部零填充 + 关键充电参数 |
| `tools/check_bytes.py` | `FFC_TEMP_HIGH=55` 时逐字节核对产物与参考 dtb |
| `tools/mkwebui_harness.py` | 生成 WebUI 离线自测页（注入假 `ksu` 桥接） |
| `tools/webui_scenarios.py` | WebUI 各状态分支的无头浏览器自测 |

> **行尾必须是 LF。** `package.py` 打包前会检查每个文本文件，发现
> `CR`（CRLF 行尾）、UTF-8 BOM、NUL 或非法 UTF-8 就直接拒绝打包。
> 这几类问题在设备上表现为 `sh: line N: : not found` 或
> `syntax error: unexpected word (expecting "in")`，从安装日志很难看出原因。
> 修改脚本时请用能保持 LF 的编辑器，不要用 PowerShell 的 `>`、
> `WriteAllLines` 之类会写 CRLF 的方式。

`FFC_TEMP_HIGH=55` 时产物与参考 `dtb` **逐字节一致**（`tools/check_bytes.py`
可以核对 DTBO 表的条目 id/rev/custom、page_size 与分区尾部零填充）。

`tools/` 下的 `fdtinfo.py`、`fdtcmp.py` 可用于语义级比对两个 dtb；
`patch_dts.awk`、`check_dts.awk` 是早期用 awk 实现的等价逻辑，仅作参考，
运行时不使用。

## 九、第三方组件与免责声明

| 组件 | 位置 | 授权 |
| --- | --- | --- |
| `dtc`（Device Tree Compiler）1.8.1 | `bin/dtc-aarch64`（静态链接 aarch64） | GPL-2.0-or-later，源码见 <https://git.kernel.org/pub/scm/utils/dtc/dtc.git> |

`tools/dl/`、`tools/dtcwin/`、`tools/build/` 是开发期用的本地工具链（Zig、Windows 版 dtc、
busybox 等），体积数百 MB，**不在本仓库内**，已由 `.gitignore` 排除。
需要跑 PC 端自测时按需自行获取，测试脚本都接受一个外部 `dtc` 路径。

本模块通过修改设备 `dtbo` 分区里的有线充电温度限制表来延长全速充电区间。
修改后的 `dtbo` 未经原厂签名，**会改变分区的哈希**。

本项目**仅以小米 17（cancún / SM8850）一台设备为目标并只在该机型上测试过**，
不构成对其他任何机型的可用性承诺。把它用在未测试的机型上属于自行实验，
可能出现充电异常、发热异常或无法开机。

使用前请确认自己了解风险并已备份；由此造成的一切后果由使用者自行承担。

