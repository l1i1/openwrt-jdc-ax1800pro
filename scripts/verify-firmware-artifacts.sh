#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FIRMWARE_DIR="${1:-${FIRMWARE:-}}"
EXPECTED_FACTORY_SQUASHFS_OFFSET=6291456

if [ -z "$FIRMWARE_DIR" ]; then
  echo "ERROR: firmware directory is required"
  exit 1
fi

ROOTFS_TMP=""
FACTORY_ROOTFS_TMP=""
FACTORY_HEADER_TMP=""

cleanup() {
  if [ -n "$ROOTFS_TMP" ] && [ -d "$ROOTFS_TMP" ]; then
    rm -rf "$ROOTFS_TMP"
  fi
  if [ -n "$FACTORY_ROOTFS_TMP" ] && [ -d "$FACTORY_ROOTFS_TMP" ]; then
    rm -rf "$FACTORY_ROOTFS_TMP"
  fi
  if [ -n "$FACTORY_HEADER_TMP" ] && [ -d "$FACTORY_HEADER_TMP" ]; then
    rm -rf "$FACTORY_HEADER_TMP"
  fi
}
trap cleanup EXIT

cd "$FIRMWARE_DIR"

echo "============================================"
echo "Verifying firmware files..."
echo "============================================"

SYSUPGRADE=$(find . -name "*squashfs-sysupgrade.bin" | head -1)
if [ -n "$SYSUPGRADE" ]; then
  SIZE=$(stat -c%s "$SYSUPGRADE" 2>/dev/null || stat -f%z "$SYSUPGRADE" 2>/dev/null)
  SIZE_MB=$((SIZE / 1024 / 1024))
  echo "✓ sysupgrade.bin found: $SYSUPGRADE ($SIZE_MB MB)"
  if [ "$SIZE_MB" -lt 10 ]; then
    echo "✗ ERROR: sysupgrade.bin is too small ($SIZE_MB MB), expected >10MB"
    exit 1
  fi
else
  echo "✗ ERROR: sysupgrade.bin not found!"
  exit 1
fi

FACTORY=$(find . -name "*squashfs-factory.bin" | head -1)
if [ -n "$FACTORY" ]; then
  SIZE=$(stat -c%s "$FACTORY" 2>/dev/null || stat -f%z "$FACTORY" 2>/dev/null)
  SIZE_MB=$((SIZE / 1024 / 1024))
  echo "✓ factory.bin found: $FACTORY ($SIZE_MB MB)"
  if [ "$SIZE_MB" -lt 10 ]; then
    echo "✗ ERROR: factory.bin is too small ($SIZE_MB MB), expected >10MB"
    exit 1
  fi
else
  echo "✗ ERROR: factory.bin not found!"
  echo "  Expected: yushu_router-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-factory.bin"
  exit 1
fi

INITRAMFS=$(find . -name "*initramfs-uImage.itb" | head -1)
if [ -n "$INITRAMFS" ]; then
  SIZE=$(stat -c%s "$INITRAMFS" 2>/dev/null || stat -f%z "$INITRAMFS" 2>/dev/null)
  SIZE_MB=$((SIZE / 1024 / 1024))
  echo "✓ initramfs found: $INITRAMFS ($SIZE_MB MB)"
else
  echo "⚠ WARNING: initramfs not found"
fi

MANIFEST=$(find . -name "*.manifest" | head -1)
CONFIG_BUILDINFO=$(find . -name "config.buildinfo" | head -1)
PROFILES_JSON=$(find . -name "profiles.json" | head -1)

METADATA_OK=1
for pair in "MANIFEST:$MANIFEST" "CONFIG_BUILDINFO:$CONFIG_BUILDINFO" "PROFILES_JSON:$PROFILES_JSON"; do
  label="${pair%%:*}"
  file="${pair#*:}"
  if [ -z "$file" ]; then
    echo "✗ ERROR: $label not found (no matching file)"
    METADATA_OK=0
  elif [ ! -f "$file" ]; then
    echo "✗ ERROR: $label is not a regular file: $file"
    METADATA_OK=0
  elif [ ! -s "$file" ]; then
    echo "✗ ERROR: $label is empty: $file"
    METADATA_OK=0
  else
    echo "✓ $label found: $file"
  fi
done

if [ "$METADATA_OK" -eq 0 ]; then
  echo ""
  echo "Contents of firmware directory for diagnostics:"
  ls -la
  exit 1
fi

require_build_config() {
  local pattern="$1"
  if grep -qx "$pattern" "$CONFIG_BUILDINFO"; then
    echo "✓ build config present: $pattern"
  else
    echo "✗ Missing build config: $pattern"
    exit 1
  fi
}

warn_build_config_if_missing() {
  local pattern="$1"
  local reason="$2"
  if grep -qx "$pattern" "$CONFIG_BUILDINFO"; then
    echo "✓ build config present: $pattern"
  else
    echo "⚠ build config not recorded: $pattern"
    echo "  note: $reason"
  fi
}

require_manifest_pkg() {
  local pkg="$1"
  if grep -q "^${pkg} - " "$MANIFEST"; then
    echo "✓ manifest package present: $pkg"
  else
    echo "✗ Missing manifest package: $pkg"
    exit 1
  fi
}

require_manifest_pkg_any() {
  local description="$1"
  shift

  local pkg
  for pkg in "$@"; do
    if grep -q "^${pkg} - " "$MANIFEST"; then
      echo "✓ manifest package present for ${description}: $pkg"
      return 0
    fi
  done

  echo "✗ Missing manifest package for ${description}"
  echo "  accepted packages: $*"
  exit 1
}

warn_manifest_pkg_any_if_missing() {
  local description="$1"
  local reason="$2"
  shift 2

  local pkg
  for pkg in "$@"; do
    if grep -q "^${pkg} - " "$MANIFEST"; then
      echo "✓ manifest package present for ${description}: $pkg"
      return 0
    fi
  done

  echo "⚠ manifest package not recorded for ${description}"
  echo "  accepted packages: $*"
  echo "  note: $reason"
}

compute_file_sha256() {
  python3 - "$1" <<'PY'
import hashlib
import sys

h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b""):
        h.update(chunk)
print(h.hexdigest())
PY
}

require_build_config "CONFIG_PACKAGE_node=y"
require_build_config "CONFIG_PACKAGE_node-npm=y"
require_build_config "CONFIG_PACKAGE_python3=y"
require_build_config "CONFIG_PACKAGE_kmod-tun=y"
require_build_config "CONFIG_PACKAGE_kmod-inet-diag=y"
require_build_config "CONFIG_PACKAGE_kmod-nft-queue=y"
require_build_config "CONFIG_PACKAGE_luci-compat=y"
# dnsmasq-full is still hard-required below via manifest + rootfs checks.
# On OpenWrt master, config.buildinfo may omit the explicit package symbol for
# provider/default-variant resolution even when dnsmasq-full is actually baked in.
warn_build_config_if_missing "CONFIG_PACKAGE_dnsmasq-full=y" \
  "falling back to manifest/rootfs verification for dnsmasq-full"
require_build_config "CONFIG_PACKAGE_uhttpd=y"
require_build_config "CONFIG_PACKAGE_ip-full=y"
warn_build_config_if_missing "CONFIG_PACKAGE_iptables-nft=y" \
  "falling back to manifest/rootfs verification for iptables nft backend"
# iw is also verified below via manifest + rootfs checks. On OpenWrt master,
# config.buildinfo may omit the explicit package symbol even when iw is baked in.
warn_build_config_if_missing "CONFIG_PACKAGE_iw=y" \
  "falling back to manifest/rootfs verification for iw"
# Storage support packages are hard-required below via manifest verification,
# and their key binaries/payloads are also checked in the verified rootfs.
# On OpenWrt master, config.buildinfo is not stable for this dependency chain:
# explicit package symbols may be omitted even when the final image contains the
# package selected via menu defaults or dependency propagation.
warn_build_config_if_missing "CONFIG_PACKAGE_parted=y" \
  "falling back to manifest/rootfs verification for parted"
warn_build_config_if_missing "CONFIG_PACKAGE_e2fsprogs=y" \
  "falling back to manifest/rootfs verification for e2fsprogs"
warn_build_config_if_missing "CONFIG_PACKAGE_blkid=y" \
  "falling back to manifest/rootfs verification for blkid"
warn_build_config_if_missing "CONFIG_PACKAGE_block-mount=y" \
  "falling back to manifest verification for block-mount"
warn_build_config_if_missing "CONFIG_PACKAGE_f2fs-tools=y" \
  "falling back to manifest/rootfs verification for f2fs-tools"
warn_build_config_if_missing "CONFIG_PACKAGE_kmod-fs-ext4=y" \
  "falling back to manifest verification for kmod-fs-ext4"
warn_build_config_if_missing "CONFIG_PACKAGE_kmod-fs-f2fs=y" \
  "falling back to manifest verification for kmod-fs-f2fs"
warn_build_config_if_missing "CONFIG_PACKAGE_kmod-fs-udf=y" \
  "falling back to manifest verification for kmod-fs-udf"
