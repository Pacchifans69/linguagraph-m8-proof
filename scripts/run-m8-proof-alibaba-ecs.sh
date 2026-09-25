#!/usr/bin/env bash
# LinguaGraph M8 formal execution adapter (Alibaba ECS).
#
# This is NOT an independent formal runner. It has no formal commit authority.
# It executes the provider-neutral semantic core ONLY when it has been invoked
# by the formal wrapper scripts/run-m8-proof.sh, proven by:
#
#   1. the wrapper-issued formal invocation context file inside the fixed
#      evidence directory, containing the in-process invocation nonce digest;
#   2. the durable single-use claim at
#      authorizations/<authorization_sha256>/claim.json, read back from OSS,
#      whose bytes hash to the claim digest bound in the context;
#   3. the claim naming exactly this authorization and this authorized executor;
#   4. a second read-only provider identity verification whose observed tuple
#      matches both the reviewed immutable identity and the claim.
#
# Without that context it refuses to consume any M8 formal authorization, will
# not invoke the semantic core, and creates no claim, archive, package index or
# closure receipt. Such an invocation is reported as NONFORMAL / NOT_APPLICABLE.
#
# RC ownership:
#   * core-exit-code.txt   = process RC of run-m8-proof-core.sh, captured here
#                            immediately after the child returns. The core never
#                            writes it.
#   * adapter-exit-code.txt = this adapter's final self-declared RC, written by
#                            the EXIT trap after all adapter work.
#
# Never run this without separate Human approval of the exact proof commit and a
# fresh single-use authorization presented to the wrapper.
set -Eeuo pipefail

M8_ADAPTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=lib/m8-synthetic-seams.sh
source "$M8_ADAPTER_LIB_DIR/m8-synthetic-seams.sh"
# shellcheck source=lib/m8-provider-identity.sh
source "$M8_ADAPTER_LIB_DIR/m8-provider-identity.sh"
# shellcheck source=lib/m8-oss.sh
source "$M8_ADAPTER_LIB_DIR/m8-oss.sh"
# shellcheck source=lib/m8-manifest.sh
source "$M8_ADAPTER_LIB_DIR/m8-manifest.sh"

M8_ADAPTER_MODE='NONFORMAL'
ADAPTER_CORE_INVOKED=0
CORE_RC=''
CLAIM_SHA256_LOCAL=''

nonformal_refuse() {
  printf 'M8_ADAPTER_MODE=NONFORMAL\n'
  printf 'M8_FORMAL_STATUS=NOT_APPLICABLE\n'
  printf 'M8_ADAPTER_REFUSAL=%s\n' "$*"
  printf 'adapter: refusing to consume any M8 formal authorization, refusing to invoke the semantic core, and creating no claim/archive/index/receipt\n' >&2
  exit 1
}

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { [[ "$1" == "$2" ]] || die "Mismatch: $3 (expected $2; got $1)"; }
record() {
  [[ -n "$EVIDENCE" && -d "$EVIDENCE" ]] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$EVIDENCE/adapter-provenance.txt"
}

# Formal eligibility guard. A direct production execution of this adapter must
# never be reachable through an offline synthetic seam, so this fails closed
# before the formal-context guards, before any provider read and before any
# host-state mutation: a redirected metadata client/endpoint or a stub object
# store can never impersonate the formal provider identity.
m8_reject_synthetic_overrides ||
  die 'offline synthetic override is set; refusing to execute the formal adapter'

# Resolve the proof root without aborting on a non-git working directory.
if [[ -n "${M8_PROOF_ROOT:-}" ]]; then
  PROOF_ROOT="$M8_PROOF_ROOT"
else
  PROOF_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
fi
readonly PROOF_ROOT
[[ -n "$PROOF_ROOT" ]] || nonformal_refuse 'the proof repository root could not be resolved'

readonly CORE="$PROOF_ROOT/scripts/run-m8-proof-core.sh"
readonly EVIDENCE="$PROOF_ROOT/proof-artifacts"

# ---------------------------------------------------------------------------
# Formal-context guards. Anything missing is NONFORMAL / NOT_APPLICABLE.
# ---------------------------------------------------------------------------
readonly CONTEXT_FILE="$EVIDENCE/formal-invocation-context.txt"

