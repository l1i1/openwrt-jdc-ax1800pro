#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PREBUILT_IPK_METADATA="$WORKSPACE_ROOT/prebuilt-ipk-metadata.txt"

echo "============================================"
echo "Extracting prebuilt IPKs into files/ overlay"
echo "============================================"

mkdir -p "$WORKSPACE_ROOT/files/usr"
: > "$PREBUILT_IPK_METADATA"

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

download_with_retry() {
  local url="$1"
  local output="$2"
  local expected_sha256="${3:-}"
  local max_retries=3
  local retry_delay=10
  local actual_sha256=""

  for i in $(seq 1 "$max_retries"); do
    echo "Downloading (attempt $i/$max_retries): $url"
    if curl -sL --connect-timeout 30 --max-time 300 --retry 2 "$url" -o "$output"; then
      if [ -s "$output" ]; then
        if [ -n "$expected_sha256" ]; then
          actual_sha256=$(compute_file_sha256 "$output")
          if [ "$actual_sha256" != "$expected_sha256" ]; then
            echo "  ✗ SHA256 mismatch for $(basename "$output")"
            echo "    expected: $expected_sha256"
            echo "    actual:   $actual_sha256"
            rm -f "$output"
          else
            echo "  ✓ Download successful: $(du -h "$output" | cut -f1)"
            echo "    sha256: $actual_sha256"
            return 0
          fi
        else
          echo "  ✓ Download successful: $(du -h "$output" | cut -f1)"
          return 0
        fi
      fi
    fi
    echo "  ✗ Download failed, retrying in ${retry_delay}s..."
    sleep "$retry_delay"
  done

  echo "ERROR: Failed to download after $max_retries attempts: $url"
  return 1
}

extract_ipk() {
  local ipk_path="$1"
  local dest="$2"
  local expected_files="$3"
  local package_name=""
  local package_arch=""
  local package_depends=""

  if [ ! -f "$ipk_path" ]; then
    echo "ERROR: IPK file not found: $ipk_path"
    return 1
  fi

  echo "Extracting: $(basename "$ipk_path")"
  rm -rf /tmp/ipk-work
  mkdir -p /tmp/ipk-work
  if ! tar -xzf "$ipk_path" -C /tmp/ipk-work/; then
    echo "ERROR: Failed to extract IPK outer archive"
    rm -rf /tmp/ipk-work
    return 1
  fi

  if [ ! -f /tmp/ipk-work/data.tar.gz ] || [ ! -f /tmp/ipk-work/control.tar.gz ]; then
    echo "ERROR: data.tar.gz or control.tar.gz not found in IPK"
    rm -rf /tmp/ipk-work
    return 1
  fi

  mkdir -p /tmp/ipk-work/control
  if ! tar -xzf /tmp/ipk-work/control.tar.gz -C /tmp/ipk-work/control/; then
    echo "ERROR: Failed to extract control.tar.gz"
    rm -rf /tmp/ipk-work
    return 1
  fi

  if [ ! -f /tmp/ipk-work/control/control ]; then
    echo "ERROR: control metadata not found in IPK"
    rm -rf /tmp/ipk-work
    return 1
  fi

  package_name=$(sed -n 's/^Package:[[:space:]]*//p' /tmp/ipk-work/control/control | head -1)
  package_arch=$(sed -n 's/^Architecture:[[:space:]]*//p' /tmp/ipk-work/control/control | head -1)
  package_depends=$(sed -n 's/^Depends:[[:space:]]*//p' /tmp/ipk-work/control/control | head -1)

  if [ -z "$package_name" ] || [ -z "$package_arch" ]; then
    echo "ERROR: IPK metadata is missing Package or Architecture"
    rm -rf /tmp/ipk-work
    return 1
  fi

  case "$package_arch" in
    aarch64_cortex-a53|all)
      ;;
    *)
      echo "ERROR: Unsupported IPK architecture for $package_name: $package_arch"
      rm -rf /tmp/ipk-work
      return 1
      ;;
  esac

  if ! tar -xzf /tmp/ipk-work/data.tar.gz -C "$dest/"; then
    echo "ERROR: Failed to extract data.tar.gz"
    rm -rf /tmp/ipk-work
    return 1
  fi

  rm -rf /tmp/ipk-work

  for f in $expected_files; do
    if [ ! -e "$dest/$f" ]; then
      echo "ERROR: Expected file not found after extraction: $dest/$f"
      return 1
    fi
  done

  printf '%s\t%s\t%s\n' "$package_name" "$package_arch" "$package_depends" >> "$PREBUILT_IPK_METADATA"
  echo "  ✓ Extraction successful"
  return 0
}

EASYTIER_VER="v2.5.0"
EASYTIER_URL="https://github.com/EasyTier/luci-app-easytier/releases/download/${EASYTIER_VER}/EasyTier-${EASYTIER_VER}-aarch64_cortex-a53-22.03.7.zip"
EASYTIER_SHA256="82448110f90cf14cb2c14a78d2beeca4b6c3884e1c1d1a9a45ba4c32b94b4421"

download_with_retry "$EASYTIER_URL" /tmp/easytier.zip "$EASYTIER_SHA256"
unzip -o /tmp/easytier.zip -d /tmp/easytier-ipk/

EASY_IPK=$(find /tmp/easytier-ipk/ -name "easytier_*.ipk" | head -1)
extract_ipk "$EASY_IPK" "$WORKSPACE_ROOT/files" \
  "usr/bin/easytier-core usr/bin/easytier-cli usr/bin/easytier-web"

LUCI_EASY_IPK=$(find /tmp/easytier-ipk/ -name "luci-app-easytier_*.ipk" | head -1)
extract_ipk "$LUCI_EASY_IPK" "$WORKSPACE_ROOT/files" \
  "usr/lib/lua/luci/controller/easytier.lua"

I18N_EASY_IPK=$(find /tmp/easytier-ipk/ -name "luci-i18n-easytier-zh-cn_*.ipk" | head -1)
if [ -n "$I18N_EASY_IPK" ]; then
  extract_ipk "$I18N_EASY_IPK" "$WORKSPACE_ROOT/files" ""
fi
rm -rf /tmp/easytier.zip /tmp/easytier-ipk/

SINGBOX_VER="1.13.19"
SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box_${SINGBOX_VER}_openwrt_aarch64_cortex-a53.ipk"
SINGBOX_SHA256="55cd213e8f524be4c9ddadc45f2d3202531c6179ba76bee5ecea9d64fd1b251f"

download_with_retry "$SINGBOX_URL" /tmp/sing-box.ipk "$SINGBOX_SHA256"
extract_ipk /tmp/sing-box.ipk "$WORKSPACE_ROOT/files" \
  "usr/bin/sing-box"
rm -f /tmp/sing-box.ipk

echo ""
echo "============================================"
echo "Prebuilt files summary:"
echo "============================================"
echo "IPK metadata:"
cat "$PREBUILT_IPK_METADATA"
echo ""
echo "Binaries:"
ls -lh "$WORKSPACE_ROOT/files/usr/bin/" 2>/dev/null || true
echo ""
echo "LuCI plugins:"
ls -la "$WORKSPACE_ROOT/files/usr/lib/lua/luci/controller/" 2>/dev/null || true
echo ""
echo "Sizes:"
du -sh "$WORKSPACE_ROOT/files/usr/bin/" 2>/dev/null || true