warn_build_config_if_missing "CONFIG_PACKAGE_kmod-cdrom=y" \
  "falling back to manifest verification for kmod-cdrom"
# These userland utilities are all hard-required below via manifest checks, and
# their shipped binaries/services are also validated in the rootfs where
# relevant. On OpenWrt master, config.buildinfo can omit explicit symbols for
# packages that are still present in the final image.
warn_build_config_if_missing "CONFIG_PACKAGE_hostapd-utils=y" \
  "falling back to manifest/rootfs verification for hostapd-utils"
warn_build_config_if_missing "CONFIG_PACKAGE_miniupnpd-nftables=y" \
  "falling back to manifest verification for miniupnpd-nftables"
warn_build_config_if_missing "CONFIG_PACKAGE_aria2=y" \
  "falling back to manifest/rootfs verification for aria2"
warn_build_config_if_missing "CONFIG_ARIA2_OPENSSL=y" \
  "falling back to aria2c ELF runtime verification for the OpenSSL-linked aria2 variant"
warn_build_config_if_missing "CONFIG_PACKAGE_curl=y" \
  "falling back to manifest/rootfs verification for curl"
warn_build_config_if_missing "CONFIG_PACKAGE_wget=y" \
  "falling back to manifest/rootfs verification for wget"
warn_build_config_if_missing "CONFIG_PACKAGE_openssh-sftp-server=y" \
  "falling back to manifest verification for openssh-sftp-server"

require_manifest_pkg "node127"
require_manifest_pkg "node-npm"
require_manifest_pkg "python3"
require_manifest_pkg "luci"
require_manifest_pkg "kmod-tun"
require_manifest_pkg "kmod-inet-diag"
require_manifest_pkg "kmod-nft-queue"
require_manifest_pkg "luci-compat"
require_manifest_pkg "dnsmasq-full"
require_manifest_pkg "uhttpd"
require_manifest_pkg "ip-full"
require_manifest_pkg "iptables-nft"
require_manifest_pkg "iw"
require_manifest_pkg "parted"
require_manifest_pkg "e2fsprogs"
require_manifest_pkg "blkid"
require_manifest_pkg "block-mount"
require_manifest_pkg "f2fs-tools"
require_manifest_pkg "kmod-fs-ext4"
require_manifest_pkg "kmod-fs-f2fs"
require_manifest_pkg "kmod-fs-udf"
require_manifest_pkg "kmod-cdrom"
require_manifest_pkg "hostapd-utils"
require_manifest_pkg "miniupnpd-nftables"
require_manifest_pkg "wimlib"
require_manifest_pkg "aria2"
require_manifest_pkg "curl"
warn_manifest_pkg_any_if_missing "wget userspace package" \
  "falling back to rootfs binary verification for BusyBox or package-provided wget" \
  "wget" "wget-ssl" "wget-nossl"
require_manifest_pkg "openssh-sftp-server"

if grep -q '^kmod-qca-nss-dp - ' "$MANIFEST"; then
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "HAS_QCA_NSS_DP=true" >> "$GITHUB_ENV"
  fi
  echo "✓ manifest package present: kmod-qca-nss-dp"
else
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "HAS_QCA_NSS_DP=false" >> "$GITHUB_ENV"
  fi
  echo "⚠ qca-nss-dp not present in manifest; release notes will omit acceleration claim"
fi

