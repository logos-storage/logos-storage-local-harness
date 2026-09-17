cfg_apply() {
  local _cfg_cmd_arg="$1" _cfg_file="$2" _cfg_preset="${3:-config}"
  if [ "$_cfg_cmd_arg" != "use_conf" ]; then
    return 1
  fi
  if [ ! -f "$_cfg_file" ]; then
    fail "Error: configuration file not found: $_cfg_file"
  fi
  echoerr "Sourcing configuration file: $_cfg_file"
  # shellcheck disable=SC1090
  source "$_cfg_file" || fail "Error sourcing configuration file: $_cfg_file"
  _cfg_apply "${_cfg_preset}" || fail "Error applying configuration from file: $_cfg_file"
}

_cfg_apply() {
  local -n _cfg_apply_values="$1"
  local _cfg_apply_key _cfg_apply_words
  local -a _cfg_apply_items

  if [ "${#_cfg_apply_values[@]}" -eq 0 ]; then
    echoerr "Error: configuration ${1} variable is empty or not an associative array"
    return 1
  fi

  for _cfg_apply_key in "${!_cfg_apply_values[@]}"; do
    if [[ "$_cfg_apply_key" == *_arr ]]; then
      # Strip the suffix and split on spaces, preserving literal shell characters.
      IFS=' ' read -r -d '' -a _cfg_apply_items < <(printf '%s\0' "${_cfg_apply_values[$_cfg_apply_key]}")
      _cfg_apply_words=''
      if [ "${#_cfg_apply_items[@]}" -gt 0 ]; then
        printf -v _cfg_apply_words '%q ' "${_cfg_apply_items[@]}"
      fi
      declare -ga -- "cfg_${_cfg_apply_key%_arr}=(${_cfg_apply_words})" || return 1
    else
      declare -g -- "cfg_${_cfg_apply_key}=${_cfg_apply_values[$_cfg_apply_key]}" || return 1
    fi
  done

  # shellcheck disable=SC2034 # Read indirectly by cfg_par_string and by callers.
  declare -g -- cfg_name="${1}"
}

# Format applied configuration keys as CSV fields in the requested order.
# Array keys keep their original _arr suffix; their items are joined by spaces.
cfg_par_string() {
  local _cfg_key _cfg_var _cfg_field _cfg_output='' _cfg_separator=''
  local IFS=' '

  for _cfg_key in "$@"; do
    if [[ ! "$_cfg_key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      echoerr "Error: invalid configuration key: $_cfg_key"
      return 1
    fi
    _cfg_var="cfg_${_cfg_key%_arr}"
    if ! declare -p "$_cfg_var" &>/dev/null; then
      echoerr "Error: configuration key is not set: $_cfg_key"
      return 1
    fi
    local -n _cfg_value="$_cfg_var"
    _cfg_field="${_cfg_value[*]}"
    # Quotes values with commas, newlines, carriage returns, or double 
    # quotes AND escape double quotes.
    if [[ "$_cfg_field" == *[,$'\r\n'\"]* ]]; then
      _cfg_field="\"${_cfg_field//\"/\"\"}\""
    fi
    _cfg_output+="${_cfg_separator}${_cfg_field}"
    _cfg_separator=,
  done

  printf '%s' "$_cfg_output"
}