[[ -n "${M8_FORMAL_WRAPPER_CONTEXT:-}" ]] ||
  nonformal_refuse 'M8_FORMAL_WRAPPER_CONTEXT is absent; only scripts/run-m8-proof.sh may invoke this adapter formally'
[[ "$M8_FORMAL_WRAPPER_CONTEXT" == "$CONTEXT_FILE" ]] ||
  nonformal_refuse "M8_FORMAL_WRAPPER_CONTEXT must be exactly $CONTEXT_FILE"
[[ -f "$CONTEXT_FILE" ]] ||
  nonformal_refuse "formal invocation context is missing: $CONTEXT_FILE"
[[ -d "$EVIDENCE" ]] ||
  nonformal_refuse "formal evidence directory is missing: $EVIDENCE"
[[ -f "$CORE" ]] || nonformal_refuse "semantic core is missing: $CORE"

# The wrapper is invoked with an explicit fixed evidence path; a redirected path
# is refused so that authority cannot be relocated.
if [[ -n "${M8_PROOF_EVIDENCE_DIR:-}" && "${M8_PROOF_EVIDENCE_DIR}" != "$EVIDENCE" ]]; then
  nonformal_refuse "M8_PROOF_EVIDENCE_DIR must be unset or exactly $EVIDENCE"
fi

# Spoofed hosted identity is refused before anything else.
for v in CIRCLE_PROJECT_USERNAME CIRCLE_PROJECT_REPONAME CIRCLE_BRANCH \
  CIRCLE_SHA1 CIRCLE_WORKFLOW_ID CIRCLE_BUILD_NUM; do
  [[ -z "${!v:-}" ]] ||
    nonformal_refuse "CircleCI identity variable $v is set; Alibaba execution must not be obtained by spoofing CircleCI"
done

context_get() {
  local key=$1
  sed -n "s/^${key}=//p" "$CONTEXT_FILE" | head -n1
}