find_rootfs_stage() {
  local candidate
  for candidate in $(find "$WORKSPACE_ROOT/openwrt/build_dir" -mindepth 2 -maxdepth 3 -type d -name "root-*" ! -name "root.orig-*" 2>/dev/null); do
    if [ -f "$candidate/etc/openwrt_release" ]; then
      echo "$candidate"
      return 0
    fi
  done
  for candidate in $(find "$WORKSPACE_ROOT/openwrt/build_dir" -mindepth 2 -maxdepth 3 -type d -name "root.orig-*" 2>/dev/null); do
    if [ -f "$candidate/etc/openwrt_release" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

find_rootfs_image() {
  local targets_dir="$WORKSPACE_ROOT/openwrt/bin/targets"

  if [ ! -d "$targets_dir" ]; then
    return 0
  fi

  find "$targets_dir" -type f \
    \( -name "*squashfs-rootfs*" -o -name "*rootfs.squashfs" -o -name "*rootfs.img" -o -name "*rootfs.bin" \) \
    ! -name "*sysupgrade*" \
    ! -name "*factory*" \
    2>/dev/null | head -1
}

extract_rootfs_image() {
  local image_path="$1"
  local workdir="$2"
  local normalized_image="$image_path"
  local list_file="$workdir/rootfs.list"
  local squashfs_meta=""
  local squashfs_magic=""
  local squashfs_bytes_used=""
  local squashfs_file_size=""

  squashfs_meta=$(python3 -c 'import os, struct, sys; p=sys.argv[1]; f=open(p, "rb"); hdr=f.read(48); f.close(); magic=hdr[:4].hex() if len(hdr) >= 4 else ""; bytes_used=struct.unpack_from("<Q", hdr, 40)[0] if len(hdr) >= 48 else 0; print(magic, bytes_used, os.path.getsize(p))' "$image_path" 2>/dev/null) || squashfs_meta=""
  set -- $squashfs_meta
  squashfs_magic="$1"
  squashfs_bytes_used="$2"
  squashfs_file_size="$3"

  if [ "$squashfs_magic" != "68737173" ] || [ -z "$squashfs_bytes_used" ] || [ -z "$squashfs_file_size" ]; then
    echo "✗ ERROR: rootfs image is not a readable squashfs payload: $image_path" >&2
    return 1
  fi

  if [ "$squashfs_file_size" -lt "$squashfs_bytes_used" ]; then
    echo "✗ ERROR: squashfs payload is truncated ($squashfs_file_size < $squashfs_bytes_used): $image_path" >&2
    return 1
  fi

  if [ "$squashfs_file_size" -gt "$squashfs_bytes_used" ]; then
    normalized_image="$workdir/rootfs.normalized.squashfs"
    echo "Trimming squashfs payload from $squashfs_file_size to $squashfs_bytes_used bytes before verification..."
    if ! head -c "$squashfs_bytes_used" "$image_path" > "$normalized_image"; then
      echo "✗ ERROR: failed to normalize squashfs payload: $image_path" >&2
      return 1
    fi
  fi

  if ! unsquashfs -ll "$normalized_image" > "$list_file" 2>/dev/null; then
    echo "✗ ERROR: failed to enumerate squashfs rootfs image: $image_path" >&2
    return 1
  fi
  ROOTFS_VIEW="$normalized_image"
  ROOTFS_LIST_FILE="$list_file"
  ROOTFS_SHA256=$(compute_file_sha256 "$normalized_image")
  ROOTFS_VIEW_DESC="squashfs rootfs image"
  return 0
}

extract_sysupgrade_rootfs() {
  local sysupgrade_path="$1"
  local workdir="$2"
  local sysupgrade_dir="$workdir/sysupgrade"
  local root_candidate=""
  local root_member=""
  local magic=""

  mkdir -p "$sysupgrade_dir"

  echo "Attempting tar extraction for sysupgrade rootfs payload..."
  if ! tar -tf "$sysupgrade_path" >/dev/null 2>&1; then
    echo "✗ ERROR: failed to read sysupgrade archive: $sysupgrade_path" >&2
    return 1
  fi

  root_member=$(tar -tf "$sysupgrade_path" | grep -E '(^|/)(root|.*rootfs.*|.*\.squashfs)$' | head -1)
  if [ -z "$root_member" ]; then
    echo "✗ ERROR: unable to find rootfs payload inside sysupgrade archive" >&2
    tar -tf "$sysupgrade_path" | sed 's#^#  archive: #' >&2
    return 1
  fi

  root_candidate="$sysupgrade_dir/rootfs.bin"
  if ! tar -xOf "$sysupgrade_path" "$root_member" > "$root_candidate"; then
    echo "✗ ERROR: failed to stream rootfs payload from sysupgrade archive: $root_member" >&2
    return 1
  fi

  magic=$(dd if="$root_candidate" bs=4 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n')
  if [ "$magic" != "68737173" ]; then
    echo "✗ ERROR: sysupgrade rootfs payload is not squashfs (magic=$magic): $root_member" >&2
    return 1
  fi

  if ! extract_rootfs_image "$root_candidate" "$workdir"; then
    echo "✗ ERROR: extracted sysupgrade rootfs could not be unsquashed: $root_member" >&2
    return 1
  fi

  ROOTFS_VIEW_DESC="sysupgrade squashfs rootfs"
  return 0
}

extract_sysupgrade_kernel() {
  local sysupgrade_path="$1"
  local out_path="$2"
  local kernel_member=""

  if ! tar -tf "$sysupgrade_path" >/dev/null 2>&1; then
    echo "✗ ERROR: failed to read sysupgrade archive while extracting kernel: $sysupgrade_path" >&2
    return 1
  fi

  kernel_member=$(tar -tf "$sysupgrade_path" | grep -E '(^|/)(kernel|.*kernel.*|.*\.itb)$' | head -1)
  if [ -z "$kernel_member" ]; then
    echo "✗ ERROR: unable to find kernel payload inside sysupgrade archive" >&2
    tar -tf "$sysupgrade_path" | sed 's#^#  archive: #' >&2
    return 1
  fi

  if ! tar -xOf "$sysupgrade_path" "$kernel_member" > "$out_path"; then
    echo "✗ ERROR: failed to stream kernel payload from sysupgrade archive: $kernel_member" >&2
    return 1
  fi

  if [ ! -s "$out_path" ]; then
    echo "✗ ERROR: extracted sysupgrade kernel payload is empty: $kernel_member" >&2
    return 1
  fi

  return 0
}

extract_factory_rootfs() {
  local factory_path="$1"
  local workdir="$2"
  local root_candidate="$workdir/rootfs.bin"
  local squashfs_offset=""

  squashfs_offset=$(python3 -c 'import pathlib, sys; data = pathlib.Path(sys.argv[1]).read_bytes(); print(data.find(b"hsqs"))' "$factory_path" 2>/dev/null) || squashfs_offset=""
  if [ -z "$squashfs_offset" ] || [ "$squashfs_offset" -lt 0 ]; then
    echo "✗ ERROR: unable to locate embedded squashfs payload inside factory image: $factory_path" >&2
    return 1
  fi

  echo "Attempting factory rootfs extraction from squashfs offset ${squashfs_offset}..."
  if ! tail -c "+$((squashfs_offset + 1))" "$factory_path" > "$root_candidate"; then
    echo "✗ ERROR: failed to extract factory rootfs payload from factory image" >&2
    return 1
  fi

  if ! extract_rootfs_image "$root_candidate" "$workdir"; then
    echo "✗ ERROR: extracted factory rootfs could not be inspected" >&2
    return 1
  fi

  ROOTFS_VIEW_DESC="factory squashfs rootfs"
  return 0
}

get_fdt_magic() {
  python3 -c 'import pathlib, sys; data = pathlib.Path(sys.argv[1]).read_bytes(); print(data[:4].hex() if len(data) >= 4 else "")' "$1"
}

get_fdt_totalsize() {
  python3 -c 'import pathlib, struct, sys; data = pathlib.Path(sys.argv[1]).read_bytes(); print(struct.unpack(">I", data[4:8])[0] if len(data) >= 8 else 0)' "$1"
}

verify_factory_header() {
  local factory_path="$1"
  local sysupgrade_path="$2"
  local workdir="$3"
  local squashfs_offset=""
  local header_path="$workdir/factory-header.bin"
  local header_fit_path="$workdir/factory-fit.bin"
  local sysupgrade_kernel_path="$workdir/sysupgrade-kernel.bin"
  local sysupgrade_fit_path="$workdir/sysupgrade-fit.bin"
  local factory_magic=""
  local sysupgrade_magic=""
  local factory_totalsize=""
  local sysupgrade_totalsize=""
  local sysupgrade_kernel_size=""
  local factory_padding_report=""
  local factory_padding_size=""
  local factory_padding_all_zero=""
  local factory_padding_first_offset=""
  local factory_padding_first_byte=""
  local factory_sha256=""
  local sysupgrade_sha256=""

  if ! command -v dumpimage >/dev/null 2>&1; then
    echo "✗ ERROR: dumpimage is required for factory header verification but is not installed"
    exit 1
  fi

  squashfs_offset=$(python3 -c 'import pathlib, sys; data = pathlib.Path(sys.argv[1]).read_bytes(); print(data.find(b"hsqs"))' "$factory_path" 2>/dev/null) || squashfs_offset=""
  if [ -z "$squashfs_offset" ] || [ "$squashfs_offset" -le 0 ]; then
    echo "✗ ERROR: factory image is missing a non-empty header before squashfs payload: $factory_path"
    exit 1
  fi
  if [ "$squashfs_offset" -ne "$EXPECTED_FACTORY_SQUASHFS_OFFSET" ]; then
    echo "✗ ERROR: factory squashfs payload starts at an unexpected offset"
    echo "  expected: $EXPECTED_FACTORY_SQUASHFS_OFFSET (0x$(printf '%x' "$EXPECTED_FACTORY_SQUASHFS_OFFSET"))"
    echo "  actual:   $squashfs_offset (0x$(printf '%x' "$squashfs_offset"))"
    exit 1
  fi

  if ! head -c "$squashfs_offset" "$factory_path" > "$header_path"; then
    echo "✗ ERROR: failed to extract factory header region: $factory_path"
    exit 1
  fi

  if [ ! -s "$header_path" ]; then
    echo "✗ ERROR: extracted factory header region is empty"
    exit 1
  fi

  factory_magic=$(get_fdt_magic "$header_path")
  if [ "$factory_magic" != "d00dfeed" ]; then
    echo "✗ ERROR: factory header does not start with FIT/DTB magic (got $factory_magic)"
    exit 1
  fi

  factory_totalsize=$(get_fdt_totalsize "$header_path")
  if [ -z "$factory_totalsize" ] || [ "$factory_totalsize" -le 0 ] || [ "$factory_totalsize" -gt "$squashfs_offset" ]; then
    echo "✗ ERROR: invalid factory FIT totalsize: $factory_totalsize"
    exit 1
  fi

  if ! head -c "$factory_totalsize" "$header_path" > "$header_fit_path"; then
    echo "✗ ERROR: failed to trim factory FIT payload to DTB totalsize"
    exit 1
  fi

  if ! dumpimage -l "$header_fit_path" >/dev/null 2>&1; then
    echo "✗ ERROR: factory header FIT metadata is not readable via dumpimage"
    exit 1
  fi

  if ! extract_sysupgrade_kernel "$sysupgrade_path" "$sysupgrade_kernel_path"; then
    exit 1
  fi

  sysupgrade_magic=$(get_fdt_magic "$sysupgrade_kernel_path")
  if [ "$sysupgrade_magic" != "d00dfeed" ]; then
    echo "✗ ERROR: sysupgrade kernel payload is not a FIT/DTB image (got $sysupgrade_magic)"
    exit 1
  fi

  sysupgrade_totalsize=$(get_fdt_totalsize "$sysupgrade_kernel_path")
  sysupgrade_kernel_size=$(stat -c%s "$sysupgrade_kernel_path" 2>/dev/null || stat -f%z "$sysupgrade_kernel_path" 2>/dev/null)
  if [ -z "$sysupgrade_totalsize" ] || [ "$sysupgrade_totalsize" -le 0 ] || [ "$sysupgrade_totalsize" -gt "$sysupgrade_kernel_size" ]; then
    echo "✗ ERROR: invalid sysupgrade kernel FIT totalsize: $sysupgrade_totalsize"
    exit 1
  fi

  if [ "$sysupgrade_totalsize" -ne "$factory_totalsize" ]; then
    echo "✗ ERROR: factory FIT totalsize does not match sysupgrade kernel payload"
    echo "  factory totalsize:   $factory_totalsize"
    echo "  sysupgrade totalsize: $sysupgrade_totalsize"
    exit 1
  fi

  if ! head -c "$sysupgrade_totalsize" "$sysupgrade_kernel_path" > "$sysupgrade_fit_path"; then
    echo "✗ ERROR: failed to trim sysupgrade kernel FIT payload to DTB totalsize"
    exit 1
  fi

  if ! dumpimage -l "$sysupgrade_fit_path" >/dev/null 2>&1; then
    echo "✗ ERROR: sysupgrade kernel FIT metadata is not readable via dumpimage"
    exit 1
  fi

  factory_sha256=$(compute_file_sha256 "$header_fit_path")
  sysupgrade_sha256=$(compute_file_sha256 "$sysupgrade_fit_path")
  if [ "$factory_sha256" != "$sysupgrade_sha256" ]; then
    echo "✗ ERROR: factory FIT header/kernel payload does not match sysupgrade kernel payload"
    echo "  factory fit sha256:    $factory_sha256"
    echo "  sysupgrade kernel sha256: $sysupgrade_sha256"
    exit 1
  fi

  echo "✓ factory FIT header/kernel matches sysupgrade kernel payload: $factory_sha256"

  factory_padding_report=$(python3 - "$factory_path" "$factory_totalsize" "$squashfs_offset" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
start = int(sys.argv[2])
end = int(sys.argv[3])
data = path.read_bytes()

if start < 0 or end < start or end > len(data):
    raise SystemExit(2)

region = data[start:end]
if not region:
    print("0\t1\t\t")
    raise SystemExit(0)

for index, value in enumerate(region):
    if value != 0:
        print(f"{len(region)}\t0\t{index}\t{value:02x}")
        raise SystemExit(0)

print(f"{len(region)}\t1\t\t")
PY
  ) || {
    echo "✗ ERROR: failed to inspect factory padding region between FIT payload and squashfs"
    exit 1
  }
  IFS=$'\t' read -r factory_padding_size factory_padding_all_zero factory_padding_first_offset factory_padding_first_byte <<< "$factory_padding_report"

  if [ "$factory_padding_all_zero" != "1" ]; then
    echo "✗ ERROR: factory padding/trailer region before squashfs is not zero-filled"
    echo "  padding size: $factory_padding_size bytes"
    echo "  first unexpected byte offset: $((factory_totalsize + factory_padding_first_offset))"
    echo "  first unexpected byte value: 0x$factory_padding_first_byte"
    exit 1
  fi

  echo "✓ factory padding/trailer before squashfs is zero-filled: $factory_padding_size bytes"
  echo "✓ factory squashfs payload starts at expected offset: $squashfs_offset"
}

rootfs_has_entry() {
  local rel="$1"
  [ -n "$ROOTFS_LIST_FILE" ] || return 1
  python3 - "$ROOTFS_LIST_FILE" "$rel" <<'PY'
import sys

list_file = sys.argv[1]
target = f"squashfs-root/{sys.argv[2]}"

with open(list_file, "r", encoding="utf-8", errors="replace") as fh:
    for raw_line in fh:
        line = raw_line.rstrip("\n")
        if not line:
            continue
        if " -> " in line:
            path = line.split(" -> ", 1)[0].rsplit(None, 1)[-1]
        else:
            path = line.rsplit(None, 1)[-1]
        if path == target:
            sys.exit(0)

sys.exit(1)
PY
}

extract_rootfs_member() {
  local rel="$1"
  local dest="$2"
  if ! unsquashfs -cat "$ROOTFS_VIEW" "$rel" > "$dest" 2>/dev/null; then
    return 1
  fi
  [ -s "$dest" ]
}

require_rootfs_entry() {
  local rel="$1"
  if rootfs_has_entry "$rel"; then
    echo "✓ rootfs entry present: /$rel"
  else
    echo "✗ Missing rootfs entry: /$rel"
    exit 1
  fi
}

rootfs_mode_for_entry() {
  local rel="$1"
  [ -n "$ROOTFS_LIST_FILE" ] || return 1
  python3 - "$ROOTFS_LIST_FILE" "$rel" <<'PY'
import sys

list_file = sys.argv[1]
target = f"squashfs-root/{sys.argv[2]}"

with open(list_file, "r", encoding="utf-8", errors="replace") as fh:
    for raw_line in fh:
        line = raw_line.rstrip("\n")
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        mode = parts[0]
        path = parts[-1]
        if " -> " in line:
            path = line.split(" -> ", 1)[0].rsplit(None, 1)[-1]
        if path == target:
            print(mode)
            sys.exit(0)

sys.exit(1)
PY
}

require_rootfs_executable() {
  local rel="$1"
  local mode=""

  mode=$(rootfs_mode_for_entry "$rel") || {
    echo "✗ Missing rootfs entry for executable check: /$rel"
    exit 1
  }

  case "$mode" in
    -??x??x??x|-??x??x???|-??x??????)
      echo "✓ rootfs entry is executable: /$rel ($mode)"
      ;;
    *)
      echo "✗ ERROR: rootfs entry is not executable: /$rel ($mode)"
      exit 1
      ;;
  esac
}

require_rootfs_any() {
  local description="$1"
  shift
  local rel
  for rel in "$@"; do
    if rootfs_has_entry "$rel"; then
      echo "✓ rootfs entry present for ${description}: /$rel"
      return 0
    fi
  done
  echo "✗ Missing rootfs entry for ${description}"
  printf '  tried: /%s\n' "$@"
  exit 1
}

require_rootfs_elf_runtime() {
  local rel="$1"
  local file_path=""
  local interpreter=""
  local soname=""
  local needed_libs=""

  if ! rootfs_has_entry "$rel"; then
    echo "✗ Missing ELF binary for runtime validation: /$rel"
    exit 1
  fi

  if ! command -v readelf >/dev/null 2>&1; then
    echo "✗ ERROR: readelf is required for ELF runtime verification"
    exit 1
  fi

  file_path=$(mktemp /tmp/rootfs-elf.XXXXXX)
  if ! extract_rootfs_member "$rel" "$file_path"; then
    rm -f "$file_path"
    echo "✗ ERROR: failed to extract ELF binary for runtime validation: /$rel"
    exit 1
  fi

  interpreter=$(readelf -l "$file_path" 2>/dev/null | sed -n 's#.*Requesting program interpreter: \(.*\)\]#\1#p' | head -1)
  if [ -n "$interpreter" ]; then
    if rootfs_has_entry "${interpreter#/}"; then
      echo "✓ ELF interpreter present for /$rel: $interpreter"
    else
      rm -f "$file_path"
      echo "✗ Missing ELF interpreter for /$rel: $interpreter"
      exit 1
    fi
  fi

  needed_libs=$(readelf -d "$file_path" 2>/dev/null | sed -n 's#.*Shared library: \[\(.*\)\]#\1#p')
  for soname in $needed_libs; do
    [ -n "$soname" ] || continue
    if rootfs_has_entry "lib/$soname" || rootfs_has_entry "usr/lib/$soname"; then
      echo "✓ ELF dependency present for /$rel: $soname"
    else
      rm -f "$file_path"
      echo "✗ Missing ELF dependency for /$rel: $soname"
      exit 1
    fi
  done

  rm -f "$file_path"
}

normalize_dep_name() {
  local raw="$1"
  local dep
  dep=$(echo "$raw" | sed 's/([^)]*)//g' | cut -d'|' -f1 | xargs)
  dep=${dep%%:*}
  echo "$dep"
}

require_prebuilt_manifest_dependencies() {
  local metadata_file="$1"
  local pkg=""
  local arch=""
  local deps=""
  local dep=""
  local normalized=""
  local prebuilt_packages=""

  [ -f "$metadata_file" ] || return 0

  while IFS=$'\t' read -r pkg arch deps; do
    normalized=$(normalize_dep_name "$pkg")
    [ -n "$normalized" ] || continue
    prebuilt_packages="${prebuilt_packages}${normalized}"$'\n'
  done < "$metadata_file"

  while IFS=$'\t' read -r pkg arch deps; do
    [ -n "$pkg" ] || continue
    echo "Checking prebuilt package metadata: $pkg ($arch)"
    IFS=',' read -ra dep_list <<< "$deps"
    for dep in "${dep_list[@]}"; do
      normalized=$(normalize_dep_name "$dep")
      case "$normalized" in
        ""|libc|kernel|base-files|busybox)
          continue
          ;;
        @*)
          continue
          ;;
      esac
      if printf '%s' "$prebuilt_packages" | grep -Fxq "$normalized"; then
        echo "✓ prebuilt overlay dependency present: $normalized"
        continue
      fi
      require_manifest_pkg "$normalized"
    done
  done < "$metadata_file"
}

