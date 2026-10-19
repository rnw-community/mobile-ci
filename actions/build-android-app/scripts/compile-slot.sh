#!/bin/sh
# CMake compiler launcher: runs the compiler only while holding one of
# $MOBILE_CI_COMPILE_SLOTS lock files in $MOBILE_CI_COMPILE_SLOTS_DIR, so every
# ninja the Android Gradle plugin starts shares one bound on concurrent
# compilers. The slot lock is held on fd 9, which the compiler inherits through
# exec, and is released when the compiler exits. A gate lock lets one waiter
# poll for a free slot while the rest block in the kernel.
set -eu

slots="${MOBILE_CI_COMPILE_SLOTS:?MOBILE_CI_COMPILE_SLOTS is not set}"
dir="${MOBILE_CI_COMPILE_SLOTS_DIR:?MOBILE_CI_COMPILE_SLOTS_DIR is not set}"

try_slots() {
  slot=0
  while [ "$slot" -lt "$slots" ]; do
    exec 9> "$dir/slot.$slot"
    if flock -n 9; then
      return 0
    fi
    exec 9>&-
    slot=$((slot + 1))
  done
  return 1
}

if ! try_slots; then
  exec 8> "$dir/gate"
  flock 8
  until try_slots; do
    sleep 0.2
  done
  exec 8>&-
fi

exec "$@"
