#!/usr/bin/env bash
# shellcheck shell=bash
# LinguaGraph M8 offline synthetic-seam authority.
#
# The M8 harness exposes a small, closed set of environment seams so the offline
# synthetic verification suite can drive the real code paths without a live
# metadata service or a live object store:
#
#   M8_SYNTHETIC_TEST_MODE       umbrella offline mode
#   M8_IMDS_BASE_URL             redirected metadata endpoint
#   M8_IMDS_CURL_BIN             redirected metadata client executable
#   M8_OSSUTIL_BIN               stub object-store client
#   M8_OSSUTIL_GET_OUTPUT_FLAG   alternative get-object response-body flag
#
# Those seams are valid ONLY while a library function is exercised directly by an
# offline test. A canonical production invocation must never be reachable
# through them: both production entrypoints call
# m8_reject_synthetic_overrides() before any external I/O or host-state
# mutation, and FAIL CLOSED when any seam is non-empty. Formal eligibility is
# therefore exactly:
#
#   all listed variables unset  => eligible
#   any listed variable non-empty => FAIL CLOSED, no claim, no evidence tree,
#                                    no canonical object, no formal marker
#
# This file is the single source of truth for the seam set; no caller restates
# the list.

if [[ -n "${M8_SYNTHETIC_SEAMS_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
M8_SYNTHETIC_SEAMS_LIB_LOADED=1

readonly -a M8_SYNTHETIC_SEAM_VARS=(
  M8_SYNTHETIC_TEST_MODE
  M8_IMDS_BASE_URL
  M8_IMDS_CURL_BIN
  M8_OSSUTIL_BIN
  M8_OSSUTIL_GET_OUTPUT_FLAG
)

# Emit the canonical seam names, one per line, in declaration order.
m8_synthetic_seam_names() {
  printf '%s\n' "${M8_SYNTHETIC_SEAM_VARS[@]}"
}

# Reject every offline synthetic seam. Prints only the offending variable name,
# never its value, so no redirected endpoint, path or executable leaks into
# command output or evidence.
m8_reject_synthetic_overrides() {
  local name value
  for name in "${M8_SYNTHETIC_SEAM_VARS[@]}"; do
    value="${!name:-}"
    if [[ -n "$value" ]]; then
      printf 'FAIL: %s is set; the formal M8 entrypoint refuses offline synthetic overrides (FAIL CLOSED)\n' \
        "$name" >&2
      return 1
    fi
  done
  return 0
}