ROOTFS_STAGE=$(find_rootfs_stage || true)
ROOTFS_IMAGE=$(find_rootfs_image || true)
ROOTFS_VIEW=""
ROOTFS_LIST_FILE=""
ROOTFS_SHA256=""
ROOTFS_VIEW_DESC=""
PRIMARY_ROOTFS_SHA256=""

if ! command -v unsquashfs >/dev/null 2>&1; then
  echo "✗ ERROR: unsquashfs is required for release verification but is not installed"
  exit 1
fi

if [ -n "$ROOTFS_IMAGE" ]; then
  ROOTFS_TMP=$(mktemp -d /tmp/openwrt-rootfs-check.XXXXXX)
  if ! extract_rootfs_image "$ROOTFS_IMAGE" "$ROOTFS_TMP"; then
    rm -rf "$ROOTFS_TMP"
    ROOTFS_TMP=""
  fi
fi

if [ -z "$ROOTFS_VIEW" ] && [ -n "$SYSUPGRADE" ]; then
  ROOTFS_TMP=$(mktemp -d /tmp/openwrt-rootfs-check.XXXXXX)
  if ! extract_sysupgrade_rootfs "$SYSUPGRADE" "$ROOTFS_TMP"; then
    rm -rf "$ROOTFS_TMP"
    ROOTFS_TMP=""
  fi
fi

if [ -z "$ROOTFS_VIEW" ]; then
  echo "✗ ERROR: unable to inspect rootfs from releasable firmware artifacts"
  echo "  standalone rootfs image: ${ROOTFS_IMAGE:-<missing>}"
  echo "  sysupgrade image: ${SYSUPGRADE:-<missing>}"
  if [ -n "$ROOTFS_STAGE" ] && [ -d "$ROOTFS_STAGE" ]; then
    echo "  note: build_dir staging exists at $ROOTFS_STAGE but is not accepted for release verification"
  fi
  exit 1
fi

echo "Using rootfs verification source: $ROOTFS_VIEW_DESC -> $ROOTFS_VIEW"
PRIMARY_ROOTFS_SHA256="$ROOTFS_SHA256"
echo "Primary rootfs squashfs sha256: $PRIMARY_ROOTFS_SHA256"

