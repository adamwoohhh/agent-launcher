#!/usr/bin/env bash
set -euo pipefail

API_URL="${SCC_API:-https://ipinfo.io}"
CLAUDE_SESSION_DIR="$PWD/.claude"

deny() {
  echo "❌ $1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >&2
  exit 1
}

cancel() {
  echo "Cancelled." >&2
  exit 1
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

detect_clis() {
  cli_names=()
  cli_paths=()

  if command -v codex >/dev/null 2>&1; then
    cli_names+=("codex")
    cli_paths+=("$(command -v codex)")
  fi

  if command -v claude >/dev/null 2>&1; then
    cli_names+=("claude")
    cli_paths+=("$(command -v claude)")
  fi
}

render_cli_menu() {
  local selected="$1" i prefix

  if (( MENU_RENDERED_LINES > 0 )); then
    printf '\033[%dA' "$MENU_RENDERED_LINES" >&2
  fi

  printf '\033[?25l' >&2
  printf 'Select CLI to launch:\033[K\n\033[K\n' >&2

  for i in "${!cli_names[@]}"; do
    if [[ "$i" == "$selected" ]]; then
      prefix=">"
    else
      prefix=" "
    fi
    printf '%s %-10s %s\033[K\n' "$prefix" "${cli_names[$i]}" "${cli_paths[$i]}" >&2
  done

  printf '\033[K\n↑/↓ move, Enter select, q cancel\033[K\n' >&2
  MENU_RENDERED_LINES=$((${#cli_names[@]} + 4))
}

restore_cursor() {
  printf '\033[?25h' >&2
}

read_key() {
  local key rest

  IFS= read -r -s -n1 key || return 1
  if [[ "$key" == $'\e' ]]; then
    IFS= read -r -s -n2 -t 1 rest || rest=""
    key+="$rest"
  fi

  printf '%s' "$key"
}

add_feature() {
  feature_types+=("$1")
  feature_names+=("$2")
  feature_paths+=("$3")
  feature_groups+=("$1")
  feature_selected+=("1")
  FEATURE_COUNT=$((FEATURE_COUNT + 1))
}

group_index() {
  local group="$1" i
  for i in "${!feature_group_names[@]}"; do
    if [[ "${feature_group_names[$i]}" == "$group" ]]; then
      printf '%s' "$i"
      return
    fi
  done
  printf '%s' "-1"
}

resolve_dir() {
  local dir="$1"
  (cd -P "$dir" 2>/dev/null && pwd)
}

discover_skill_dir() {
  local root="$1" entry skill_file name real_dir child_dir child_name child_real_dir
  [[ -d "$root" ]] || return 0

  while IFS= read -r entry; do
    name="$(basename "$entry")"
    real_dir="$(resolve_dir "$entry")"
    [[ -n "$name" && -n "$real_dir" ]] || continue
    skill_file="$real_dir/SKILL.md"
    if [[ -f "$skill_file" ]]; then
      add_feature "skill" "$name" "$real_dir"
      continue
    fi

    while IFS= read -r skill_file; do
      child_dir="$(dirname "$skill_file")"
      child_name="$(basename "$child_dir")"
      child_real_dir="$(resolve_dir "$child_dir")"
      [[ -n "$child_name" && -n "$child_real_dir" ]] || continue
      add_feature "skill" "$name:$child_name" "$child_real_dir"
    done < <(find -L "$real_dir" -mindepth 2 -maxdepth 2 -name SKILL.md -type f 2>/dev/null | sort)
  done < <(find -L "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
}

discover_codex_config_resources() {
  local config="$HOME/.codex/config.toml"
  local line plugin
  [[ -f "$config" ]] || return 0

  plugin=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[plugins\.\"([^\"]+)\"\]$ ]]; then
      plugin="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^\[mcp_servers\.([A-Za-z0-9_-]+)\]$ ]]; then
      add_feature "mcp" "${BASH_REMATCH[1]}" "$config"
      plugin=""
      continue
    fi
    if [[ -n "$plugin" && "$line" =~ ^enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$ ]]; then
      add_feature "plugin" "$plugin" "$config"
      plugin=""
      continue
    fi
  done < "$config"
  return 0
}

discover_claude_plugins() {
  local root="$HOME/.claude/plugins/marketplaces"
  local marker plugin_dir plugin_name section_dir section marketplace_dir marketplace
  [[ -d "$root" ]] || return 0

  while IFS= read -r marker; do
    plugin_dir="$(dirname "$(dirname "$marker")")"
    plugin_name="$(basename "$plugin_dir")"
    section_dir="$(dirname "$plugin_dir")"
    section="$(basename "$section_dir")"
    [[ "$section" == "plugins" || "$section" == "external_plugins" ]] || continue
    marketplace_dir="$(dirname "$section_dir")"
    marketplace="$(basename "$marketplace_dir")"
    [[ -n "$marketplace" && -n "$plugin_name" ]] || continue
    add_feature "plugin" "$marketplace:$plugin_name" "$(resolve_dir "$plugin_dir")"
  done < <(find -L "$root" -mindepth 5 -maxdepth 5 -path '*/.claude-plugin/plugin.json' -type f 2>/dev/null | sort)
}

discover_features() {
  feature_types=()
  feature_names=()
  feature_paths=()
  feature_groups=()
  feature_selected=()
  FEATURE_COUNT=0

  case "$SELECTED_CLI" in
    codex)
      discover_skill_dir "$HOME/.agents/skills"
      discover_skill_dir "$HOME/.codex/skills"
      discover_codex_config_resources
      ;;
    claude)
      discover_skill_dir "$HOME/.agents/skills"
      discover_skill_dir "$HOME/.claude/skills"
      discover_claude_plugins
      ;;
  esac
  assign_feature_groups
}

prefix_exists() {
  local prefix="$1" i
  for i in "${!feature_names[@]}"; do
    if [[ "${feature_types[$i]}" == "skill" && "${feature_names[$i]}" == "$prefix-"* ]]; then
      return 0
    fi
  done
  return 1
}

assign_feature_groups() {
  local i name prefix
  for i in "${!feature_names[@]}"; do
    name="${feature_names[$i]}"
    if [[ "${feature_types[$i]}" == "skill" ]]; then
      if [[ "$name" == *:* ]]; then
        feature_groups[$i]="${name%%:*}"
      elif [[ "$name" == *-* ]]; then
        feature_groups[$i]="${name%%-*}"
      elif prefix_exists "$name"; then
        feature_groups[$i]="$name"
      else
        feature_groups[$i]="skill"
      fi
    else
      feature_groups[$i]="${feature_types[$i]}"
    fi
  done
}

print_feature_row() {
  local row="$1" selected="$2" row_type i cursor mark group group_state size suffix

  row_type="${visible_row_types[$row]}"
  group="${visible_row_groups[$row]}"
  if [[ "$row" == "$selected" ]]; then
    cursor=">"
  else
    cursor=" "
  fi

  if [[ "$row_type" == "group" ]]; then
    group_state="$(group_mark "$group")"
    size="$(group_size "$group")"
    if group_collapsed "$group"; then
      suffix=" ($size, collapsed)"
    else
      suffix=" ($size)"
    fi
    printf '%s %s \033[1m%s\033[0m%s\033[K' "$cursor" "$group_state" "$group" "$suffix" >&2
  else
    i="${visible_row_feature_indexes[$row]}"
    if [[ "${feature_selected[$i]}" == "1" ]]; then
      mark="[x]"
    else
      mark="[ ]"
    fi
    printf '%s   %s %-7s %s\033[K' "$cursor" "$mark" "${feature_types[$i]}" "${feature_names[$i]}" >&2
  fi
}

render_feature_row_at() {
  local row="$1" selected="$2" screen_row

  if (( row < FEATURE_MENU_SCROLL || row >= FEATURE_MENU_SCROLL + FEATURE_MENU_BODY_LINES )); then
    return
  fi

  screen_row=$((2 + row - FEATURE_MENU_SCROLL))
  printf '\0338\033[%dB' "$screen_row" >&2
  print_feature_row "$row" "$selected"
}

finish_feature_partial_render() {
  printf '\0338\033[%dB' "$FEATURE_MENU_MAX_LINES" >&2
}

render_feature_menu() {
  local selected="$1" row end_row

  if (( FEATURE_MENU_RENDERED_LINES > 0 )); then
    printf '\0338\033[J' >&2
  else
    printf '\0337' >&2
  fi

  build_visible_feature_rows
  adjust_feature_scroll

  printf '\033[?25l' >&2
  printf 'Select features to enable:\033[K\n\033[K\n' >&2

  end_row=$((FEATURE_MENU_SCROLL + FEATURE_MENU_BODY_LINES))
  if (( end_row > VISIBLE_ROW_COUNT )); then
    end_row="$VISIBLE_ROW_COUNT"
  fi

  for (( row = FEATURE_MENU_SCROLL; row < end_row; row++ )); do
    print_feature_row "$row" "$selected"
    printf '\n' >&2
  done

  for (( ; row < FEATURE_MENU_SCROLL + FEATURE_MENU_BODY_LINES; row++ )); do
    printf '\033[K\n' >&2
  done

  printf '\033[K\n↑/↓ move/scroll, ←/→ collapse/expand, Space toggle item, g toggle group, Enter continue, a toggle all, q cancel\033[K\n' >&2
  FEATURE_MENU_RENDERED_LINES=1
}

group_mark() {
  local group="$1" i selected=0 total=0
  for i in "${!feature_names[@]}"; do
    [[ "${feature_groups[$i]}" == "$group" ]] || continue
    total=$((total + 1))
    [[ "${feature_selected[$i]}" == "1" ]] && selected=$((selected + 1))
  done
  if (( selected == 0 )); then
    printf '[ ]'
  elif (( selected == total )); then
    printf '[x]'
  else
    printf '[-]'
  fi
}

count_groups() {
  local i previous="" count=0
  for i in "${!feature_names[@]}"; do
    if [[ "${feature_groups[$i]}" != "$previous" ]]; then
      previous="${feature_groups[$i]}"
      count=$((count + 1))
    fi
  done
  GROUP_COUNT="$count"
}

initialize_feature_menu_groups() {
  local i group idx
  feature_group_names=()
  feature_group_sizes=()
  feature_group_collapsed=()

  for i in "${!feature_names[@]}"; do
    group="${feature_groups[$i]}"
    idx="$(group_index "$group")"
    if (( idx < 0 )); then
      feature_group_names+=("$group")
      feature_group_sizes+=("1")
      feature_group_collapsed+=("0")
    else
      feature_group_sizes[$idx]=$((feature_group_sizes[$idx] + 1))
    fi
  done

  for i in "${!feature_group_names[@]}"; do
    if (( feature_group_sizes[$i] > 5 )); then
      feature_group_collapsed[$i]="1"
    fi
  done
}

group_size() {
  local idx
  idx="$(group_index "$1")"
  if (( idx >= 0 )); then
    printf '%s' "${feature_group_sizes[$idx]}"
  else
    printf '%s' "0"
  fi
}

group_collapsed() {
  local idx
  idx="$(group_index "$1")"
  [[ "$idx" != "-1" && "${feature_group_collapsed[$idx]}" == "1" ]]
}

toggle_group_collapsed() {
  local idx
  idx="$(group_index "$1")"
  (( idx >= 0 )) || return
  if [[ "${feature_group_collapsed[$idx]}" == "1" ]]; then
    feature_group_collapsed[$idx]="0"
  else
    feature_group_collapsed[$idx]="1"
  fi
}

collapse_group() {
  local idx
  idx="$(group_index "$1")"
  (( idx >= 0 )) || return 1
  [[ "${feature_group_collapsed[$idx]}" == "1" ]] && return 1
  feature_group_collapsed[$idx]="1"
}

expand_group() {
  local idx
  idx="$(group_index "$1")"
  (( idx >= 0 )) || return 1
  [[ "${feature_group_collapsed[$idx]}" == "0" ]] && return 1
  feature_group_collapsed[$idx]="0"
}

build_visible_feature_rows() {
  local i previous_group="" group
  visible_row_types=()
  visible_row_feature_indexes=()
  visible_row_groups=()

  for i in "${!feature_names[@]}"; do
    group="${feature_groups[$i]}"
    if [[ "$group" != "$previous_group" ]]; then
      previous_group="$group"
      visible_row_types+=("group")
      visible_row_feature_indexes+=("-1")
      visible_row_groups+=("$group")
    fi

    if ! group_collapsed "$group"; then
      visible_row_types+=("item")
      visible_row_feature_indexes+=("$i")
      visible_row_groups+=("$group")
    fi
  done
  VISIBLE_ROW_COUNT="${#visible_row_types[@]}"
}

first_visible_item_row() {
  local i
  for i in "${!visible_row_types[@]}"; do
    if [[ "${visible_row_types[$i]}" == "item" ]]; then
      printf '%s' "$i"
      return
    fi
  done
  printf '%s' "0"
}

initial_feature_row() {
  if [[ "${visible_row_types[0]}" == "group" ]] && group_collapsed "${visible_row_groups[0]}"; then
    printf '%s' "0"
  else
    first_visible_item_row
  fi
}

clamp_feature_cursor() {
  if (( selected_row < 0 )); then
    selected_row=0
  elif (( selected_row >= VISIBLE_ROW_COUNT )); then
    selected_row=$((VISIBLE_ROW_COUNT - 1))
  fi
}

adjust_feature_scroll() {
  clamp_feature_cursor
  if (( selected_row < FEATURE_MENU_SCROLL )); then
    FEATURE_MENU_SCROLL="$selected_row"
  elif (( selected_row >= FEATURE_MENU_SCROLL + FEATURE_MENU_BODY_LINES )); then
    FEATURE_MENU_SCROLL=$((selected_row - FEATURE_MENU_BODY_LINES + 1))
  fi
  if (( FEATURE_MENU_SCROLL < 0 )); then
    FEATURE_MENU_SCROLL=0
  fi
}

toggle_group() {
  local group="$1" i any_selected=0
  for i in "${!feature_names[@]}"; do
    [[ "${feature_groups[$i]}" == "$group" ]] || continue
    [[ "${feature_selected[$i]}" == "1" ]] && any_selected=1
  done
  for i in "${!feature_names[@]}"; do
    [[ "${feature_groups[$i]}" == "$group" ]] || continue
    if (( any_selected )); then
      feature_selected[$i]="0"
    else
      feature_selected[$i]="1"
    fi
  done
}

select_features() {
  local selected_row=0 key i any_selected row_type feature_index group
  local needs_full_render=1 old_selected_row old_scroll

  discover_features
  if (( FEATURE_COUNT == 0 )); then
    return
  fi
  count_groups
  initialize_feature_menu_groups
  build_visible_feature_rows
  selected_row="$(initial_feature_row)"

  if [[ ! -t 0 && "${SCC_ALLOW_NON_TTY:-}" != "1" ]]; then
    deny "Interactive feature selection requires a TTY."
  fi

  FEATURE_MENU_MAX_LINES=20
  FEATURE_MENU_BODY_LINES=$((FEATURE_MENU_MAX_LINES - 4))
  FEATURE_MENU_SCROLL=0
  FEATURE_MENU_RENDERED_LINES=0
  trap 'restore_cursor; echo >&2; exit 130' INT TERM
  while true; do
    if (( needs_full_render )); then
      render_feature_menu "$selected_row"
      needs_full_render=0
    fi
    key="$(read_key)" || { restore_cursor; echo >&2; cancel; }
    row_type="${visible_row_types[$selected_row]}"
    feature_index="${visible_row_feature_indexes[$selected_row]}"
    group="${visible_row_groups[$selected_row]}"

    case "$key" in
      $'\e[A')
        old_selected_row="$selected_row"
        old_scroll="$FEATURE_MENU_SCROLL"
        if (( selected_row == 0 )); then
          selected_row=$((VISIBLE_ROW_COUNT - 1))
        else
          selected_row=$((selected_row - 1))
        fi
        adjust_feature_scroll
        if (( FEATURE_MENU_SCROLL == old_scroll )); then
          render_feature_row_at "$old_selected_row" "$selected_row"
          render_feature_row_at "$selected_row" "$selected_row"
          finish_feature_partial_render
        else
          needs_full_render=1
        fi
        ;;
      $'\e[B')
        old_selected_row="$selected_row"
        old_scroll="$FEATURE_MENU_SCROLL"
        selected_row=$(((selected_row + 1) % VISIBLE_ROW_COUNT))
        adjust_feature_scroll
        if (( FEATURE_MENU_SCROLL == old_scroll )); then
          render_feature_row_at "$old_selected_row" "$selected_row"
          render_feature_row_at "$selected_row" "$selected_row"
          finish_feature_partial_render
        else
          needs_full_render=1
        fi
        ;;
      $'\e[D')
        if [[ "$row_type" == "group" ]] && collapse_group "$group"; then
          build_visible_feature_rows
          clamp_feature_cursor
          needs_full_render=1
        fi
        ;;
      $'\e[C')
        if [[ "$row_type" == "group" ]] && expand_group "$group"; then
          build_visible_feature_rows
          clamp_feature_cursor
          needs_full_render=1
        fi
        ;;
      " ")
        if [[ "$row_type" == "item" ]]; then
          if [[ "${feature_selected[$feature_index]}" == "1" ]]; then
            feature_selected[$feature_index]="0"
          else
            feature_selected[$feature_index]="1"
          fi
        fi
        needs_full_render=1
        ;;
      g|G)
        toggle_group "$group"
        needs_full_render=1
        ;;
      a|A)
        any_selected=0
        for i in "${!feature_selected[@]}"; do
          [[ "${feature_selected[$i]}" == "1" ]] && any_selected=1
        done
        for i in "${!feature_selected[@]}"; do
          if (( any_selected )); then
            feature_selected[$i]="0"
          else
            feature_selected[$i]="1"
          fi
        done
        needs_full_render=1
        ;;
      "")
        restore_cursor
        trap - INT TERM
        echo >&2
        return
        ;;
      q|Q)
        restore_cursor
        trap - INT TERM
        echo >&2
        cancel
        ;;
    esac
  done
}

