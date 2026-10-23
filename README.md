# DTBO 有线充电限制解锁（KernelSU 模块）

**在安装过程中**就直接完成「提取 → 解包 → 改写 → 打包 → 校验 → 刷入」，
装完重启即生效，不需要等开机再跑。

它对**当前系统所在槽位**的 `dtbo` 分区做三件事：

* 把有线充电的 JEITA / 温度分段表改成目标值，使 **0~56 ℃ 区间全程全速充电**；
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

* **执行时机**：`customize.sh`（安装阶段）里调用同一套 `run_main`，
  安装界面会实时打印每一步。`post-fs-data.sh` 只在需要时补跑：
  上一次刷写的开机确认/回滚，以及系统 OTA 把 `dtbo` 换回原厂后重新应用。
* **镜像格式**：自动识别两种，都能处理——
  * **DTBO 表**（`0xd7b7ab1e` 魔数）：解析 `dt_table_header` 与 `dt_table_entry`，
    逐个条目改写，再按原镜像的布局风格重新排布。
    * **字节序**两种都认：官方 `mkdtimg` 是小端（文件头字节 `1e ab b7 d7`），
      也有厂商用大端（文件头字节 `d7 b7 ab 1e`，例如 SM8850 这批机型）。
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

1. 用 KernelSU（或 Magisk）安装 `dtbo_charge_unlock-v1.2.0.zip`。
   **安装过程中就会刷写**，安装界面能看到完整过程与结果。
2. 安装完成 → 重启手机 → 新 `dtbo` 生效。

想先只看看不写分区，把 `config.conf` 里的 `DRY_RUN` 改成 `1` 再安装，
安装界面会走到「复核通过」但跳过写入，产物在 `/dev/dtbo_charge_unlock/new.img`。

装好之后随时可以手动重跑（会打印全过程）：

```sh
su -c "sh /data/adb/modules/dtbo_charge_unlock/action.sh"
```

之后模块不会每次开机都重刷：它按镜像 sha256 判断，只有检测到 `dtbo`
被换过（例如 OTA）才会重新应用。

## 三、安全机制

| 机制 | 说明 |
| --- | --- |
| 备份 | 刷写前把整个分区备份到 `backup/dtbo_a_YYYYmmdd-HHMMSS.img`，并校验备份完整 |
| 刷前复核 | 新镜像必须能反编译回来，且 174 项参数逐条匹配，否则中止 |
| 刷后回读 | 写入后回读分区比对 sha256，不一致立刻回滚 |
| 开机确认 | 每次刷写生成一个一次性令牌；下次开机走到 `service.sh`（开机后期）即记为确认 |
| 自动回滚 | 刷写后连续 3 次开机都没走到开机后期，判定新 dtbo 有问题，自动写回备份并停用模块 |
| 安装失败不阻断 | 安装阶段刷写失败（例如分区只读）时模块照常装好，下次开机再试；想直接中止可设 `ABORT_ON_INSTALL_FAIL=1` |

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
| `FFC_TEMP_HIGH` | `56` | 全速充电温度上限（℃）。设成 `55` 就是完全照抄参考表；留空表示不调整 |
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
├── post-fs-data.sh       开机早期：确认/回滚、OTA 后重新应用
├── service.sh            开机后期：确认「新 dtbo 能正常开机」
├── action.sh             KernelSU「操作」按钮 / 手动执行
├── restore.sh            手工回滚
├── dump.sh               只读导出：拆出每个 DTB 存成 .dtb/.dts，并生成参数汇总
├── uninstall.sh          卸载时把备份留存到 /sdcard/Download（不改分区）
├── bin/dtc-aarch64       静态链接的 aarch64 dtc 1.8.1
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

* 需要 root（KernelSU / Magisk）。能否写分区由 `dd` 的返回值和回读校验决定，
  模块本身不做 bootloader 状态判断。
* 改写是「按属性名精确替换」，如果某个目标属性在原厂 `dtbo` 里不存在，
  校验会报 `MISMATCH`/`MISSING` 并中止——这是有意的保守行为。
* `mca_charger_thermal` 被禁用后，整机高温时不再降功率，
  请自行注意散热，尤其是边充边玩、车内暴晒等场景。
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
#         part_dtbo_be.img（大端 + 条目紧凑排列，复现实际遇到的机型）
python tools/mkfixtures.py . /path/to/dtc

# 2) 各测试
sh tools/test_load.sh      . /path/to/dtc build/sb_load
sh tools/test_install.sh   . build/part_dtbo.img  /path/to/dtc build/sb_inst
sh tools/test_lifecycle.sh . build/part_dtbo.img  /path/to/dtc build/sb_life
sh tools/test_rollback.sh  . build/part_dtbo.img  /path/to/dtc build/sb_rb
sh tools/test_edge.sh      . build/part_dtbo.img  /path/to/dtc build/sb_edge
sh tools/test_module.sh    . build/part_dtbo.img  /path/to/dtc build/sandbox

# 3) 重新生成改写规则（换了参考 dts 才需要）
python tools/gen_ref.py  <参考.dts> ref
python tools/gen_sed.py  ref/patch.list ref

# 4) 打包（内置编码检查，有 CRLF / BOM 会直接拒绝）
python tools/package.py  . dist/dtbo_charge_unlock-v1.4.0.zip
```

| 测试 | 覆盖内容 |
| --- | --- |
| `test_load.sh` | `common.sh` 能被正常 source，所有函数都定义齐全 |
| `test_install.sh` | 模拟安装器跑 `customize.sh`：安装阶段即完成刷写、备份、状态落盘 |
| `test_lifecycle.sh` | 安装 → 重启确认 → 再次开机清理状态 → 第三次识别为已刷过 |
| `test_rollback.sh` | 连续 3 次开机未确认 → 自动回滚 → 写 `halted` → 后续跳过 |
| `test_edge.sh` | 令牌匹配/不匹配、同一次开机内刷写不计数、校验器正反两向、`FORCE_SLOT` |
| `test_module.sh` | DTBO 表（3 条目 / 单条目 / 混合板型 / **大端+紧凑布局**）、裸 DTB 单段与双段、已刷过跳过、演练模式、A/B 与单分区槽位 |

辅助脚本：

| 脚本 | 用途 |
| --- | --- |
| `tools/inspect_dtbo.py` | 打印 dtbo 镜像的表头与条目（两种字节序都试），定位结构问题 |
| `tools/verify_real.py` | 独立校验产物：字节序/id/rev/custom/重叠/尾部零填充 + 关键充电参数 |
| `tools/check_bytes.py` | `FFC_TEMP_HIGH=55` 时逐字节核对产物与参考 dtb |

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
修改后的 `dtbo` 未经原厂签名，**会改变分区的哈希**。使用前请确认自己了解风险并已备份；
由此造成的一切后果由使用者自行承担。