require_rootfs_entry "etc/init.d/mgrserver"
require_rootfs_entry "etc/init.d/rc-common-selfheal"
require_rootfs_entry "etc/init.d/rcS"
require_rootfs_entry "etc/init.d/network"
require_rootfs_entry "etc/init.d/firewall"
require_rootfs_entry "etc/init.d/dnsmasq"
require_rootfs_entry "etc/init.d/uhttpd"
require_rootfs_entry "etc/init.d/cron"
require_rootfs_entry "etc/hotplug.d/iface/35-yushu-wan-autofit"
require_rootfs_entry "etc/hotplug.d/net/35-yushu-wan-autofit"
require_rootfs_entry "etc/crontabs"
require_rootfs_entry "usr/bin/health-check"
require_rootfs_entry "usr/bin/service-watchdog"
require_rootfs_entry "usr/bin/yushu-wan-autofit"
require_rootfs_entry "usr/bin/yushu-wan-autofit-hotplug"
require_rootfs_entry "etc/uci-defaults/95-yushu-default-lan"
require_rootfs_entry "etc/uci-defaults/96-ath11k-mac80211-compat"
require_rootfs_entry "etc/uci-defaults/98-disable-flow-offload-for-singbox"
require_rootfs_entry "etc/uci-defaults/98-home-partition"
require_rootfs_entry "etc/uci-defaults/99-mgrserver-ports"
require_rootfs_entry "etc/uci-defaults/99-restrict-admin-vpn"
require_rootfs_entry "etc/uci-defaults/99-service-watchdog-cron"
require_rootfs_entry "etc/uci-defaults/99-yushu-wan-autofit"
require_rootfs_entry "lib/preinit/81_rc_common_selfheal"
require_rootfs_entry "usr/bin/sing-box"
require_rootfs_entry "etc/init.d/sing-box"
require_rootfs_entry "etc/config/sing-box"
require_rootfs_entry "usr/bin/easytier-core"
require_rootfs_entry "usr/bin/easytier-cli"
require_rootfs_entry "usr/bin/easytier-web"
require_rootfs_entry "usr/bin/wimlib-imagex"
require_rootfs_entry "usr/bin/aria2c"
require_rootfs_entry "usr/sbin/mkfs.f2fs"
require_rootfs_entry "etc/init.d/easytier"
require_rootfs_entry "etc/config/easytier"
require_rootfs_entry "usr/lib/lua/luci/controller/easytier.lua"
require_rootfs_entry "usr/share/rpcd/acl.d/luci-app-easytier.json"
if ! rootfs_has_entry "usr/share/mgrserver-defaults/res/pxe/config.ini"; then
  echo "✗ Missing rootfs entry: /usr/share/mgrserver-defaults/res/pxe/config.ini"
  if rootfs_has_entry "usr/share/mgrserver-defaults/res/pxe/pxe/config.ini"; then
    echo "  note: found nested /usr/share/mgrserver-defaults/res/pxe/pxe/config.ini; PXE source directory was copied one level too high"
  fi
  if rootfs_has_entry "files/usr/share/mgrserver-defaults/res/pxe/config.ini"; then
    echo "  note: found /files/usr/share/mgrserver-defaults/res/pxe/config.ini; OpenWrt overlay was copied as openwrt/files/files"
  fi
  exit 1
fi
echo "✓ rootfs entry present: /usr/share/mgrserver-defaults/res/pxe/config.ini"
require_rootfs_entry "usr/share/mgrserver-defaults/res/pxe/set_pxe.sh"
require_rootfs_entry "usr/share/mgrserver-defaults/res/pxe/up_pxe_res.sh"
require_rootfs_entry "usr/share/mgrserver-defaults/res/pxe/tftpboot"
require_rootfs_entry "usr/share/mgrserver-defaults/res/pxe/res/pe-menu.exe"
require_rootfs_entry "root/mgrserver/commands.json"
require_rootfs_entry "root/mgrserver/web-dist/index.html"
require_rootfs_entry "usr/bin/node"
require_rootfs_entry "usr/bin/npm"
require_rootfs_any "curl binary" "usr/bin/curl" "bin/curl"
require_rootfs_any "wget binary" "usr/bin/wget" "bin/wget"
require_rootfs_any "ip binary" "usr/sbin/ip" "sbin/ip"
require_rootfs_any "iw binary" "usr/sbin/iw" "sbin/iw"
require_rootfs_any "blkid binary" "usr/sbin/blkid" "sbin/blkid"
require_rootfs_any "mkfs.ext4 binary" "usr/sbin/mkfs.ext4" "sbin/mkfs.ext4"
require_rootfs_any "iptables binary" "usr/sbin/iptables" "sbin/iptables" "usr/bin/iptables"
require_rootfs_any "crond binary" "usr/sbin/crond" "sbin/crond" "bin/crond"
require_rootfs_any "MgrServer server entry" "root/mgrserver/dist/index.js" "root/mgrserver/bundle/index.cjs"
require_rootfs_executable "etc/init.d/mgrserver"
require_rootfs_executable "etc/init.d/rc-common-selfheal"
require_rootfs_executable "etc/init.d/rcS"
require_rootfs_executable "etc/init.d/network"
require_rootfs_executable "etc/init.d/firewall"
require_rootfs_executable "etc/init.d/dnsmasq"
require_rootfs_executable "etc/init.d/uhttpd"
require_rootfs_executable "etc/init.d/cron"
require_rootfs_executable "etc/uci-defaults/95-yushu-default-lan"
require_rootfs_executable "etc/uci-defaults/96-ath11k-mac80211-compat"
require_rootfs_executable "etc/uci-defaults/98-disable-flow-offload-for-singbox"
require_rootfs_executable "etc/uci-defaults/98-home-partition"
require_rootfs_executable "etc/uci-defaults/99-mgrserver-ports"
require_rootfs_executable "etc/uci-defaults/99-restrict-admin-vpn"
require_rootfs_executable "etc/uci-defaults/99-service-watchdog-cron"
require_rootfs_executable "etc/uci-defaults/99-yushu-wan-autofit"
require_rootfs_executable "usr/bin/yushu-wan-autofit"
require_rootfs_executable "usr/bin/yushu-wan-autofit-hotplug"
require_rootfs_executable "usr/share/mgrserver-defaults/res/pxe/set_pxe.sh"
require_rootfs_executable "usr/share/mgrserver-defaults/res/pxe/up_pxe_res.sh"

verify_pxe_defaults_runtime_assets() {
  local tmp=""

  if ! grep -Fq 'find . -type f' "$WORKSPACE_ROOT/scripts/stage-mgrserver-overlay.sh" || \
     ! grep -Fq "sort > filelist.txt" "$WORKSPACE_ROOT/scripts/stage-mgrserver-overlay.sh"; then
    echo "✗ ERROR: PXE staging does not generate res/filelist.txt from staged files"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-pxe-filelist.XXXXXX)
  if ! extract_rootfs_member "usr/share/mgrserver-defaults/res/pxe/res/filelist.txt" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract PXE res/filelist.txt"
    exit 1
  fi

  if ! grep -Fxq 'pe-menu.exe' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE res/filelist.txt does not include pe-menu.exe"
    exit 1
  fi
  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-pxe-home-sync.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/98-home-partition" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract PXE runtime default synchronization"
    exit 1
  fi

  if grep -Fq 'PXE defaults already present: $PXE_TARGET' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE runtime sync still skips firmware-managed asset updates"
    exit 1
  fi

  if ! grep -Fq 'for item in "$PXE_DEFAULTS"/*; do' "$tmp" || \
     ! grep -Fq 'config.ini|os|winpe)' "$tmp" || \
     ! grep -Fq 'cp -a "$item" "$PXE_TARGET/"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE runtime sync does not refresh managed assets while preserving runtime data"
    exit 1
  fi
  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-pxe-set.XXXXXX)
  if ! extract_rootfs_member "usr/share/mgrserver-defaults/res/pxe/set_pxe.sh" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract PXE set_pxe.sh"
    exit 1
  fi

  if ! grep -Fq '[ -f "$TFTP_ROOT/undionly.kpxe" ]' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE set_pxe.sh does not guard undionly.kpxe DHCP option"
    exit 1
  fi

  if ! grep -Fq "add_pxe_boot 'ipxe.efi' efi64" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE set_pxe.sh does not provide UEFI ipxe.efi boot rule"
    exit 1
  fi

  if ! grep -Fq "add_pxe_match ipxe '175'" "$tmp" || \
     ! grep -Fq "add_pxe_boot 'autoexec.ipxe' ipxe" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE set_pxe.sh does not chain iPXE clients to autoexec.ipxe"
    exit 1
  fi

  if ! grep -Fq 'find "$PXE_ROOT" -type f -name "*.sh" -exec chmod +x {} \;' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE set_pxe.sh does not preserve executable bits for updater scripts"
    exit 1
  fi

  if grep -Fq 'uci delete dhcp.${DNSMASQ_SECTION}.dhcp_option' "$tmp" || \
     grep -Fq 'uci delete dhcp.lan.dhcp_option' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE set_pxe.sh clears unrelated DHCP options"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ PXE defaults refresh managed runtime assets and include guarded bootfile selection"
}

