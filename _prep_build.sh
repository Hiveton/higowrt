#!/bin/bash
set -x
cd ~/openwrt-25.12
cp -f feeds.conf.default feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
cat > .config <<CFG
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_mediatek_mt7987a-rfb=y
CFG
make defconfig
echo "=== DEFCONFIG DONE, kernel ver: ==="
grep LINUX_VERSION include/kernel-* 2>/dev/null | head
make -j4 tools/install 2>&1
echo "=== TOOLS DONE rc=$? ==="
make -j4 toolchain/install 2>&1
echo "=== TOOLCHAIN DONE rc=$? ==="
df -h / | tail -1
