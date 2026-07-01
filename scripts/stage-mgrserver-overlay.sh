#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MGRSERVER_SRC="${1:-$WORKSPACE_ROOT/mgrserver-src}"
FILES_ROOT="${2:-$WORKSPACE_ROOT/files}"
CLEAR_SCRIPT="$WORKSPACE_ROOT/scripts/clear-mgrserver-runtime-overlay.sh"
MGR_DEST="$FILES_ROOT/root/mgrserver"
PXE_DEST="$FILES_ROOT/usr/share/mgrserver-defaults/res/pxe"
PXE_SRC="$MGRSERVER_SRC/pxe-server"
FIRMWARE_VERSION_DEST="$FILES_ROOT/etc/mgrserver/firmware_version"

if [ ! -d "$MGRSERVER_SRC" ]; then
  echo "ERROR: MgrServer source directory not found: $MGRSERVER_SRC" >&2
  exit 1
fi

mkdir -p "$FILES_ROOT"
bash "$CLEAR_SCRIPT" "$FILES_ROOT"

cd "$MGRSERVER_SRC"

echo "Installing MgrServer dependencies (for build only)..."
pnpm install --frozen-lockfile

echo "Building contracts..."
pnpm --filter @mgr/contracts build

echo "Building web frontend..."
pnpm --filter @mgr/web build

echo "Building standalone bundle..."
pnpm --filter @mgr/server bundle:obf

echo "Staging MgrServer runtime..."
mkdir -p "$MGR_DEST/bundle"
cp packages/server/dist-bundle/index.cjs "$MGR_DEST/bundle/"
cp packages/server/commands.json "$MGR_DEST/"
[ -f packages/server/.mgrserver-first-start ] && cp packages/server/.mgrserver-first-start "$MGR_DEST/"

if [ -d packages/web/dist ]; then
  cp -r packages/web/dist "$MGR_DEST/web-dist"
else
  echo "ERROR: packages/web/dist not found after build" >&2
  exit 1
fi

if [ -n "${FIRMWARE_VERSION_CODE:-}" ]; then
  if ! printf '%s' "$FIRMWARE_VERSION_CODE" | grep -Eq '^[0-9]+$'; then
    echo "ERROR: FIRMWARE_VERSION_CODE must be numeric: $FIRMWARE_VERSION_CODE" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$FIRMWARE_VERSION_DEST")"
  printf '%s\n' "$FIRMWARE_VERSION_CODE" > "$FIRMWARE_VERSION_DEST"
  echo "Firmware version staged: $FIRMWARE_VERSION_CODE"
else
  echo "FIRMWARE_VERSION_CODE not set; keeping existing firmware_version overlay"
fi

cd "$MGR_DEST"

echo "MgrServer staged at: $MGR_DEST"
du -sh "$MGR_DEST"

if [ ! -d "$PXE_SRC/pxe" ]; then
  echo "ERROR: No PXE resources found at $PXE_SRC/pxe" >&2
  exit 1
fi

echo "Staging PXE resources..."
mkdir -p "$PXE_DEST"
cp -a "$PXE_SRC/pxe/." "$PXE_DEST/"

if [ ! -s "$PXE_DEST/config.ini" ]; then
  cat > "$PXE_DEST/config.ini" <<'EOF'
[Auto]
Mode = 3

[OS]
FileName =
Index = 7
Unattend = 1
KeepDesktop = 1
InjectVmd = 1
EOF
fi

if [ ! -d "$PXE_DEST/tftpboot" ]; then
  echo "ERROR: PXE tftpboot defaults missing after staging: $PXE_DEST/tftpboot" >&2
  exit 1
fi

if [ -d "$PXE_DEST/res" ]; then
  (
    cd "$PXE_DEST/res"
    find . -type f | sed 's|^\./||' | sort > filelist.txt
  )
fi

if [ -d "$PXE_SRC/util" ]; then
  mkdir -p "$PXE_DEST/util"
  find "$PXE_SRC/util" -maxdepth 1 -type f -name "*.sh" -exec cp {} "$PXE_DEST/util/" \;
fi

[ -f "$PXE_SRC/set_pxe.sh" ] && cp "$PXE_SRC/set_pxe.sh" "$PXE_DEST/"
[ -f "$PXE_SRC/up_pxe_res.sh" ] && cp "$PXE_SRC/up_pxe_res.sh" "$PXE_DEST/"

find "$PXE_DEST" -name "*.sh" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
find "$PXE_DEST" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

echo "PXE resources staged at: $PXE_DEST"
du -sh "$PXE_DEST"
