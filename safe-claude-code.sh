#!/usr/bin/env bash
set -euo pipefail
shopt -s nocasematch extglob

API_URL="${SCC_API:-https://ipinfo.io}"
CONFIG_FILE="${SCC_CONFIG_FILE:-$HOME/.config/safe-claude-code/rules.conf}"

deny() {
  echo "❌ $1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >&2
  exit 1
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

resp="$(curl -fsS --max-time 5 "$API_URL")" || deny "Failed to fetch $API_URL"
[[ "$(trim "$resp")" == \{* ]] || deny "Invalid JSON from $API_URL" "$resp"

get_field() {
  local f="$1"
  if [[ "$resp" =~ \"$f\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

rule_keys=()
rule_vals=()

set_rule() {
  local k="$1" v="$2" i
  for i in "${!rule_keys[@]}"; do
    if [[ "${rule_keys[$i]}" == "$k" ]]; then
      rule_vals[$i]="$v"
      return
    fi
  done
  rule_keys+=("$k")
  rule_vals+=("$v")
}

if [[ -f "$CONFIG_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    key="$(trim "${line%%=*}")"
    val="${line#*=}"
    [[ -n "$key" ]] && set_rule "$key" "$val"
  done < "$CONFIG_FILE"
fi

for name in "${!SCC_@}"; do
  field="${name#SCC_}"
  [[ "$field" == "CONFIG_FILE" || "$field" == "API" ]] && continue
  set_rule "$field" "${!name}"
done

if (( ${#rule_keys[@]} == 0 )); then
  deny "No rules configured. Set SCC_<field>=patterns or create $CONFIG_FILE" "$resp"
fi

for i in "${!rule_keys[@]}"; do
  field="${rule_keys[$i]}"
  patterns="${rule_vals[$i]}"
  actual="$(get_field "$field")"
  if [[ -z "$actual" ]]; then
    deny "Field '$field' not present in response" "$resp"
  fi
  matched=0
  IFS=',' read -ra pats <<< "$patterns"
  for pat in "${pats[@]}"; do
    pat="$(trim "$pat")"
    [[ -z "$pat" ]] && continue
    if [[ "$actual" == $pat ]]; then
      matched=1
      break
    fi
  done
  if (( ! matched )); then
    deny "Field '$field'='$actual' does not match: $patterns" "$resp"
  fi
done

exec claude "$@"
