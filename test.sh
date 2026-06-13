#!/usr/bin/env bash
# Unit tests for safe-claude-code.sh.
# All tests run in an isolated temp dir with mocked curl/codex/claude.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN="$SCRIPT_DIR/safe-claude-code.sh"

[[ -f "$MAIN" ]] || { echo "missing: $MAIN" >&2; exit 1; }

PASS=0
FAIL=0
FAILED=()

# ---------- fixtures ----------

setup_env() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  CODEX_LOG="$TMP/codex.log"
  CLAUDE_LOG="$TMP/claude.log"

  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_CURL_FAIL:-0}" == "1" ]]; then
  exit 22
fi
printf '%s' "${MOCK_RESP:-{\}}"
EOF
  chmod +x "$TMP/bin/curl"

  export PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export SCC_ALLOW_NON_TTY=1

  local v
  for v in $(env | awk -F= '/^SCC_/ {print $1}'); do
    [[ "$v" == "SCC_ALLOW_NON_TTY" ]] && continue
    unset "$v"
  done
}

cleanup_env() { rm -rf "$TMP"; }

add_fake_cli() {
  local name="$1" log="$2"
  cat > "$TMP/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$log"
echo MOCK_${name}_CALLED
exit 0
EOF
  chmod +x "$TMP/bin/$name"
}

# ---------- assertions ----------

assert_eq() {
  local got="$1" want="$2" msg="${3:-values differ}"
  if [[ "$got" != "$want" ]]; then
    printf '    %s\n      want: %q\n      got:  %q\n' "$msg" "$want" "$got" >&2
    return 1
  fi
}

assert_contains() {
  local hay="$1" needle="$2" msg="${3:-output missing substring}"
  if [[ "$hay" != *"$needle"* ]]; then
    printf '    %s\n      needle: %q\n      output: %s\n' "$msg" "$needle" "$hay" >&2
    return 1
  fi
}

assert_not_contains() {
  local hay="$1" needle="$2" msg="${3:-output contains forbidden substring}"
  if [[ "$hay" == *"$needle"* ]]; then
    printf '    %s\n      needle: %q\n      output: %s\n' "$msg" "$needle" "$hay" >&2
    return 1
  fi
}

# ---------- runner ----------

run_test() {
  local name="$1" fn="$2"
  (
    setup_env
    trap cleanup_env EXIT
    "$fn"
  )
  local rc=$?
  if (( rc == 0 )); then
    echo "  ok   $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $name"
    FAIL=$((FAIL + 1))
    FAILED+=("$name")
  fi
}

# ========== safe-claude-code tests ==========

t_no_cli_denies() {
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'y\n' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "No supported CLI found"
}

t_single_codex_prints_ipinfo_and_runs_after_yes() {
  add_fake_cli codex "$CODEX_LOG"
  export MOCK_RESP='{"ip":"1.2.3.4","city":"Beijing","country":"CN","timezone":"Asia/Shanghai"}'
  out="$(printf 'y\n' | bash "$MAIN" --foo 'bar baz' 2>&1)"
  assert_contains "$out" "Detected CLI: codex" || return 1
  assert_contains "$out" '"ip":"1.2.3.4"' || return 1
  assert_contains "$out" "MOCK_codex_CALLED" || return 1
  got="$(cat "$CODEX_LOG")"
  want=$'--foo\nbar baz'
  assert_eq "$got" "$want" "args were not forwarded to codex"
}

t_single_claude_runs_after_yes() {
  add_fake_cli claude "$CLAUDE_LOG"
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf 'yes\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "Detected CLI: claude" || return 1
  assert_contains "$out" "MOCK_claude_CALLED"
}

t_confirmation_defaults_to_no() {
  add_fake_cli codex "$CODEX_LOG"
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\n' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "Cancelled" || return 1
  assert_not_contains "$out" "MOCK_codex_CALLED"
}

t_selector_enter_chooses_first_cli() {
  add_fake_cli codex "$CODEX_LOG"
  add_fake_cli claude "$CLAUDE_LOG"
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "Select CLI to launch" || return 1
  assert_contains "$out" "MOCK_codex_CALLED" || return 1
  assert_not_contains "$out" "MOCK_claude_CALLED"
}

t_selector_down_enter_chooses_second_cli() {
  add_fake_cli codex "$CODEX_LOG"
  add_fake_cli claude "$CLAUDE_LOG"
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[B\n''y\n' | bash "$MAIN" --model sonnet 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  got="$(cat "$CLAUDE_LOG")"
  want=$'--model\nsonnet'
  assert_eq "$got" "$want" "args were not forwarded to claude"
}

t_selector_q_cancels() {
  add_fake_cli codex "$CODEX_LOG"
  add_fake_cli claude "$CLAUDE_LOG"
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'q' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "Cancelled" || return 1
  assert_not_contains "$out" "MOCK_codex_CALLED" || return 1
  assert_not_contains "$out" "MOCK_claude_CALLED"
}

t_curl_failure_denies() {
  add_fake_cli codex "$CODEX_LOG"
  out="$(MOCK_CURL_FAIL=1 bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "Failed to fetch"
}

t_invalid_json_denies() {
  add_fake_cli codex "$CODEX_LOG"
  export MOCK_RESP='not json at all'
  out="$(bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "Invalid JSON"
}

echo "safe-claude-code:"
run_test "no supported CLI -> deny"                         t_no_cli_denies
run_test "single codex prints ipinfo and runs after yes"     t_single_codex_prints_ipinfo_and_runs_after_yes
run_test "single claude runs after yes"                      t_single_claude_runs_after_yes
run_test "confirmation defaults to no"                       t_confirmation_defaults_to_no
run_test "selector Enter chooses first CLI"                  t_selector_enter_chooses_first_cli
run_test "selector Down+Enter chooses second CLI"            t_selector_down_enter_chooses_second_cli
run_test "selector q cancels"                                t_selector_q_cancels
run_test "curl failure -> deny"                              t_curl_failure_denies
run_test "invalid JSON response -> deny"                     t_invalid_json_denies

echo
echo "===================="
printf "Passed: %d\nFailed: %d\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  echo
  echo "Failed tests:"
  for t in "${FAILED[@]}"; do echo "  - $t"; done
  exit 1
fi
