#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIRMWARE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
AUTOFIT="$FIRMWARE_DIR/files/usr/bin/yushu-wan-autofit"
HOTPLUG="$FIRMWARE_DIR/files/usr/bin/yushu-wan-autofit-hotplug"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yushu-wan-autofit-test.XXXXXX")
AUTOFIT_LIB="$TEST_DIR/yushu-wan-autofit.lib"
HOTPLUG_TEST="$TEST_DIR/yushu-wan-autofit-hotplug"
AUTOFIT_STUB="$TEST_DIR/autofit"
LOCK_DIR="$TEST_DIR/lock"
PENDING_DIR="$TEST_DIR/pending"

cleanup() {
  rm -rf "$TEST_DIR"
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

wait_for_file() {
  file="$1"
  attempts=0

  while [ ! -f "$file" ] && [ "$attempts" -lt 5 ]; do
    sleep 1
    attempts=$((attempts + 1))
  done

  [ -f "$file" ]
}

trap cleanup EXIT INT TERM

sed '$d' "$AUTOFIT" > "$AUTOFIT_LIB"

if (
  . "$AUTOFIT_LIB"
  take_lock() { :; }
  current_wan_device() { printf '%s\n' wan; }
  wait_wan_healthy() { return 1; }
  candidate_carrier_signature() { printf '%s\n' unchanged; }
  recent_failed_scan_matches() { return 1; }
  find_br_lan_section() { return 0; }
  br_lan_ports() { return 0; }
  dev_exists() { return 1; }
  record_failed_scan() { :; }
  restore_original_config() { : > "$TEST_DIR/restored"; }
  reload_network_config() { : > "$TEST_DIR/reloaded"; }
  log_msg() { :; }
  uci() { return 0; }
  CANDIDATES="lan1 lan2"
  main --once
); then
  fail "all-skipped scan unexpectedly succeeded"
fi

[ ! -e "$TEST_DIR/restored" ] || fail "all-skipped scan restored the original configuration"
[ ! -e "$TEST_DIR/reloaded" ] || fail "all-skipped scan reloaded the network"

if (
  . "$AUTOFIT_LIB"
  take_lock() { :; }
  current_wan_device() { printf '%s\n' wan; }
  wait_wan_healthy() { return 1; }
  candidate_carrier_signature() { printf '%s\n' changed; }
  recent_failed_scan_matches() { return 1; }
  find_br_lan_section() { printf '%s\n' br_lan; }
  br_lan_ports() { printf '%s\n' 'lan1 lan2'; }
  try_candidate() { candidate_applied=1; return 1; }
  restore_original_config() { : > "$TEST_DIR/applied-restored"; }
  record_failed_scan() { :; }
  log_msg() { :; }
  uci() { return 0; }
  CANDIDATES="lan1"
  main --once
); then
  fail "applied candidate failure unexpectedly succeeded"
fi

[ -e "$TEST_DIR/applied-restored" ] || fail "applied candidate failure did not restore the original configuration"

if ! (
  . "$AUTOFIT_LIB"
  take_lock() { :; }
  current_wan_device() { printf '%s\n' wan; }
  wait_wan_healthy() { return 1; }
  candidate_carrier_signature() { printf '%s\n' unchanged; }
  recent_failed_scan_matches() { return 0; }
  ifup() { : > "$TEST_DIR/ifup-called"; }
  log_msg() { :; }
  main --once
); then
  fail "cooldown scan unexpectedly failed"
fi

[ ! -e "$TEST_DIR/ifup-called" ] || fail "cooldown scan ran ifup wan"

sed \
  -e "s|^AUTOFIT=.*|AUTOFIT=\"$AUTOFIT_STUB\"|" \
  -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$LOCK_DIR\"|" \
  -e "s|^PENDING_DIR=.*|PENDING_DIR=\"$PENDING_DIR\"|" \
  "$HOTPLUG" > "$HOTPLUG_TEST"
chmod +x "$HOTPLUG_TEST"

printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$TEST_DIR/autofit.args"' > "$AUTOFIT_STUB"
chmod +x "$AUTOFIT_STUB"
mkdir "$LOCK_DIR"
ACTION=ifup INTERFACE=wan YUSHU_WAN_AUTOFIT_HOTPLUG_DELAY_SECONDS=0 "$HOTPLUG_TEST"
[ ! -e "$TEST_DIR/autofit.args" ] || fail "active auto-fit lock still scheduled a hotplug probe"
[ ! -d "$PENDING_DIR" ] || fail "active auto-fit lock left pending state behind"
rmdir "$LOCK_DIR"

export TEST_DIR PENDING_DIR
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" > "$TEST_DIR/autofit.args"' \
  'printf "run\n" >> "$TEST_DIR/autofit.runs"' \
  'if [ -d "$PENDING_DIR" ]; then : > "$TEST_DIR/pending-during-run"; else : > "$TEST_DIR/pending-missing"; fi' \
  'while [ ! -f "$TEST_DIR/allow-autofit-exit" ]; do sleep 1; done' \
  'if [ -d "$PENDING_DIR" ]; then : > "$TEST_DIR/autofit-finished"; else : > "$TEST_DIR/pending-removed-early"; fi' \
  > "$AUTOFIT_STUB"
chmod +x "$AUTOFIT_STUB"
ACTION=ifup INTERFACE=wan YUSHU_WAN_AUTOFIT_HOTPLUG_DELAY_SECONDS=0 "$HOTPLUG_TEST"

wait_for_file "$TEST_DIR/pending-during-run" || fail "hotplug probe did not start"
[ -d "$PENDING_DIR" ] || fail "pending state was removed before auto-fit completed"
ACTION=ifupdate INTERFACE=wan YUSHU_WAN_AUTOFIT_HOTPLUG_DELAY_SECONDS=0 "$HOTPLUG_TEST"
[ "$(wc -l < "$TEST_DIR/autofit.runs" | tr -d ' ')" = "1" ] || fail "coalesced hotplug event started a second auto-fit run"
: > "$TEST_DIR/allow-autofit-exit"
wait_for_file "$TEST_DIR/autofit-finished" || fail "hotplug auto-fit did not complete"
sleep 1
[ ! -d "$PENDING_DIR" ] || fail "pending state remained after auto-fit completed"
[ "$(cat "$TEST_DIR/autofit.args")" = "--once" ] || fail "hotplug probe did not use --once"
[ ! -e "$TEST_DIR/pending-missing" ] || fail "pending state was missing while auto-fit ran"
[ ! -e "$TEST_DIR/pending-removed-early" ] || fail "pending state was removed before auto-fit completed"

echo "PASS: WAN auto-fit regression checks"