verify_mac80211_runtime_compat() {
  local rel=""
  local tmp=""

  for rel in "lib/netifd/wireless/mac80211.sh" "lib/wifi/mac80211.sh"; do
    if ! rootfs_has_entry "$rel"; then
      continue
    fi

    tmp=$(mktemp /tmp/rootfs-content.XXXXXX)
    if ! extract_rootfs_member "$rel" "$tmp"; then
      rm -f "$tmp"
      echo "✗ ERROR: failed to extract /$rel for compatibility verification"
      exit 1
    fi

    if grep -Eq 'iw phy .*\bset (distance|frag)\b' "$tmp"; then
      rm -f "$tmp"
      echo "✗ ERROR: rootfs /$rel still contains unsupported ath11k iw operations"
      exit 1
    fi

    rm -f "$tmp"
    echo "✓ rootfs mac80211 runtime script excludes unsupported ath11k iw operations: /$rel"
    return 0
  done

  echo "✗ ERROR: unable to find a mac80211 runtime script in the verified rootfs"
  exit 1
}

verify_mac80211_runtime_compat

verify_inittab_sysinit_guard() {
  local tmp=""

  if ! rootfs_has_entry "etc/inittab"; then
    echo "✗ ERROR: missing /etc/inittab in verified rootfs"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-inittab.XXXXXX)
  if ! extract_rootfs_member "etc/inittab" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/inittab for boot-guard verification"
    exit 1
  fi

  if ! grep -Fqx '::sysinit:/etc/init.d/rcS S boot' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/inittab does not keep the expected rcS sysinit entry"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ /etc/inittab keeps the expected rcS sysinit entry"
}

verify_inittab_sysinit_guard

verify_rcs_boot_wrapper() {
  local tmp=""

  if ! rootfs_has_entry "etc/init.d/rcS"; then
    echo "✗ ERROR: missing /etc/init.d/rcS in verified rootfs"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-rcs.XXXXXX)
  if ! extract_rootfs_member "etc/init.d/rcS" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/init.d/rcS for boot-wrapper verification"
    exit 1
  fi

  if ! grep -Fq 'repairing missing /etc/rc.common before rcS' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/rcS does not log the expected rc.common repair path"
    exit 1
  fi

  if ! grep -Fq '/bin/sh "$ROM_RC_COMMON" "$script" "$param"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/rcS does not run rc.d scripts through /rom/etc/rc.common"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ /etc/init.d/rcS keeps the expected ROM rc.common boot wrapper"
}

verify_preinit_overlay_boot_repair() {
  local tmp=""

  if ! rootfs_has_entry "lib/preinit/81_rc_common_selfheal"; then
    echo "✗ ERROR: missing /lib/preinit/81_rc_common_selfheal in verified rootfs"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-preinit.XXXXXX)
  if ! extract_rootfs_member "lib/preinit/81_rc_common_selfheal" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /lib/preinit/81_rc_common_selfheal for preinit verification"
    exit 1
  fi

  if ! grep -Fqx 'boot_hook_add preinit_main do_rc_common_selfheal' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal is not registered on preinit_main after mount_root restore"
    exit 1
  fi

  if grep -Fq 'boot_hook_add preinit_mount_root do_rc_common_selfheal' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal still runs on preinit_mount_root before sysupgrade config restore"
    exit 1
  fi

  if ! grep -Fq 'etc/inittab:0644' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/inittab"
    exit 1
  fi

  if ! grep -Fq 'etc/init.d/rcS:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/init.d/rcS"
    exit 1
  fi

  if ! grep -Fq 'etc/init.d/rc-common-selfheal:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/init.d/rc-common-selfheal"
    exit 1
  fi

  if ! grep -Fq 'etc/init.d/mgrserver:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/init.d/mgrserver"
    exit 1
  fi

  if ! grep -Fq 'etc/hotplug.d/iface/35-yushu-wan-autofit:0644' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/hotplug.d/iface/35-yushu-wan-autofit"
    exit 1
  fi

  if ! grep -Fq 'etc/hotplug.d/net/35-yushu-wan-autofit:0644' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/hotplug.d/net/35-yushu-wan-autofit"
    exit 1
  fi

  if ! grep -Fq 'etc/uci-defaults/95-yushu-default-lan:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/uci-defaults/95-yushu-default-lan"
    exit 1
  fi

  if ! grep -Fq 'etc/uci-defaults/96-ath11k-mac80211-compat:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/uci-defaults/96-ath11k-mac80211-compat"
    exit 1
  fi

  if ! grep -Fq 'etc/uci-defaults/98-disable-flow-offload-for-singbox:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/uci-defaults/98-disable-flow-offload-for-singbox"
    exit 1
  fi

  if ! grep -Fq 'etc/uci-defaults/98-home-partition:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/uci-defaults/98-home-partition"
    exit 1
  fi

  if ! grep -Fq 'etc/uci-defaults/99-mgrserver-ports:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/uci-defaults/99-mgrserver-ports"
    exit 1
  fi

  if ! grep -Fq 'etc/uci-defaults/99-restrict-admin-vpn:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/uci-defaults/99-restrict-admin-vpn"
    exit 1
  fi

  if ! grep -Fq 'etc/uci-defaults/99-service-watchdog-cron:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/uci-defaults/99-service-watchdog-cron"
    exit 1
  fi

  if ! grep -Fq 'etc/uci-defaults/99-yushu-wan-autofit:0755' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not reset stale overlay /etc/uci-defaults/99-yushu-wan-autofit"
    exit 1
  fi

  if ! grep -Fq 'boot-critical overlay repair left files unavailable after reset' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: preinit self-heal does not hard-fail when repaired boot files stay unavailable"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ preinit self-heal resets stale overlay copies of the boot-critical boot and first-boot files"
}

verify_flow_offload_guard() {
  local tmp=""

  if ! rootfs_has_entry "etc/uci-defaults/98-disable-flow-offload-for-singbox"; then
    echo "✗ ERROR: missing /etc/uci-defaults/98-disable-flow-offload-for-singbox in verified rootfs"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-disable-flow-offload.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/98-disable-flow-offload-for-singbox" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/98-disable-flow-offload-for-singbox for verification"
    exit 1
  fi

  if ! head -n 1 "$tmp" | grep -Fqx '#!/bin/sh'; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/98-disable-flow-offload-for-singbox is not a shell script"
    exit 1
  fi

  if ! grep -Fq "flow_offloading='0'" "$tmp" || ! grep -Fq "flow_offloading_hw='0'" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/98-disable-flow-offload-for-singbox does not disable firewall flow offload"
    exit 1
  fi

  if ! grep -Fq '/etc/init.d/firewall restart' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/98-disable-flow-offload-for-singbox does not restart firewall after disabling offload"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ /etc/uci-defaults/98-disable-flow-offload-for-singbox disables flow offload for sing-box"
}

verify_mgrserver_flow_offload_guard() {
  local tmp=""

  if ! rootfs_has_entry "etc/init.d/mgrserver"; then
    echo "✗ ERROR: missing /etc/init.d/mgrserver in verified rootfs"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-mgrserver-flow-offload.XXXXXX)
  if ! extract_rootfs_member "etc/init.d/mgrserver" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/init.d/mgrserver for flow-offload guard verification"
    exit 1
  fi

  if ! grep -Fq 'ensure_flow_offload_disabled()' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/mgrserver does not define a flow-offload guard"
    exit 1
  fi

  if ! grep -Fq "flow_offloading='0'" "$tmp" || ! grep -Fq "flow_offloading_hw='0'" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/mgrserver flow-offload guard does not disable both offload flags"
    exit 1
  fi

  if ! sed -n '/^start_service()/,/^}/p' "$tmp" | grep -Fq 'ensure_flow_offload_disabled'; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/mgrserver does not invoke flow-offload guard from start_service"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ /etc/init.d/mgrserver keeps firewall flow offload disabled before starting"
}

verify_mgrserver_health_check() {
  local tmp=""

  if ! rootfs_has_entry "etc/init.d/mgrserver"; then
    echo "✗ ERROR: missing /etc/init.d/mgrserver in verified rootfs"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-mgrserver-init.XXXXXX)
  if ! extract_rootfs_member "etc/init.d/mgrserver" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/init.d/mgrserver for health-check verification"
    exit 1
  fi

  if ! grep -Fq 'HEALTH_CHECK_URL="http://127.0.0.1:%s/api/config"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/mgrserver does not target lightweight /api/config liveness"
    exit 1
  fi

  if ! head -n 1 "$tmp" | grep -Fqx '#!/bin/sh /rom/etc/rc.common'; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/mgrserver is not pinned to /rom/etc/rc.common"
    exit 1
  fi

  if ! grep -Fq 'HEALTH_CHECK_PATTERN=' "$tmp" || ! grep -Fq 'grep -Fq "$HEALTH_CHECK_PATTERN"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/mgrserver liveness check does not validate the config response"
    exit 1
  fi

  if ! grep -Fq 'respawn ${respawn_threshold:-300} ${respawn_timeout:-5} ${respawn_retry:-5}' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/mgrserver does not use the documented five-minute respawn window"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ /etc/init.d/mgrserver uses the lightweight config liveness check"
}

