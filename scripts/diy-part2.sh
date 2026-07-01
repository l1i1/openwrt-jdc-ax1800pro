#!/bin/bash
# DIY Part 2: Execute before make

# Avoid literal glob when no files match (git bash on Windows)
shopt -s nullglob

echo "DIY Part 2: Custom settings"

# Modify default hostname
echo "Setting hostname to JDCloud..."
sed -i 's/ImmortalWrt/JDCloud/g' package/base-files/files/bin/config_generate

# Use the YuShu management subnet even when WAN is disconnected on first boot.
echo "Setting default LAN IP to 10.10.10.1..."
if grep -Fq "192.168.1.1" package/base-files/files/bin/config_generate; then
    sed -i 's/192\.168\.1\.1/10.10.10.1/g' package/base-files/files/bin/config_generate
    echo "  default LAN IP patched in config_generate"
else
    echo "  WARNING: default LAN IP pattern not found in config_generate"
fi

# Modify default timezone
echo "Setting timezone to Asia/Shanghai..."
sed -i "s|timezone='UTC'|timezone='CST-8'|g" package/base-files/files/bin/config_generate
sed -i "s|zonename='UTC'|zonename='Asia/Shanghai'|g" package/base-files/files/bin/config_generate
sed -i 's|/usr/bin/ntpdate|/usr/sbin/ntpdate|g' package/base-files/files/bin/config_generate 2>/dev/null || true

# Clear root password (ensure empty password)
echo "Clearing root password..."
sed -i 's/root:.*/root:::0:99999:7:::/g' package/base-files/files/etc/shadow

# Fix fail2ban build error (Cannot import setuptools.build_meta)
echo "Fixing fail2ban build dependencies..."
FAIL2BAN_MAKEFILE="feeds/packages/net/fail2ban/Makefile"
if [ -f "$FAIL2BAN_MAKEFILE" ]; then
    if grep -q "PKG_BUILD_DEPENDS" "$FAIL2BAN_MAKEFILE"; then
        sed -i 's/PKG_BUILD_DEPENDS:=/PKG_BUILD_DEPENDS:=python3\/host python-setuptools\/host python-wheel\/host /' "$FAIL2BAN_MAKEFILE"
    else
        sed -i '/include $(TOPDIR)\/rules.mk/a PKG_BUILD_DEPENDS:=python3\/host python-setuptools\/host python-wheel\/host' "$FAIL2BAN_MAKEFILE"
    fi
    echo "  fail2ban Makefile patched: $(grep PKG_BUILD_DEPENDS "$FAIL2BAN_MAKEFILE")"
else
    echo "  WARNING: fail2ban Makefile not found at $FAIL2BAN_MAKEFILE"
fi

# ============================================================
# Report source-tree acceleration support
# The current source tree exposes qca-nss-dp, but not the full qca-nss-drv stack.
# ============================================================
echo "Checking source-tree acceleration support..."
if [ -f "package/kernel/qca-nss-dp/Makefile" ]; then
    echo "  qca-nss-dp package detected in source tree"
else
    echo "  WARNING: qca-nss-dp package not found in source tree"
fi