context_validate() {
  local schema authorization_kind authorization_sha semantic_auth_sha proof_sha
  local proof_tree authorized_executor_id executor_id claim_object claim_sha
  local run_prefix nonce_sha formal_entrypoint

  schema="$(context_get schema)"
  formal_entrypoint="$(context_get formal_entrypoint)"
  authorization_kind="$(context_get authorization_kind)"
  authorization_sha="$(context_get authorization_sha256)"
  semantic_auth_sha="$(context_get semantic_auth_sha256)"
  proof_sha="$(context_get proof_sha)"
  proof_tree="$(context_get proof_tree)"
  authorized_executor_id="$(context_get authorized_executor_id)"
  executor_id="$(context_get executor_id)"
  claim_object="$(context_get claim_object)"
  claim_sha="$(context_get claim_sha256)"
  run_prefix="$(context_get run_prefix)"
  nonce_sha="$(context_get invocation_nonce_sha256)"

  expect "$schema" 'linguagraph-m8-formal-invocation-context/v1' context_schema
  expect "$formal_entrypoint" 'scripts/run-m8-proof.sh' context_formal_entrypoint
  [[ "$authorization_kind" == 'SEMANTIC' || "$authorization_kind" == 'DURABILITY_RETRY' ]] ||
    die "context authorization_kind is invalid: $authorization_kind"
  [[ "$authorization_sha" =~ ^[0-9a-f]{64}$ ]] || die 'context authorization_sha256 is not a SHA-256'
  [[ "$semantic_auth_sha" =~ ^[0-9a-f]{64}$ ]] || die 'context semantic_auth_sha256 is not a SHA-256'
  [[ "$proof_sha" =~ ^[0-9a-f]{40}$ ]] || die 'context proof_sha is not a commit SHA'
  [[ "$proof_tree" =~ ^[0-9a-f]{40}$ ]] || die 'context proof_tree is not a tree SHA'
  [[ "$claim_sha" =~ ^[0-9a-f]{64}$ ]] || die 'context claim_sha256 is not a SHA-256'
  [[ "$nonce_sha" =~ ^[0-9a-f]{64}$ ]] || die 'context invocation_nonce_sha256 is not a SHA-256'
  expect "$authorized_executor_id" "$(m8_provider_identity_executor_id)" context_authorized_executor_id
  expect "$executor_id" "$(m8_provider_identity_executor_id)" context_executor_id
  expect "$claim_object" "authorizations/$authorization_sha/claim.json" context_claim_object
  expect "$run_prefix" "runs/$proof_sha/$semantic_auth_sha" context_run_prefix

  # The authorization presented to the wrapper must be the one in the context.
  # The presented value is the exact Human-issued TOKEN, so it is hashed here and
  # the DIGEST is compared to the context's authorization_sha256; the token is
  # never echoed and never enters evidence.
  local presented='' presented_sha=''
  if [[ -n "${M8_PROOF_RUN_AUTHORIZATION:-}" && -n "${M8_PROOF_RETRY_AUTHORIZATION:-}" ]]; then
    die 'present exactly one of M8_PROOF_RUN_AUTHORIZATION or M8_PROOF_RETRY_AUTHORIZATION'
  fi
  presented="${M8_PROOF_RUN_AUTHORIZATION:-${M8_PROOF_RETRY_AUTHORIZATION:-}}"
  [[ -n "$presented" ]] ||
    die 'no authorization token was presented to the adapter'
  presented_sha="$(printf '%s' "$presented" | sha256sum | cut -d' ' -f1)"
  presented=''
  expect "$presented_sha" "$authorization_sha" adapter_authorization_sha
  expect "${APPROVED_PROOF_SHA:-}" "$proof_sha" adapter_approved_proof_sha

  # The in-process nonce proves this context was produced for this invocation.
  [[ -n "${M8_FORMAL_RUN_NONCE:-}" ]] ||
    nonformal_refuse 'M8_FORMAL_RUN_NONCE is absent; the context did not come from a live wrapper invocation'
  expect "$(printf '%s' "$M8_FORMAL_RUN_NONCE" | sha256sum | cut -d' ' -f1)" "$nonce_sha" context_invocation_nonce

  M8_ADAPTER_MODE='FORMAL'
  AUTHORIZATION_SHA="$authorization_sha"
  AUTHORIZATION_KIND="$authorization_kind"
  CLAIM_OBJECT="$claim_object"
  CONTEXT_CLAIM_SHA256="$claim_sha"
  return 0
}

# ---------------------------------------------------------------------------
# Durable claim verification (independent of the wrapper's in-process state).
# ---------------------------------------------------------------------------
claim_verify() {
  local claim_local="$EVIDENCE/claim-adapter-readback.json"
  m8_oss_require_config || die 'OSS bucket configuration is required for formal execution'

  if ! m8_oss_get_object "$CLAIM_OBJECT" "$claim_local" "$EVIDENCE/adapter-oss.log"; then
    die "durable claim could not be read back from $CLAIM_OBJECT; refusing to invoke the semantic core"
  fi
  CLAIM_SHA256_LOCAL="$(sha256sum "$claim_local" | cut -d' ' -f1)"
  expect "$CLAIM_SHA256_LOCAL" "$CONTEXT_CLAIM_SHA256" durable_claim_sha256
  expect "$(m8_json_get "$claim_local" schema)" 'linguagraph-m8-claim/v1' claim_schema
  expect "$(m8_json_get "$claim_local" authorization_sha256)" "$AUTHORIZATION_SHA" claim_authorization_sha
  expect "$(m8_json_get "$claim_local" authorization_kind)" "$AUTHORIZATION_KIND" claim_authorization_kind
  expect "$(m8_json_get "$claim_local" authorized_executor_id)" \
    "$(m8_provider_identity_executor_id)" claim_authorized_executor_id
  expect "$(m8_json_get "$claim_local" executor_id)" \
    "$(m8_provider_identity_executor_id)" claim_executor_id
  expect "$(m8_json_get "$claim_local" single_use)" 'true' claim_single_use
  expect "$(m8_json_get "$claim_local" proof_sha)" "${APPROVED_PROOF_SHA:-}" claim_proof_sha
  expect "$(m8_json_get "$claim_local" claim_object)" "$CLAIM_OBJECT" claim_object_binding
  CLAIM_FILE="$claim_local"
  return 0
}

