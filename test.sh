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

t_codex_resource_selector_disables_unchecked_items() {
  add_fake_cli codex "$CODEX_LOG"
  setup_codex_resources
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'a\n''y\n' | bash "$MAIN" --foo 2>&1)"
  assert_contains "$out" "Select features to enable" || return 1
  assert_contains "$out" "MOCK_codex_CALLED" || return 1
  got="$(cat "$CODEX_LOG")"
  alpha_skill="$(real_path "$HOME/.codex/skills/alpha/SKILL.md")"
  beta_skill="$(real_path "$HOME/.codex/skills/beta/SKILL.md")"
  want="$(printf '%s\n' \
    "-c" \
    "skills.config=[{path=\"$alpha_skill\",enabled=false},{path=\"$beta_skill\",enabled=false}]" \
    "-c" \
    'plugins."browser@openai-bundled".enabled=false' \
    "-c" \
    "mcp_servers.node_repl.enabled=false" \
    "--foo")"
  assert_eq "$got" "$want" "disabled Codex resources were not converted to config overrides" || return 1
  assert_not_contains "$got" 'skills."alpha".enabled=false' "Codex skill disable should not use unsupported -c key"
  got_env="$(cat "$CODEX_LOG.codex_env")"
  assert_eq "$got_env" "" "Codex skill disable should not use temporary CODEX_HOME"
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
  out="$(printf 'g\n''y\n' | bash "$MAIN" --foo 2>&1)"
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

t_prefix_root_skill_joins_prefixed_group() {
  add_fake_cli codex "$CODEX_LOG"
  setup_understand_skills
  export MOCK_RESP='{"ip":"1.2.3.4","country":"CN"}'
  out="$(printf 'g\n''y\n' | bash "$MAIN" --foo 2>&1)"
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
  out="$(printf 'g\n''y\n' | bash "$MAIN" --foo 2>&1)"
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

t_claude_unchecked_skill_creates_local_claude_after_confirm() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''y\n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "Create temporary .claude" || return 1
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  skill_log="$(cat "$CLAUDE_LOG.skills")"
  assert_not_contains "$skill_log" "/alpha/SKILL.md" "disabled skill alpha was copied" || return 1
  assert_contains "$skill_log" "/beta/SKILL.md" "enabled skill beta was not available" || return 1
  skill_links="$(cat "$CLAUDE_LOG.skill_links")"
  beta_skill_dir="$(real_path "$HOME/.claude/skills/beta")"
  assert_contains "$skill_links" "$PWD/.claude/skills/beta -> $beta_skill_dir" "enabled skill beta should be symlinked from global config" || return 1
  got_env="$(cat "$CLAUDE_LOG.env")"
  assert_eq "$got_env" "$PWD/.claude" "Claude was not launched with local CLAUDE_CONFIG_DIR"
  [[ ! -d ".claude" ]] || { echo "    temporary .claude was not cleaned up" >&2; rm -rf ".claude"; return 1; }
}

t_claude_unchecked_skill_requires_local_claude_confirmation() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''n\n' | bash "$MAIN" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1" || return 1
  assert_contains "$out" "Create temporary .claude" || return 1
  assert_not_contains "$out" "MOCK_claude_CALLED" || return 1
  [[ ! -d ".claude" ]] || { echo "    .claude should not be created when user declines" >&2; rm -rf ".claude"; return 1; }
}

t_claude_local_claude_creation_defaults_to_yes() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''\n''\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "Create temporary .claude" || return 1
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  got_env="$(cat "$CLAUDE_LOG.env")"
  assert_eq "$got_env" "$PWD/.claude" "Claude was not launched with local CLAUDE_CONFIG_DIR"
  [[ ! -d ".claude" ]] || { echo "    temporary .claude was not cleaned up" >&2; rm -rf ".claude"; return 1; }
}

t_claude_temp_config_inherits_global_non_skill_files() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_global_config
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf ' \n''y\n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  inherited="$(cat "$CLAUDE_LOG.inherited")"
  assert_contains "$inherited" "auth.json=auth-token" "global auth was not available in temporary .claude" || return 1
  assert_contains "$inherited" 'settings.json={"theme":"dark"}' "global settings were not available in temporary .claude" || return 1
  assert_contains "$inherited" "projects/current.json=project-state" "global project state was not available in temporary .claude" || return 1
  assert_contains "$inherited" "cache/token.txt=cached-token" "global cache was not available in temporary .claude" || return 1
  assert_contains "$inherited" '.claude.json={"account":"logged-in"}' "global Claude account file was not available in temporary .claude" || return 1
  [[ ! -d ".claude" ]] || { echo "    temporary .claude was not cleaned up" >&2; rm -rf ".claude"; return 1; }
}

t_claude_unchecked_plugin_creates_temp_plugins_without_disabled_plugin() {
  add_fake_cli claude "$CLAUDE_LOG"
  setup_claude_skills
  setup_claude_plugins
  export MOCK_RESP='{"ip":"5.6.7.8","country":"HK"}'
  out="$(printf '\033[B\033[B \n''y\n''y\n' | bash "$MAIN" 2>&1)"
  assert_contains "$out" "official:plugin-alpha" || return 1
  assert_contains "$out" "official:plugin-beta" || return 1
  assert_contains "$out" "MOCK_claude_CALLED" || return 1
  plugin_log="$(cat "$CLAUDE_LOG.plugins")"
  assert_not_contains "$plugin_log" "/plugin-alpha" "disabled plugin alpha was available in temporary .claude" || return 1
  assert_contains "$plugin_log" "/plugin-beta" "enabled plugin beta was not available in temporary .claude" || return 1
  assert_contains "$plugin_log" "/plugin-gamma" "unlisted plugin gamma should be preserved in temporary .claude" || return 1
  [[ -d "$HOME/.claude/plugins/marketplaces/official/plugins/plugin-alpha" ]] || { echo "    global disabled plugin should not be deleted" >&2; return 1; }
  [[ ! -d ".claude" ]] || { echo "    temporary .claude was not cleaned up" >&2; rm -rf ".claude"; return 1; }
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
run_test "codex unchecked resources become -c disables"      t_codex_resource_selector_disables_unchecked_items
run_test "codex reads agent symlink skills real paths"       t_codex_reads_agents_symlink_skills_and_uses_real_paths
run_test "feature group toggle disables group members"       t_feature_group_toggle_disables_group_members
run_test "prefix root skill joins prefixed group"            t_prefix_root_skill_joins_prefixed_group
run_test "bundle symlink skills are discovered and grouped"  t_bundle_symlink_skills_are_discovered_and_grouped
run_test "codex unchecked skill uses skills.config"          t_codex_unchecked_skill_uses_skills_config_override
run_test "claude unchecked skill creates local .claude"       t_claude_unchecked_skill_creates_local_claude_after_confirm
run_test "claude local .claude creation requires confirm"     t_claude_unchecked_skill_requires_local_claude_confirmation
run_test "claude local .claude creation defaults to yes"      t_claude_local_claude_creation_defaults_to_yes
run_test "claude temp config inherits global non-skill files" t_claude_temp_config_inherits_global_non_skill_files
run_test "claude unchecked plugin creates temp plugins"       t_claude_unchecked_plugin_creates_temp_plugins_without_disabled_plugin
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
