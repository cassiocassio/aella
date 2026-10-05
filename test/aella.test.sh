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
  export HOME="$SB" TMPDIR="$SB" AELLA_TEST_LOG="$SB/calls.log" AELLA_PW_POLL=0
  : > "$AELLA_TEST_LOG"
  unset FAKE_STATE FAKE_IP FAKE_LS_ROWS FAKE_IID FAKE_AMI FAKE_MYIP FAKE_PW FAKE_SSM FAKE_SG_CIDRS \
        FAKE_PBCOPY_FAIL FAKE_OPEN_FAIL FAKE_PW_ERR FAKE_KEYGEN_FAIL FAKE_NO_KEYPAIR FAKE_WAIT_SECS \
        AELLA_PW_TIMEOUT AELLA_DISK AELLA_TYPE AELLA_REGION
}
aella() { env PATH="$DIR/bin:$PATH" bash "$AELLA" "$@"; }
called() { grep -q "$1" "$AELLA_TEST_LOG"; }
ncalls() { grep -c "$1" "$AELLA_TEST_LOG"; }

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
gen_ud() { # $1 = infocmp stub body, $2 = login user (default ubuntu)
  { printf '%s\n' "$1"; sed -n '/^build_userdata()/,/^}/p' "$AELLA"; echo "build_userdata ${2:-ubuntu}"; } | bash
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

# --- one up/down at a time: a second one fails fast, launches nothing -------
sandbox; export FAKE_WAIT_SECS=3
aella up >/dev/null 2>&1 & bg=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$HOME/.aella-lock/pid" ] && break; sleep 0.2; done
out=$(aella up 2>&1); rc=$?
out2=$(aella down -y 2>&1); rc2=$?
wait "$bg"; rc1=$?
{ [ $rc1 -eq 0 ] && [ $rc -eq 1 ] && echo "$out" | grep -q "already running (pid " \
    && [ $rc2 -eq 1 ] && echo "$out2" | grep -q "already running" \
    && [ "$(ncalls run-instances)" -eq 1 ] && ! called terminate-instances; } \
  && pass "concurrent up/down: the second fails fast with a clear message, one launch, no terminate" \
  || fail "concurrent lock" "rc1=$rc1 rc=$rc rc2=$rc2 $out $out2 $(cat "$AELLA_TEST_LOG")"
[ ! -e "$HOME/.aella-lock" ] && [ "$(cat "$HOME/.aella-instance")" = i-newbox000 ] \
  && pass "lock: released when up finishes; the first up's box is the tracked one" || fail "lock not released"
unset FAKE_WAIT_SECS

# the test script itself stands in for a live aella holding the lock
sandbox; mkdir "$HOME/.aella-lock"; echo $$ > "$HOME/.aella-lock/pid"
out=$(aella up 2>&1); rc=$?
{ [ $rc -eq 1 ] && ! called run-instances && echo "$out" | grep -q "pid $$" \
    && [ "$(cat "$HOME/.aella-lock/pid")" = $$ ]; } \
  && pass "lock held by a live aella: refuses, launches nothing, leaves its lock alone" || fail "live lock" "rc=$rc $out"

sandbox; sh -c 'exit 0' & dead=$!; wait "$dead"
mkdir "$HOME/.aella-lock"; echo "$dead" > "$HOME/.aella-lock/pid"
out=$(aella up 2>&1); rc=$?
{ [ $rc -eq 0 ] && called run-instances && echo "$out" | grep -q "stale lock" && [ ! -e "$HOME/.aella-lock" ]; } \
  && pass "stale lock (holder died): cleared, up proceeds, lock released" || fail "stale lock" "rc=$rc $out"

sandbox; sleep 30 & other=$!
mkdir "$HOME/.aella-lock"; echo "$other" > "$HOME/.aella-lock/pid"
out=$(aella up 2>&1); rc=$?; kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
{ [ $rc -eq 0 ] && called run-instances; } \
  && pass "stale lock whose pid was reused by a non-aella process: still cleared" || fail "pid reuse" "rc=$rc $out"

sandbox; mkdir "$HOME/.aella-lock"   # no pid yet: its owner may be mid-mkdir
out=$(aella up 2>&1); rc=$?
{ [ $rc -eq 1 ] && ! called run-instances; } && pass "fresh lock with no pid yet: treated as busy" || fail "pid-less fresh lock" "rc=$rc $out"
touch -t 202001010000 "$HOME/.aella-lock"
out=$(aella up 2>&1); rc=$?
{ [ $rc -eq 0 ] && called run-instances; } && pass "old lock with no pid: treated as stale" || fail "pid-less old lock" "rc=$rc $out"

sandbox; echo i-running > "$HOME/.aella-instance"; export FAKE_STATE=running
aella up >/dev/null 2>&1
printf 'n\n' | aella down >/dev/null 2>&1
[ ! -e "$HOME/.aella-lock" ] && pass "lock: released on the refusal paths too (orphan guard, 'kept')" || fail "lock leaked on refusal"
unset FAKE_STATE

sandbox; export FAKE_WAIT_SECS=2
aella up >/dev/null 2>&1 & bg=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$HOME/.aella-lock/pid" ] && break; sleep 0.2; done
kill -TERM "$(cat "$HOME/.aella-lock/pid")"; wait "$bg"; rc=$?
{ [ $rc -ne 0 ] && [ ! -e "$HOME/.aella-lock" ]; } && pass "lock: released when up is killed mid-launch" || fail "lock leaked on TERM" "rc=$rc"
unset FAKE_WAIT_SECS

sandbox; echo i-abc > "$HOME/.aella-instance"; export FAKE_IP=9.9.9.9
mkdir "$HOME/.aella-lock"; echo $$ > "$HOME/.aella-lock/pid"
aella ssh >/dev/null 2>&1; rc=$?
{ [ $rc -eq 0 ] && called "ssh .*ubuntu@9.9.9.9"; } && pass "lock: only up/down take it — ssh works during an up" || fail "ssh blocked by lock"
unset FAKE_IP

# --- region: recorded at up, followed afterwards ---------------------------
sandbox; export AELLA_REGION=eu-west-2
aella up >/dev/null 2>&1; unset AELLA_REGION
{ called "run-instances .*@eu-west-2$" && [ "$(cat "$HOME/.aella-region" 2>/dev/null)" = eu-west-2 ]; } \
  && pass "up: launches in AELLA_REGION and records it" || fail "region record" "$(cat "$AELLA_TEST_LOG")"
sandbox; aella up >/dev/null 2>&1
[ "$(cat "$HOME/.aella-region" 2>/dev/null)" = eu-north-1 ] && pass "up: records the default region too" || fail "default region record"

sandbox; echo i-abc > "$HOME/.aella-instance"; echo eu-west-2 > "$HOME/.aella-region"; export FAKE_IP=9.9.9.9
aella ssh >/dev/null 2>&1; aella ip >/dev/null 2>&1; aella status >/dev/null 2>&1
aella push "$HOME/.aella-region" x >/dev/null 2>&1; aella pull y >/dev/null 2>&1; aella tunnel >/dev/null 2>&1
aella rdp >/dev/null 2>&1
{ called "ssh .*ubuntu@9.9.9.9" && ! grep -v '@eu-west-2$' "$AELLA_TEST_LOG" | grep -q '^ec2 '; } \
  && pass "ssh/ip/status/push/pull/tunnel/rdp: every AWS call goes to the box's recorded region" \
  || fail "follow region" "$(cat "$AELLA_TEST_LOG")"
aella down -y >/dev/null 2>&1
{ called "terminate-instances .*@eu-west-2$" && [ ! -e "$HOME/.aella-region" ] && [ ! -e "$HOME/.aella-instance" ]; } \
  && pass "down (no AELLA_REGION): terminates in the recorded region, clears the region record" \
  || fail "down region" "$(cat "$AELLA_TEST_LOG")"
unset FAKE_IP

sandbox; echo i-abc > "$HOME/.aella-instance"; echo eu-west-2 > "$HOME/.aella-region"; export AELLA_REGION=us-east-1
out=$(aella ssh 2>&1); rc=$?
out2=$(aella down -y 2>&1); rc2=$?
{ [ $rc -eq 1 ] && [ $rc2 -eq 1 ] && ! called "^ssh " && ! called terminate-instances \
    && echo "$out" | grep -q "is in eu-west-2, but AELLA_REGION=us-east-1" && echo "$out2" | grep -q "AELLA_REGION=eu-west-2 aella down" \
    && [ -s "$HOME/.aella-instance" ] && [ ! -e "$HOME/.aella-lock" ]; } \
  && pass "AELLA_REGION disagrees with the box's region: refuses (ssh, down), keeps state, says how" \
  || fail "region conflict" "rc=$rc rc2=$rc2 $out $out2"
export AELLA_REGION=eu-west-2
aella down -y >/dev/null 2>&1
called "terminate-instances .*@eu-west-2$" && pass "AELLA_REGION agreeing with the box: fine" || fail "region agree"
unset AELLA_REGION

sandbox; echo i-old > "$HOME/.aella-instance"; export AELLA_REGION=eu-west-2
aella down -y >/dev/null 2>&1; unset AELLA_REGION
called "terminate-instances .*@eu-west-2$" && pass "box tracked before regions were recorded: AELLA_REGION still applies" || fail "legacy region"
sandbox; echo i-old > "$HOME/.aella-instance"
aella down -y >/dev/null 2>&1
called "terminate-instances .*@eu-north-1$" && pass "...and with no AELLA_REGION, the default" || fail "legacy default region"

sandbox; echo i-running > "$HOME/.aella-instance"; echo eu-west-2 > "$HOME/.aella-region"; export FAKE_STATE=running
out=$(aella up 2>&1); rc=$?
{ [ $rc -eq 1 ] && ! called run-instances && called "describe-instances .*i-running.*@eu-west-2$" \
    && echo "$out" | grep -q "already exists in eu-west-2"; } \
  && pass "up in another region while the tracked box runs: the orphan guard still finds it" \
  || fail "cross-region orphan guard" "rc=$rc $out $(cat "$AELLA_TEST_LOG")"
unset FAKE_STATE

sandbox; echo i-there > "$HOME/.aella-instance"; echo eu-west-2 > "$HOME/.aella-region"
export FAKE_LS_ROWS_eu_north_1="$(printf 'i-here\trunning\tm7i-flex.large\t1.2.3.4\t2026-10-05\tNone\tubuntu')"
export FAKE_LS_ROWS_eu_west_2="$(printf 'i-there\trunning\tm7i-flex.large\t5.6.7.8\t2026-10-05\tNone\tfedora')"
out=$(aella ls)
{ echo "$out" | grep -q '^   i-here .* eu-north-1 ' && echo "$out" | grep -q '^ \* i-there .* eu-west-2 '; } \
  && pass "ls: covers AELLA_REGION/default and the current box's region, with a region column" || fail "ls regions" "$out"
unset FAKE_LS_ROWS_eu_north_1 FAKE_LS_ROWS_eu_west_2

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

# --- fedora: version picker must skip Rawhide / ELN / Prerelease ----------
ver=$( { sed -n '/^FEDORA_OWNER=/,/^}/p' "$AELLA"; sed -n '/^latest_fedora_version()/,/^}/p' "$AELLA"; echo latest_fedora_version; } \
       | env PATH="$DIR/bin:$PATH" bash )
[ "$ver" = "42" ] && pass "latest_fedora_version: picks highest STABLE (42, not Rawhide/ELN/45-Prerelease)" \
  || fail "fedora version picker" "got '$ver' — a decoy image leaked through"

# --- fedora: build_userdata follows the login user ------------------------
ud=$(gen_ud 'infocmp() { return 1; }' fedora)
{ printf '%s' "$ud" | bash -n && printf '%s' "$ud" | grep -q '^AELLA_USER=fedora$' \
    && printf '%s' "$ud" | grep -q 'BASHRC="/home/\$AELLA_USER/.bashrc"' \
    && ! printf '%s' "$ud" | grep -q 'chown ubuntu:ubuntu'; } \
  && pass "build_userdata fedora: user-parameterised bashrc path + chown" || fail "build_userdata fedora" "$ud"

# --- fedora: up --fedora queries Fedora images and records the login ------
sandbox
aella up --fedora >/dev/null 2>&1
{ called "describe-images .*Fedora-Cloud-Base-AmazonEC2.x86_64-42" \
    && called "run-instances" \
    && [ "$(cat "$HOME/.aella-user" 2>/dev/null)" = fedora ]; } \
  && pass "up --fedora: Fedora AMI filter, launches, records login 'fedora'" \
  || fail "up --fedora" "$(cat "$AELLA_TEST_LOG")"

# --- fedora: ssh/push/pull follow the recorded login ----------------------
sandbox; echo i-abc > "$HOME/.aella-instance"; echo fedora > "$HOME/.aella-user"
export FAKE_IP=9.9.9.9
aella ssh >/dev/null 2>&1
called "ssh .*fedora@9.9.9.9" && pass "ssh: uses the recorded fedora login" || fail "ssh fedora" "$(cat "$AELLA_TEST_LOG")"
: > "$SB/clip.mp4"
aella push "$SB/clip.mp4" recordings >/dev/null 2>&1
called "scp .*clip.mp4 fedora@9.9.9.9:recordings" && pass "push: scp to fedora@ip" || fail "push fedora" "$(cat "$AELLA_TEST_LOG")"
aella pull out/report.html . >/dev/null 2>&1
called "scp .*fedora@9.9.9.9:out/report.html" && pass "pull: scp from fedora@ip" || fail "pull fedora" "$(cat "$AELLA_TEST_LOG")"
unset FAKE_IP

# --- a box launched before .aella-user existed is Ubuntu, not a crash -----
sandbox; echo i-legacy > "$HOME/.aella-instance"; export FAKE_IP=7.7.7.7
aella ssh >/dev/null 2>&1
called "ssh .*ubuntu@7.7.7.7" && pass "no login record (pre-Fedora box): falls back to ubuntu" || fail "legacy fallback" "$(cat "$AELLA_TEST_LOG")"
unset FAKE_IP

# --- down clears the login record too, or the next box inherits it --------
sandbox; echo i-abc > "$HOME/.aella-instance"; echo fedora > "$HOME/.aella-user"
aella down -y >/dev/null 2>&1
[ ! -f "$HOME/.aella-user" ] && pass "down -y: clears the login record with the box" || fail "down leaves stale login record"

# --- an unknown distro is refused before anything is launched -------------
sandbox
out=$(env AELLA_DISTRO=arch bash "$AELLA" up 2>&1); rc=$?
{ [ $rc -eq 1 ] && ! called "run-instances"; } \
  && pass "unknown distro: refuses, launches nothing" || fail "distro validation" "rc=$rc"

# --- linux up is unchanged by Windows support ------------------------------
sandbox
aella up >/dev/null 2>&1
{ called "group-names aella-sg " && ! called "aella-win-sg" && called "run-instances .*m7i-flex.large" \
    && called 'VolumeSize":20' && ! called "authorize-security-group-ingress .*3389" \
    && called "Key=aella-os,Value=ubuntu"; } \
  && pass "up (ubuntu): aella-sg, m7i-flex.large, 20 GB, no RDP rule added, tagged ubuntu" \
  || fail "linux up regressed" "$(cat "$AELLA_TEST_LOG")"

# --- key pairs are per-region: a moved region imports the existing key ------
sandbox; echo "PEM" > "$HOME/.ssh/aella-key.pem"; export FAKE_NO_KEYPAIR=notfound
aella up >/dev/null 2>&1
{ called "import-key-pair --key-name aella-key" && ! called "create-key-pair"; } \
  && pass "up in a region without the key pair: imports the local key (doesn't fail at launch)" \
  || fail "key import" "$(cat "$AELLA_TEST_LOG")"
sandbox; echo "PEM" > "$HOME/.ssh/aella-key.pem"; export FAKE_NO_KEYPAIR=denied
aella up >/dev/null 2>&1
{ ! called "import-key-pair" && called "run-instances"; } \
  && pass "no ec2:DescribeKeyPairs permission: no import attempt, launches as before" \
  || fail "key check w/o permission" "$(cat "$AELLA_TEST_LOG")"

# --- windows: up launches the right thing, scoped to your IP ---------------
PW='Sup3r$ecret;pw'
sandbox; export FAKE_PW="$PW"
out=$(aella up --windows 2>&1); rc=$?
{ [ $rc -eq 0 ] && called "ssm get-parameter --name /aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base" \
    && called "run-instances --image-id ami-win2025 --instance-type m7i-flex.large" \
    && called 'VolumeSize":60' && called "Key=aella-os,Value=windows" \
    && [ "$(cat "$HOME/.aella-user" 2>/dev/null)" = Administrator ]; } \
  && pass "up --windows: SSM AMI, m7i-flex.large, 60 GB, tagged, records Administrator" \
  || fail "up --windows" "rc=$rc $out $(cat "$AELLA_TEST_LOG")"
{ called "authorize-security-group-ingress .*--port 3389 --cidr 203.0.113.7/32" \
    && called "authorize-security-group-ingress .*--port 22 --cidr 203.0.113.7/32" \
    && ! called "authorize.*0.0.0.0/0" && ! called "group-names aella-sg "; } \
  && pass "up --windows: RDP + SSH from your /32 only, via aella-win-sg (aella-sg untouched)" \
  || fail "windows ingress scope" "$(cat "$AELLA_TEST_LOG")"
{ [ "$(cat "$HOME/clipboard" 2>/dev/null)" = "$PW" ] && ! echo "$out" | grep -qF "$PW" \
    && ! grep -qF "$PW" "$AELLA_TEST_LOG" && echo "$out" | grep -q clipboard; } \
  && pass "up --windows: password goes to the clipboard, never to the terminal or argv" \
  || fail "password handling" "$out"
called "get-password-data .*--priv-launch-key $HOME/.ssh/aella-key.pem" \
  && pass "up --windows: decrypts with the aella key" || fail "priv-launch-key" "$(cat "$AELLA_TEST_LOG")"

sandbox; export FAKE_PW="$PW" AELLA_TYPE=t3.large
aella up --windows >/dev/null 2>&1
called "run-instances .*--instance-type t3.large" \
  && pass "up --windows: AELLA_TYPE still overrides" || fail "windows type override" "$(cat "$AELLA_TEST_LOG")"

sandbox; export AELLA_DISK=20
out=$(aella up --windows 2>&1); rc=$?
{ [ $rc -eq 1 ] && ! called "run-instances" && echo "$out" | grep -q ">= 30"; } \
  && pass "up --windows with AELLA_DISK=20: refuses before launching" || fail "windows disk floor" "rc=$rc $out"
sandbox; export FAKE_PW="$PW" AELLA_DISK=30
aella up --windows >/dev/null 2>&1; rc=$?
{ [ $rc -eq 0 ] && called 'VolumeSize":30'; } \
  && pass "up --windows with AELLA_DISK=30: the floor itself is allowed" || fail "windows disk at floor" "rc=$rc"

# --- windows: failure paths ------------------------------------------------
sandbox; export FAKE_PW="$PW" FAKE_SSM=denied
aella up --windows >/dev/null 2>&1
{ called "describe-images --owners amazon .*Windows_Server-2025-English-Full-Base-\*" && called "run-instances"; } \
  && pass "no ssm:GetParameter: falls back to EC2's newest Amazon Windows image" || fail "ssm fallback" "$(cat "$AELLA_TEST_LOG")"

sandbox; export FAKE_SSM=denied FAKE_AMI=None
out=$(aella up --windows 2>&1); rc=$?
{ [ $rc -eq 1 ] && ! called "run-instances" && echo "$out" | grep -q "no Windows Server 2025 AMI"; } \
  && pass "region without the AMI: clear error, launches nothing" || fail "no AMI" "rc=$rc $out"

sandbox; export FAKE_MYIP=""
out=$(aella up --windows 2>&1); rc=$?
{ [ $rc -eq 1 ] && ! called "run-instances" && ! called "authorize-security-group-ingress"; } \
  && pass "public-IP lookup fails: no '/32' rule, launches nothing" || fail "my_ip guard" "rc=$rc $out"

sandbox; export AELLA_PW_TIMEOUT=0 FAKE_PW_ERR=1
out=$(aella up --windows 2>&1); rc=$?
{ [ $rc -eq 1 ] && echo "$out" | grep -q "no password after" && echo "$out" | grep -q "UnauthorizedOperation" \
    && [ -s "$HOME/.aella-instance" ]; } \
  && pass "password timeout: exits 1, shows the real error, box stays tracked (aella down still works)" || fail "pw timeout" "rc=$rc $out"

sandbox; export FAKE_PW="$PW" FAKE_PBCOPY_FAIL=1
out=$(aella up --windows 2>&1)
f=$(ls "$SB"/aella-pw.* 2>/dev/null | head -1)
{ [ -n "$f" ] && [ "$(cat "$f")" = "$PW" ] && ls -l "$f" | grep -q '^-rw-------' && ! echo "$out" | grep -qF "$PW"; } \
  && pass "no clipboard: password in a 0600 temp file, still not printed" || fail "pw file fallback" "$out"

sandbox; export FAKE_PW="$PW" FAKE_KEYGEN_FAIL=1
aella up --windows >/dev/null 2>&1; rc=$?
{ [ $rc -eq 0 ] && called "run-instances"; } \
  && pass "unreadable key for user-data: still launches (RDP only)" || fail "keygen fail" "rc=$rc"

# --- windows: user-data ------------------------------------------------------
# (ends at the next function: the PowerShell inside has its own lines starting with '}')
gen_wud() { { sed -n '/^build_userdata_windows()/,/^wait_password()/p' "$AELLA" | sed '$d'; printf 'build_userdata_windows %q\n' "$1"; } | bash; }
ud=$(gen_wud 'ssh-rsa AAAAB3NzaC1yc2EKEY')
{ printf '%s' "$ud" | head -1 | grep -q '^<powershell>$' && printf '%s' "$ud" | tail -1 | grep -q '^</powershell>$' \
    && printf '%s' "$ud" | grep -qF "\$key = 'ssh-rsa AAAAB3NzaC1yc2EKEY'" \
    && printf '%s' "$ud" | grep -qF 'administrators_authorized_keys' \
    && printf '%s' "$ud" | grep -qF "/inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'" \
    && printf '%s' "$ud" | grep -qF "@('PasswordAuthentication no', 'KbdInteractiveAuthentication no')" \
    && [ "$(printf '%s' "$ud" | grep -n 'StartupType Automatic' | cut -d: -f1)" -lt "$(printf '%s' "$ud" | grep -n '^Start-Service sshd; Stop' | cut -d: -f1)" ]; } \
  && pass "build_userdata_windows: key-only sshd, locked-ACL admin key, un-disables sshd before starting it" || fail "windows user-data" "$ud"
ud=$(gen_wud "ssh-rsa AAAA'; Remove-Item C:\\ -Recurse; '"); rc=$?
{ [ $rc -ne 0 ] && [ -z "$ud" ]; } && pass "build_userdata_windows: refuses a key that could break out of its quotes" \
  || fail "windows user-data injection" "$ud"

# --- windows: rdp -------------------------------------------------------------
sandbox; echo i-win > "$HOME/.aella-instance"; echo Administrator > "$HOME/.aella-user"
export FAKE_IP=9.9.9.9 FAKE_PW="$PW" FAKE_SG_CIDRS="$(printf '198.51.100.9/32\t203.0.113.7/32')"
out=$(aella rdp 2>&1); rc=$?
rdpf=$(sed -n 's/^open //p' "$AELLA_TEST_LOG" | head -1)
{ [ $rc -eq 0 ] && [ -n "$rdpf" ] && grep -q '^full address:s:9.9.9.9:3389' "$rdpf" \
    && grep -q '^username:s:Administrator' "$rdpf" && ls -l "$rdpf" | grep -q '^-rw-------' \
    && ls -ld "$(dirname "$rdpf")" | grep -q '^drwx------'; } \
  && pass "rdp (windows): writes a 0600 .rdp (address + Administrator) in a 0700 dir, opens it" \
  || fail "rdp windows" "rc=$rc $out $(cat "$AELLA_TEST_LOG")"
{ [ "$(cat "$HOME/clipboard" 2>/dev/null)" = "$PW" ] && ! echo "$out" | grep -qF "$PW" && ! grep -qF "$PW" "$rdpf"; } \
  && pass "rdp (windows): password to clipboard only — not printed, not in the .rdp" || fail "rdp password" "$out"
{ called "revoke-security-group-ingress .*--cidr 198.51.100.9/32" && ! called "revoke.*203.0.113.7"; } \
  && pass "rdp (windows): re-allows your current IP and revokes the one you roamed from" \
  || fail "rdp roaming" "$(cat "$AELLA_TEST_LOG")"

sandbox; echo i-win > "$HOME/.aella-instance"; echo Administrator > "$HOME/.aella-user"
export FAKE_IP=9.9.9.9 FAKE_PW="$PW" FAKE_OPEN_FAIL=1
out=$(aella rdp 2>&1); rc=$?
{ [ $rc -eq 1 ] && echo "$out" | grep -q "Windows App"; } \
  && pass "rdp with no .rdp handler: install hint for Windows App, exit 1" || fail "rdp no handler" "rc=$rc $out"

sandbox; echo i-lin > "$HOME/.aella-instance"
export FAKE_IP=9.9.9.9
out=$(aella rdp 2>&1)
{ called "authorize-security-group-ingress --group-id sg-123 .*3389" && ! called "^open " \
    && ! called "get-password-data" && echo "$out" | grep -q "connect an RDP client to 9.9.9.9:3389"; } \
  && pass "rdp (linux box): unchanged — re-allows 3389 on aella-sg, no password, no .rdp" \
  || fail "rdp linux regressed" "$out $(cat "$AELLA_TEST_LOG")"
unset FAKE_IP FAKE_PW FAKE_SG_CIDRS FAKE_OPEN_FAIL

# --- windows: ssh / push follow Administrator + PowerShell -----------------
sandbox; echo i-win > "$HOME/.aella-instance"; echo Administrator > "$HOME/.aella-user"
export FAKE_IP=9.9.9.9
aella ssh >/dev/null 2>&1
: > "$SB/report.xlsx"
aella push "$SB/report.xlsx" inbox >/dev/null 2>&1
{ called "ssh .*Administrator@9.9.9.9" && called "New-Item -ItemType Directory -Force -Path \"inbox\"" \
    && ! called "mkdir -p" && called "scp .*report.xlsx Administrator@9.9.9.9:inbox"; } \
  && pass "ssh/push (windows): Administrator login, PowerShell mkdir" || fail "windows ssh/push" "$(cat "$AELLA_TEST_LOG")"
unset FAKE_IP

# --- ls shows the platform --------------------------------------------------
sandbox
export FAKE_LS_ROWS="$(printf 'i-win\trunning\tt3.large\t1.2.3.4\t2026-10-05\twindows\twindows\ni-fed\trunning\tm7i-flex.large\t5.6.7.8\t2026-10-05\tNone\tfedora\ni-old\trunning\tm7i-flex.large\t5.6.7.9\t2026-07-20\tNone\tNone')"
out=$(aella ls)
{ echo "$out" | grep -q 'i-win .* windows ' && echo "$out" | grep -q 'i-fed .* fedora ' \
    && echo "$out" | grep -q 'i-old .* linux '; } \
  && pass "ls: shows each box's platform (tag, else EC2 platform)" || fail "ls platform" "$out"
unset FAKE_LS_ROWS

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
