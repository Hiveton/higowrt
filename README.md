# HiGoWRT

HiGoWRT 是基于 [OpenWrt](https://openwrt.org) 25.12.4（Linux 内核 6.12）的路由器固件，
集成了 **MediaTek MT7987 / MT7992 Wi-Fi 7 proprietary 驱动栈**（MTK 闭源 SDK 驱动）。

在标准 OpenWrt 之上，HiGoWRT 完成了 MTK Filogic 平台专有 Wi-Fi 7 驱动从内核 6.6 到 6.12 的完整移植，
保留 OpenWrt 的全部能力（LuCI、netifd、UCI、软件包生态），WiFi 走 cfg80211/nl80211 标准栈管理。

---

## 支持设备

| 设备 | SoC | Wi-Fi | 说明 |
|---|---|---|---|
| Hiveton H5000M | MT7987A | MT7992 (BE3600) | eMMC 启动 |
| TP-Link TL-7DR7230 | MT7988A | MT7992 (BE7200) | NAND/UBI |

驱动层已支持的芯片 / SKU：

| 芯片 | SKU |
|---|---|
| MT7990 | BE3600 |
| MT7991 | BE5040 |
| MT7992 | BE6500 / BE7200 |
| MT7995 | BE13500 |
| MT7996 | BE19000 |

---

## 一、安装编译依赖

### Ubuntu 22.04 / 24.04（推荐）
```bash
sudo apt update
sudo apt install -y build-essential clang flex bison g++ gawk \
  gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
  python3-distutils python3-setuptools rsync unzip zlib1g-dev \
  file wget qemu-utils ccache libelf-dev
```

### Debian 12
```bash
sudo apt update
sudo apt install -y build-essential clang flex bison g++ gawk \
  gcc-multilib gettext git libncurses-dev libssl-dev python3 \
  rsync unzip zlib1g-dev file wget libelf-dev
```

> 不要用 root 用户编译。建议普通用户。
> 内存建议 ≥ 8G（链接 mt_wifi.ko 45MB 较吃内存）；不足时用 `make -j2`。

---

## 二、获取源码

```bash
git clone https://github.com/Hiveton/higowrt.git
cd higowrt
```

---

## 三、放置 vendor 驱动 SDK 包

MTK Wi-Fi 7 proprietary 驱动源码以闭源 SDK tarball 形式提供（**不随仓库分发**），
请将 SDK 包放入 `dl/` 目录：

```bash
mkdir -p dl
cp /path/to/mt7993_20250919-39602c.tar.xz dl/   # 主驱动 (mt_wifi7 / mt_hwifi)
cp /path/to/warp_20250919-9c1cfa.tar.xz   dl/   # WED 硬件加速 (warp)
cp /path/to/mt_wifi_osal-a53418.tar.xz    dl/   # OSAL 抽象层 (mt_wifi_osal)
```

> 这 **3 个 tarball 都来自** MTK Wi-Fi7 SDK（`mtk-wifi-mt7987-mt7990-mt7992-mt7993-v8.3.1.3` 的 `dl/` 目录），
> 因体积与授权原因不放入 git 仓库。**三个缺一不可**——否则对应驱动包会报 `No such file` 编译失败。

---

## 四、更新 feeds

```bash
./scripts/feeds update -a
./scripts/feeds install -a
```

---

## 五、选择配置并编译

### 方式 A：使用预置 defconfig
```bash
# H5000M (MT7987 + MT7992 BE3600)
cp defconfig/mt7987_mt7992.config .config
# 或 TL-7DR7230 (MT7988 + MT7992 BE7200)
# cp defconfig/mt7988_mt7992.config .config

make defconfig
make -j$(nproc)        # 内存不足用 make -j2
```

### 方式 B：手动配置
```bash
make menuconfig
# Target System  -> MediaTek Ace (filogic)
# Target Profile -> 选择目标设备 (Hiveton H5000M / TP-Link TL-7DR7230)
make defconfig
make -j$(nproc)
```

编译产物在 `bin/targets/mediatek/filogic/`：
- `*-squashfs-sysupgrade.itb` — 正式刷写
- `*-initramfs*.itb` — 内存启动调试（首刷建议先用它验证）

---

## 六、刷机

1. 串口（115200 8N1）进 U-Boot，TFTP 加载 `initramfs.itb` 内存启动验证驱动；
2. 确认 WiFi/网口正常后，`sysupgrade -n` 刷 `sysupgrade.itb` 到 eMMC/NAND。

WiFi 配置走标准 OpenWrt UCI：编辑 `/etc/config/wireless` 后 `wifi up`。

---

## 注意事项

- **WARP 版本是编译期单值**：MT7987（WARP 3_1）与 MT7988（WARP 3）不能同一次 build，
  请分别用对应 defconfig 编译；切换芯片需 `make package/mtk/drivers/mt_wifi7/clean`。
- **SKU**：不同 SKU 对应不同固件 band 配置，由 `CONFIG_MTK_WIFI7_SKU_TYPE` 决定。
- **HNAT/WHNAT**：已集成硬件 NAT 加速（mtkhnat 模块 + WED-WO）。

---

## 项目结构（HiGoWRT 相对标准 OpenWrt 的增量）

```
target/linux/mediatek/
  patches-6.12/999-9100-*, 999-9101-*   # HNAT 统计/SER 等内核扩展
  files-6.12/drivers/net/ethernet/mediatek/mtk_hnat/   # vendor HNAT 源
  dts/mt7987a-hiveton-h5000m.dts                       # H5000M 板级
  dts/mt7988d-tplink-tl-7dr7230-rev1.0-sp2.dts         # TL-7DR7230 板级
  image/filogic.mk                                     # 设备定义
package/mtk/drivers/
  mt_wifi7/  mt_hwifi/  mt_wifi_osal/  warp/  wifi-profile/   # proprietary 驱动包 + 6.12 适配 patches
defconfig/                                             # 各设备/SKU 预置配置
```

---

## 致谢与许可

- 基于 [OpenWrt](https://github.com/openwrt/openwrt) 25.12.4（GPL-2.0）。
- MediaTek Wi-Fi 7 驱动为 MTK 闭源 SDK，版权归 MediaTek 所有。
- 移植过程与问题记录见 [`MIGRATION_ISSUES.md`](MIGRATION_ISSUES.md)。
