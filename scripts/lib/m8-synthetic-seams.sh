#!/usr/bin/env bash
# shellcheck shell=bash
# LinguaGraph M8 production override-seam authority.
#
# The M8 harness exposes a small, closed set of environment seams. Five let the
# offline synthetic verification suite drive the real code paths without a live
# metadata service or a live object store; two are internal executable /
# script-substitution overrides used only while a library function is exercised
# directly by an offline test:
#
#   M8_SYNTHETIC_TEST_MODE       umbrella offline mode
#   M8_IMDS_BASE_URL             redirected metadata endpoint
#   M8_IMDS_CURL_BIN             redirected metadata client executable
#   M8_OSSUTIL_BIN               stub object-store client
#   M8_OSSUTIL_GET_OUTPUT_FLAG   alternative get-object response-body flag
#   M8_ADAPTER_SCRIPT_OVERRIDE   substitute the formal execution adapter
#   M8_PYTHON_BIN                substitute the python3 interpreter
#
# The last two are production-reachable substitution points: M8_PYTHON_BIN is
# consumed by the authorization/JSON/manifest/versioning classification helpers,
# and M8_ADAPTER_SCRIPT_OVERRIDE selects the script PHASE A executes. They belong
# to the same closed production set, not to a separate concern.
#
# Every listed seam is valid ONLY while a library function is exercised directly
# by an offline test. A canonical production invocation must never be reachable
# through any of them: both production entrypoints call
# m8_reject_synthetic_overrides() before any external I/O, authorization
# consumption or host-state mutation, and FAIL CLOSED when any listed variable is
# non-empty. Formal eligibility is therefore exactly:
#
#   all listed variables unset    => eligible
#   any listed variable non-empty => FAIL CLOSED, no claim, no evidence tree,
#                                    no canonical object, no formal marker
#
# This file is the single source of truth for the production override set; no
# caller restates the list, and no second production seam authority may exist.

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
  M8_ADAPTER_SCRIPT_OVERRIDE
  M8_PYTHON_BIN
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

# ---------------------------------------------------------------------------
# R2I-C4 / B03: closed OSS trust-target environment authority.
#
# This is a DISTINCT list from the seven production override seams above. It
# closes the ambient inputs that could redirect the effective OSS trust target
# (endpoint, credentials, auth mode, config source, profile selection, ECS role
# selection, proxy path). Ambient OSS_* variables outrank the configuration file
# in ossutil's documented precedence, and OSSUTIL_CONFIG_FILE / OSSUTIL_PROFILE
# are not OSS_-prefixed, so they are not covered by `--ignore-env-var`; each is
# therefore rejected explicitly. Every listed variable is fail-closed on being
# non-empty, and only the offending NAME is ever printed.
# ---------------------------------------------------------------------------
readonly -a M8_OSS_TRUST_ENV_REJECT_VARS=(
  M8_OSSUTIL_CONFIG_FILE
  OSS_ACCESS_KEY_ID
  OSS_ACCESS_KEY_SECRET
  OSS_SESSION_TOKEN
  OSS_ROLE_ARN
  OSS_ROLE_SESSION_NAME
  OSS_REGION
  OSS_ENDPOINT
  OSSUTIL_CONFIG_FILE
  OSSUTIL_PROFILE
  ALIBABA_CLOUD_ECS_METADATA
  HTTP_PROXY
  HTTPS_PROXY
  ALL_PROXY
  NO_PROXY
  http_proxy
  https_proxy
  all_proxy
  no_proxy
)

# Emit the canonical closed trust-environment variable names, one per line.
m8_oss_trust_env_names() {
  printf '%s\n' "${M8_OSS_TRUST_ENV_REJECT_VARS[@]}"
}

# Reject every closed OSS trust-environment variable. Prints only the offending
# variable name, never its value.
m8_reject_oss_trust_environment() {
  local name value
  for name in "${M8_OSS_TRUST_ENV_REJECT_VARS[@]}"; do
    value="${!name:-}"
    if [[ -n "$value" ]]; then
      printf 'FAIL: %s is set; the formal M8 OSS trust-target environment is closed (FAIL CLOSED)\n' \
        "$name" >&2
      return 1
    fi
  done
  return 0
}
