#!/usr/bin/env bash
# Unit tests for safe-claude-code.sh.
# All tests run in an isolated temp dir with mocked curl/codex/claude.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN="$SCRIPT_DIR/safe-claude-code.sh"
INSTALLER="$SCRIPT_DIR/install.sh"

[[ -f "$MAIN" ]] || { echo "missing: $MAIN" >&2; exit 1; }
[[ -f "$INSTALLER" ]] || { echo "missing: $INSTALLER" >&2; exit 1; }

PASS=0
FAIL=0
FAILED=()

# ---------- fixtures ----------

setup_env() {
  TMP="$(mktemp -d)"
  rm -rf ".claude"
  rm -rf ".temp"
  mkdir -p "$TMP/bin"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  CODEX_LOG="$TMP/codex.log"
  CLAUDE_LOG="$TMP/claude.log"

  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_CURL_FAIL:-0}" == "1" ]]; then
  exit 22
fi
out=""
while (($#)); do
  case "$1" in
    -o)
      shift
      out="${1:-}"
      ;;
  esac
  shift || true
done
if [[ -n "$out" ]]; then
  printf '%s' "${MOCK_RESP:-{\}}" > "$out"
  exit 0
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

cleanup_env() {
  rm -rf "$TMP"
  rm -rf ".claude"
  rm -rf ".temp"
}

add_fake_cli() {
  local name="$1" log="$2"
cat > "$TMP/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${CLAUDE_CONFIG_DIR:-}" > "$log.env"
printf '%s\n' "\${CODEX_HOME:-}" > "$log.codex_env"
if [[ -n "\${CLAUDE_CONFIG_DIR:-}" && -d "\$CLAUDE_CONFIG_DIR/skills" ]]; then
  find -L "\$CLAUDE_CONFIG_DIR/skills" -name SKILL.md -type f | sort > "$log.skills"
  {
    find "\$CLAUDE_CONFIG_DIR/skills" -mindepth 1 -maxdepth 1 -type l | sort | while IFS= read -r link; do
      printf '%s -> %s\n' "\$link" "\$(readlink "\$link")"
    done
  } > "$log.skill_links"
elif [[ -n "\${CODEX_HOME:-}" && -d "\$CODEX_HOME/skills" ]]; then
  find "\$CODEX_HOME/skills" -name SKILL.md -type f | sort > "$log.skills"
  : > "$log.skill_links"
else
  : > "$log.skills"
  : > "$log.skill_links"
fi
if [[ -n "\${CLAUDE_CONFIG_DIR:-}" && -d "\$CLAUDE_CONFIG_DIR/plugins" ]]; then
  find -L "\$CLAUDE_CONFIG_DIR/plugins/marketplaces" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort > "$log.plugins"
else
  : > "$log.plugins"
fi
if [[ -n "\${CLAUDE_CONFIG_DIR:-}" ]]; then
  {
    for rel in auth.json settings.json projects/current.json cache/token.txt; do
      if [[ -f "\$CLAUDE_CONFIG_DIR/\$rel" ]]; then
        printf '%s=' "\$rel"
        cat "\$CLAUDE_CONFIG_DIR/\$rel"
        printf '\n'
      fi
    done
    if [[ -f "\$CLAUDE_CONFIG_DIR/.claude.json" ]]; then
      printf '%s=' ".claude.json"
      cat "\$CLAUDE_CONFIG_DIR/.claude.json"
      printf '\n'
    fi
  } > "$log.inherited"
  sibling_config="\$(dirname "\$CLAUDE_CONFIG_DIR")/.claude.json"
  if [[ -f "\$sibling_config" ]]; then
    cat "\$sibling_config" > "$log.sibling_claude_json"
  else
    : > "$log.sibling_claude_json"
  fi
fi
printf '%s\n' "\$@" > "$log"
echo MOCK_${name}_CALLED
exit 0
EOF
  chmod +x "$TMP/bin/$name"
}

setup_codex_resources() {
  mkdir -p "$HOME/.codex/skills/alpha" "$HOME/.codex/skills/beta" "$HOME/.codex"
  printf '%s\n' '---' 'name: alpha' '---' > "$HOME/.codex/skills/alpha/SKILL.md"
  printf '%s\n' '---' 'name: beta' '---' > "$HOME/.codex/skills/beta/SKILL.md"
  cat > "$HOME/.codex/config.toml" <<'EOF'
[plugins."browser@openai-bundled"]
enabled = true

[mcp_servers.node_repl]
command = "node-repl"
EOF
}

setup_unsorted_codex_resources() {
  mkdir -p "$HOME/.agents/skills/zeta" "$HOME/.codex/skills/alpha" "$HOME/.codex"
  printf '%s\n' '---' 'name: zeta' '---' > "$HOME/.agents/skills/zeta/SKILL.md"
  printf '%s\n' '---' 'name: alpha' '---' > "$HOME/.codex/skills/alpha/SKILL.md"
  cat > "$HOME/.codex/config.toml" <<'EOF'
[plugins."delta"]
enabled = true

[plugins."beta"]
enabled = true
EOF
}

setup_claude_skills() {
  mkdir -p "$HOME/.claude/skills/alpha" "$HOME/.claude/skills/beta"
  printf '%s\n' '---' 'name: alpha' '---' > "$HOME/.claude/skills/alpha/SKILL.md"
  printf '%s\n' '---' 'name: beta' '---' > "$HOME/.claude/skills/beta/SKILL.md"
}

setup_claude_global_config() {
  setup_claude_skills
  mkdir -p "$HOME/.claude/projects" "$HOME/.claude/cache"
  printf '%s' '{"account":"logged-in"}' > "$HOME/.claude.json"
  printf '%s' 'auth-token' > "$HOME/.claude/auth.json"
  printf '%s' '{"theme":"dark"}' > "$HOME/.claude/settings.json"
  printf '%s' 'project-state' > "$HOME/.claude/projects/current.json"
  printf '%s' 'cached-token' > "$HOME/.claude/cache/token.txt"
}

setup_claude_plugins() {
  mkdir -p "$HOME/.claude/plugins/marketplaces/official/.claude-plugin"
  mkdir -p "$HOME/.claude/plugins/marketplaces/official/plugins/plugin-alpha/.claude-plugin"
  mkdir -p "$HOME/.claude/plugins/marketplaces/official/plugins/plugin-beta/.claude-plugin"
  mkdir -p "$HOME/.claude/plugins/marketplaces/official/plugins/plugin-gamma"
  printf '%s' '{"known":true}' > "$HOME/.claude/plugins/known_marketplaces.json"
  printf '%s' 'marketplace' > "$HOME/.claude/plugins/marketplaces/official/README.md"
  printf '%s' '{"name":"official"}' > "$HOME/.claude/plugins/marketplaces/official/.claude-plugin/marketplace.json"
  printf '%s' '{"name":"plugin-alpha"}' > "$HOME/.claude/plugins/marketplaces/official/plugins/plugin-alpha/.claude-plugin/plugin.json"
  printf '%s' '{"name":"plugin-beta"}' > "$HOME/.claude/plugins/marketplaces/official/plugins/plugin-beta/.claude-plugin/plugin.json"
}

setup_claude_prefixed_plugins() {
  mkdir -p "$HOME/.claude/plugins/marketplaces/official/plugins/browser/.claude-plugin"
  mkdir -p "$HOME/.claude/plugins/marketplaces/official/plugins/lark-base/.claude-plugin"
  mkdir -p "$HOME/.claude/plugins/marketplaces/official/plugins/lark-im/.claude-plugin"
  printf '%s' '{"name":"browser"}' > "$HOME/.claude/plugins/marketplaces/official/plugins/browser/.claude-plugin/plugin.json"
  printf '%s' '{"name":"lark-base"}' > "$HOME/.claude/plugins/marketplaces/official/plugins/lark-base/.claude-plugin/plugin.json"
  printf '%s' '{"name":"lark-im"}' > "$HOME/.claude/plugins/marketplaces/official/plugins/lark-im/.claude-plugin/plugin.json"
}

real_path() {
  local p="$1"
  (cd -P "$(dirname "$p")" && printf '%s/%s' "$(pwd)" "$(basename "$p")")
}

setup_agent_symlink_skills() {
  mkdir -p "$HOME/.agents/skills" "$TMP/real-skills/lark-approval" "$TMP/real-skills/lark-apps"
  printf '%s\n' '---' 'name: lark-approval' '---' > "$TMP/real-skills/lark-approval/SKILL.md"
  printf '%s\n' '---' 'name: lark-apps' '---' > "$TMP/real-skills/lark-apps/SKILL.md"
  ln -s "$TMP/real-skills/lark-approval" "$HOME/.agents/skills/lark-approval"
  ln -s "$TMP/real-skills/lark-apps" "$HOME/.agents/skills/lark-apps"
}

setup_understand_skills() {
  mkdir -p "$HOME/.agents/skills/understand" "$HOME/.agents/skills/understand-chat"
  printf '%s\n' '---' 'name: understand' '---' > "$HOME/.agents/skills/understand/SKILL.md"
  printf '%s\n' '---' 'name: understand-chat' '---' > "$HOME/.agents/skills/understand-chat/SKILL.md"
}

setup_superpowers_bundle_skills() {
  mkdir -p "$HOME/.agents/skills" "$TMP/superpowers/brainstorming" "$TMP/superpowers/systematic-debugging"
  printf '%s\n' '---' 'name: brainstorming' '---' > "$TMP/superpowers/brainstorming/SKILL.md"
  printf '%s\n' '---' 'name: systematic-debugging' '---' > "$TMP/superpowers/systematic-debugging/SKILL.md"
  ln -s "$TMP/superpowers" "$HOME/.agents/skills/superpowers"
}

setup_many_lark_skills() {
  local i name
  mkdir -p "$HOME/.agents/skills"
  for i in 01 02 03 04 05 06; do
    name="lark-tool-$i"
    mkdir -p "$HOME/.agents/skills/$name"
    printf '%s\n' '---' "name: $name" '---' > "$HOME/.agents/skills/$name/SKILL.md"
  done
}

setup_many_feature_groups() {
  local i name
  mkdir -p "$HOME/.agents/skills"
  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18; do
    name="tool$i-alpha"
    mkdir -p "$HOME/.agents/skills/$name"
    printf '%s\n' '---' "name: $name" '---' > "$HOME/.agents/skills/$name/SKILL.md"
  done
}

setup_many_small_feature_groups() {
  local i name
  mkdir -p "$HOME/.agents/skills"
  for i in 01 02 03 04 05 06 07 08 09; do
    for name in "tool$i-alpha" "tool$i-beta"; do
      mkdir -p "$HOME/.agents/skills/$name"
      printf '%s\n' '---' "name: $name" '---' > "$HOME/.agents/skills/$name/SKILL.md"
    done
  done
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

assert_order() {
  local hay="$1" first="$2" second="$3" msg="${4:-items are not ordered}"
  if [[ "$hay" != *"$first"*"$second"* ]]; then
    printf '    %s\n      first: %q\n      second: %q\n      output: %s\n' "$msg" "$first" "$second" "$hay" >&2
    return 1
  fi
}

first_feature_selector_frame() {
  local out="$1"
  printf '%s' "$out" | awk '
    /Select features to enable:/ {in_frame=1}
    in_frame {print}
    in_frame && /move/ {exit}
  '
}

last_feature_selector_frame() {
  local out="$1"
  printf '%s' "$out" | awk '
    /Select features to enable:/ {frame=$0 "\n"; in_frame=1; next}
    in_frame {frame=frame $0 "\n"}
    in_frame && /move/ {last=frame; in_frame=0}
    END {printf "%s", last}
  '
}

count_occurrences() {
  local hay="$1" needle="$2"
  printf '%s' "$hay" | awk -v needle="$needle" '
  {
    hay = hay $0 "\n"
  }
  END {
    count = 0
    start = 1
    while ((pos = index(substr(hay, start), needle)) > 0) {
      count++
      start += pos + length(needle) - 1
    }
    print count
  }'
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

t_confirmation_defaults_to_yes() {
  add_fake_cli codex "$CODEX_LOG"
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "MOCK_codex_CALLED" || return 1
}

t_confirmation_no_cancels() {
  add_fake_cli codex "$CODEX_LOG"
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'n\n' | bash "$MAIN" 2>&1)"
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

t_codex_resource_selector_disables_unchecked_skills_and_plugins_only() {
  add_fake_cli codex "$CODEX_LOG"
  setup_codex_resources
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'a\n''y\n' | bash "$MAIN" --foo 2>&1)"
  assert_contains "$out" "Select features to enable" || return 1
  assert_not_contains "$out" "mcp" "selector should not show MCP resources" || return 1
  assert_contains "$out" "MOCK_codex_CALLED" || return 1
  got="$(cat "$CODEX_LOG")"
  alpha_skill="$(real_path "$HOME/.codex/skills/alpha/SKILL.md")"
  beta_skill="$(real_path "$HOME/.codex/skills/beta/SKILL.md")"
  want="$(printf '%s\n' \
    "-c" \
    "skills.config=[{path=\"$alpha_skill\",enabled=false},{path=\"$beta_skill\",enabled=false}]" \
    "-c" \
    'plugins."browser@openai-bundled".enabled=false' \
    "--foo")"
  assert_eq "$got" "$want" "disabled Codex resources were not converted to config overrides" || return 1
  assert_not_contains "$got" 'skills."alpha".enabled=false' "Codex skill disable should not use unsupported -c key"
  assert_not_contains "$got" "mcp_servers.node_repl.enabled=false" "MCP resources should be ignored"
  got_env="$(cat "$CODEX_LOG.codex_env")"
  assert_eq "$got_env" "" "Codex skill disable should not use temporary CODEX_HOME"
}

t_features_are_sorted_by_type_then_name() {
  add_fake_cli codex "$CODEX_LOG"
  setup_unsorted_codex_resources
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'q' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  frame="$(first_feature_selector_frame "$out")"
  assert_order "$frame" "skill   alpha" "skill   zeta" "skills should be globally sorted by name across scanned directories" || return 1
  assert_order "$frame" "skill   zeta" "plugin  beta" "skills should be displayed before plugins" || return 1
  assert_order "$frame" "plugin  beta" "plugin  delta" "plugins should be sorted by name"
}

t_codex_reads_agents_symlink_skills_and_uses_real_paths() {
  add_fake_cli codex "$CODEX_LOG"
  setup_agent_symlink_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'a\n''y\n' | bash "$MAIN" --foo 2>&1)"
  assert_contains "$out" "lark" || return 1
  assert_contains "$out" "lark-approval" || return 1
  assert_contains "$out" "lark-apps" || return 1
  got="$(cat "$CODEX_LOG")"
  approval_skill="$(real_path "$TMP/real-skills/lark-approval/SKILL.md")"
  apps_skill="$(real_path "$TMP/real-skills/lark-apps/SKILL.md")"
  want="$(printf '%s\n' \
    "-c" \
    "skills.config=[{path=\"$approval_skill\",enabled=false},{path=\"$apps_skill\",enabled=false}]" \
    "--foo")"
  assert_eq "$got" "$want" "agent symlink skills were not disabled using resolved real paths"
}

t_feature_group_toggle_disables_group_members() {
  add_fake_cli codex "$CODEX_LOG"
  setup_agent_symlink_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[A \n''y\n' | bash "$MAIN" --foo 2>&1)"
  assert_contains "$out" "lark" || return 1
  assert_not_contains "$out" "group  lark" || return 1
  assert_contains "$out" $'\033[1mlark\033[0m' || return 1
  assert_contains "$out" "  [x] skill   lark-approval" || return 1
  got="$(cat "$CODEX_LOG")"
  approval_skill="$(real_path "$TMP/real-skills/lark-approval/SKILL.md")"
  apps_skill="$(real_path "$TMP/real-skills/lark-apps/SKILL.md")"
  want="$(printf '%s\n' \
    "-c" \
    "skills.config=[{path=\"$approval_skill\",enabled=false},{path=\"$apps_skill\",enabled=false}]" \
    "--foo")"
  assert_eq "$got" "$want" "group toggle did not disable all group members"
}

t_left_arrow_on_item_collapses_group_and_selects_group_row() {
  add_fake_cli codex "$CODEX_LOG"
  setup_agent_symlink_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[Dq' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "> [x] "$'\033[1m'"lark"$'\033[0m'" (2, collapsed)" "Left arrow on an item should collapse its group and select the group row" || return 1
}

t_right_arrow_on_item_is_ignored() {
  add_fake_cli codex "$CODEX_LOG"
  setup_agent_symlink_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[Cq' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" ">   [x] skill   lark-approval" "Right arrow on an item should leave focus on the item" || return 1
  assert_not_contains "$out" "collapsed" "Right arrow on an item should not collapse the current group" || return 1
}

t_prefixed_plugins_are_grouped_separately_from_generic_plugins() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_prefixed_plugins
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf '\033[B \n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" $'\033[1mplugin\033[0m' || return 1
  assert_contains "$out" $'\033[1mlark\033[0m' || return 1
  got="$(cat "$CLAUDE_LOG")"
  want="$(printf '%s\n' \
    "--settings" \
    '{"enabledPlugins":{"lark-base@official":false,"lark-im@official":false}}')"
  assert_eq "$got" "$want" "Space on a prefixed plugin group should disable only that plugin group"
}

t_prefix_root_skill_joins_prefixed_group() {
  add_fake_cli codex "$CODEX_LOG"
  setup_understand_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[A \n''y\n' | bash "$MAIN" --foo 2>&1)"
  assert_contains "$out" $'\033[1munderstand\033[0m' || return 1
  assert_not_contains "$out" $'\033[1mskill\033[0m' || return 1
  got="$(cat "$CODEX_LOG")"
  understand_skill="$(real_path "$HOME/.agents/skills/understand/SKILL.md")"
  chat_skill="$(real_path "$HOME/.agents/skills/understand-chat/SKILL.md")"
  want="$(printf '%s\n' \
    "-c" \
    "skills.config=[{path=\"$understand_skill\",enabled=false},{path=\"$chat_skill\",enabled=false}]" \
    "--foo")"
  assert_eq "$got" "$want" "understand root skill did not join understand-* group"
}

t_bundle_symlink_skills_are_discovered_and_grouped() {
  add_fake_cli codex "$CODEX_LOG"
  setup_superpowers_bundle_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[A \n''y\n' | bash "$MAIN" --foo 2>&1)"
  assert_contains "$out" $'\033[1msuperpowers\033[0m' || return 1
  assert_contains "$out" "superpowers:brainstorming" || return 1
  assert_contains "$out" "superpowers:systematic-debugging" || return 1
  got="$(cat "$CODEX_LOG")"
  brainstorming_skill="$(real_path "$TMP/superpowers/brainstorming/SKILL.md")"
  debugging_skill="$(real_path "$TMP/superpowers/systematic-debugging/SKILL.md")"
  want="$(printf '%s\n' \
    "-c" \
    "skills.config=[{path=\"$brainstorming_skill\",enabled=false},{path=\"$debugging_skill\",enabled=false}]" \
    "--foo")"
  assert_eq "$got" "$want" "bundle symlink skills were not discovered or grouped"
}

t_large_group_is_collapsed_by_default() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_lark_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'q' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  frame="$(first_feature_selector_frame "$out")"
  assert_contains "$frame" $'\033[1mlark\033[0m' || return 1
  assert_contains "$frame" "collapsed" || return 1
  assert_not_contains "$frame" "lark-tool-01" "large groups should not show members before expansion"
}

t_right_arrow_on_collapsed_group_expands_it() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_lark_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[Cq' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "lark-tool-01" "Right arrow on a collapsed group should reveal members" || return 1
  assert_contains "$out" $'\0338\033[J' "selector update should restore and clear the previous frame"
}

t_left_arrow_on_expanded_group_collapses_it() {
  add_fake_cli codex "$CODEX_LOG"
  setup_agent_symlink_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[A\033[Dq' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "collapsed" "Left arrow on an expanded group should collapse it"
}

t_enter_on_collapsed_group_continues() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_lark_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\n''y\n' | bash "$MAIN" --foo 2>&1)"
  assert_contains "$out" "MOCK_codex_CALLED" || return 1
  assert_not_contains "$out" "lark-tool-01" "Enter should continue instead of expanding collapsed groups" || return 1
  got="$(cat "$CODEX_LOG")"
  assert_eq "$got" "--foo" "Enter on a collapsed group should continue to launch without changing selection"
}

t_feature_selector_redraw_restores_saved_cursor() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_lark_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[Cq' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" $'\0337' "feature selector should save its starting cursor position" || return 1
  assert_contains "$out" $'\0338\033[J' "feature selector redraw should restore cursor and clear old content" || return 1
  assert_not_contains "$out" $'\033[20A' "feature selector redraw should not rely on moving up a fixed number of rows"
}

t_feature_selector_movement_updates_rows_without_full_redraw() {
  add_fake_cli codex "$CODEX_LOG"
  setup_codex_resources
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf '\033[Bq' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  count="$(count_occurrences "$out" "Select features to enable:")"
  assert_eq "$count" "1" "plain cursor movement should not redraw the whole selector"
}

t_feature_selector_frame_is_limited_to_20_lines() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_small_feature_groups
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'q' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  frame="$(first_feature_selector_frame "$out")"
  line_count="$(printf '%s\n' "$frame" | wc -l | tr -d ' ')"
  assert_eq "$line_count" "20" "feature selector should render at most 20 lines" || return 1
  assert_not_contains "$frame" "tool09-alpha" "items beyond the viewport should not be in the first frame"
}

t_down_scrolls_feature_selector_viewport() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_small_feature_groups
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  local keys="" i
  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34; do
    keys+=$'\033[B'
  done
  out="$(printf '%sq' "$keys" | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "tool09-beta" "down key should scroll later rows into the selector viewport"
}

t_down_scrolls_when_focus_reaches_third_row_from_bottom() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_small_feature_groups
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  local keys="" i
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    keys+=$'\033[B'
  done
  out="$(printf '%sq' "$keys" | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "tool06-alpha" "down movement should render newly visible rows when focus reaches the third row from the bottom"
}

t_scrolling_refreshes_rows_without_reprinting_prompt() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_small_feature_groups
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  local keys="" i
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    keys+=$'\033[B'
  done
  out="$(printf '%sq' "$keys" | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  count="$(count_occurrences "$out" "↑/↓ move/scroll")"
  assert_eq "$count" "1" "scroll redraw should not reprint the footer prompt" || return 1
  assert_contains "$out" "tool06-alpha" "scroll redraw should still render newly visible rows"
}

t_up_scrolls_when_focus_reaches_third_row_from_top() {
  add_fake_cli codex "$CODEX_LOG"
  setup_many_small_feature_groups
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  local keys="" i
  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
    keys+=$'\033[B'
  done
  for i in 01 02 03 04 05 06 07 08 09 10; do
    keys+=$'\033[A'
  done
  out="$(printf '%sq' "$keys" | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  frame="$(last_feature_selector_frame "$out")"
  assert_contains "$frame" "tool01-alpha" "viewport should scroll back up when focus reaches the third row from the top"
}

t_codex_unchecked_skill_uses_skills_config_override() {
  add_fake_cli codex "$CODEX_LOG"
  setup_codex_resources
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf ' \n''y\n' | bash "$MAIN" --foo 2>&1)"
  assert_contains "$out" "MOCK_codex_CALLED" || return 1
  got="$(cat "$CODEX_LOG")"
  alpha_skill="$(real_path "$HOME/.codex/skills/alpha/SKILL.md")"
  want="$(printf '%s\n' \
    "-c" \
    "skills.config=[{path=\"$alpha_skill\",enabled=false}]" \
    "--foo")"
  assert_eq "$got" "$want" "disabled Codex skill should use skills.config override" || return 1
  assert_not_contains "$got" 'skills."alpha".enabled=false' "Codex skill disable should not use unsupported -c key"
  got_env="$(cat "$CODEX_LOG.codex_env")"
  assert_eq "$got_env" "" "Codex skill disable should not use temporary CODEX_HOME"
}

t_claude_unchecked_skill_uses_settings_override() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  got="$(cat "$CLAUDE_LOG")"
  want="$(printf '%s\n' \
    "--settings" \
    '{"skillOverrides":{"alpha":"off"}}')"
  assert_eq "$got" "$want" "disabled Claude skill should use --settings skillOverrides" || return 1
  got_env="$(cat "$CLAUDE_LOG.env")"
  assert_eq "$got_env" "" "Claude settings override should not use CLAUDE_CONFIG_DIR" || return 1
  [[ ! -d ".temp/.claude" ]] || { echo "    .temp/.claude should not be created for Claude settings override" >&2; rm -rf ".temp"; return 1; }
}

t_claude_does_not_scan_agents_skills() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_agent_symlink_skills
  setup_claude_skills
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  assert_not_contains "$out" "lark-approval" "Claude selector should not show ~/.agents skills" || return 1
  assert_not_contains "$out" "lark-apps" "Claude selector should not show ~/.agents skills" || return 1
  got="$(cat "$CLAUDE_LOG")"
  want="$(printf '%s\n' \
    "--settings" \
    '{"skillOverrides":{"alpha":"off"}}')"
  assert_eq "$got" "$want" "Claude should only disable skills that Claude Code reads"
}

t_claude_unchecked_skill_preserves_user_args() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''y\n' | bash "$MAIN" --model sonnet 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  got="$(cat "$CLAUDE_LOG")"
  want="$(printf '%s\n' \
    "--settings" \
    '{"skillOverrides":{"alpha":"off"}}' \
    "--model" \
    "sonnet")"
  assert_eq "$got" "$want" "Claude --settings should be prepended before forwarded args"
}

t_claude_unchecked_plugin_uses_enabled_plugins_setting() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  setup_claude_plugins
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf '\033[B\033[B\033[B \n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  got="$(cat "$CLAUDE_LOG")"
  want="$(printf '%s\n' \
    "--settings" \
    '{"enabledPlugins":{"plugin-alpha@official":false}}')"
  assert_eq "$got" "$want" "disabled Claude plugin should use --settings enabledPlugins"
}

t_claude_existing_project_claude_does_not_block_settings_override() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  mkdir -p ".claude"
  printf '%s' "project-local" > ".claude/project-marker"
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  got_env="$(cat "$CLAUDE_LOG.env")"
  assert_eq "$got_env" "" "Claude settings override should not use CLAUDE_CONFIG_DIR" || return 1
  assert_eq "$(cat .claude/project-marker)" "project-local" "existing project .claude should be left untouched" || return 1
  [[ ! -d ".temp/.claude" ]] || { echo "    temporary .temp/.claude was not cleaned up" >&2; rm -rf ".temp"; return 1; }
}

t_claude_settings_override_does_not_touch_global_non_skill_files() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_global_config
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  [[ -f "$HOME/.claude/auth.json" ]] || { echo "    global auth should not be moved or deleted" >&2; return 1; }
  [[ -f "$HOME/.claude.json" ]] || { echo "    global account file should not be moved or deleted" >&2; return 1; }
  [[ ! -e ".temp/.claude.json" ]] || { echo "    .temp/.claude.json should not be created for Claude settings override" >&2; rm -rf ".temp"; return 1; }
}

t_claude_unchecked_skill_and_plugin_merge_settings() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  setup_claude_plugins
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \033[B\033[B\033[B \n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  got="$(cat "$CLAUDE_LOG")"
  want="$(printf '%s\n' \
    "--settings" \
    '{"skillOverrides":{"alpha":"off"},"enabledPlugins":{"plugin-alpha@official":false}}')"
  assert_eq "$got" "$want" "Claude disabled skill and plugin settings should be merged into one --settings argument"
}

t_debug_prints_codex_launch_command() {
  add_fake_cli codex "$CODEX_LOG"
  setup_codex_resources
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf ' \n''y\n' | AL_DEBUG=1 bash "$MAIN" --foo 2>&1)"
  alpha_skill="$(real_path "$HOME/.codex/skills/alpha/SKILL.md")"
  assert_contains "$out" "Launch command:" || return 1
  assert_contains "$out" "codex" || return 1
  assert_contains "$out" "skills.config=" || return 1
  assert_contains "$out" "$alpha_skill" || return 1
  assert_contains "$out" "--foo" || return 1
}

t_debug_prints_claude_launch_command() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''y\n' | AL_DEBUG=1 bash "$MAIN" --model sonnet 2>&1)"
  assert_contains "$out" "Launch command:" || return 1
  assert_contains "$out" "claude" || return 1
  assert_contains "$out" "--settings" || return 1
  assert_contains "$out" "skillOverrides" || return 1
  assert_contains "$out" "alpha" || return 1
  assert_contains "$out" "off" || return 1
  assert_contains "$out" "--model" || return 1
}

t_debug_arg_is_forwarded_without_enabling_launcher_debug() {
  add_fake_cli claude "$CLAUDE_LOG"
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf 'y\n' | bash "$MAIN" --debug 2>&1)"
  assert_not_contains "$out" "Launch command:" "--debug argument should not enable launcher debug output" || return 1
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  got="$(cat "$CLAUDE_LOG")"
  want="--debug"
  assert_eq "$got" "$want" "--debug should still be forwarded as a normal target CLI argument"
}

t_installer_creates_agent_launch_commands() {
  local install_dir="$TMP/install-bin"
  mkdir -p "$install_dir"
  printf '%s' old > "$install_dir/safe-claude-code"
  ln -sf safe-claude-code "$install_dir/scc"
  printf '%s' old > "$install_dir/scc-config"

  export MOCK_RESP='#!/usr/bin/env bash
echo installed agent launcher
'
  out="$(SCC_INSTALL_DIR="$install_dir" bash "$INSTALLER" 2>&1)"
  assert_contains "$out" "$install_dir/agent-launch" || return 1
  assert_contains "$out" "$install_dir/al -> agent-launch" || return 1
  [[ -x "$install_dir/agent-launch" ]] || { echo "    agent-launch was not installed as executable" >&2; return 1; }
  assert_eq "$(readlink "$install_dir/al")" "agent-launch" "al should point to agent-launch" || return 1
  [[ ! -e "$install_dir/safe-claude-code" ]] || { echo "    old safe-claude-code command should be removed" >&2; return 1; }
  [[ ! -e "$install_dir/scc" ]] || { echo "    old scc command should be removed" >&2; return 1; }
  [[ ! -e "$install_dir/scc-config" ]] || { echo "    old scc-config command should be removed" >&2; return 1; }
}

echo "safe-claude-code:"
run_test "no supported CLI -> deny"                         t_no_cli_denies
run_test "single codex prints ipinfo and runs after yes"     t_single_codex_prints_ipinfo_and_runs_after_yes
run_test "single claude runs after yes"                      t_single_claude_runs_after_yes
run_test "confirmation defaults to yes"                      t_confirmation_defaults_to_yes
run_test "confirmation no cancels"                           t_confirmation_no_cancels
run_test "selector Enter chooses first CLI"                  t_selector_enter_chooses_first_cli
run_test "selector Down+Enter chooses second CLI"            t_selector_down_enter_chooses_second_cli
run_test "selector q cancels"                                t_selector_q_cancels
run_test "curl failure -> deny"                              t_curl_failure_denies
run_test "invalid JSON response -> deny"                     t_invalid_json_denies
run_test "codex unchecked skills/plugins become disables"    t_codex_resource_selector_disables_unchecked_skills_and_plugins_only
run_test "features sorted by type then name"                 t_features_are_sorted_by_type_then_name
run_test "codex reads agent symlink skills real paths"       t_codex_reads_agents_symlink_skills_and_uses_real_paths
run_test "Space on group toggles group members"              t_feature_group_toggle_disables_group_members
run_test "Left on item collapses group"                      t_left_arrow_on_item_collapses_group_and_selects_group_row
run_test "Right on item is ignored"                          t_right_arrow_on_item_is_ignored
run_test "prefixed plugins are grouped"                      t_prefixed_plugins_are_grouped_separately_from_generic_plugins
run_test "prefix root skill joins prefixed group"            t_prefix_root_skill_joins_prefixed_group
run_test "bundle symlink skills are discovered and grouped"  t_bundle_symlink_skills_are_discovered_and_grouped
run_test "large groups collapse by default"                  t_large_group_is_collapsed_by_default
run_test "Right expands collapsed group"                     t_right_arrow_on_collapsed_group_expands_it
run_test "Left collapses expanded group"                     t_left_arrow_on_expanded_group_collapses_it
run_test "Enter on collapsed group continues"                t_enter_on_collapsed_group_continues
run_test "feature selector redraw restores saved cursor"     t_feature_selector_redraw_restores_saved_cursor
run_test "feature selector movement updates rows only"       t_feature_selector_movement_updates_rows_without_full_redraw
run_test "feature selector renders max 20 lines"             t_feature_selector_frame_is_limited_to_20_lines
run_test "Down scrolls feature selector viewport"            t_down_scrolls_feature_selector_viewport
run_test "Down scrolls at third row from bottom"             t_down_scrolls_when_focus_reaches_third_row_from_bottom
run_test "scrolling refreshes rows only"                     t_scrolling_refreshes_rows_without_reprinting_prompt
run_test "Up scrolls at third row from top"                  t_up_scrolls_when_focus_reaches_third_row_from_top
run_test "codex unchecked skill uses skills.config"          t_codex_unchecked_skill_uses_skills_config_override
run_test "claude unchecked skill uses --settings"             t_claude_unchecked_skill_uses_settings_override
run_test "claude ignores agents skills"                       t_claude_does_not_scan_agents_skills
run_test "claude unchecked skill preserves args"               t_claude_unchecked_skill_preserves_user_args
run_test "claude unchecked plugin uses enabledPlugins"         t_claude_unchecked_plugin_uses_enabled_plugins_setting
run_test "claude existing project .claude does not block"      t_claude_existing_project_claude_does_not_block_settings_override
run_test "claude settings leaves global config alone"          t_claude_settings_override_does_not_touch_global_non_skill_files
run_test "claude settings merge skill and plugin disables"     t_claude_unchecked_skill_and_plugin_merge_settings
run_test "debug prints codex launch command"                  t_debug_prints_codex_launch_command
run_test "debug prints claude launch command"                 t_debug_prints_claude_launch_command
run_test "--debug arg is forwarded only"                      t_debug_arg_is_forwarded_without_enabling_launcher_debug
run_test "installer creates agent-launch and al"              t_installer_creates_agent_launch_commands

echo
echo "===================="
printf "Passed: %d\nFailed: %d\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  echo
  echo "Failed tests:"
  for t in "${FAILED[@]}"; do echo "  - $t"; done
  exit 1
fi