verify_health_check_script() {
  local tmp=""

  if ! rootfs_has_entry "usr/bin/health-check"; then
    echo "✗ ERROR: missing /usr/bin/health-check in verified rootfs"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-health-check.XXXXXX)
  if ! extract_rootfs_member "usr/bin/health-check" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /usr/bin/health-check for verification"
    exit 1
  fi

  if ! grep -Fq 'http://127.0.0.1:${MGR_PORT}/api/health' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/health-check does not target /api/health"
    exit 1
  fi

  if grep -Fq 'http://127.0.0.1:${MGR_PORT}/health' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/health-check still targets the stale /health endpoint"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ /usr/bin/health-check targets the expected /api/health endpoint"
}

verify_rc_common_selfheal_script() {
  local tmp=""

  if ! rootfs_has_entry "etc/init.d/rc-common-selfheal"; then
    echo "✗ ERROR: missing /etc/init.d/rc-common-selfheal in verified rootfs"
    exit 1
  fi

  tmp=$(mktemp /tmp/rootfs-rc-common-selfheal.XXXXXX)
  if ! extract_rootfs_member "etc/init.d/rc-common-selfheal" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/init.d/rc-common-selfheal for verification"
    exit 1
  fi

  if ! head -n 1 "$tmp" | grep -Fqx '#!/bin/sh /rom/etc/rc.common'; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/rc-common-selfheal is not pinned to /rom/etc/rc.common"
    exit 1
  fi

  if grep -Fq 'cp "$ROM_RC_COMMON" /etc/rc.common' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/rc-common-selfheal still writes directly into merged /etc/rc.common"
    exit 1
  fi

  if ! grep -Fq '/etc/rc.common is still missing after overlay repair' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/init.d/rc-common-selfheal does not hard-fail when /etc/rc.common stays missing"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ /etc/init.d/rc-common-selfheal fails loudly if merged /etc/rc.common stays missing"
}

