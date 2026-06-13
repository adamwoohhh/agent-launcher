#!/usr/bin/env bash
set -euo pipefail

API_URL="${SCC_API:-https://ipinfo.io}"

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
  printf 'Continue and launch %s? [y/N] ' "$SELECTED_CLI" >&2

  if [[ ! -t 0 && "${SCC_ALLOW_NON_TTY:-}" != "1" ]]; then
    echo >&2
    deny "Confirmation requires a TTY."
  fi

  IFS= read -r answer || cancel
  case "$(trim "$answer")" in
    y|Y|yes|YES|Yes) ;;
    *) cancel ;;
  esac
}

detect_clis
select_cli

resp="$(curl -fsS --max-time 5 "$API_URL")" || deny "Failed to fetch $API_URL"
[[ "$(trim "$resp")" == \{* ]] || deny "Invalid JSON from $API_URL" "$resp"

confirm_launch

exec "$SELECTED_CLI" "$@"