# ---------------------------------------------------------------------------
# Post-claim defence-in-depth provider identity re-verification.
# ---------------------------------------------------------------------------
provider_identity_reverify() {
  local claim=$1 root="$EVIDENCE/provider-identity" observed expected field
  m8_provider_identity_verify "$root" reexec ||
    die 'post-claim read-only provider identity verification failed'

  for field in instance_id region_id zone_id instance_type image_id; do
    observed="$(cat "$root/reexec/${field//_/-}.txt")"
    expected="$(m8_json_get "$claim" "provider_identity.$field")"
    expect "$observed" "$expected" "reexec_provider_identity_$field"
  done
  observed="$(cat "$root/reexec/instance-identity-document.sha256")"
  expected="$(m8_json_get "$claim" provider_identity.identity_document_sha256)"
  expect "$observed" "$expected" reexec_provider_identity_document_sha256
  observed="$(cat "$root/reexec/instance-identity-pkcs7.sha256")"
  expected="$(m8_json_get "$claim" provider_identity.identity_pkcs7_sha256)"
  expect "$observed" "$expected" reexec_provider_identity_pkcs7_sha256
  return 0
}

# ---------------------------------------------------------------------------
# EXIT trap: adapter-exit-code.txt is the adapter's final self-declared RC.
# ---------------------------------------------------------------------------
adapter_finalize() {
  local exit_code=$? first_line=''
  trap - EXIT

  if (( ADAPTER_CORE_INVOKED == 1 )); then
    first_line="$(head -n1 "$EVIDENCE/outcome.txt" 2>/dev/null || printf '')"
    if [[ -z "$first_line" ]]; then
      printf 'FAIL missing_outcome adapter_exit=%s\n' "$exit_code" > "$EVIDENCE/outcome.txt"
      (( exit_code == 0 )) && exit_code=1
    elif [[ "$first_line" == 'PASS' && "$exit_code" != 0 ]]; then
      printf 'FAIL adapter_exit=%s\n' "$exit_code" > "$EVIDENCE/outcome.txt"
    elif [[ "$first_line" != 'PASS' && "$exit_code" == 0 ]]; then
      exit_code=1
    fi
  fi

  printf '%s\n' "$exit_code" > "$EVIDENCE/adapter-exit-code.txt"
  exit "$exit_code"
}

# R2I-C14: install the adapter's EXIT trap BEFORE context_validate. A
# formal-context validation failure must still leave the adapter's own numeric
# adapter-exit-code.txt, which the wrapper captures and cross-checks; installing
# the trap after validation meant a validation failure (e.g. the
# context_invocation_nonce mismatch) produced no adapter RC record at all.
#
# The trap is installed only here -- after every formal-entry eligibility guard
# above (resolved proof root; fixed EVIDENCE path; EVIDENCE/context/core existence;
# wrapper-context path equality; CircleCI spoof rejection) and after
# adapter_finalize is defined -- so a direct NONFORMAL invocation still exits
# through nonformal_refuse before any trap exists and creates no host state.
trap adapter_finalize EXIT
context_validate
mkdir -p "$EVIDENCE" || die "cannot create $EVIDENCE"
record adapter_mode "$M8_ADAPTER_MODE"
record authorization_kind "$AUTHORIZATION_KIND"
record authorization_sha256 "$AUTHORIZATION_SHA"
record context_claim_sha256 "$CONTEXT_CLAIM_SHA256"
record date_utc "$(date -u +%FT%TZ)"

claim_verify
provider_identity_reverify "$CLAIM_FILE"

# ---------------------------------------------------------------------------
# Semantic execution. The core-exit-code.txt capture happens immediately after
# the child returns and is the only place that file is ever written.
# ---------------------------------------------------------------------------
ADAPTER_CORE_INVOKED=1
CORE_RC=0
bash "$CORE" || CORE_RC=$?
printf '%s\n' "$CORE_RC" > "$EVIDENCE/core-exit-code.txt"
record core_exit_code "$CORE_RC"

exit "$CORE_RC"