# ============================================================
# MgrServer: ensure files overlay permissions
# ============================================================
echo "Setting MgrServer file permissions..."
OVERLAY_DIR="$PWD/files"
if [ -d "$OVERLAY_DIR" ]; then
    # Ensure all uci-defaults scripts are executable
    for f in "$OVERLAY_DIR/etc/uci-defaults/"*; do
        if [ -f "$f" ]; then
            chmod 0755 "$f"
            echo "  chmod 0755 $(basename "$f")"
        fi
    done

    # Ensure init.d scripts are executable
    for f in "$OVERLAY_DIR/etc/init.d/"*; do
        if [ -f "$f" ]; then
            chmod 0755 "$f"
            echo "  chmod 0755 $(basename "$f")"
        fi
    done

    # Ensure overlay helper scripts are executable even when staged from a
    # Windows checkout where file mode bits are not reliable.
    for f in "$OVERLAY_DIR/usr/bin/"*; do
        if [ -f "$f" ]; then
            chmod 0755 "$f"
            echo "  chmod 0755 usr/bin/$(basename "$f")"
        fi
    done

    # Report MgrServer bundle size if present
    if [ -d "$OVERLAY_DIR/root/mgrserver" ]; then
        MGR_SIZE=$(du -sh "$OVERLAY_DIR/root/mgrserver" | awk '{print $1}')
        echo "  MgrServer bundle size: $MGR_SIZE"
    else
        echo "  WARNING: MgrServer bundle not found at files/root/mgrserver"
    fi

    # Report PXE resources size if present
    if [ -d "$OVERLAY_DIR/usr/share/mgrserver-defaults/res/pxe" ]; then
        PXE_SIZE=$(du -sh "$OVERLAY_DIR/usr/share/mgrserver-defaults/res/pxe" | awk '{print $1}')
        echo "  PXE resources size: $PXE_SIZE"
    fi
fi

# ============================================================
# ath11k/mac80211 compatibility
# Patch the source tree so the final rootfs already avoids unsupported
# iw operations on JDCloud RE-SS-01, instead of pinning mac80211.sh in overlay.
# ============================================================
echo "Patching mac80211 wifi script for ath11k compatibility..."
MAC80211_SCRIPTS=()
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    MAC80211_SCRIPTS+=("$candidate")
done < <(find package/network/config/wifi-scripts -type f -name 'mac80211.sh' 2>/dev/null | sort)

if [ "${#MAC80211_SCRIPTS[@]}" -gt 0 ]; then
    for script_path in "${MAC80211_SCRIPTS[@]}"; do
        sed -i '/set distance/d' "$script_path"
        sed -i '/set frag/d' "$script_path"
        echo "  ✓ patched $script_path"
    done

    if grep -R -n -E 'iw phy .*set (distance|frag)|set distance|set frag' package/network/config/wifi-scripts >/dev/null 2>&1; then
        echo "  ✗ ERROR: ath11k compatibility patch did not fully apply inside package/network/config/wifi-scripts"
        grep -R -n -E 'iw phy .*set (distance|frag)|set distance|set frag' package/network/config/wifi-scripts || true
        exit 1
    fi
else
    echo "  ✗ ERROR: unable to locate mac80211 wifi script in source tree"
    exit 1
fi

# ============================================================
# Add factory.bin for JDCloud RE-SS-01 (eMMC device)
# Reference: https://github.com/VIKINGYFY/immortalwrt/blob/master/target/linux/qualcommax/image/ipq60xx.mk
# U-Boot supports both factory.bin and sysupgrade.bin formats
# ============================================================
echo "Adding factory.bin generation for JDCloud RE-SS-01..."
IPQ60XX_MK="target/linux/qualcommax/image/ipq60xx.mk"
if [ -f "$IPQ60XX_MK" ]; then
    # Check if factory.bin is already defined for jdcloud_re-ss-01
    if ! grep -A 15 "define Device/jdcloud_re-ss-01" "$IPQ60XX_MK" | grep -q "IMAGE/factory.bin"; then
        # Use awk to insert factory.bin definition before endef in jdcloud_re-ss-01 block
        # Must add: $(call Device/EmmcImage) and IMAGE/factory.bin definition
        # Note: Use \x24 to represent $ in awk to avoid shell expansion
        awk '
        /^define Device\/jdcloud_re-ss-01/ { in_block=1 }
        in_block && /^\tDEVICE_PACKAGES/ {
            print
            print "\t\x24(call Device/EmmcImage)"
            next
        }
        in_block && /^endef/ {
            print "\tIMAGE/factory.bin := append-kernel | pad-to \x24\x24(KERNEL_SIZE) | append-rootfs | append-metadata"
            in_block=0
        }
        { print }
        ' "$IPQ60XX_MK" > "$IPQ60XX_MK.tmp" && mv "$IPQ60XX_MK.tmp" "$IPQ60XX_MK"
        
        # Verify the patch was applied correctly
        if grep -A 15 "define Device/jdcloud_re-ss-01" "$IPQ60XX_MK" | grep -q "IMAGE/factory.bin"; then
            echo "  ✓ factory.bin generation added to jdcloud_re-ss-01"
            echo "  Verifying patch..."
            grep -A 15 "define Device/jdcloud_re-ss-01" "$IPQ60XX_MK"
        else
            echo "  ✗ ERROR: factory.bin patch failed!"
            echo "  Current definition:"
            grep -A 15 "define Device/jdcloud_re-ss-01" "$IPQ60XX_MK"
            exit 1
        fi
    else
        echo "  factory.bin already defined, skipping"
    fi
