# ImmortalWrt-6.6 → OpenWrt 25.12 (内核 6.12) MT7987/MT7992 移植问题全记录

> 从 0 迁移过程中遇到的所有问题、根因与解决方案。
> 目标：把 immortalwrt-hiveton-mt-6.6 的 MTK proprietary Wi-Fi 7 驱动栈移植到 OpenWrt 25.12.4（内核 6.12.87）。
> 编译服务器：10.211.55.3（x86_64 VM），代码在 `~/openwrt-25.12`。

---

## 目录
1. [环境与构建问题](#1-环境与构建问题)
2. [内核 6.6→6.12 移植问题](#2-内核-6612-移植问题)
3. [HNAT 硬件加速集成问题](#3-hnat-硬件加速集成问题)
4. [proprietary WiFi 驱动栈问题](#4-proprietary-wifi-驱动栈问题)
5. [6 个 SKU 适配问题](#5-6-个-sku-适配问题)
6. [设备 DTS 问题](#6-设备-dts-问题)
7. [镜像组装问题](#7-镜像组装问题)
8. [持久化与可重现问题](#8-持久化与可重现问题)
9. [经验总结](#9-经验总结)

---

## 1. 环境与构建问题

| 问题 | 现象 | 根因 | 解决 |
|---|---|---|---|
| SSH 自动化失败 | sshpass "Failed to get a pseudo terminal" | macOS 本环境 sshpass 的 pty 分配失效 | 改用 `SSH_ASKPASS` 机制：`/tmp/rmt.sh` 包装 `SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force ssh ... </dev/null` |
| 服务器时钟偏差 | make 报时间戳错乱、文件 mtime in future | VM 时钟落后约 14 小时 | `sudo date`/`timedatectl` 校时（用户仅授权时钟用 sudo） |
| 磁盘空间不足 | 编译中途 no space | 默认盘太小 | 用户扩 VM 盘 + 加 80G 新盘，格式化自动挂载，构建目录迁到新盘 |
| 工具链 OOM | 链接阶段 OOM killed | `-j4` 在 5.8G RAM 不够 | 先 `-j2`，后用户加 RAM 到 7.7G |
| rsync 丢源码 | 编译报缺文件（如 tools/.../src/bin/） | `--exclude='bin/'` 未锚定，误删所有 bin 目录 | 改用锚定 exclude（`/bin/`） |
| mtime 时钟偏斜 | quilt/make 重复重做 | 文件 mtime 比系统时间新 | 非 sudo `touch` 重新打时间戳 |

---

## 2. 内核 6.6→6.12 移植问题

### 2.1 补丁 rebase
- **MTK vendor 补丁集（677 个）rebase 到 6.12**：triage 后 56 个直接 OK / 48 个 FAIL，逐个分流。
- `999-2903-mtk-enhance.patch`：fuzz 错位把 hnat_desc 结构误插进 `nft_counter.c` → **删除**。
- `999-3019-adaptive-PPPQ.patch`：孤儿补丁（依赖已 DROP 的 qdma_shaper）→ **删除**。
- `999-3003`(internal QoS) + `999-3010`(dispatch short pkt)：引入 qos_toggle + 内置 mtk_eth_soc 调 conntrack 模块符号 `__nf_ct_ext_find` 链接失败 → **删除**（HNAT 基础 offload 不依赖 vendor internal-QoS）。

### 2.2 6.12 内核 API 变化（逐个适配）
| API 变化 | 表现 | 修法 |
|---|---|---|
| vmalloc 头迁移 | `implicit declaration of vmalloc/vfree` | 加 `#include <linux/vmalloc.h>` |
| strlcpy 移除 | `implicit declaration of strlcpy` | `strlcpy` → `strscpy`（批量） |
| platform_driver.remove | `assignment from incompatible pointer type (int vs void)` | remove 函数 `int`→`void`，删 `return 值` |
| DSA 重命名 | `struct dsa_port has no member 'master'` | `master` → `conduit`（6.12 DSA master/slave→conduit/user） |
| asm/unaligned | 头找不到 | `asm/unaligned.h` → `linux/unaligned.h` |
| PCI 中断常量 | `PCI_IRQ_LEGACY undeclared` | `PCI_IRQ_LEGACY` → `PCI_IRQ_INTX` |
| init_dummy_netdev | 返回值变化 | 改为返回 void 调用 |
| nf_conn_counter | `no member diff_packets/diff_bytes` | vendor 扩展成员，加回内核 struct（见 §3） |
| flow_offload_hw_path | `no member skb_hash` | vendor 扩展成员，加回内核 struct（见 §3） |
| station_info | `no member aid` | 6.12 移除 aid，删赋值（degraded dump aid） |

### 2.3 配置阻塞
- 新 Kconfig 选项阻塞 syncconfig：`NF_FLOW_TABLE_NETLINK`、`MEDIATEK_NETSYS_V2/V3` → 加到 `generic/config-6.12`。
- `# CONFIG_KERNEL_WERROR is not set`（顶层 .config）—— 关全局 -Werror。
- **重要区分**：kernel config 在 `target/linux/{generic,mediatek,mediatek/filogic}/config-6.12`，**不在顶层 .config**（顶层只有 target/包选择）。一开始加错文件导致 HNAT/NETSYS 没生效。

---

## 3. HNAT 硬件加速集成问题

| 问题 | 根因 | 解决 |
|---|---|---|
| HNAT 怎么集成 | OpenWrt 25.12 mediatek **自带官方 mtkhnat patch**（`999-2742/2743/2744/2745`） | 复用官方 patch + carry vendor mtk_hnat 源（提供符号） |
| 999-2745 应用失败 | 我在 files-6.12 误建/留下 `mediatek/Makefile` 空壳，覆盖 upstream → patch 的 Makefile hunk FAILED | **删除 files-6.12 的 mediatek/Makefile**，让 upstream + patch 管理 |
| HNAT 启用不了 | `NET_MEDIATEK_HNAT` depends `IP_NF_NAT`（iptables 专用），但 25.12 用 nftables | 改 999-2745 的 Kconfig depends `IP_NF_NAT`→`NF_NAT`（通用，已 =m） |
| HNAT=y 冲突 | built-in 不能依赖模块（NF_CONNTRACK=m） | `CONFIG_NET_MEDIATEK_HNAT=m`（模块） |
| mtk_hnat -Werror | vendor `ccflags-y=-Werror` + 6.12 严格警告 | 去掉 -Werror |
| hnat_nf_hook.c 编译错 | 用 `nf_conn_counter.diff_packets/diff_bytes` + `flow_offload_hw_path.skb_hash`（vendor 内核 struct 扩展，6.12 upstream 无） | **先 degraded（注释），后完整恢复**：在 `nf_conntrack_acct.h`/`nf_flow_table.h` struct **末尾**加回成员（不改现有偏移=低风险），patch 落 `999-9100-hnat-accounting-members.patch` |
| hnat_stag.c | `dp->cpu_dp->master` | → `conduit` |
| 符号缺失（wifi7 链接） | mt_wifi.ko 引用 7 个 hook 符号（`ra_sw_nat_hook_tx/rx`、`ppe_dev_register_hook` 等），内核没编 mtk_hnat | 启用 mtk_hnat 模块（提供 6 个 hook 指针）；`ppd_dev` + `mtk_check_wifi_busy` 在 hnat.c 补定义 |
| SER 完整化（mtk_set_pse_drop） | 真实函数操作 PSE 寄存器，依赖 vendor 全局 `g_eth`（upstream 无） | `999-9101`：mtk_eth_soc.c 加 `g_eth` 全局 + EXPORT + probe 设置 + EXPORT `mtk_w32`；hnat.c 真实实现 mtk_set_pse_drop |

---

## 4. proprietary WiFi 驱动栈问题

> 5 个包：mt_wifi_osal / mt_wifi7（主驱动 mt_wifi.ko 45MB）/ mt_hwifi / warp / mtkhnat。

### 4.1 关键路线决策：cfg80211 vs osal
- 驱动有两条 cfg80211 路径：vendor osal-cfg80211 vs wifi7 自带 full-ops。
- **最终用 SDK 权威 `mt7992.config`**（启用 `CONFIG_MTK_WIFI7_CFG80211_SUPPORT`）走 wifi7 cfg80211 full-ops——feature 组合自洽（RT_CFG80211/A4_CONN/EHT_BE 定义齐全）。
- 之前手做的 osal 路径 degraded patches（103/104/106）反而冲突，已删。

### 4.2 mac80211 版本鸿沟
- SDK vendor mac80211 patches = 1432 个（5.4 era），25.12 = 6.12 era（backports 6.18.26）。无法整套 carry。
- cfg80211 backports 的 MLO 系统性加 `link_id` 参数（如 `cfg80211_rx_unexpected_4addr_frame` 加 link_id）→ vendor 调用逐个补参数。

### 4.3 mt_wifi_osal
- 100-add-vmalloc-include / 101-disable-rps-map(degraded, rps_map struct 6.12 私有化) / 102-no-werror / 103-net-6.12-api(strlcpy→strscpy, init_dummy_netdev) / 104-cfg80211-6.12-ops(set_wiphy_params/set_antenna/get_antenna/get_tx_power 加 radio_idx/link_id)

### 4.4 mt_wifi7（主驱动，290 个 .o）
- 100-6.12-header-compat / 101-no-werror / 102-macro-compat(AC_NUM) / 105-strlcpy-strscpy(批量) / 110-cfg80211-link-id / 111-vlan-stub(register_vlan_dev/unregister_vlan_dev/vlan_setup 内核内部 API 6.12 未导出→stub, degraded AP-VLAN) / 112-station-info-aid
- SPECTRUM 关（依赖未 carry 的 mt_spectrum 包）；ICAP/PHY_ICS 保留（internal，不依赖外部包）。
- **WHNAT**（WiFi 硬件 NAT）：先 degraded 关（符号缺），后启用——补 `mtk_set_pse_drop` 符号。

### 4.5 warp（WED 加速）
- 100-no-werror / 101-platform-remove-void / 102-vmalloc-include
- **CONFIG_WARP_VERSION 空**：config.in `default 3_1 if TARGET_mediatek_mt7987` 不匹配本移植的 filogic target → 加 `default 3_1 if TARGET_mediatek_filogic`（mt7987）/ version 3（mt7988）。
- **WED-WO 子系统**：mt7988 需 `CONFIG_WED_HW_RRO_SUPPORT=y` 才编 mcu WO（warp_msg/woif/wo/woctrl），否则 modpost 缺 10 个 WO 符号。

### 4.6 共享 build_dir 坑
- hwifi 的 `WIFI_DRIVER_NAME:=mt_wifi7`，与 wifi7 **共享 PKG_BUILD_DIR=mt_wifi7**。
- 只有 wifi7 prepare 这个目录，hwifi 的 patches **不会被应用** → hwifi 的改（PCI_IRQ_INTX、MULTI_FW_HEADER）必须并入 wifi7 的 patches（120/121-*）。

---

## 5. 6 个 SKU 适配问题

> 芯片↔SKU（用户提供，driver 用代号命名有别）：MT7990→BE3600 / MT7991→BE5040 / MT7992→BE6500、BE7200 / MT7995→BE13500 / MT7996→BE19000。
> driver 代号：`CHIP_MT7992`(Kite 家族)=BE3600SDB/BE5040/BE6500/BE7200；`CHIP_MT7990`(Eagle 家族)=BE13000_255/BE19000。

| 问题 | 根因 | 解决 |
|---|---|---|
| MULTI_FW_HEADER 误用 | 我为 BE3600SDB 无条件加 `-DCONFIG_HWIFI_MULTI_FW_HEADER`，导致 BE5040/BE7200（该走单 FW 路径）误用 band 数组路径 → `FirmwareImage_1_1_len undeclared` | **条件化**：hwifi 包 Makefile `ifeq SKU=BE3600SDB → C_FLAG MULTI_FW=y`；121 patch 改为 `ifeq ($(CONFIG_HWIFI_MULTI_FW_HEADER),y)` 条件 |
| BE7200 FW 缺 | tarball v8.3.1.3 的 MT7992 1_1 band 只有 sdb 变体（BE3600 用的 band 数组），**无 1_1 单 FW** | BE7200 改用 3_1 band（= BE6500，同芯片 MT7992 FW 兼容）。若需 BE7200 专用 1_1 FW 须 MTK 提供 |
| same-file cp 破坏源 | `cp -rf X X`（源=目标）会先截断目标=源 → **删除源文件**（破坏 mcu_hdr）；之后 driver include 该文件 No such file | SKU 段 cp 的源 band 必须 ≠ 目标 1_1（如 3_1→1_1）；同名 cp 删除 |
| FW header 命名 | 各 SKU 从不同 band 编号 cp 生成目标 `1_1_hdr.h`；`1_1_hdr_.h`（带多余 `_`）是误改 | 对齐 tarball 实际文件名（无多余 `_`） |
| SKU 不能同 build | `CONFIG_WARP_VERSION`/`CHIP` 是编译期单值，mt7987(3_1)/mt7988(3) 不能共存 | 每个 SKU/芯片独立 .config；切 CHIP 需 `make wifi7 clean` |

**6 SKU 状态**：BE3600✅ / BE5040✅ / BE6500✅ / BE7200✅(3_1) / BE13500✅ / BE19000✅。

---

## 6. 设备 DTS 问题

### 6.1 h5000m（MT7987A，README 指定）
- 基于 mt7987a-rfb 新建 + Hiveton 定制（model/compatible、WiFi GPIO LED、PWM 风扇、gpio-keys）。
- 用 `DEVICE_DTS_OVERLAY` 复用 rfb-emmc + rfb-eth1-i2p5g。
- 删除 pwm_fan_pins 引用（25.12 无）。
- SKU = BE3600SDB（tarball 的 MT7992 1_1 只有 sdb）。

### 6.2 TL-7DR7230（MT7988A，扩展）
从 immortalwrt-6.6 carry dts，6.12 适配：
| 问题 | 修法 |
|---|---|
| `Label or path uart0 not found` | `&uart0` → `&serial0`（25.12 mt7988a.dtsi 用 serial0/1/2） |
| `THERMAL_NO_LIMIT undeclared`（syntax error） | 加 `#include <dt-bindings/thermal/thermal.h>`（25.12 dtsi 不再间接带入） |
| `i2c0_pins`/`spi0_flash_pins`/`gbe0_led0_pins`/`gbe1_led0_pins`/`mdio0_pins`/`i2p5gbe_led0_pins` non-existent | 25.12 mt7988a.dtsi 把这些 pinctrl 引用放进 SoC dtsi、要求设备 dts 定义 → 从 mt7988a-rfb.dts carry 这些 pinctrl 定义到 &pio |
| device packages | 去 mt76 的 `kmod-mt7992-firmware`，用 proprietary；PHY 用 airoha-en8811h（2.5G） |

### 6.3 BPI-R4（MT7988A + MT7990，扩展）
- 25.12 已有 device（但配 MT7996 mt76），dts 依赖（mt7988a.dtsi + rt5190a binding）齐全。
- MT7990(Eagle) driver path 复用 MT7992 的 common 6.12 适配，无新 chip-specific 错误。

---

## 7. 镜像组装问题

| 问题 | 根因 | 解决 |
|---|---|---|
| `PKG_VERSION:=TEST` | vendor 占位版本，OpenWrt 24/opkg 接受，但 **25 的 apk mkpkg 报 "version invalid"** | 所有 package/mtk/drivers/*/Makefile 改 `PKG_VERSION:=1` |
| 包文件冲突①（PHY firmware） | `mt798x-2p5g-phy-firmware-internal` 与 `mt7987-2p5g-phy-firmware` 抢同一 i2p5ge-phy*.bin | 禁用 internal（用正式） |
| 包文件冲突②（/sbin/wifi） | vendor `wifi-profile`(wifi_jedi) 与 OpenWrt `wifi-scripts` 抢 /sbin/wifi | 禁用 wifi-profile |
| WiFi 怎么管理 | driver 走 cfg80211 路径（CONFIG_MTK_WIFI7_CFG80211_SUPPORT） | **用 OpenWrt 标准栈 wifi-scripts + wpad + netifd（nl80211）**，UCI `/etc/config/wireless` 配置；不需 vendor wifi-profile（那是 iwpriv/dat 路径） |
| kmod-mt_wifi7 依赖元数据 | mt_wifi.ko 引用 mtkhnat.ko 符号，但 DEPENDS 没声明 | DEPENDS 无条件加 `+kmod-mediatek_hnat`（FAST_NAT 路径总引用） |

---

## 8. 持久化与可重现问题

- **build_dir 改易丢**：改 files/源会触发 re-prepare（重解压 + 重应用 patches），build_dir 的裸改丢失 → 一切适配必须落 **package patches / files-6.12 / patches-6.12**。
- **内核 header 改** → `patches-6.12/`（quilt patch）。
- **生成 patch 的坑**：sed 加全局时勿用末尾 `\n`（多余空行致 patch context 不匹配 Hunk FAILED）；patch 要基于干净 prepare 的基线 diff。
- **可重现验证**：强制删 `.prepared` 重 prepare + 重应用全部 patches，make EXIT=0 = 完全可重现（clean build 也能出）。

---

## 9. 经验总结

1. **kernel config 不在顶层 .config**——在 `target/linux/*/config-6.12`，这是新手最易踩的坑。
2. **OpenWrt 25.12 已自带 mtkhnat**（999-274x），不要重复造，复用 + 补 vendor 源即可。
3. **6.12 API 变化是机械但量大**：strlcpy/platform.remove/DSA master/PCI_IRQ/vmalloc 头——同一类在不同包反复出现，可批量处理。
4. **cfg80211 路径选择决定成败**：用 SDK 权威 config（wifi7 full-ops），而非手拼 osal 路径。
5. **共享 PKG_BUILD_DIR 的包**（hwifi↔wifi7），patches 要放主包（wifi7）目录。
6. **SKU/CHIP 是编译期单值**，每个独立 .config 单独 build；切芯片必须 clean。
7. **same-file cp 会删源文件**——FW header cp 的源 band 必须 ≠ 目标。
8. **degraded 是有效的中间策略**：先 stub/注释让链路打通拿里程碑，再逐个恢复为完整实现（HNAT 统计、SER、WHNAT 都这样从 degraded 升到完整）。
9. **物理边界**：编译服务器是 x86 VM，无法刷写/运行 ARM64 固件——刷机与硬件 WiFi 验证必须在真实设备做。

---

## 附：交付物
- 固件：`_firmware_output/`（h5000m + TL-7DR7230 各 sysupgrade + initramfs，34MB）+ 刷机/验证脚本
- 完整修复清单：`_server_backup/kernel_6.12_fixes_manifest.md`
- 各设备/SKU 配置：`_server_backup/configs/`
- 服务器构建树：`10.211.55.3:~/openwrt-25.12`（完整可重现）
