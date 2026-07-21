#!/bin/bash
# Unit tests for aella. Mocks the AWS CLI (test/bin/aws) — never touches AWS,
# never spends money. Covers the money/lockout guards and the fiddly bits
# (user-data heredocs, version picker). Run: bash test/aella.test.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
AELLA="$DIR/../aella"
PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "     $2"; FAIL=$((FAIL + 1)); }

# Fresh sandbox per test: throwaway HOME (for the state file + .ssh), a call log,
# and the fake aws first on PATH. FAKE_* env vars steer the mock.
sandbox() {
  SB=$(mktemp -d); mkdir -p "$SB/.ssh"
  export HOME="$SB" AELLA_TEST_LOG="$SB/calls.log"
  : > "$AELLA_TEST_LOG"
  unset FAKE_STATE FAKE_IP FAKE_LS_ROWS FAKE_IID FAKE_AMI
}
aella() { env PATH="$DIR/bin:$PATH" bash "$AELLA" "$@"; }
called() { grep -q "$1" "$AELLA_TEST_LOG"; }

echo "TEST: aella (mocked AWS — no real calls)"
echo

# --- dispatch / help -------------------------------------------------------
sandbox
out=$(aella help); rc=$?
{ [ $rc -eq 0 ] && [ -n "$out" ]; } && pass "help: exit 0, prints usage" || fail "help" "rc=$rc"

sandbox
out=$(aella bogus 2>/dev/null); rc=$?
{ [ $rc -eq 1 ] && [ -z "$out" ]; } && pass "unknown cmd: exit 1, help to stderr (stdout empty)" || fail "unknown cmd" "rc=$rc out='$out'"

# --- build_userdata: valid shell both ways (nested heredocs are the risk) ---
gen_ud() { # $1 = infocmp stub body
  { printf '%s\n' "$1"; sed -n '/^build_userdata()/,/^}/p' "$AELLA"; echo build_userdata; } | bash
}
ud=$(gen_ud 'infocmp() { return 1; }')
{ printf '%s' "$ud" | bash -n && printf '%s' "$ud" | grep -q force_color_prompt; } \
  && pass "build_userdata (no terminfo): valid shell + bashrc block" || fail "build_userdata no-terminfo"
ud=$(gen_ud 'infocmp() { printf "xterm-ghostty,\n\tam,\n"; }')
{ printf '%s' "$ud" | bash -n && printf '%s' "$ud" | grep -q 'base64 -d'; } \
  && pass "build_userdata (terminfo): valid shell + base64 block" || fail "build_userdata terminfo"

# --- down: the destructive path -------------------------------------------
sandbox
out=$(aella down); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "no box"; } && pass "down with no box: clean 'no box'" || fail "down no box" "rc=$rc"

sandbox; echo i-abc > "$HOME/.aella-instance"
printf 'n\n' | aella down >/dev/null 2>&1
{ ! called "terminate-instances" && [ -f "$HOME/.aella-instance" ]; } \
  && pass "down answered 'n': does NOT terminate, keeps state" || fail "down 'n' safety" "terminate was called!"

sandbox; echo i-abc > "$HOME/.aella-instance"
aella down -y >/dev/null 2>&1
{ called "terminate-instances" && [ ! -f "$HOME/.aella-instance" ]; } \
  && pass "down -y: terminates, clears state" || fail "down -y"

# --- up: the orphan-billing guard -----------------------------------------
sandbox; echo i-running > "$HOME/.aella-instance"; export FAKE_STATE=running
out=$(aella up 2>&1); rc=$?
{ [ $rc -eq 1 ] && ! called "run-instances"; } \
  && pass "up with a live box: refuses, launches nothing (no orphan)" || fail "double-up guard" "rc=$rc"
unset FAKE_STATE

# --- cur_ip guard: no ssh to an empty host --------------------------------
sandbox; echo i-abc > "$HOME/.aella-instance"; export FAKE_IP=None
out=$(aella ssh 2>&1); rc=$?
{ [ $rc -eq 1 ] && echo "$out" | grep -qi "no public IP"; } \
  && pass "ssh with no public IP: exits 1, no ssh to empty host" || fail "cur_ip None guard" "rc=$rc"
unset FAKE_IP

# --- ls: tag-based listing, marks the current pointer ---------------------
sandbox
echo i-tracked > "$HOME/.aella-instance"
export FAKE_LS_ROWS="$(printf 'i-tracked\trunning\tm7i-flex.large\t1.2.3.4\t2026-07-21\ni-orphan\trunning\tc7g.large\t5.6.7.8\t2026-07-20')"
out=$(aella ls)
{ echo "$out" | grep -q '\* i-tracked' && echo "$out" | grep -q 'i-orphan'; } \
  && pass "ls: lists all aella boxes, marks current with *" || fail "ls" "$out"
unset FAKE_LS_ROWS

# --- push / pull: file transfer to the box --------------------------------
sandbox; echo i-abc > "$HOME/.aella-instance"; export FAKE_IP=9.9.9.9
: > "$SB/movie.mp4"
aella push "$SB/movie.mp4" interviews >/dev/null 2>&1
{ called "ssh .*mkdir -p .*interviews" && called "scp .*movie.mp4 ubuntu@9.9.9.9:interviews"; } \
  && pass "push: makes remote dir + scp -r to ubuntu@ip:dst" || fail "push" "$(cat "$AELLA_TEST_LOG")"

sandbox; echo i-abc > "$HOME/.aella-instance"; export FAKE_IP=9.9.9.9
aella pull out/report.html ./here >/dev/null 2>&1
called "scp .*ubuntu@9.9.9.9:out/report.html ./here" \
  && pass "pull: scp -r from box to local dest" || fail "pull" "$(cat "$AELLA_TEST_LOG")"
unset FAKE_IP

sandbox; echo i-abc > "$HOME/.aella-instance"
out=$(aella push 2>&1); rc=$?
{ [ $rc -eq 1 ] && echo "$out" | grep -q usage; } \
  && pass "push without src: usage + exit 1 (no transfer attempted)" || fail "push no-arg" "rc=$rc"

# --- version picker: highest wins, portable ------------------------------
ver=$( { sed -n '/^latest_ubuntu_version()/,/^}/p' "$AELLA"; echo latest_ubuntu_version; } \
       | env PATH="$DIR/bin:$PATH" bash )
[ "$ver" = "25.04" ] && pass "latest_ubuntu_version: picks highest (25.04)" || fail "version picker" "got '$ver'"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