else
    echo "  WARNING: $IPQ60XX_MK not found"
fi

# ============================================================
# Node.js version selection
# Use Node.js 22.x - 官方 packages 中的可用版本
# ============================================================
echo "Configuring Node.js version..."

# 清理之前可能下载的 Node.js 源码（强制重新下载正确版本）
echo "  Cleaning old Node.js downloads..."
rm -rf dl/node-20.* 2>/dev/null || true
rm -rf dl/node-v20.* 2>/dev/null || true
rm -rf dl/node-24.* 2>/dev/null || true
rm -rf dl/node-v24.* 2>/dev/null || true
rm -rf build_dir/target-*/node-v20.* 2>/dev/null || true
rm -rf build_dir/target-*/node-v24.* 2>/dev/null || true

# 清理所有 Node.js 相关配置
echo "  Cleaning Node.js configuration..."
sed -i '/^CONFIG_NODEJS_/d' .config
sed -i '/^CONFIG_PACKAGE_node=y$/d' .config
sed -i '/^# CONFIG_PACKAGE_node is not set$/d' .config
sed -i '/^CONFIG_PACKAGE_node-npm=y$/d' .config
sed -i '/^# CONFIG_PACKAGE_node-npm is not set$/d' .config

# 强制使用 Node.js 22.x
echo "  Setting Node.js 22.x..."
echo "CONFIG_NODEJS_22=y" >> .config
echo "CONFIG_PACKAGE_node=y" >> .config
echo "CONFIG_PACKAGE_node-npm=y" >> .config

# 确保使用 small ICU (节省空间)
echo "CONFIG_NODEJS_ICU_SMALL=y" >> .config

# 禁用其他版本 (确保不被选中)
echo "# CONFIG_NODEJS_20 is not set" >> .config
echo "# CONFIG_NODEJS_24 is not set" >> .config
echo "# CONFIG_NODEJS_25 is not set" >> .config

# 重新生成配置（overlay 阶段通过 SKIP_MAKE_DEFCONFIG=1 跳过，避免与后续 step 重复执行）
if [ "${SKIP_MAKE_DEFCONFIG:-}" != "1" ]; then
  echo "  Running make defconfig..."
  make defconfig
else
  echo "  Skipping make defconfig (SKIP_MAKE_DEFCONFIG=1)"
fi

# 验证配置
echo "  Verifying Node.js configuration..."
if grep -q "CONFIG_NODEJS_22=y" .config; then
    echo "  ✓ Node.js 22.x configured"
else
    echo "  ✗ ERROR: Node.js 22.x not configured!"
    grep "CONFIG_NODEJS" .config | head -5
    exit 1
fi

if grep -q "CONFIG_PACKAGE_node-npm=y" .config; then
    echo "  ✓ node-npm configured"
else
    echo "  ✗ ERROR: node-npm not configured!"
    grep "CONFIG_PACKAGE_node" .config
    exit 1
fi

if grep -q "CONFIG_NODEJS_24=y" .config; then
    echo "  ✗ WARNING: Node.js 24.x still enabled!"
    grep "CONFIG_NODEJS" .config
fi

echo "Node.js 22.x configuration complete"

echo "DIY Part 2: Done"