build_codex_feature_args() {
  local i type name skill_config
  cli_extra_args=()
  skill_config=""

  for i in "${!feature_names[@]}"; do
    [[ "${feature_selected[$i]}" == "0" ]] || continue
    type="${feature_types[$i]}"
    name="${feature_names[$i]}"
    case "$type" in
      skill)
        if [[ -f "${feature_paths[$i]}/SKILL.md" ]]; then
          if [[ -n "$skill_config" ]]; then
            skill_config+=","
          fi
          skill_config+="{path=\"${feature_paths[$i]}/SKILL.md\",enabled=false}"
        fi
        ;;
      plugin) cli_extra_args+=("-c" "plugins.\"$name\".enabled=false") ;;
      mcp)    cli_extra_args+=("-c" "mcp_servers.$name.enabled=false") ;;
    esac
  done

  if [[ -n "$skill_config" ]]; then
    cli_extra_args=("-c" "skills.config=[$skill_config]" ${cli_extra_args[@]+"${cli_extra_args[@]}"})
  fi
}

has_disabled_features() {
  local i
  for i in "${!feature_selected[@]}"; do
    [[ "${feature_selected[$i]}" == "0" ]] && return 0
  done
  return 1
}

confirm_claude_session_dir() {
  local answer

  echo >&2
  printf 'Create temporary .claude in %s for this Claude session? [Y/n] ' "$PWD" >&2
  IFS= read -r answer || cancel
  case "$(trim "$answer")" in
    ""|y|Y|yes|YES|Yes) ;;
    *) cancel ;;
  esac
}

