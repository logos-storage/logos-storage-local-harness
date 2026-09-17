#!/usr/bin/env bash
# Run an experiment once per configuration whose name matches a shell glob.
set -e -o pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <experiment_script> <configuration_script> '<pattern>'" >&2
  exit 1
fi

experiment_script=$1
configuration_script=$2
pattern=$3

for script in "$experiment_script" "$configuration_script"; do
  if [[ ! -f "$script" || ! -r "$script" ]]; then
    echo "Error: script is not a readable file: $script" >&2
    exit 1
  fi
done

# Ensure source resolves relative paths against the working directory, not PATH.
if [[ "$configuration_script" != /* ]]; then
  configuration_script="$PWD/$configuration_script"
fi

# Source in a subshell so configuration variables cannot change the runner.
configuration_names() (
  _rwc_existing=$'\n'$(compgen -A arrayvar)$'\n'
  # shellcheck disable=SC1090
  source "$1" >&2 || exit 1

  while IFS= read -r _rwc_name; do
    # Ignore Bash's built-in arrays and other arrays present before sourcing.
    [[ "$_rwc_existing" != *$'\n'"$_rwc_name"$'\n'* ]] || continue
    _rwc_declaration=$(declare -p "$_rwc_name")
    if [[ "$_rwc_declaration" =~ ^declare\ -[^[:space:]]*A ]]; then
      printf '%s\n' "$_rwc_name"
    fi
  done < <(compgen -A arrayvar | LC_ALL=C sort)
)

names=$(configuration_names "$configuration_script") || {
  echo "Error: could not load configurations from $configuration_script" >&2
  exit 1
}

matched=false
status=0
while IFS= read -r name; do
  # The unquoted right-hand side intentionally performs shell glob matching.
  # shellcheck disable=SC2053
  [[ -n "$name" && "$name" == $pattern ]] || continue
  matched=true
  echo "Running $experiment_script with configuration $name" >&2
  if bash "$experiment_script" use_conf "$configuration_script" "$name"; then
    continue
  else
    result=$?
    echo "Error: configuration $name failed with exit status $result" >&2
    # An interrupt should stop the batch as well as the current experiment.
    [[ "$result" -ne 130 && "$result" -ne 143 ]] || exit "$result"
    status=1
  fi
done <<< "$names"

if [[ "$matched" == false ]]; then
  echo "Error: no configurations match pattern '$pattern'" >&2
  exit 1
fi

exit "$status"
