#!/usr/bin/env bats
# shellcheck disable=SC2128,SC2317
setup() {
  load test_helper/common_setup
  common_setup

  # shellcheck source=./src/procmon.bash
  source "${LIB_SRC}/procmon.bash"

  pm_set_outputs "${TEST_OUTPUTS}/pm"
}

@test "should allow awaiting for a process" {
  job() {
    sleep 0.1
  }

  pm_start

  pm_async job
  pid=$result

  assert pm_await "$pid"
  pm_stop
}

@test "should allow awaiting for a process up until a timeout" {
  job() {
    sleep 5000
  }

  pm_start

  pm_async job
  pid=$result

  refute pm_await "$pid" 1
  pm_stop
}

@test "should kill processes recursively" {
  # Note that this is fragile. We need to structure
  # the process tree such that the parent does not exit
  # before the child, or the child will be reparented to
  # init and won't be killed. The defensive thing to do
  # here is to wait on any child you'd like cleaned before
  # exiting its parent subshell.
  (
    # each backgrounded process generates two processes:
    # the process itself, and its subshell.
    sleep 500 &
    sl1=$!
    (
      sleep 500 &
      pm_await $!
    ) &
    sh1=$!
    (
      sleep 500 &
      pm_await $!
    ) &
    sh2=$!
    pm_await $sl1
    pm_await $sh1
    pm_await $sh2
  ) &
  parent=$!

  pm_list_descendants "$parent"
  assert_equal "${#result[@]}" 9

  pm_kill_rec "$parent"
  pm_await "$parent" 5

  pm_list_descendants "$parent"
  # the parent will still show amongst its descendants,
  # even though it is dead.
  assert_equal "${#result[@]}" 1
}

@test "should not start process monitor twice" {
  assert_equal "$(pm_state)" "halted"

  assert pm_start
  assert_equal "$(pm_state)" "running"

  refute pm_start

  assert pm_stop
  assert_equal "$(pm_state)" "halted"
}

@test "should not stop the process monitor if it wasn't started" {
  refute pm_stop
}

@test "should keep track of process IDs" {
  assert pm_start

  pm_known_pids
  assert [ ${#result[@]} -eq 0 ]

  # shellcheck disable=SC2317
  job() {
    while [ ! -f "${_pm_output}/sync" ]; do
      sleep 0.1
    done
  }

  pm_async job
  p1=$result

  pm_async job
  p2=$result

  pm_known_pids
  assert [ ${#result[@]} -eq 2 ]

  touch "${_pm_output}/sync"

  pm_await "$p1"
  pm_await "$p2"

  # This should be more than enough for the process monitor to
  # catch the exits. The alternative would be implementing temporal
  # predicates.
  sleep 1

  pm_known_pids
  assert [ ${#result[@]} -eq 0 ]

  pm_stop
}

@test "should stop the monitor and all other processes if one process fails" {
  assert pm_start

  # shellcheck disable=SC2317
  job() {
    exit_code=$1
    while [ ! -f "${_pm_output}/sync" ]; do
      sleep 0.1
    done
    return 1
  }

  pm_async job 0
  p1=$result

  pm_async job 1
  p2=$result

  touch "${_pm_output}/sync"

  pm_await "$p1"
  pm_await "$p2"

  pm_join 3

  assert_equal "$(pm_state)" "halted_process_failure"
}

@test "should no longer track a process if requested" {
  assert pm_start

  job() {
    echoerr "starting job"
    touch "${_pm_output}/sync"
    sleep 50
  }

  pm_async job
  pid1=$result

  while [ ! -f "${_pm_output}/sync" ]; do
    sleep 0.1
  done

  pm_stop_tracking "$pid1" # remove this and the test should fail
  pm_kill_rec "$pid1"
  pm_await "$pid1"

  # Sleeps a bit to let the procmon catch up.
  sleep 3

  pm_stop

  assert_equal "$(pm_state)" "halted"
}

callback() {
  local event="$1" proc_type="$2" pid="$3" exit_code

  if [ "$event" = "start" ]; then
    shift 3
    touch "${_pm_output}/${pid}-${proc_type}-start"
  elif [ "$event" = "exit" ]; then
    exit_code="$4"
    shift 4
    touch "${_pm_output}/${pid}-${proc_type}-${exit_code}-exit"
  fi

  if [ "$#" -gt 0 ]; then
    echo "$*" > "${_pm_output}/${pid}-${proc_type}-${event}-args"
  fi
}

@test "should call lifecycle callbacks when processes start and stop" {

  pm_register_callback "sleepy" "callback"

  pm_start

  pm_async sleep 0.1 -%- "sleepy"
  pid1=$result
  pm_async sleep 0.1 -%- "sleepy"
  pid2=$result
  pm_async sleep 0.1 -%- "awake"
  pid3=$result

  pm_await "$pid1"
  pm_await "$pid2"
  pm_await "$pid3"

  pm_stop

  assert_equal "$(pm_state)" "halted"

  assert [ -f "${_pm_output}/${pid1}-sleepy-start" ]
  assert [ -f "${_pm_output}/${pid1}-sleepy-0-exit" ]
  assert [ -f "${_pm_output}/${pid1}-sleepy-start" ]
  assert [ -f "${_pm_output}/${pid2}-sleepy-0-exit" ]
  assert [ ! -f "${_pm_output}/${pid3}-awake-start" ]
  assert [ ! -f "${_pm_output}/${pid3}-awake-0-exit" ]
}

@test "should invoke lifecycle callback when process is killed" {
  pm_register_callback "sleepy" "callback"

  pm_start

  pm_async sleep 10 -%- "sleepy"
  pid1=$result
  echoerr "Run this line"
  pm_async false -%- "sleepy"
  pid2=$result

  pm_join

  assert_equal "$(pm_state)" "halted_process_failure"

  assert [ -f "${_pm_output}/${pid1}-sleepy-start" ]
  assert [ -f "${_pm_output}/${pid1}-sleepy-killed-exit" ]
  assert [ -f "${_pm_output}/${pid2}-sleepy-start" ]
  assert [ -f "${_pm_output}/${pid2}-sleepy-1-exit" ]
}

@test "should allow passing custom arguments to lifecycle callback" {
  pm_register_callback "sleepy" "callback"

  pm_start

  pm_async sleep 0.1 -%- "sleepy" "arg1" "arg2"
  pid=$result

  pm_await "$pid"

  assert_equal "$(cat "${_pm_output}/${pid}-sleepy-start-args")" "arg1 arg2"
  assert_equal "$(cat "${_pm_output}/${pid}-sleepy-exit-args")" "arg1 arg2"

  pm_stop
}