inherit_claude_global_config() {
  local global_dir="$HOME/.claude" entry name
  [[ -d "$global_dir" ]] || return 0

  while IFS= read -r entry; do
    name="$(basename "$entry")"
    [[ "$name" == "skills" || "$name" == "plugins" ]] && continue
    ln -s "$entry" "$CLAUDE_SESSION_DIR/$name"
  done < <(find "$global_dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort)

  if [[ -e "$HOME/.claude.json" ]]; then
    ln -s "$HOME/.claude.json" "$CLAUDE_SESSION_DIR/.claude.json"
  fi
}

claude_plugin_disabled_by_path() {
  local path="$1" i
  for i in "${!feature_names[@]}"; do
    [[ "${feature_types[$i]}" == "plugin" ]] || continue
    [[ "${feature_paths[$i]}" == "$path" ]] || continue
    [[ "${feature_selected[$i]}" == "0" ]]
    return
  done
  return 1
}

prepare_claude_plugins() {
  local global_plugins="$HOME/.claude/plugins"
  local global_marketplaces="$global_plugins/marketplaces"
  local target_plugins="$CLAUDE_SESSION_DIR/plugins"
  local entry marketplace_dir marketplace_name section_dir section plugin_dir plugin_name plugin_real target_dir
  [[ -d "$global_plugins" ]] || return 0

  mkdir -p "$target_plugins"
  while IFS= read -r entry; do
    [[ "$(basename "$entry")" == "marketplaces" ]] && continue
    ln -s "$entry" "$target_plugins/$(basename "$entry")"
  done < <(find "$global_plugins" -mindepth 1 -maxdepth 1 2>/dev/null | sort)

  [[ -d "$global_marketplaces" ]] || return 0
  mkdir -p "$target_plugins/marketplaces"
  while IFS= read -r marketplace_dir; do
    marketplace_name="$(basename "$marketplace_dir")"
    mkdir -p "$target_plugins/marketplaces/$marketplace_name"
    while IFS= read -r entry; do
      case "$(basename "$entry")" in
        plugins|external_plugins) continue ;;
      esac
      ln -s "$entry" "$target_plugins/marketplaces/$marketplace_name/$(basename "$entry")"
    done < <(find "$marketplace_dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
  done < <(find "$global_marketplaces" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  while IFS= read -r section_dir; do
    section="$(basename "$section_dir")"
    marketplace_dir="$(dirname "$section_dir")"
    marketplace_name="$(basename "$marketplace_dir")"
    target_dir="$target_plugins/marketplaces/$marketplace_name/$section"
    mkdir -p "$target_dir"
    while IFS= read -r plugin_dir; do
      plugin_name="$(basename "$plugin_dir")"
      plugin_real="$(resolve_dir "$plugin_dir")"
      [[ -n "$plugin_real" ]] || continue
      claude_plugin_disabled_by_path "$plugin_real" && continue
      ln -s "$plugin_real" "$target_dir/$plugin_name"
    done < <(find -L "$section_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  done < <(find "$global_marketplaces" -mindepth 2 -maxdepth 2 -type d \( -name plugins -o -name external_plugins \) 2>/dev/null | sort)
}

prepare_claude_session_dir() {
  local i type name path target

  if ! has_disabled_features; then
    return
  fi

  confirm_claude_session_dir
  [[ ! -e "$CLAUDE_SESSION_DIR" ]] || deny "$CLAUDE_SESSION_DIR already exists; refusing to overwrite it."

  mkdir -p "$CLAUDE_SESSION_DIR"
  inherit_claude_global_config
  mkdir -p "$CLAUDE_SESSION_DIR/skills"
  prepare_claude_plugins
  CLAUDE_TEMP_CONFIG_CREATED=1
  for i in "${!feature_names[@]}"; do
    [[ "${feature_selected[$i]}" == "1" ]] || continue
    type="${feature_types[$i]}"
    name="${feature_names[$i]}"
    path="${feature_paths[$i]}"
    if [[ "$type" == "skill" && -d "$path" ]]; then
      target="$CLAUDE_SESSION_DIR/skills/$name"
      mkdir -p "$(dirname "$target")"
      ln -s "$path" "$target"
    fi
  done

  export CLAUDE_CONFIG_DIR="$CLAUDE_SESSION_DIR"
}

select_cli() {
  local selected=0 key

  if (( ${#cli_names[@]} == 0 )); then
    deny "No supported CLI found. Install codex or claude first."
  fi

  if (( ${#cli_names[@]} == 1 )); then
    SELECTED_CLI="${cli_names[0]}"
    echo "Detected CLI: $SELECTED_CLI (${cli_paths[0]})" >&2
    return
  fi

  if [[ ! -t 0 && "${SCC_ALLOW_NON_TTY:-}" != "1" ]]; then
    deny "Interactive CLI selection requires a TTY."
  fi

  MENU_RENDERED_LINES=0
  trap 'restore_cursor; echo >&2; exit 130' INT TERM
  while true; do
    render_cli_menu "$selected"
    key="$(read_key)" || { restore_cursor; echo >&2; cancel; }

    case "$key" in
      $'\e[A')
        if (( selected == 0 )); then
          selected=$((${#cli_names[@]} - 1))
        else
          selected=$((selected - 1))
        fi
        ;;
      $'\e[B')
        selected=$(((selected + 1) % ${#cli_names[@]}))
        ;;
      "")
        SELECTED_CLI="${cli_names[$selected]}"
        restore_cursor
        trap - INT TERM
        echo >&2
        echo "Selected CLI: $SELECTED_CLI (${cli_paths[$selected]})" >&2
        return
        ;;
      q|Q)
        restore_cursor
        trap - INT TERM
        echo >&2
        cancel
        ;;
    esac
  done
}

confirm_launch() {
  local answer

  echo >&2
  echo "IPinfo response:" >&2
  printf '%s\n' "$resp" >&2
  echo >&2
  printf 'Continue and launch %s? [Y/n] ' "$SELECTED_CLI" >&2

  if [[ ! -t 0 && "${SCC_ALLOW_NON_TTY:-}" != "1" ]]; then
    echo >&2
    deny "Confirmation requires a TTY."
  fi

  IFS= read -r answer || cancel
  case "$(trim "$answer")" in
    ""|y|Y|yes|YES|Yes) ;;
    *) cancel ;;
  esac
}

detect_clis
select_cli
select_features
if [[ "$SELECTED_CLI" == "claude" ]]; then
  prepare_claude_session_dir
fi

resp="$(curl -fsS --max-time 5 "$API_URL")" || deny "Failed to fetch $API_URL"
[[ "$(trim "$resp")" == \{* ]] || deny "Invalid JSON from $API_URL" "$resp"

confirm_launch

cli_extra_args=()
if [[ "$SELECTED_CLI" == "codex" ]]; then
  build_codex_feature_args
fi

if [[ "${CLAUDE_TEMP_CONFIG_CREATED:-0}" == "1" ]]; then
  set +e
  "$SELECTED_CLI" ${cli_extra_args[@]+"${cli_extra_args[@]}"} "$@"
  rc=$?
  set -e
  rm -rf "$CLAUDE_SESSION_DIR"
  exit "$rc"
fi

exec "$SELECTED_CLI" ${cli_extra_args[@]+"${cli_extra_args[@]}"} "$@"
