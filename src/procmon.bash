#!/usr/bin/env bash
#
# procmon is a process monitor that tracks a set (group) of processes
# and kills the entire process group and all of its descendants if one
# of them fails or gets killed. It is used to ensure that no processes
# from failed experiments are left behind.
#
LIB_SRC=${LIB_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# shellcheck source=./src/utils.bash
source "${LIB_SRC}/utils.bash"

_pm_pid=""

declare -g -A _pm_callbacks

pm_set_outputs() {
  _pm_output="$1"
}

_pm_init_output() {
  if [ -z "${_pm_output}" ]; then
    echoerr "Error: outputs not set"
    return 1
  fi

  rm -rf "${_pm_output}" || true
  mkdir -p "${_pm_output}"
}

# Starts the process monitor.
# Returns:
#   1 if the process monitor is already running
#   0 otherwise
pm_start() {
  _pm_assert_state_not "running" || return 1
  _pm_init_output || return 1

  echoerr "[procmon] starting process monitor"

  export _pm_output
  (
    _pm_pid=${BASHPID}
    echoerr "[procmon] enter monitoring loop"
    while true; do
      pm_known_pids
      for pid in "${result[@]}"; do
        if kill -0 "${pid}" 2> /dev/null; then
          continue
        fi

        exit_code=$(cat "${_pm_output}/${pid}.pid")
        # If the cat fails, this means the file was deleted, which means
        # the process is no longer being tracked but the call to pm_stop_tracking
        # happened after we called pm_known_pids last. Simply ignore the process.
        #
        # shellcheck disable=SC2181
        if [ $? -ne 0 ]; then
          echoerr "[procmon] ${pid} file vanished (removed from tracking?)"
          continue
        fi

        # Parent process crashed or got killed. We won't get a return code in
        # these cases.
        if [ -z "$exit_code" ]; then
          echoerr "[procmon] ${pid} died with unknown exit code. Aborting."
          _pm_halt "halted_no_return"
        fi

        # Parent process exited successfully, all good.
        if [ "$exit_code" -eq 0 ]; then
          echoerr "[procmon] ${pid} died with exit code $exit_code."
          rm "${_pm_output}/${pid}.pid"
          continue
        fi

        # If we got thus far, the parent process died with a non-zero exit code,
        # so we kill the whole process group.
        echoerr "[procmon] ${pid} is dead with exit code $exit_code. Aborting."
        _pm_halt "halted_process_failure"
      done
      sleep 1
    done
  ) &
  _pm_pid=$!
  echoerr "[procmon] started with PID $_pm_pid"
  return 0
}

# Stops tracking a given PID. This means that the process dying or exiting
# with an error code will no longer stop the whole process group.
# Arguments:
#   $1: PID to stop tracking
# Returns:
#   1 if the process monitor is not running
#   0 otherwise
pm_stop_tracking() {
  _pm_assert_state "running" || return 1

  local pid=$1
  rm -rf "${_pm_output}/${pid}.pid" || true
}

# Returns the list of PIDs being tracked by the process monitor by
# setting the `result` variable.
# Returns:
#   1 if the process monitor is not running
#   0 otherwise
pm_known_pids() {
  _pm_assert_state "running" || return 1

  local base_name pid
  result=()
  for pid_file in "${_pm_output}"/*.pid; do
    [[ -f "${pid_file}" ]] || continue # null glob
    base_name=$(basename "${pid_file}")
    pid=${base_name%.pid}
    result+=("${pid}")
  done
}

pm_state() {
  # No process ID, process monitor never ran.
  if [ -z "$_pm_pid" ]; then
    echo "halted"
    return 0
  fi

  # Process ID is set and process is running.
  if kill -0 "$_pm_pid"; then
    echo "running"
    return 0
  fi

  if [ -f "${_pm_output}/pm_exit_code" ]; then
    exit_code=$(cat "${_pm_output}/pm_exit_code")
    echo "$exit_code"
    return 0
  fi

  echo "error_no_exit_code"
  return 1
}

pm_is_running() {
  local state
  state=$(pm_state)
  [ "$state" = "running" ]
}

_pm_halt() {
  _pm_assert_state "running" || return 1

  pm_known_pids
  pids=("${result[@]}")

  for pid in "${pids[@]}"; do
    pm_kill_rec "${pid}"
  done

  echo "$1" > "${_pm_output}/pm_exit_code"

  # last but not least, harakiri
  pm_kill_rec "$_pm_pid"

  echoerr "Procmon halted with [$1]"
}

# Stops the process monitor, killing the entire process group.
# Returns:
#   1 if the process monitor is not running
#   0 otherwise
pm_stop() {
  _pm_halt "halted"
}

# Waits for the process monitor to exit. Returns immediately if
# the process monitor is not running.
# Arguments:
#   $1: timeout in seconds
pm_join() {
  pm_await "$_pm_pid" "$1"
}

# Kills a process and all of its descendants. This is full of caveats
# so make sure you see `test_procmon` for an example of how to use it.
# Arguments:
#   $1: process ID
pm_kill_rec() {
  local parent="$1" descendant

  pm_list_descendants "$parent"
  for descendant in "${result[@]}"; do
    echo "[procmon] killing process $descendant"
    kill -s TERM "$descendant" 2> /dev/null || true
  done

  # Tries to wait so processes are not left lingering.
  for descendant in "${result[@]}"; do
    pm_await "$descendant" || echo "[procmon] failed to wait for process $descendant"
  done

  return 0
}

pm_list_descendants() {
  result=()
  _pm_list_descendants "$@"
}

pm_async() {
  _pm_assert_state "running" || return 1

  proc_type=""
  command=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -%-)
        shift
        proc_type="$1"
        shift
        break
        ;;
      *)
        command+=("$1")
        shift
        ;;
    esac
  done

  (
    set -e
    _pm_job_started "${BASHPID}" "$proc_type" "$@"
    trap '_pm_job_exited "${BASHPID}" "$proc_type" "killed" "$@"' TERM
    trap '_pm_job_exited "${BASHPID}" "$proc_type" "$?" "$@"' EXIT
    "${command[@]}"
  ) &
  result=("$!")
}

pm_await() {
  local pid=$1 timeout=${2:-30} start="${SECONDS}"
  while kill -0 "$pid" 2> /dev/null; do
    if [ "$timeout" != 'Inf' ] && ((SECONDS - start > timeout)); then
      echoerr "Error: timeout waiting for process $pid to exit"
      return 1
    fi
    sleep 0.1
  done
  echoerr "Process $pid exited"
  return 0
}

pm_await_all() {
  local pids=("$@") timeout=${2:-30}
  for pid in "${pids[@]}"; do
    pm_await "$pid" "$timeout" || return 1
  done
}

_pm_job_started() {
  local pid=$1 proc_type=$2
  shift 2
  echoerr "[procmon] job started: $pid ($proc_type), args: ${*:-<no args>}"
  if [ ! -f "${_pm_output}/${pid}.pid" ]; then
    touch "${_pm_output}/${pid}.pid"
  fi
  _pm_invoke_callback "start" "$proc_type" "$pid" "$@"
}

_pm_job_exited() {
  local pid=$1\
    proc_type=$2\
    exit_code=$3

  shift 3

  local pid_file="${_pm_output}/${pid}.pid"

  # If the process is not tracked, don't write down an exit code.
  if [ ! -f "$pid_file" ]; then
    echoerr "[procmon] no PID file found for process $pid"
  else
    echo "$exit_code" > "$pid_file"
  fi
  _pm_invoke_callback "exit" "$proc_type" "$pid" "$exit_code" "$@"
}

pm_register_callback() {
  local proc_type="$1" callback="$2"
  _pm_callbacks[$proc_type]="$callback"
}

_pm_invoke_callback() {
  local event="$1" proc_type="$2" pid="$3"
  shift 3
  if [ -n "$proc_type" ]; then
    # calls the callback for this proc type
    if [ -n "${_pm_callbacks[$proc_type]}" ]; then
      "${_pm_callbacks[$proc_type]}" "$event" "$proc_type" "$pid" "$@"
    fi
  fi
}

_pm_list_descendants() {
  local parent="$1"
  result+=("${parent}")

  for pid in $(ps -o pid --ppid "$parent" | tail -n +2 | tr -d ' '); do
    _pm_list_descendants "$pid"
  done
}

_pm_assert_state_not() {
  local state="$1" current_state
  current_state=$(pm_state)

  if [ "$current_state" = "$state" ]; then
    echoerr "[procmon] illegal state: $current_state"
    return 1
  fi
}

_pm_assert_state() {
  local state="$1" current_state
  current_state=$(pm_state)

  if [ "$current_state" != "$state" ]; then
    echoerr "[procmon] illegal state: $current_state"
    return 1
  fi
}