verify_uci_defaults_boot_semantics() {
  local tmp=""

  tmp=$(mktemp /tmp/rootfs-yushu-default-lan.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/95-yushu-default-lan" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/95-yushu-default-lan for boot-semantics verification"
    exit 1
  fi

  if grep -Fq 'rm -f "$0"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/95-yushu-default-lan still tries to self-delete via \$0"
    exit 1
  fi

  if ! grep -Fq 'DEFAULT_LAN_IP="10.10.10.1"' "$tmp" || \
     ! grep -Fq '192.168.1.1' "$tmp" || \
     ! grep -Fq 'network.lan.ipaddr="$DEFAULT_LAN_IP"' "$tmp" || \
     ! grep -Fq 'address=/yushu-router/${lan_ip}' "$tmp" || \
     ! grep -Fq 'lan_ip="${raw_lan_ip%%/*}"' "$tmp" || \
     ! grep -Fq 'RC_COMMON="/rom/etc/rc.common"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/95-yushu-default-lan does not pin LAN and router DNS defaults"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-ath11k-defaults.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/96-ath11k-mac80211-compat" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/96-ath11k-mac80211-compat for boot-semantics verification"
    exit 1
  fi

  if grep -Fq 'rm -f "$0"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/96-ath11k-mac80211-compat still tries to self-delete via \$0"
    exit 1
  fi

  if grep -Eq '(^|[[:space:]])(cp|mv|sed|perl|awk)[[:space:]].*mac80211\.sh|>>?[[:space:]].*mac80211\.sh|mac80211\.sh.*>>?' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/96-ath11k-mac80211-compat still mutates the runtime mac80211.sh in overlay"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-home-defaults.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/98-home-partition" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/98-home-partition for boot-semantics verification"
    exit 1
  fi

  if grep -Fq 'rm -f "$0"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/98-home-partition still tries to self-delete via \$0"
    exit 1
  fi

  if grep -Fq 'mountpoint -q "$TARGET"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/98-home-partition still depends on mountpoint(1)"
    exit 1
  fi

  if ! grep -Fq 'mounted_source_for_target()' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/98-home-partition does not use /proc/mounts-based mount detection"
    exit 1
  fi

  if ! grep -Fq 'apply_pxe_setup()' "$tmp" || \
     ! grep -Fq '[ -f "$script" ]' "$tmp" || \
     ! grep -Fq 'OFFLINE_STRICT=true QUIET=1 /bin/sh "$script"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/98-home-partition does not apply PXE setup in offline mode"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-ports-defaults.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/99-mgrserver-ports" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/99-mgrserver-ports for boot-semantics verification"
    exit 1
  fi

  if grep -Fq 'rm -f "$0"' "$tmp" || grep -Fq 'trap cleanup EXIT' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports still tries to self-delete via \$0"
    exit 1
  fi

  if grep -En '^[[:space:]]*uci -q (delete|del_list) ' "$tmp" | grep -Ev '\|\| true([[:space:]]|$)' >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports still has bare uci -q delete/del_list calls under set -e"
    exit 1
  fi

  if grep -Fq 'for entry in $LISTENS_RAW' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports still splits nginx listen entries on shell whitespace"
    exit 1
  fi

  if ! grep -Fq 'config_list_foreach "$section" listen rewrite_nginx_listen_entry' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports does not preserve full nginx listen list values"
    exit 1
  fi

  if ! grep -Fq 'first_token="${entry%% *}"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports does not isolate the nginx listen address token before rewriting"
    exit 1
  fi

  if ! grep -Fq 'ensure_mgrserver_started' "$tmp" || ! grep -Fq 'run_init_script mgrserver start' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports does not start MgrServer during the first boot pass"
    exit 1
  fi

  if grep -Fq 'run_init_script mgrserver restart' "$tmp" || grep -Fq 'run_init_script mgrserver health_check' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports blocks first boot on MgrServer restart/health_check"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-wan-autofit-defaults.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/99-yushu-wan-autofit" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/99-yushu-wan-autofit for boot-semantics verification"
    exit 1
  fi

  if grep -Fq 'rm -f "$0"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-yushu-wan-autofit still tries to self-delete via \$0"
    exit 1
  fi

  if ! grep -Fq 'CRON_LINE="* * * * * /usr/bin/yushu-wan-autofit --once"' "$tmp" || \
     ! grep -Fq '/usr/bin/yushu-wan-autofit --boot' "$tmp" || \
     ! grep -Fq ') >/dev/null 2>&1 &' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-yushu-wan-autofit does not install non-blocking boot/cron probes"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-wan-autofit-hotplug.XXXXXX)
  if ! extract_rootfs_member "usr/bin/yushu-wan-autofit-hotplug" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /usr/bin/yushu-wan-autofit-hotplug for boot-semantics verification"
    exit 1
  fi

  if ! grep -Fq 'AUTOFIT="/usr/bin/yushu-wan-autofit"' "$tmp" || \
     ! grep -Fq 'LOCK_DIR="/tmp/yushu-wan-autofit.lock"' "$tmp" || \
     ! grep -Fq 'PENDING_DIR="/tmp/yushu-wan-autofit.hotplug.pending"' "$tmp" || \
     ! grep -Fq 'YUSHU_WAN_AUTOFIT_HOTPLUG_DELAY_SECONDS' "$tmp" || \
     ! grep -Fq '[ -d "$LOCK_DIR" ]' "$tmp" || \
     ! grep -Fq 'trap cleanup EXIT INT TERM' "$tmp" || \
     ! grep -Fq '"$AUTOFIT" --once' "$tmp" || \
     grep -Fq '"$AUTOFIT" --force' "$tmp" || \
     grep -A 1 -F 'sleep "$delay"' "$tmp" | grep -Fq 'rmdir "$PENDING_DIR" 2>/dev/null || true'; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/yushu-wan-autofit-hotplug does not retain pending state and schedule lock-aware once probes"
    exit 1
  fi

  rm -f "$tmp"

  for rel in "etc/hotplug.d/iface/35-yushu-wan-autofit" "etc/hotplug.d/net/35-yushu-wan-autofit"; do
    tmp=$(mktemp /tmp/rootfs-wan-autofit-hotplug-wrapper.XXXXXX)
    if ! extract_rootfs_member "$rel" "$tmp"; then
      rm -f "$tmp"
      echo "✗ ERROR: failed to extract /$rel for boot-semantics verification"
      exit 1
    fi

    if ! grep -Fq '/usr/bin/yushu-wan-autofit-hotplug' "$tmp"; then
      rm -f "$tmp"
      echo "✗ ERROR: /$rel does not invoke yushu-wan-autofit-hotplug"
      exit 1
    fi

    rm -f "$tmp"
  done

  tmp=$(mktemp /tmp/rootfs-wan-autofit.XXXXXX)
  if ! extract_rootfs_member "usr/bin/yushu-wan-autofit" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /usr/bin/yushu-wan-autofit for boot-semantics verification"
    exit 1
  fi

  if ! grep -Fq 'wan_is_healthy()' "$tmp" || \
     ! grep -Fq 'gateway_l2_ok()' "$tmp" || \
     ! grep -Fq 'candidate_is_safe()' "$tmp" || \
     ! grep -Fq 'reload_network_config()' "$tmp" || \
     ! grep -Fq 'recent_failed_scan_matches()' "$tmp" || \
     ! grep -Fq 'YUSHU_WAN_AUTOFIT_SCAN_COOLDOWN_SECONDS' "$tmp" || \
     ! grep -Fq 'set_br_lan_ports_for_candidate()' "$tmp" || \
     ! grep -Fq 'local candidate_applied=0' "$tmp" || \
     ! grep -Fq 'if [ "$candidate_applied" -eq 1 ]; then' "$tmp" || \
     ! grep -Fq 'PHYSICAL_WAN="${YUSHU_WAN_AUTOFIT_PHYSICAL_WAN:-wan}"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/yushu-wan-autofit does not contain conservative WAN candidate probing"
    exit 1
  fi

  if ! awk '
    /if \[ "\$candidate_applied" -eq 1 \]; then/ { conditional_restore = 1 }
    conditional_restore && /restore_original_config / { found_restore = 1 }
    END { exit found_restore ? 0 : 1 }
  ' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/yushu-wan-autofit does not restore only after a candidate was applied"
    exit 1
  fi

  if ! awk '
    /recent_failed_scan_matches "\$signature"/ { checked_cooldown = 1 }
    checked_cooldown && /if ifup wan/ { ifup_after_cooldown = 1 }
    END { exit ifup_after_cooldown ? 0 : 1 }
  ' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/yushu-wan-autofit does not check cooldown before resetting WAN"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ uci-defaults rely on boot-managed cleanup and avoid mountpoint(1) dependencies"
}

verify_rom_rc_common_runtime_calls() {
  local tmp=""

  tmp=$(mktemp /tmp/rootfs-default-lan-runtime.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/95-yushu-default-lan" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/95-yushu-default-lan for runtime-call verification"
    exit 1
  fi

  if ! grep -Fq 'RC_COMMON="/rom/etc/rc.common"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/95-yushu-default-lan does not pin init-script calls to /rom/etc/rc.common"
    exit 1
  fi

  if grep -Eq '(^|[^/])/etc/init\.d/(network|dnsmasq) (reload|restart)' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/95-yushu-default-lan still directly executes init scripts that depend on /etc/rc.common"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-ath11k.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/96-ath11k-mac80211-compat" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/96-ath11k-mac80211-compat for runtime-call verification"
    exit 1
  fi

  if ! grep -Fq '/bin/sh /rom/etc/rc.common /etc/init.d/rc-common-selfheal enable' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/96-ath11k-mac80211-compat does not enable rc-common-selfheal via /rom/etc/rc.common"
    exit 1
  fi

  if grep -Eq '^[[:space:]]*/etc/init\.d/rc-common-selfheal enable' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/96-ath11k-mac80211-compat still directly executes /etc/init.d/rc-common-selfheal"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-ports.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/99-mgrserver-ports" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/99-mgrserver-ports for runtime-call verification"
    exit 1
  fi

  if ! grep -Fq 'RC_COMMON="/rom/etc/rc.common"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports does not pin init-script calls to /rom/etc/rc.common"
    exit 1
  fi

  if grep -Eq '(^|[^/])/etc/init\.d/(mgrserver|uhttpd|nginx) (enable|start|restart|health_check|enabled)' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-mgrserver-ports still directly executes init scripts that depend on /etc/rc.common"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-watchdog.XXXXXX)
  if ! extract_rootfs_member "usr/bin/service-watchdog" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /usr/bin/service-watchdog for runtime-call verification"
    exit 1
  fi

  if ! grep -Fq 'RC_COMMON="/rom/etc/rc.common"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/service-watchdog does not pin init-script calls to /rom/etc/rc.common"
    exit 1
  fi

  if grep -Fq '/etc/init.d/mgrserver health_check' "$tmp" || grep -Fq '/etc/init.d/mgrserver restart' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/service-watchdog still directly executes /etc/init.d/mgrserver"
    exit 1
  fi

  if ! sed -n '/^restart_service()/,/^}/p' "$tmp" | grep -Fq 'run_init_script "$name" "$check_action"'; then
    rm -f "$tmp"
    echo "✗ ERROR: /usr/bin/service-watchdog does not verify service health after restart"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-cron.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/99-service-watchdog-cron" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/99-service-watchdog-cron for runtime-call verification"
    exit 1
  fi

  if ! grep -Fq 'RC_COMMON="/rom/etc/rc.common"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-service-watchdog-cron does not pin cron init-script calls to /rom/etc/rc.common"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-wan-autofit-cron.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/99-yushu-wan-autofit" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/99-yushu-wan-autofit for runtime-call verification"
    exit 1
  fi

  if ! grep -Fq 'RC_COMMON="/rom/etc/rc.common"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/99-yushu-wan-autofit does not pin cron init-script calls to /rom/etc/rc.common"
    exit 1
  fi

  rm -f "$tmp"

  tmp=$(mktemp /tmp/rootfs-home.XXXXXX)
  if ! extract_rootfs_member "etc/uci-defaults/98-home-partition" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract /etc/uci-defaults/98-home-partition for runtime-call verification"
    exit 1
  fi

  if ! grep -Fq "RC_COMMON='/rom/etc/rc.common'" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: /etc/uci-defaults/98-home-partition does not pin fstab init-script calls to /rom/etc/rc.common"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ custom runtime scripts pin init-script calls to /rom/etc/rc.common when merged /etc/rc.common is absent"
}

verify_pxe_download_engine() {
  local tmp=""

  tmp=$(mktemp /tmp/rootfs-pxe-updater.XXXXXX)
  if ! extract_rootfs_member "usr/share/mgrserver-defaults/res/pxe/up_pxe_res.sh" "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: failed to extract PXE updater for download-engine verification"
    exit 1
  fi

  if ! grep -Fq 'command -v aria2c >/dev/null 2>&1 || fail "aria2c is required but not installed."' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE updater does not hard-require aria2c"
    exit 1
  fi

  if ! grep -Fq 'aria2c \' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE updater does not download through aria2c"
    exit 1
  fi

  if grep -Eq '(^|[[:space:]])wget([[:space:]]|$)' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE updater still uses wget for metadata or Boot.iso downloads"
    exit 1
  fi

  if ! grep -Fq 'is_active_updater_pid()' "$tmp" || \
     ! grep -Fq '"/proc/$pid/cmdline"' "$tmp" || \
     ! grep -Fq '"/up_pxe_res.sh"' "$tmp"; then
    rm -f "$tmp"
    echo "✗ ERROR: PXE updater does not validate stale lock PID command lines"
    exit 1
  fi

  rm -f "$tmp"
  echo "✓ PXE updater uses aria2c instead of wget for remote downloads"
}

verify_rcs_boot_wrapper
verify_preinit_overlay_boot_repair
verify_mgrserver_health_check
verify_flow_offload_guard
verify_mgrserver_flow_offload_guard
verify_health_check_script
verify_rc_common_selfheal_script
verify_uci_defaults_boot_semantics
verify_rom_rc_common_runtime_calls
verify_pxe_defaults_runtime_assets
verify_pxe_download_engine

require_prebuilt_manifest_dependencies "$WORKSPACE_ROOT/prebuilt-ipk-metadata.txt"
require_rootfs_elf_runtime "usr/bin/sing-box"
require_rootfs_elf_runtime "usr/bin/easytier-core"
require_rootfs_elf_runtime "usr/bin/easytier-cli"
require_rootfs_elf_runtime "usr/bin/easytier-web"
require_rootfs_elf_runtime "usr/bin/wimlib-imagex"
require_rootfs_elf_runtime "usr/bin/aria2c"

FACTORY_HEADER_TMP=$(mktemp -d /tmp/openwrt-factory-header-check.XXXXXX)
verify_factory_header "$FACTORY" "$SYSUPGRADE" "$FACTORY_HEADER_TMP"

FACTORY_ROOTFS_TMP=$(mktemp -d /tmp/openwrt-factory-rootfs-check.XXXXXX)
if ! extract_factory_rootfs "$FACTORY" "$FACTORY_ROOTFS_TMP"; then
  rm -rf "$FACTORY_ROOTFS_TMP"
  FACTORY_ROOTFS_TMP=""
  exit 1
fi

if [ "$ROOTFS_SHA256" != "$PRIMARY_ROOTFS_SHA256" ]; then
  echo "✗ ERROR: factory rootfs payload does not match verified release rootfs"
  echo "  primary rootfs sha256: $PRIMARY_ROOTFS_SHA256"
  echo "  factory rootfs sha256: $ROOTFS_SHA256"
  exit 1
fi
echo "✓ factory rootfs payload matches verified release rootfs: $ROOTFS_SHA256"

echo ""
echo "============================================"
echo "Firmware verification complete"
echo "============================================"
