#!/usr/bin/env bash
# LinguaGraph M8-HSDR-F02 R2E-B01 offline verification.
#
# Runs ONLY offline/static/synthetic checks:
#   * bash -n and structural (grep) invariants over the proof harness;
#   * python3 stdlib fixture tests for the JSON verifiers;
#   * synthetic shell fixtures driving the real wrapper/OSS phase functions
#     against tests/fixtures/fake-ossutil.sh.
#
# It never calls a provider API, never contacts Alibaba OSS, never runs
# Playwright, pytest, Vitest or a Product build, and never installs anything.
#
# Every check is labelled V01..V40. Exit status is non-zero if any check fails.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly FIXTURES="$REPO_ROOT/tests/fixtures"
readonly FAKE_OSSUTIL="$FIXTURES/fake-ossutil.sh"
readonly PYTHON="${M8_PYTHON_BIN:-python3}"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/m8-r2b-verify.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

STATIC_TOTAL=0
STATIC_PASS=0
SYNTH_TOTAL=0
SYNTH_PASS=0
CORR_TOTAL=0
CORR_PASS=0
declare -a FAILED_CHECKS=()

run_check() {
  local kind=$1 id=$2 desc=$3 fn=$4 out='' rc=0
  case "$kind" in
    static) STATIC_TOTAL=$((STATIC_TOTAL + 1)) ;;
    synth) SYNTH_TOTAL=$((SYNTH_TOTAL + 1)) ;;
    corr) CORR_TOTAL=$((CORR_TOTAL + 1)) ;;
  esac
  out="$("$fn" 2>&1)" || rc=$?
  if (( rc == 0 )) && ! grep -q '^ASSERT_FAIL:' <<<"$out"; then
    printf 'PASS [%-6s] %s %s\n' "$kind" "$id" "$desc"
    case "$kind" in
      static) STATIC_PASS=$((STATIC_PASS + 1)) ;;
      synth) SYNTH_PASS=$((SYNTH_PASS + 1)) ;;
      corr) CORR_PASS=$((CORR_PASS + 1)) ;;
    esac
  else
    printf 'FAIL [%-6s] %s %s\n' "$kind" "$id" "$desc"
    printf '     %s\n' "${out//$'\n'/$'\n'     }"
    FAILED_CHECKS+=("$id")
  fi
}

# --- assertion helpers ------------------------------------------------------
# A test function runs inside a command substitution and is therefore invoked in
# a condition context, where bash suppresses errexit for the whole dynamic
# extent of the call. Assertions must not rely on errexit: they abort their
# subshell explicitly and print a marker that run_check also looks for, so a
# failed assertion can never be silently overridden by a later success.
assert_fail() { printf 'ASSERT_FAIL: %s\n' "$*"; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || assert_fail "assert_eq: expected '$2', got '$1' (${3:-})"
}
assert_grep() {
  grep -Eq -e "$1" "$2" || assert_fail "assert_grep: '$1' not found in $2"
}
assert_no_grep() {
  if grep -Eq -e "$1" "$2"; then
    grep -En -- "$1" "$2" | head -n5 | sed 's/^/     /'
    assert_fail "assert_no_grep: '$1' unexpectedly present in $2"
  fi
}
assert_contains() {
  grep -Fq -- "$2" "$1" || assert_fail "assert_contains: '$2' not found in $1"
}
assert_no_contains() {
  grep -Fq -- "$2" "$1" && assert_fail "assert_no_contains: '$2' unexpectedly present in $1"
  return 0
}
assert_file() { [[ -f "$1" ]] || assert_fail "assert_file: $1 is not a regular file"; }
assert_no_file() { [[ ! -e "$1" ]] || assert_fail "assert_no_file: $1 unexpectedly exists"; }
assert_exit_fail() {
  "$@" >/dev/null 2>&1 && assert_fail "assert_exit_fail: $* unexpectedly succeeded"
  return 0
}
assert_exit_ok() {
  "$@" >/dev/null 2>&1 || assert_fail "assert_exit_ok: $* unexpectedly failed"
}

readonly CORE="$REPO_ROOT/scripts/run-m8-proof-core.sh"
readonly ADAPTER="$REPO_ROOT/scripts/run-m8-proof-alibaba-ecs.sh"
readonly WRAPPER="$REPO_ROOT/scripts/run-m8-proof.sh"
readonly PREFLIGHT="$REPO_ROOT/scripts/preflight-m8-alibaba-ecs.sh"
readonly OSS_LIB="$REPO_ROOT/scripts/lib/m8-oss.sh"
readonly IDENTITY_LIB="$REPO_ROOT/scripts/lib/m8-provider-identity.sh"
readonly MANIFEST_LIB="$REPO_ROOT/scripts/lib/m8-manifest.sh"
readonly SEAMS_LIB="$REPO_ROOT/scripts/lib/m8-synthetic-seams.sh"
readonly REQUIRED_LIST="$REPO_ROOT/scripts/lib/m8-required-artifacts.txt"

# Frozen seven-spec Playwright release surface in the actual JSON reporter
# namespace (relative to the reporter rootDir <candidate>/apps/web). This is the
# only namespace the JSON-report contract may expect.
readonly -a PLAYWRIGHT_FROZEN_SPECS=(
  'e2e/golden-path.spec.ts'
  'e2e/unicode.spec.ts'
  'e2e/segmentation.spec.ts'
  'e2e/token-segmentation.spec.ts'
  'e2e/lemma-annotation.spec.ts'
  'e2e/pos-annotation.spec.ts'
  'e2e/workbench-information-architecture.spec.ts'
)

# The five offline synthetic seams owned by scripts/lib/m8-synthetic-seams.sh.
readonly -a SYNTHETIC_SEAM_VARS=(
  M8_SYNTHETIC_TEST_MODE
  M8_IMDS_BASE_URL
  M8_IMDS_CURL_BIN
  M8_OSSUTIL_BIN
  M8_OSSUTIL_GET_OUTPUT_FLAG
)

# ===========================================================================
# Synthetic formal fixture.
# ===========================================================================
bootstrap_formal_fixture() {
  # shellcheck source=lib/m8-provider-identity.sh
  source "$IDENTITY_LIB"
  # shellcheck source=lib/m8-manifest.sh
  source "$MANIFEST_LIB"

  SB="$(mktemp -d "$TMPROOT/sb.XXXXXX")"
  PROOF="$SB/proof"
  HOST="$SB/host"
  EVIDENCE="$PROOF/proof-artifacts"
  FAKE_ROOT="$SB/oss"
  mkdir -p "$PROOF" "$HOST" "$FAKE_ROOT/objects"

  cp -a "$REPO_ROOT/scripts" "$PROOF/scripts"
  git -C "$PROOF" init -q
  git -C "$PROOF" add -A >/dev/null
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$PROOF" commit -qm 'synthetic proof fixture' >/dev/null

  APPROVED_PROOF_SHA="$(git -C "$PROOF" rev-parse HEAD)"
  APPROVED_PROOF_TREE="$(git -C "$PROOF" rev-parse HEAD^{tree})"
  export APPROVED_PROOF_SHA APPROVED_PROOF_TREE
  export M8_PROOF_ROOT="$PROOF"
  export M8_PROOF_HOST_STATE="$HOST"
  export M8_PROOF_EVIDENCE_DIR="$EVIDENCE"
  export M8_SYNTHETIC_TEST_MODE=1
  export M8_OSS_BUCKET='test-bucket'
  export M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
  export M8_FAKE_OSS_ROOT="$FAKE_ROOT"
  export M8_FAKE_OSS_VERSIONING='unversioned'
  export M8_EXECUTOR_ID="$M8_PROVIDER_EXECUTOR_ID"

  ISSUED_LOCAL="$SB/issued.json"
  # B1 authorization identity: the Human-issued input is the exact TOKEN string.
  # authorization_sha256 is SHA256(TOKEN) and is what issued.json must bind; it is
  # never derived from the issued-document bytes.
  SEMANTIC_TOKEN='M8-EXI-01-RUN-SYNTHETIC-TOKEN'
  AUTH="$(printf '%s' "$SEMANTIC_TOKEN" | sha256sum | cut -d' ' -f1)"
  "$PYTHON" - "$ISSUED_LOCAL" "$APPROVED_PROOF_SHA" "$APPROVED_PROOF_TREE" "$AUTH" <<'PY'
import json
import sys

out, proof_sha, proof_tree, authorization_sha256 = sys.argv[1:5]
document = {
    "schema": "linguagraph-m8-run-authorization/v1",
    "authorization_kind": "SEMANTIC",
    "authorization_id": "M8-EXI-01-RUN-SYNTHETIC",
    "authorization_sha256": authorization_sha256,
    "proof_sha": proof_sha,
    "proof_tree": proof_tree,
    "candidate_sha": "2441f9cf60b7cc9402c5b257be010b559b39b717",
    "candidate_tree": "5d1b7c7cc104cd365b0ea629d9ead7677d17f2be",
    "candidate_parent": "e4b1cc66f540ab74c0ef9bd014b0a0da3a2d9c1d",
    "frozen_main": "cf26ea557bd746a518ff32b8b7e7a7542be7f7ae",
    "provider_identity": {
        "instance_id": "i-j6c9854oyawy89fcdxy2",
        "region_id": "cn-hongkong",
        "zone_id": "cn-hongkong-d",
        "instance_type": "ecs.g9i.xlarge",
        "image_id": "ubuntu_24_04_x64_20G_alibase_20260916.vhd",
        "identity_document_sha256": "60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d",
        "identity_pkcs7_sha256": "89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211",
    },
    "authorized_executor_id": "alibaba-ecs:i-j6c9854oyawy89fcdxy2",
    "single_use": True,
    "issued_utc": "2026-01-01T00:00:00Z",
}
with open(out, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY

  export M8_PROOF_RUN_AUTHORIZATION="$SEMANTIC_TOKEN"
  stage_object "authorizations/$AUTH/issued.json" "$ISSUED_LOCAL"

  M8_PRECLAIM_DIR="$HOST/preclaim/$AUTH"
  SEAL_DIR="$HOST/sealed/$AUTH"
  # SEAL_DIR is deliberately NOT created here: the wrapper must create the
  # host-local seal directory itself before PHASE A writes its validation output.
  write_identity_capture "$M8_PRECLAIM_DIR/provider-identity/primary"
  export M8_PRECLAIM_DIR SEAL_DIR AUTH SB PROOF HOST EVIDENCE FAKE_ROOT ISSUED_LOCAL
  export SEMANTIC_TOKEN
}

# Write a synthetic but correctly valued read-only provider identity capture.
write_identity_capture() {
  local dir=$1
  mkdir -p "$dir"
  printf '%s\n' "$EXPECTED_INSTANCE_ID" >"$dir/instance-id.txt"
  printf '%s\n' "$EXPECTED_REGION_ID" >"$dir/region-id.txt"
  printf '%s\n' "$EXPECTED_ZONE_ID" >"$dir/zone-id.txt"
  printf '%s\n' "$EXPECTED_INSTANCE_TYPE" >"$dir/instance-type.txt"
  printf '%s\n' "$EXPECTED_IMAGE_ID" >"$dir/image-id.txt"
  printf 'synthetic-identity-document\n' >"$dir/instance-identity-document.json"
  printf 'synthetic-identity-pkcs7\n' >"$dir/instance-identity-pkcs7.txt"
  printf '%s\n' "$EXPECTED_IDENTITY_DOCUMENT_SHA256" >"$dir/instance-identity-document.sha256"
  printf '%s\n' "$EXPECTED_IDENTITY_PKCS7_SHA256" >"$dir/instance-identity-pkcs7.sha256"
  printf 'provider_identity_capture=SYNTHETIC\n' >"$dir/provider-identity-result.txt"
}

stage_object() {
  local key=$1 source=$2
  local destination="$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$key"
  mkdir -p "$(dirname "$destination")"
  cp -f "$source" "$destination"
}

object_bytes() {
  cat "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$1"
}

# Materialize the canonical required artifact set under <root>, never clobbering
# a file that already exists (the fixture's correctly valued identity captures
# must survive).
populate_required_root() {
  local root=$1 rel
  mkdir -p "$root"
  while IFS= read -r rel; do
    case "$rel" in '' | '#'*) continue ;; esac
    if [[ -e "$root/$rel" ]]; then
      continue
    fi
    mkdir -p "$(dirname "$root/$rel")"
    printf 'synthetic\n' >"$root/$rel"
  done <"$REQUIRED_LIST"
}

populate_required_artifacts() {
  populate_required_root "$EVIDENCE"
  printf 'PLAYWRIGHT_EFFECTIVE_RETRIES=0\n' >"$EVIDENCE/playwright-effective-retries.txt"
  printf 'PASS\n' >"$EVIDENCE/outcome.txt"
  printf '0\n' >"$EVIDENCE/core-exit-code.txt"
  printf '0\n' >"$EVIDENCE/adapter-exit-code.txt"
  printf '0\n' >"$EVIDENCE/formal-execution-rc.txt"
  : >"$EVIDENCE/docker-owned-marker"
  # The formal adapter's post-claim defence-in-depth capture is represented with
  # correct observed values, since the wrapper now independently re-checks it.
  write_identity_capture "$EVIDENCE/provider-identity/reexec"
}

# Runs the real wrapper phase functions for a synthetic SEMANTIC closure.
run_formal_success() {
  bootstrap_formal_fixture
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/run-m8-proof.sh"
  m8_wrapper_init
  m8_guard_local_syntax || return 1
  m8_load_authorization || return 1
  m8_claim_create || return 1
  m8_evidence_initialize || return 1
  populate_required_artifacts
  FORMAL_EXECUTION_RC=0
  m8_phase_a_validate || return 1
  m8_phase_b_seal || return 1
  m8_phase_c_durability || return 1
  m8_phase_d_commit || return 1
  printf 'FORMAL_FIXTURE_RECEIPT_SHA=%s\n' "$RECEIPT_VERIFIED_SHA256"
}

# ===========================================================================
# V01..V05 — frozen RC contract (static).
# ===========================================================================
v01() {
  local bad
  bad="$(grep -n 'core-exit-code\.txt' "$CORE" | grep -Ev '^[0-9]+:[[:space:]]*#' |
    grep -Ev '\[\[ ! -e|die ' || true)"
  [[ -z "$bad" ]] || { printf 'core writes core-exit-code.txt:\n%s\n' "$bad"; return 1; }
  assert_grep 'guard_core_rc_ownership' "$CORE"
  assert_contains "$ADAPTER" 'printf '"'"'%s\n'"'"' "$CORE_RC" > "$EVIDENCE/core-exit-code.txt"'
  assert_no_grep '>[[:space:]]*"\$M8_EVIDENCE/core-exit-code\.txt"' "$WRAPPER"
}

v02() {
  grep -A1 -F 'bash "$CORE" || CORE_RC=$?' "$ADAPTER" | grep -Fq 'core-exit-code.txt' ||
    { printf 'adapter does not capture the core RC immediately after the child returns\n'; return 1; }
}

v03() {
  local body="$TMPROOT/v03-finalize" trap_line core_line
  assert_grep 'trap adapter_finalize EXIT' "$ADAPTER"
  sed -n '/^adapter_finalize()/,/^}/p' "$ADAPTER" >"$body"
  assert_grep '> "\$EVIDENCE/adapter-exit-code\.txt"' "$body"
  trap_line="$(grep -n 'trap adapter_finalize EXIT' "$ADAPTER" | cut -d: -f1)"
  core_line="$(grep -n 'bash "\$CORE" || CORE_RC=\$?' "$ADAPTER" | cut -d: -f1)"
  (( trap_line < core_line )) ||
    { printf 'the EXIT trap is installed after the core invocation\n'; return 1; }
}

v04() {
  grep -A1 -F 'bash "$M8_ADAPTER_SCRIPT"' "$WRAPPER" | grep -Fq 'formal-execution-rc.txt' ||
    { printf 'wrapper does not capture the adapter RC immediately after the child returns\n'; return 1; }
}

v05() {
  assert_grep 'adapter_rc.*==.*execution_rc' "$WRAPPER"
  assert_grep 'adapter-exit-code\.txt is not numeric' "$WRAPPER"
  assert_grep 'FAIL CLOSED' "$WRAPPER"
}

# ===========================================================================
# V06..V16 — synthetic lifecycle behaviour.
# ===========================================================================
v06() {
  local d
  d="$(mktemp -d "$TMPROOT/v06.XXXXXX")"
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    M8_EVIDENCE="$d"
    printf '0\n' >"$d/formal-execution-rc.txt"
    if m8_rc_crosscheck 2>/dev/null; then printf 'absent adapter RC did not fail\n'; return 1; fi
    : >"$d/adapter-exit-code.txt"
    if m8_rc_crosscheck 2>/dev/null; then printf 'empty adapter RC did not fail\n'; return 1; fi
    printf '7\n' >"$d/adapter-exit-code.txt"
    if m8_rc_crosscheck 2>/dev/null; then printf 'mismatched RC did not fail\n'; return 1; fi
    printf 'x\n' >"$d/adapter-exit-code.txt"
    if m8_rc_crosscheck 2>/dev/null; then printf 'non-numeric adapter RC did not fail\n'; return 1; fi
    printf '7\n' >"$d/formal-execution-rc.txt"
    printf '7\n' >"$d/adapter-exit-code.txt"
    m8_rc_crosscheck
  )
}

v07() {
  # A signal-terminated adapter is a distinct numeric RC, never conflated with
  # 0/1, and a mismatch against the adapter's own declaration fails closed.
  local d stub rc=0
  d="$(mktemp -d "$TMPROOT/v07.XXXXXX")"
  stub="$TMPROOT/term-adapter.sh"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EVIDENCE="${M8_STUB_EVIDENCE:?}"
# A correct adapter declares the signal-derived RC (128 + 15).
finalize() { printf '143\n' >"$EVIDENCE/adapter-exit-code.txt"; }
trap finalize EXIT
printf 'PASS\n' >"$EVIDENCE/outcome.txt"
kill -TERM $$
sleep 30
EOF
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    M8_EVIDENCE="$d"
    M8_ADAPTER_SCRIPT="$stub"
    export M8_STUB_EVIDENCE="$d"
    m8_phase_a_invoke_adapter || return 1
    assert_eq "$(cat "$d/formal-execution-rc.txt")" '143' 'TERM formal RC'
    assert_eq "$(cat "$d/adapter-exit-code.txt")" '143' 'TERM adapter RC'
  ) || rc=$?
  (( rc == 0 )) || return 1
  # A wrong self-declaration (0 for a TERM) must be rejected by the cross-check.
  local wrong="$TMPROOT/term-adapter-wrong.sh"
  cat >"$wrong" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EVIDENCE="${M8_STUB_EVIDENCE:?}"
finalize() { printf '0\n' >"$EVIDENCE/adapter-exit-code.txt"; }
trap finalize EXIT
printf 'PASS\n' >"$EVIDENCE/outcome.txt"
kill -TERM $$
sleep 30
EOF
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    M8_EVIDENCE="$d"
    M8_ADAPTER_SCRIPT="$wrong"
    export M8_STUB_EVIDENCE="$d"
    if m8_phase_a_invoke_adapter; then printf 'TERM RC mismatch was accepted\n'; return 1; fi
  )
}

v08() {
  # SIGKILL cannot run an in-process trap: the adapter RC is absent and the
  # wrapper must fail closed instead of fabricating it.
  local d stub
  d="$(mktemp -d "$TMPROOT/v08.XXXXXX")"
  stub="$TMPROOT/kill-adapter.sh"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EVIDENCE="${M8_STUB_EVIDENCE:?}"
trap 'printf "%s\n" "$?" >"$EVIDENCE/adapter-exit-code.txt"' EXIT
kill -KILL $$
sleep 30
EOF
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    M8_EVIDENCE="$d"
    M8_ADAPTER_SCRIPT="$stub"
    export M8_STUB_EVIDENCE="$d"
    if m8_phase_a_invoke_adapter; then printf 'SIGKILLed adapter was accepted\n'; return 1; fi
    assert_eq "$(cat "$d/formal-execution-rc.txt")" '137' 'SIGKILL formal RC'
    assert_no_file "$d/adapter-exit-code.txt"
  )
}

v09() {
  # The closure receipt is the LAST mutating commit object.
  local log last
  log="$TMPROOT/v09-mutation.log"
  (
    export M8_FAKE_OSS_MUTATION_LOG="$log"
    run_formal_success || return 1
    last="$(grep '^WRITE put-object ' "$log" | tail -n1)"
    case "$last" in
      *closure-receipt.json) ;;
      *) printf 'last mutating object was not the closure receipt: %s\n' "$last"; return 1 ;;
    esac
    assert_eq "$(grep -c '^WRITE put-object .*closure-receipt\.json' "$log")" '1' 'receipt write count'
  )
}

v10() {
  # Once the archive digest is fixed, mutating the archive must fail durability.
  local log
  log="$TMPROOT/v10-mutation.log"
  (
    export M8_FAKE_OSS_MUTATION_LOG="$log"
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    populate_required_artifacts
    FORMAL_EXECUTION_RC=0
    m8_phase_a_validate || return 1
    m8_phase_b_seal || return 1
    printf 'tamper\n' >>"$M8_ARCHIVE_LOCAL"
    if m8_phase_c_durability; then printf 'mutated archive passed durability\n'; return 1; fi
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
  )
}

v11() {
  # A durability failure must never materialize a closure receipt.
  local log
  log="$TMPROOT/v11-mutation.log"
  (
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    export M8_FAKE_OSS_FAIL_PUT_KEY="$M8_OSS_BUCKET-placeholder"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    populate_required_artifacts
    FORMAL_EXECUTION_RC=0
    m8_phase_a_validate || return 1
    m8_phase_b_seal || return 1
    export M8_FAKE_OSS_FAIL_PUT_KEY="$PACKAGE_INDEX_OBJECT"
    if m8_phase_c_durability; then printf 'injected durability failure passed\n'; return 1; fi
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
  )
}

v12() {
  # Tampered receipt read-back => FAIL CLOSED, never "follow the tampered RC".
  local log tampered
  log="$TMPROOT/v12-mutation.log"
  tampered="$TMPROOT/tampered-receipt.json"
  (
    export M8_FAKE_OSS_MUTATION_LOG="$log"
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    populate_required_artifacts
    FORMAL_EXECUTION_RC=0
    m8_phase_a_validate || return 1
    m8_phase_b_seal || return 1
    m8_phase_c_durability || return 1
    printf '{"formal_command_rc": 0}\n' >"$tampered"
    export M8_FAKE_OSS_TAMPER_RECEIPT="$tampered"
    if m8_phase_d_commit; then printf 'tampered receipt read-back passed\n'; return 1; fi
    if m8_terminal_success; then printf 'formal RC emitted after tampered read-back\n'; return 1; fi
  )
}

v13() {
  # Success: fetched receipt RC == terminal marker == wrapper success.
  local out rc=0
  out="$TMPROOT/v13.out"
  (
    run_formal_success || return 1
    assert_eq "$(m8_json_get "$M8_SEAL_DIR/closure-receipt.readback.json" formal_command_rc)" '0' 'receipt formal_command_rc'
    assert_eq "$(m8_json_get "$M8_SEAL_DIR/closure-receipt.readback.json" closure_outcome)" 'PASS' 'receipt closure_outcome'
    local marker
    marker="$(m8_emit_formal_rc_marker "$RECEIPT_VERIFIED_SHA256" 0)" || return 1
    assert_eq "$marker" 'HSDR_F02_FORMAL_RUN_COMMAND_RC=0' 'terminal marker'
    if m8_emit_formal_rc_marker 'deadbeef' 0 >/dev/null; then
      printf 'marker emitted for a mismatched receipt digest\n'; return 1
    fi
    if m8_emit_formal_rc_marker "$RECEIPT_VERIFIED_SHA256" 1 >/dev/null; then
      printf 'marker emitted for a non-zero formal RC\n'; return 1
    fi
    # A tampered post-claim identity capture must fail the wrapper's own check.
    printf 'i-tampered\n' >"$EVIDENCE/provider-identity/reexec/instance-id.txt"
    if m8_phase_a_validate 2>/dev/null; then
      printf 'tampered post-claim identity capture was accepted\n'; return 1
    fi
    m8_terminal_success
  ) >"$out" 2>&1 || rc=$?
  (( rc == 0 )) || { printf 'success fixture failed (rc=%s):\n%s\n' "$rc" "$(tail -n6 "$out")"; return 1; }
  grep -Fq 'HSDR_F02_FORMAL_RUN_COMMAND_RC=0' "$out" ||
    { printf 'wrapper success did not emit the formal RC marker\n'; return 1; }
}

v14() {
  # A committed authorization hard-refuses and never re-emits the formal RC.
  local out rc=0
  out="$TMPROOT/v14.out"
  (
    run_formal_success || return 1
    if m8_already_committed_check; then printf 'committed authorization was accepted\n'; return 1; fi
    return 0
  ) >"$out" 2>&1 || rc=$?
  (( rc == 0 )) || { printf 'committed re-invocation probe failed:\n%s\n' "$(tail -n3 "$out")"; return 1; }
  grep -Fq 'ALREADY_COMMITTED' "$out" ||
    { printf 'no ALREADY_COMMITTED diagnostic was produced\n'; return 1; }
  # The refusal must happen before any execution or formal RC can be produced.
  local check_line execute_line
  check_line="$(grep -n '^  m8_already_committed_check || return 1' "$WRAPPER" | cut -d: -f1)"
  execute_line="$(grep -n '^  m8_phase_b_seal || return 1' "$WRAPPER" | cut -d: -f1)"
  (( check_line < execute_line )) ||
    { printf 'ALREADY_COMMITTED gate does not precede execution/seal\n'; return 1; }
  ! grep -Fq 'HSDR_F02_FORMAL_RUN_COMMAND_RC=0' "$out" ||
    { printf 'formal RC marker emitted on an ALREADY_COMMITTED path\n'; return 1; }
}

v15() {
  # The adapter is not an independent formal runner.
  local root="$TMPROOT/v15-proof" out="$TMPROOT/v15.out" rc=0
  mkdir -p "$root/scripts/lib"
  cp -a "$REPO_ROOT/scripts/lib/." "$root/scripts/lib/"
  cp "$ADAPTER" "$root/scripts/run-m8-proof-alibaba-ecs.sh"
  cat >"$root/scripts/run-m8-proof-core.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'core-invoked\n' >>"${M8_CORE_SENTINEL:?}"
EOF
  export M8_CORE_SENTINEL="$TMPROOT/v15-core-invoked"
  M8_PROOF_ROOT="$root" bash "$root/scripts/run-m8-proof-alibaba-ecs.sh" >"$out" 2>&1 || rc=$?
  (( rc != 0 )) || { printf 'adapter succeeded without wrapper context\n'; return 1; }
  assert_contains "$out" 'M8_ADAPTER_MODE=NONFORMAL'
  assert_contains "$out" 'M8_FORMAL_STATUS=NOT_APPLICABLE'
  assert_no_file "$M8_CORE_SENTINEL"
  assert_no_file "$root/proof-artifacts"
  assert_no_file "$root/candidate"
}

v16() {
  # An existing claim cannot be re-consumed, taken over or renewed.
  (
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    local claimed_sha
    claimed_sha="$(sha256sum "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$CLAIM_OBJECT" | cut -d' ' -f1)"
    if m8_claim_create; then printf 'existing claim was re-consumed\n'; return 1; fi
    assert_eq "$(sha256sum "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$CLAIM_OBJECT" | cut -d' ' -f1)" \
      "$claimed_sha" 'claim object unchanged'
    assert_no_grep 'lease_token|takeover|fencing|expires_at|renewal_token' "$WRAPPER"
  )
}

# ===========================================================================
# V17..V26 — identity, claim, versioning, no-overwrite.
# ===========================================================================
v17() {
  local dup
  dup="$(grep -rn 'i-j6c9854oyawy89fcdxy2' "$REPO_ROOT/scripts" | grep -v 'lib/m8-provider-identity.sh' || true)"
  [[ -z "$dup" ]] || { printf 'provider identity duplicated outside the shared library:\n%s\n' "$dup"; return 1; }
  local const
  for const in EXPECTED_INSTANCE_ID EXPECTED_REGION_ID EXPECTED_ZONE_ID \
    EXPECTED_INSTANCE_TYPE EXPECTED_IMAGE_ID EXPECTED_IDENTITY_DOCUMENT_SHA256 \
    EXPECTED_IDENTITY_PKCS7_SHA256; do
    local count
    count="$(grep -rl "^readonly ${const}=" "$REPO_ROOT/scripts" | wc -l)"
    assert_eq "$count" '1' "$const definition count"
  done
  # The reviewed-tuple guard must fail closed even inside a condition context,
  # where bash suppresses errexit for the whole dynamic extent of the call.
  (
    # shellcheck source=/dev/null
    source "$IDENTITY_LIB"
    if m8_provider_identity_assert 'i-tampered' "$EXPECTED_REGION_ID" "$EXPECTED_ZONE_ID" \
      "$EXPECTED_INSTANCE_TYPE" "$EXPECTED_IMAGE_ID" "$EXPECTED_IDENTITY_DOCUMENT_SHA256" \
      "$EXPECTED_IDENTITY_PKCS7_SHA256" 2>/dev/null; then
      printf 'provider identity guard accepted a tampered instance id\n'
      return 1
    fi
    m8_provider_identity_assert "$EXPECTED_INSTANCE_ID" "$EXPECTED_REGION_ID" "$EXPECTED_ZONE_ID" \
      "$EXPECTED_INSTANCE_TYPE" "$EXPECTED_IMAGE_ID" "$EXPECTED_IDENTITY_DOCUMENT_SHA256" \
      "$EXPECTED_IDENTITY_PKCS7_SHA256"
  )
}

v18() {
  local body version_line identity_line claim_line
  body="$TMPROOT/v18.wrapper-run"
  sed -n '/^m8_wrapper_run()/,/^}/p' "$WRAPPER" >"$body"
  version_line="$(grep -n 'm8_oss_versioning_guard "\$M8_PRECLAIM_DIR"' "$body" | head -n1 | cut -d: -f1)"
  identity_line="$(grep -n 'm8_provider_identity_preclaim || return 1' "$body" | head -n1 | cut -d: -f1)"
  claim_line="$(grep -n 'm8_claim_create || return 1' "$body" | head -n1 | cut -d: -f1)"
  [[ -n "$version_line" && -n "$identity_line" && -n "$claim_line" ]] ||
    { printf 'wrapper ordering anchors not found\n'; return 1; }
  (( version_line < identity_line && identity_line < claim_line )) ||
    { printf 'order must be versioning(%s) < identity(%s) < claim(%s)\n' "$version_line" "$identity_line" "$claim_line"; return 1; }

  # Guards must fail closed even when called in a condition context.
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    if M8_OSS_BUCKET='NOT_A_VALID_BUCKET' m8_oss_require_config 2>/dev/null; then
      printf 'oss config guard accepted an invalid bucket\n'
      return 1
    fi
    if M8_OSSUTIL_BIN='/nonexistent/ossutil' M8_OSS_BUCKET='test-bucket' m8_oss_require_config 2>/dev/null; then
      printf 'oss config guard accepted a non-executable binary\n'
      return 1
    fi
  ) || return 1
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    local bad_core="$TMPROOT/v18-bad-core.sh"
    cat >"$bad_core" <<'EOF'
#!/usr/bin/env bash
printf 'candidate_sha=0000000000000000000000000000000000000000\n'
EOF
    M8_CORE_SCRIPT="$bad_core"
    if m8_guard_static_binding 2>/dev/null; then
      printf 'static binding guard accepted a tampered core binding\n'
      return 1
    fi
    M8_CORE_SCRIPT="$CORE"
    m8_guard_static_binding
  )
}

v19() {
  local body claim_line identity_line core_line
  body="$TMPROOT/v19.adapter"
  cp "$ADAPTER" "$body"
  claim_line="$(grep -n '^claim_verify$' "$body" | cut -d: -f1)"
  identity_line="$(grep -n '^provider_identity_reverify "\$CLAIM_FILE"$' "$body" | cut -d: -f1)"
  core_line="$(grep -n 'bash "\$CORE" || CORE_RC=\$?' "$body" | cut -d: -f1)"
  [[ -n "$claim_line" && -n "$identity_line" && -n "$core_line" ]] ||
    { printf 'adapter ordering anchors not found\n'; return 1; }
  (( claim_line < identity_line && identity_line < core_line )) ||
    { printf 'adapter must verify the claim, re-verify identity, then invoke the core\n'; return 1; }
  # The adapter holds no commit authority: it must create no canonical object.
  assert_no_grep 'm8_oss_put_object' "$ADAPTER"
  assert_no_grep 'closure-receipt|package-index|m8_archive_build|m8_manifest_generate' "$ADAPTER"
}

v20() {
  assert_grep 'forbid-overwrite true' "$OSS_LIB"
  assert_no_grep 'forbid-overwrite false' "$OSS_LIB"
  assert_no_grep 'head-object' "$WRAPPER"
  assert_grep 'm8_oss_put_object_no_overwrite' "$WRAPPER"
  # The capability guard must accept a fully capable client and fail closed on
  # one that cannot demonstrate --forbid-overwrite.
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v20-oss"
    mkdir -p "$M8_FAKE_OSS_ROOT"
    M8_FAKE_OSS_CAPABILITY=full m8_oss_capability_guard - || return 1
    if M8_FAKE_OSS_CAPABILITY=no-forbid-overwrite m8_oss_capability_guard - 2>/dev/null; then
      printf 'capability guard accepted a client without --forbid-overwrite\n'
      return 1
    fi
  )
}

v21() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v21-oss" M8_FAKE_OSS_VERSIONING='enabled'
    mkdir -p "$M8_FAKE_OSS_ROOT"
    if m8_oss_versioning_guard -; then printf 'versioning Enabled was accepted\n'; return 1; fi
  )
}

v22() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v22-oss" M8_FAKE_OSS_VERSIONING='suspended'
    mkdir -p "$M8_FAKE_OSS_ROOT"
    if m8_oss_versioning_guard -; then printf 'versioning Suspended was accepted\n'; return 1; fi
  )
}

v23() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    mkdir -p "$TMPROOT/v23-oss"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v23-oss"
    M8_FAKE_OSS_VERSIONING='unversioned' m8_oss_versioning_guard - || return 1
    M8_FAKE_OSS_VERSIONING='null' m8_oss_versioning_guard - || return 1
  )
}

v24() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    mkdir -p "$TMPROOT/v24-oss"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v24-oss"
    if M8_FAKE_OSS_VERSIONING='garbage' m8_oss_versioning_guard -; then
      printf 'unparseable versioning response was accepted\n'; return 1
    fi
    if M8_FAKE_OSS_VERSIONING='denied' m8_oss_versioning_guard -; then
      printf 'access-denied versioning response was accepted\n'; return 1
    fi
  )
}

v25() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v25-oss"
    mkdir -p "$M8_FAKE_OSS_ROOT"
    local first="$TMPROOT/v25-a.txt" second="$TMPROOT/v25-b.txt" rc=0
    printf 'first\n' >"$first"
    printf 'second\n' >"$second"
    if m8_oss_put_object_no_overwrite 'runs/x/a.txt' "$first" -; then :; else rc=$?; fi
    assert_eq "$rc" '0' 'first put rc'
    rc=0
    if m8_oss_put_object_no_overwrite 'runs/x/a.txt' "$second" -; then :; else rc=$?; fi
    assert_eq "$rc" "$M8_OSS_EXISTS" 'second put rc'
    assert_eq "$(object_bytes 'runs/x/a.txt')" 'first' 'stored bytes'
  )
}

v26() {
  # The read-only versioning guard must precede the first PutObject.
  local log
  log="$TMPROOT/v26-mutation.log"
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v26-oss" M8_FAKE_OSS_MUTATION_LOG="$log"
    export M8_FAKE_OSS_VERSIONING='unversioned'
    mkdir -p "$M8_FAKE_OSS_ROOT"
    local body="$TMPROOT/v26-body.txt"
    printf 'payload\n' >"$body"
    m8_oss_versioning_guard - || return 1
    m8_oss_put_object_no_overwrite 'authorizations/x/claim.json' "$body" - || return 1
    log="$log"
    local first_write first_read
    first_read="$(grep -n '^READ get-bucket-versioning' "$log" | head -n1 | cut -d: -f1)"
    first_write="$(grep -n '^WRITE put-object' "$log" | head -n1 | cut -d: -f1)"
    [[ -n "$first_read" && -n "$first_write" ]] || { printf 'mutation log anchors missing\n'; return 1; }
    (( first_read < first_write )) ||
      { printf 'a PutObject preceded the versioning guard\n'; return 1; }
  )
}

# ===========================================================================
# V27..V40 — Playwright runtime evidence, receipt commit, retry, policy.
# ===========================================================================
# ---------------------------------------------------------------------------
# Playwright JSON report mutations.
#
# The checked-in positive fixture is minimal and realistic: seven suites with
# rootDir-relative `e2e/...` file values and 34 spec objects. Every negative
# report is derived PROGRAMMATICALLY from it, so no near-duplicate fixture tree
# is maintained and no impossible-path fixture can drift from the contract.
# ---------------------------------------------------------------------------
mutate_playwright_report() {
  local mode=$1 out=$2
  "$PYTHON" - "$FIXTURES/playwright-json-good.json" "$out" "$mode" <<'PY'
import copy
import json
import sys

source, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]

if mode == "unparseable":
    with open(out, "w", encoding="utf-8") as handle:
        handle.write("{ this is not a Playwright JSON report\n")
    raise SystemExit(0)

with open(source, encoding="utf-8") as handle:
    report = json.load(handle)

if mode == "bad-retries":
    report["config"]["projects"][0]["retries"] = 2
elif mode == "bad-project":
    report["config"]["projects"][0]["name"] = "firefox"
elif mode == "bad-stats":
    report["stats"]["expected"] = 33
    report["stats"]["unexpected"] = 1
    report["stats"]["flaky"] = 1
    report["stats"]["skipped"] = 1
elif mode == "drop-spec":
    report["suites"] = report["suites"][:-1]
elif mode == "duplicate-basename":
    extra = copy.deepcopy(report["suites"][0])
    extra["title"] = "vendor/e2e/golden-path.spec.ts"
    extra["file"] = "vendor/e2e/golden-path.spec.ts"
    for spec in extra["specs"]:
        spec["file"] = "vendor/e2e/golden-path.spec.ts"
    report["suites"].append(extra)
else:
    raise SystemExit("unknown Playwright mutation mode: %s" % mode)

with open(out, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

v27() {
  local out="$TMPROOT/v27-out.txt"
  local -a spec_args=()
  local spec
  for spec in "${PLAYWRIGHT_FROZEN_SPECS[@]}"; do
    spec_args+=(--spec "$spec")
  done
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$FIXTURES/playwright-json-good.json" --out "$out" \
    "${spec_args[@]}" >/dev/null || return 1
  assert_eq "$(cat "$out")" 'PLAYWRIGHT_EFFECTIVE_RETRIES=0' 'effective retries content'
  assert_eq "$(wc -c <"$out")" "$(printf 'PLAYWRIGHT_EFFECTIVE_RETRIES=0\n' | wc -c)" 'effective retries byte length'
  # The realistic positive fixture must use the actual rootDir-relative namespace.
  assert_no_contains "$FIXTURES/playwright-json-good.json" 'apps/web/e2e'
  assert_contains "$FIXTURES/playwright-json-good.json" '"file": "e2e/golden-path.spec.ts"'
}

v28() {
  local out="$TMPROOT/v28-out.txt" report="$TMPROOT/v28-report.json"
  mutate_playwright_report bad-retries "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" >/dev/null 2>&1; then
    printf 'retries != 0 was accepted\n'
    return 1
  fi
  assert_no_file "$out"
}

v29() {
  local out="$TMPROOT/v29-out.txt" report="$TMPROOT/v29-report.json"
  mutate_playwright_report bad-project "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" >/dev/null 2>&1; then
    printf 'non-chromium project was accepted\n'
    return 1
  fi
  assert_no_file "$out"
}

v30() {
  local out="$TMPROOT/v30-out.txt" report="$TMPROOT/v30-report.json"
  mutate_playwright_report bad-stats "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" >/dev/null 2>&1; then
    printf 'flaky/expected mismatch was accepted\n'
    return 1
  fi
  assert_no_file "$out"
}

v31() {
  local out="$TMPROOT/v31-out.txt" report="$TMPROOT/v31-unparseable.json"
  mutate_playwright_report unparseable "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" >/dev/null 2>&1; then
    printf 'unparseable report was accepted\n'
    return 1
  fi
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$TMPROOT/absent-report.json" --out "$out" >/dev/null 2>&1; then
    printf 'missing report was accepted\n'
    return 1
  fi
  assert_no_file "$out"
}

v32() {
  local body="$TMPROOT/v32-browser"
  sed -n '/^browser_e2e()/,/^}/p' "$CORE" >"$body"
  assert_eq "$(grep -c -- '--reporter' "$body")" '1' 'single reporter option in the browser stage'
  assert_grep '--reporter=list,json' "$body"
  assert_grep 'export CI=1' "$body"
  assert_grep 'PLAYWRIGHT_JSON_OUTPUT_FILE=' "$body"
  assert_grep 'verify-m8-playwright-json\.py' "$body"
}

v33() {
  assert_grep '--retries=0' "$CORE"
  assert_grep '--fail-on-flaky-tests' "$CORE"
  assert_eq "$(grep -oE 'e2e/[a-z-]+\.spec\.ts' "$CORE" | sort -u | wc -l)" '7' 'seven frozen specs'
  local spec
  for spec in golden-path unicode segmentation token-segmentation lemma-annotation \
    pos-annotation workbench-information-architecture; do
    assert_contains "$CORE" "e2e/$spec.spec.ts"
  done
}

v34() {
  local missing_root="$TMPROOT/v34-missing" full_root="$TMPROOT/v34-full"
  mkdir -p "$missing_root/sub"
  printf 'x\n' >"$missing_root/a.txt"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$missing_root" --required "$REQUIRED_LIST" >/dev/null 2>&1; then
    printf 'incomplete evidence root was accepted\n'
    return 1
  fi
  populate_required_root "$full_root"
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$full_root" --required "$REQUIRED_LIST" >/dev/null || return 1
  # A required list that is entirely comments is refused.
  printf '# nothing\n\n' >"$TMPROOT/v34-empty-list.txt"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$full_root" --required "$TMPROOT/v34-empty-list.txt" >/dev/null 2>&1; then
    printf 'empty required list was accepted\n'
    return 1
  fi
}

v35() {
  local receipt="$TMPROOT/v35-receipt.json"
  (
    run_formal_success || return 1
    cp "$M8_SEAL_DIR/closure-receipt.readback.json" "$receipt"
    assert_no_grep 'terminal_line' "$receipt"
    "$PYTHON" "$REPO_ROOT/scripts/verify-m8-closure-receipt.py" --receipt "$receipt" >/dev/null || return 1
    "$PYTHON" - "$receipt" "$TMPROOT/v35-tampered.json" <<'PY'
import json
import sys

source, out = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)
document["terminal_line"] = "HSDR_F02_FORMAL_RUN_COMMAND_RC=0"
with open(out, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
PY
    if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-closure-receipt.py" \
      --receipt "$TMPROOT/v35-tampered.json" >/dev/null 2>&1; then
      printf 'receipt with terminal_line was accepted\n'
      return 1
    fi
  )
}

v36() {
  (
    run_formal_success || return 1
    local receipt="$M8_SEAL_DIR/closure-receipt.readback.json"
    "$PYTHON" "$REPO_ROOT/scripts/verify-m8-closure-receipt.py" \
      --receipt "$receipt" \
      --expect-sha256 "$RECEIPT_VERIFIED_SHA256" \
      --expect-proof-sha "$APPROVED_PROOF_SHA" \
      --expect-candidate-sha '2441f9cf60b7cc9402c5b257be010b559b39b717' \
      --expect-authorization-sha "$AUTH" \
      --expect-archive-sha256 "$SEALED_ARCHIVE_SHA256" >/dev/null || return 1
    # Cross-binding and provider digest fields must be present and consistent.
    assert_eq "$(m8_json_get "$receipt" cross_binding.sealed_archive_sha256)" \
      "$(m8_json_get "$receipt" archive_sha256)" 'sealed archive cross-binding'
    assert_eq "$(m8_json_get "$receipt" cross_binding.package_index_archive_sha256)" \
      "$(m8_json_get "$receipt" archive_sha256)" 'package index cross-binding'
    assert_eq "$(m8_json_get "$receipt" cross_binding.manifest_sha256)" \
      "$(m8_json_get "$receipt" artifact_manifest_sha256)" 'manifest cross-binding'
    assert_eq "$(m8_json_get "$receipt" cross_binding.claim_object_sha256)" \
      "$(m8_json_get "$receipt" claim_sha256)" 'claim cross-binding'
    # B1/B5: the issued-DOCUMENT digest is the separate cross-bound field, while
    # authorization_sha256 is the token identity and must not be the document
    # digest.
    assert_eq "$(m8_json_get "$receipt" cross_binding.issued_document_sha256)" \
      "$(m8_json_get "$receipt" issued_document_sha256)" 'issued document cross-binding'
    assert_eq "$(m8_json_get "$receipt" issued_document_sha256)" \
      "$(sha256sum "$M8_PRECLAIM_DIR/issued.json" | cut -d' ' -f1)" 'issued document digest'
    assert_eq "$(m8_json_get "$receipt" authorization_sha256)" "$AUTH" 'token authorization identity'
    [[ "$(m8_json_get "$receipt" authorization_sha256)" != \
      "$(m8_json_get "$receipt" issued_document_sha256)" ]] ||
      { printf 'authorization_sha256 was conflated with the issued-document digest\n'; return 1; }
    assert_eq "$(m8_json_get "$receipt" provider_identity.instance_id)" \
      "$EXPECTED_INSTANCE_ID" 'provider instance binding'
    assert_eq "$(m8_json_get "$receipt" provider_identity.identity_document_sha256)" \
      "$EXPECTED_IDENTITY_DOCUMENT_SHA256" 'provider document digest binding'
    # Every canonical receipt field is materialised by the wrapper builder.
    local field
    while IFS= read -r field; do
      case "$field" in '' | '#'*) continue ;; esac
      m8_json_get "$receipt" "$field" >/dev/null ||
        { printf 'canonical receipt field is absent: %s\n' "$field"; return 1; }
    done <"$REPO_ROOT/scripts/lib/m8-receipt-fields.txt"
  )
}

v37() {
  (
    run_formal_success || return 1
    local receipt="$M8_SEAL_DIR/closure-receipt.readback.json" tampered="$TMPROOT/v37-tampered.json"
    "$PYTHON" - "$receipt" "$tampered" <<'PY'
import json
import sys

source, out = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)
document["formal_command_rc"] = 1
with open(out, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
PY
    if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-closure-receipt.py" \
      --receipt "$tampered" >/dev/null 2>&1; then
      printf 'receipt with formal_command_rc=1 was accepted\n'
      return 1
    fi
  )
}

# Executable lines only: a comment that merely documents a prohibition is not a
# capability. A trailing comment on a real call would still be detected.
code_only() { grep -v '^[[:space:]]*#' "$1"; }

v38() {
  assert_contains "$REPO_ROOT/README.md" 'ISSUER'
  assert_contains "$REPO_ROOT/README.md" 'EXECUTOR'
  local pattern='DeleteObject|delete-object|PutBucketVersioning|put-bucket-versioning'
  assert_no_grep "$pattern" <(code_only "$OSS_LIB")
  assert_no_grep "$pattern" <(code_only "$WRAPPER")
  assert_no_grep "$pattern" <(code_only "$ADAPTER")
  assert_no_grep "$pattern" <(code_only "$CORE")
  # Controls: the filter must not hide a real call, and must drop pure comments.
  local control="$TMPROOT/v38-control.sh"
  printf '# delete-object only in a comment\nossutil api delete-object --bucket b\n' >"$control"
  grep -Eq -e 'delete-object' <(code_only "$control") ||
    { printf 'control: a real delete-object call was not detected\n'; return 1; }
  printf '# PutBucketVersioning only in a comment\n' >"$control"
  if grep -Eq -e 'PutBucketVersioning' <(code_only "$control"); then
    printf 'control: a comment-only mention was not filtered\n'
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Durability-retry fixture.
# ---------------------------------------------------------------------------
bootstrap_retry_fixture() {
  # shellcheck source=lib/m8-provider-identity.sh
  source "$IDENTITY_LIB"
  # shellcheck source=lib/m8-manifest.sh
  source "$MANIFEST_LIB"

  SB="$(mktemp -d "$TMPROOT/rt.XXXXXX")"
  PROOF="$SB/proof"
  HOST="$SB/host"
  EVIDENCE="$PROOF/proof-artifacts"
  FAKE_ROOT="$SB/oss"
  mkdir -p "$PROOF" "$HOST" "$FAKE_ROOT/objects"
  cp -a "$REPO_ROOT/scripts" "$PROOF/scripts"
  git -C "$PROOF" init -q
  git -C "$PROOF" add -A >/dev/null
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$PROOF" commit -qm 'synthetic retry fixture' >/dev/null
  APPROVED_PROOF_SHA="$(git -C "$PROOF" rev-parse HEAD)"
  APPROVED_PROOF_TREE="$(git -C "$PROOF" rev-parse HEAD^{tree})"
  export APPROVED_PROOF_SHA APPROVED_PROOF_TREE
  export M8_PROOF_ROOT="$PROOF" M8_PROOF_HOST_STATE="$HOST" M8_PROOF_EVIDENCE_DIR="$EVIDENCE"
  export M8_SYNTHETIC_TEST_MODE=1 M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
  export M8_FAKE_OSS_ROOT="$FAKE_ROOT" M8_FAKE_OSS_VERSIONING='unversioned'
  export M8_EXECUTOR_ID="$M8_PROVIDER_EXECUTOR_ID"

  # A pre-existing sealed semantic run: archive + package index.
  SEMANTIC_AUTH="$(printf 'semantic-authorization' | sha256sum | cut -d' ' -f1)"
  SEAL_DIR="$HOST/sealed/$SEMANTIC_AUTH"
  ARCHIVE_NAME="m8-proof-artifacts-$APPROVED_PROOF_SHA-$SEMANTIC_AUTH.tar.gz"
  ARCHIVE_OBJECT="runs/$APPROVED_PROOF_SHA/$SEMANTIC_AUTH/$ARCHIVE_NAME"
  PACKAGE_INDEX_OBJECT="runs/$APPROVED_PROOF_SHA/$SEMANTIC_AUTH/package-index.json"
  RECEIPT_OBJECT="runs/$APPROVED_PROOF_SHA/$SEMANTIC_AUTH/closure-receipt.json"
  ARCHIVE_LOCAL="$SEAL_DIR/$ARCHIVE_NAME"
  PACKAGE_INDEX_LOCAL="$SEAL_DIR/package-index.json"

  local archive_root="$SB/sealed-root"
  mkdir -p "$archive_root/proof-artifacts"
  printf 'sealed artifact\n' >"$archive_root/proof-artifacts/payload.txt"
  m8_manifest_generate "$archive_root/proof-artifacts"
  mkdir -p "$SEAL_DIR"
  m8_archive_build "$archive_root" 'proof-artifacts' "$ARCHIVE_LOCAL" || return 1
  local archive_sha manifest_sha archive_size
  archive_sha="$(sha256sum "$ARCHIVE_LOCAL" | cut -d' ' -f1)"
  archive_size="$(wc -c <"$ARCHIVE_LOCAL" | tr -d '[:space:]')"
  manifest_sha="$(sha256sum "$archive_root/proof-artifacts/artifact-manifest.sha256" | cut -d' ' -f1)"
  "$PYTHON" - "$PACKAGE_INDEX_LOCAL" "$archive_sha" "$archive_size" "$manifest_sha" \
    "$ARCHIVE_NAME" "$ARCHIVE_OBJECT" "$APPROVED_PROOF_SHA" "$APPROVED_PROOF_TREE" \
    "$SEMANTIC_AUTH" <<'PY'
import json
import sys

(out, archive_sha, archive_size, manifest_sha, archive_name, archive_object,
 proof_sha, proof_tree, semantic_auth) = sys.argv[1:10]
document = {
    "schema": "linguagraph-m8-package-index/v1",
    "authorization_kind": "SEMANTIC",
    "authorization_sha256": semantic_auth,
    "semantic_auth_sha256": semantic_auth,
    "retry_auth_sha256": None,
    "proof_sha": proof_sha,
    "proof_tree": proof_tree,
    "archive": {
        "name": archive_name,
        "object": archive_object,
        "sha256": archive_sha,
        "size_bytes": int(archive_size),
    },
    "artifact_manifest": {"name": "artifact-manifest.sha256", "sha256": manifest_sha},
    "exit_codes": {"core": 0, "adapter": 0, "formal_execution": 0},
    "playwright_effective_retries": 0,
    "artifacts": [],
    "execution_started_utc": "2026-01-01T00:00:00Z",
    "sealed_utc": "2026-01-01T00:05:00Z",
}
with open(out, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
  local package_index_sha
  package_index_sha="$(sha256sum "$PACKAGE_INDEX_LOCAL" | cut -d' ' -f1)"

  RETRY_ISSUED="$SB/retry-issued.json"
  RETRY_TOKEN='M8-EXI-01-RETRY-SYNTHETIC-TOKEN'
  RETRY_AUTH="$(printf '%s' "$RETRY_TOKEN" | sha256sum | cut -d' ' -f1)"
  "$PYTHON" - "$RETRY_ISSUED" "$APPROVED_PROOF_SHA" "$APPROVED_PROOF_TREE" \
    "$SEMANTIC_AUTH" "$archive_sha" "$package_index_sha" "$ARCHIVE_NAME" "$RETRY_AUTH" <<'PY'
import json
import sys

(out, proof_sha, proof_tree, semantic_auth, archive_sha,
 package_index_sha, archive_name, retry_auth) = sys.argv[1:9]
document = {
    "schema": "linguagraph-m8-durability-retry-authorization/v1",
    "authorization_kind": "DURABILITY_RETRY",
    "authorization_id": "M8-EXI-01-RETRY-SYNTHETIC",
    "authorization_sha256": retry_auth,
    "semantic_auth_sha256": semantic_auth,
    "proof_sha": proof_sha,
    "proof_tree": proof_tree,
    "candidate_sha": "2441f9cf60b7cc9402c5b257be010b559b39b717",
    "candidate_tree": "5d1b7c7cc104cd365b0ea629d9ead7677d17f2be",
    "candidate_parent": "e4b1cc66f540ab74c0ef9bd014b0a0da3a2d9c1d",
    "frozen_main": "cf26ea557bd746a518ff32b8b7e7a7542be7f7ae",
    "provider_identity": {
        "instance_id": "i-j6c9854oyawy89fcdxy2",
        "region_id": "cn-hongkong",
        "zone_id": "cn-hongkong-d",
        "instance_type": "ecs.g9i.xlarge",
        "image_id": "ubuntu_24_04_x64_20G_alibase_20260916.vhd",
        "identity_document_sha256": "60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d",
        "identity_pkcs7_sha256": "89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211",
    },
    "authorized_executor_id": "alibaba-ecs:i-j6c9854oyawy89fcdxy2",
    "single_use": True,
    "run_prefix": "runs/%s/%s" % (proof_sha, semantic_auth),
    "archive_name": archive_name,
    "archive_sha256": archive_sha,
    "package_index_sha256": package_index_sha,
    "issued_utc": "2026-01-02T00:00:00Z",
}
with open(out, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY

  export M8_PROOF_RETRY_AUTHORIZATION="$RETRY_TOKEN"
  stage_object "authorizations/$RETRY_AUTH/issued.json" "$RETRY_ISSUED"

  M8_PRECLAIM_DIR="$HOST/preclaim/$RETRY_AUTH"
  export M8_PRECLAIM_DIR SEAL_DIR SB PROOF HOST EVIDENCE FAKE_ROOT
  export SEMANTIC_AUTH RETRY_AUTH RETRY_TOKEN ARCHIVE_LOCAL PACKAGE_INDEX_LOCAL
  export ARCHIVE_NAME ARCHIVE_OBJECT PACKAGE_INDEX_OBJECT RECEIPT_OBJECT
}

run_retry_success() {
  bootstrap_retry_fixture
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/run-m8-proof.sh"
  m8_wrapper_init
  m8_guard_local_syntax || return 1
  m8_load_authorization || return 1
  m8_claim_create || return 1
  m8_evidence_initialize || return 1
  m8_phase_b_seal || return 1
  m8_phase_c_durability || return 1
  m8_phase_d_commit || return 1
}

v39() {
  # A retry with a missing local package-index is NOT eligible and must not
  # regenerate it or produce a receipt.
  (
    bootstrap_retry_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    rm -f "$M8_PACKAGE_INDEX_LOCAL"
    if m8_phase_b_seal; then printf 'retry with missing package-index was eligible\n'; return 1; fi
    assert_no_file "$PACKAGE_INDEX_LOCAL"
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
  )
}

v40() {
  # A retry never reruns core/adapter and writes only the allowed objects.
  local log rc=0
  log="$TMPROOT/v40-mutation.log"
  (
    export M8_FAKE_OSS_MUTATION_LOG="$log"
    run_retry_success || return 1
    assert_no_file "$EVIDENCE/stages.txt"
    assert_no_file "$EVIDENCE/adapter-raw.log"
    assert_no_file "$EVIDENCE/outcome.txt"
    local line key
    while IFS= read -r line; do
      case "$line" in
        'WRITE put-object '*)
          key="${line#WRITE put-object }"
          case "$key" in
            "$ARCHIVE_OBJECT" | "$PACKAGE_INDEX_OBJECT" | "$RECEIPT_OBJECT" | "$CLAIM_OBJECT") ;;
            *) printf 'retry wrote a non-canonical object: %s\n' "$key"; return 1 ;;
          esac
          ;;
      esac
    done <"$log"
    assert_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
    # Static: the retry branch never invokes the semantic execution phase.
    local body
    body="$TMPROOT/v40.wrapper-run"
    sed -n '/DURABILITY_RETRY) : ;; #/,/^  esac/p' "$WRAPPER" >"$body"
    assert_grep 'DURABILITY_RETRY' "$body"
    assert_no_grep 'm8_phase_a' "$body"
  ) || rc=$?
  (( rc == 0 )) || return 1

  # A retry is allowed on the host that still holds the failed semantic run's
  # evidence tree, and must leave that tree byte-identical.
  (
    bootstrap_retry_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    mkdir -p "$EVIDENCE"
    printf 'failed-semantic-run-evidence\n' >"$EVIDENCE/payload.txt"
    printf 'FAIL exit=1\n' >"$EVIDENCE/outcome.txt"
    local before
    before="$(cd "$EVIDENCE" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
    m8_guard_clean_start || { printf 'retry was blocked by the failed run evidence tree\n'; return 1; }
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    m8_phase_b_seal || return 1
    m8_phase_c_durability || return 1
    m8_phase_d_commit || return 1
    assert_eq "$(cd "$EVIDENCE" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" \
      "$before" 'sealed evidence tree unchanged by retry'
  ) || rc=$?
  (( rc == 0 )) || return 1

  # The semantic path still refuses a pre-existing evidence tree.
  (
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    mkdir -p "$EVIDENCE"
    if m8_guard_clean_start; then
      printf 'a semantic run accepted a pre-existing evidence tree\n'
      return 1
    fi
  )
}

# ===========================================================================
# R2E-B01 correction regressions (C01..C09). These are separate from the legacy
# V01..V40 baseline: a green V01..V40 alone is not sufficient evidence.
# ===========================================================================

assert_required_list_reject() {
  local root=$1 list=$2 pattern=$3 out='' rc=0
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$list" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'required list was accepted: %s\n' "$list"; return 1; }
  grep -Fq -- "$pattern" <<<"$out" ||
    { printf 'missing diagnostic %s for %s:\n%s\n' "$pattern" "$list" "$out"; return 1; }
  return 0
}

assert_manifest_reject() {
  local root=$1 manifest=$2 pattern=$3 out='' rc=0
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" --manifest "$manifest" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'manifest was accepted: %s\n' "$manifest"; return 1; }
  grep -Fq -- "$pattern" <<<"$out" ||
    { printf 'missing diagnostic %s for %s:\n%s\n' "$pattern" "$manifest" "$out"; return 1; }
  return 0
}

# C01 — authorization_sha256 = SHA256(exact Human-issued TOKEN).
c01() {
  # The needle is assembled at runtime so this check cannot match itself.
  local needle='issued_json_content''_sha256' hits
  hits="$(grep -rn "$needle" "$REPO_ROOT/scripts" \
    "$REPO_ROOT/tests/run-static-verification.sh" || true)"
  [[ -z "$hits" ]] ||
    { printf 'self-referential issued.json digest remains:\n%s\n' "$hits"; return 1; }
  # Static: the adapter derives the presented token's digest itself and compares
  # the DIGEST with the context; the raw token is never compared with, or
  # written beside, the context digest.
  assert_contains "$ADAPTER" 'presented_sha='
  assert_no_contains "$ADAPTER" 'expect "$presented" "$authorization_sha"'
  assert_contains "$WRAPPER" 'm8_sha256_token'
  (
    bootstrap_formal_fixture || return 1
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init

    # Two distinct tokens with IDENTICAL issued-document byte content derive
    # different authorization_sha256 object paths, and neither path is the
    # document digest.
    local doc="$TMPROOT/c01-identical-doc.json" sha_a sha_b doc_sha
    printf '{"schema": "linguagraph-m8-run-authorization/v1"}\n' >"$doc"
    sha_a="$(m8_sha256_token 'm8-token-alpha')"
    sha_b="$(m8_sha256_token 'm8-token-beta')"
    assert_eq "$(wc -c <"$doc")" "$(wc -c <"$doc")" 'identical document bytes'
    [[ "$sha_a" != "$sha_b" ]] ||
      { printf 'distinct tokens produced the same authorization identity\n'; return 1; }
    [[ "authorizations/$sha_a/issued.json" != "authorizations/$sha_b/issued.json" ]] ||
      { printf 'the token identity does not determine the object path\n'; return 1; }
    doc_sha="$(sha256sum "$doc" | cut -d' ' -f1)"
    [[ "$doc_sha" != "$sha_a" && "$doc_sha" != "$sha_b" ]] ||
      { printf 'authorization identity is still derived from document bytes\n'; return 1; }

    # A document that does not BIND the presented token digest FAILS CLOSED.
    stage_object "authorizations/$sha_a/issued.json" "$doc"
    export M8_PROOF_RUN_AUTHORIZATION='m8-token-alpha'
    if m8_guard_local_syntax && m8_load_authorization 2>/dev/null; then
      printf 'a document without the token binding was accepted\n'
      return 1
    fi

    # The correctly bound document is accepted, at the token-derived path, even
    # though its own bytes do not hash to the authorization identity.
    stage_object "authorizations/$AUTH/issued.json" "$ISSUED_LOCAL"
    export M8_PROOF_RUN_AUTHORIZATION="$SEMANTIC_TOKEN"
    m8_guard_local_syntax || return 1
    m8_load_authorization || return 1
    assert_eq "$AUTHORIZATION_SHA256" "$AUTH" 'token-derived authorization identity'
    assert_eq "$ISSUED_OBJECT" "authorizations/$AUTH/issued.json" 'token-derived object path'
    assert_eq "$ISSUED_DOCUMENT_SHA256" "$(sha256sum "$ISSUED_LOCAL" | cut -d' ' -f1)" \
      'issued-document byte identity'
    [[ "$AUTHORIZATION_SHA256" != "$ISSUED_DOCUMENT_SHA256" ]] ||
      { printf 'authorization identity was conflated with the document digest\n'; return 1; }
  )
}

# C02 — a mismatched issued.json.authorization_sha256 FAILS CLOSED.
c02() {
  (
    bootstrap_formal_fixture || return 1
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init

    local mismatched="$TMPROOT/c02-mismatched-issued.json"
    "$PYTHON" - "$ISSUED_LOCAL" "$mismatched" <<'PY'
import json
import sys

source, out = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)
document["authorization_sha256"] = "0" * 64
with open(out, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
    stage_object "authorizations/$AUTH/issued.json" "$mismatched"
    m8_guard_local_syntax || return 1
    if m8_load_authorization 2>/dev/null; then
      printf 'mismatched issued authorization_sha256 was accepted\n'
      return 1
    fi
    # The exact-byte self-reference is gone: the fixture document bytes do NOT
    # hash to $AUTH, yet a correctly bound document loads.
    [[ "$(sha256sum "$ISSUED_LOCAL" | cut -d' ' -f1)" != "$AUTH" ]] ||
      { printf 'fixture document digest accidentally equals the token identity\n'; return 1; }
    stage_object "authorizations/$AUTH/issued.json" "$ISSUED_LOCAL"
    m8_load_authorization || return 1
  )
}

# C03 — every synthetic seam is rejected by both production entrypoints.
c03() {
  local name out rc=0
  local -a unset_args=()
  for name in "${SYNTHETIC_SEAM_VARS[@]}"; do
    unset_args+=(-u "$name")
  done

  # The seam set is single-sourced in the shared library.
  assert_eq "$(grep -rl 'readonly -a M8_SYNTHETIC_SEAM_VARS=' "$REPO_ROOT/scripts" | wc -l)" \
    '1' 'seam declaration count'
  assert_contains "$WRAPPER" 'm8_reject_synthetic_overrides'
  assert_contains "$ADAPTER" 'm8_reject_synthetic_overrides'

  for name in "${SYNTHETIC_SEAM_VARS[@]}"; do
    rc=0
    out="$(env "${unset_args[@]}" "$name=seam-probe" bash "$WRAPPER" 2>&1)" || rc=$?
    (( rc != 0 )) || { printf '%s did not make the formal wrapper fail closed\n' "$name"; return 1; }
    grep -Fq "$name is set" <<<"$out" ||
      { printf '%s: no seam diagnostic was produced\n%s\n' "$name" "$out"; return 1; }
    grep -Fq 'refuses offline synthetic overrides' <<<"$out" ||
      { printf '%s: unexpected refusal path\n%s\n' "$name" "$out"; return 1; }
    ! grep -Fq 'missing single-use authorization' <<<"$out" ||
      { printf '%s: the guard did not precede the authorization check\n' "$name"; return 1; }
    ! grep -Fq 'HSDR_F02_FORMAL_RUN_COMMAND_RC' <<<"$out" ||
      { printf '%s: a formal marker was emitted on a rejected invocation\n' "$name"; return 1; }
    ! grep -Fq 'M8_SYNTHETIC_OUTCOME=OK' <<<"$out" ||
      { printf '%s: synthetic success was reported on a rejected invocation\n' "$name"; return 1; }
  done

  # Direct production execution of the adapter must refuse the same seams before
  # its formal-context guards.
  for name in M8_IMDS_BASE_URL M8_OSSUTIL_BIN; do
    rc=0
    out="$(env "${unset_args[@]}" "$name=seam-probe" bash "$ADAPTER" 2>&1)" || rc=$?
    (( rc != 0 )) || { printf '%s did not make the adapter fail closed\n' "$name"; return 1; }
    grep -Fq "$name is set" <<<"$out" ||
      { printf 'adapter %s: no seam diagnostic\n%s\n' "$name" "$out"; return 1; }
    ! grep -Fq 'M8_ADAPTER_MODE=' <<<"$out" ||
      { printf 'adapter %s: a formal/nonformal mode was declared\n' "$name"; return 1; }
  done

  # The clean formal path is NOT blocked: with every seam unset the wrapper still
  # reaches its authorization guard.
  rc=0
  out="$(env "${unset_args[@]}" bash "$WRAPPER" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'the clean formal path unexpectedly succeeded\n'; return 1; }
  grep -Fq 'missing single-use authorization' <<<"$out" ||
    { printf 'the clean formal path did not reach the authorization guard\n%s\n' "$out"; return 1; }
  return 0
}

# C04 — the JSON-report contract uses the reporter rootDir-relative namespace.
c04() {
  local out="$TMPROOT/c04-out.txt" report="$TMPROOT/c04-report.json" body="$TMPROOT/c04-browser"
  local -a spec_args=() wrong_args=()
  local spec
  for spec in "${PLAYWRIGHT_FROZEN_SPECS[@]}"; do
    spec_args+=(--spec "$spec")
    wrong_args+=(--spec "apps/web/$spec")
  done
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$FIXTURES/playwright-json-good.json" --out "$out" \
    "${spec_args[@]}" >/dev/null || return 1
  # The old, wrong `apps/web/e2e/...` expectation must now FAIL.
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$FIXTURES/playwright-json-good.json" --out "$out" \
    "${wrong_args[@]}" >/dev/null 2>&1; then
    printf 'apps/web/e2e expectations were accepted for a rootDir-relative report\n'
    return 1
  fi
  assert_no_file "$out"
  # A duplicated basename in another directory must not satisfy the spec set.
  mutate_playwright_report duplicate-basename "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" "${spec_args[@]}" >/dev/null 2>&1; then
    printf 'a duplicated spec basename in another directory was accepted\n'
    return 1
  fi
  # A dropped frozen spec must fail.
  mutate_playwright_report drop-spec "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" "${spec_args[@]}" >/dev/null 2>&1; then
    printf 'a missing frozen spec was accepted\n'
    return 1
  fi
  # Static: the core never re-prefixes the reporter namespace.
  sed -n '/^browser_e2e()/,/^}/p' "$CORE" >"$body"
  assert_contains "$body" 'spec_args+=(--spec "$spec")'
  assert_no_contains "$body" 'apps/web/$spec'
  assert_no_contains "$body" 'apps/web/e2e'
}

# C05 — every PutObject uses the official file:// body form.
c05() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_FAKE_OSS_ROOT="$TMPROOT/c05-oss" M8_FAKE_OSS_VERSIONING='unversioned'
    export M8_FAKE_OSS_BODY_LOG="$TMPROOT/c05-body.log"
    mkdir -p "$M8_FAKE_OSS_ROOT"
    : >"$M8_FAKE_OSS_BODY_LOG"
    local body="$TMPROOT/c05-body.txt"
    printf 'file-body-payload\n' >"$body"
    m8_oss_put_object_no_overwrite 'runs/c05/body.txt' "$body" - || return 1
    assert_eq "$(cat "$M8_FAKE_OSS_BODY_LOG")" "file://$body" 'exact file:// body argument'
    assert_eq "$(object_bytes 'runs/c05/body.txt')" 'file-body-payload' 'stored body bytes'
    # The stub refuses a bare local path, so a regression cannot pass silently.
    if "$FAKE_OSSUTIL" api put-object --bucket test-bucket --key runs/c05/bare.txt \
      --body "$body" --forbid-overwrite true >/dev/null 2>&1; then
      printf 'the synthetic ossutil accepted a bare --body path\n'
      return 1
    fi
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/test-bucket/runs/c05/bare.txt"
    # Static: the official form is used and the bare form is absent.
    assert_contains "$OSS_LIB" '--body "file://$file"'
    assert_no_contains "$OSS_LIB" '--body "$file"'
    # GetObject stays binary: ossutil stdout goes straight into a file, is never
    # captured by command substitution, and is installed with a rename.
    local get_body="$TMPROOT/c05-get-object"
    sed -n '/^m8_oss_get_object()/,/^}/p' "$OSS_LIB" >"$get_body"
    assert_contains "$get_body" '>"$tmp" 2>"${tmp}.stderr"'
    assert_no_contains "$get_body" '=$(m8_oss_api'
    assert_contains "$get_body" 'mv -f "$tmp" "$out"'
  )
}

# C06 — completeness rejects an unexpected/unclassified artifact.
c06() {
  local root="$TMPROOT/c06-root" out='' rc=0
  populate_required_root "$root"
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" >/dev/null || return 1
  printf 'stray\n' >"$root/unclassified-artifact.txt"
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'an unexpected artifact was accepted\n'; return 1; }
  grep -Fq 'unexpected unclassified artifact' <<<"$out" ||
    { printf 'missing unexpected-artifact diagnostic:\n%s\n' "$out"; return 1; }
  rm -f "$root/unclassified-artifact.txt"
  rm -f "$root/outcome.txt"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" >/dev/null 2>&1; then
    printf 'a missing required artifact was accepted\n'
    return 1
  fi
  # The required set must carry exactly one evidence log per core stage(), so the
  # explicit inventory cannot silently fall behind the semantic core.
  local stage_logs expected_logs
  expected_logs="$(grep -oE '^stage [a-z_]+' "$CORE" | awk '{print $2".log"}' | sort -u)"
  stage_logs="$(grep -E '^[a-z_]+\.log$' "$REQUIRED_LIST" | sort -u)"
  [[ -n "$expected_logs" ]] || { printf 'no core stage() invocations were found\n'; return 1; }
  assert_eq "$stage_logs" "$expected_logs" 'stage evidence logs'
}

# C07 — required-list validation: duplicates, absolute, traversal, globs.
c07() {
  local root="$TMPROOT/c07-root" bad="$TMPROOT/c07-list.txt"
  populate_required_root "$root"
  { cat "$REQUIRED_LIST"; printf 'outcome.txt\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'duplicates required entry' || return 1
  { cat "$REQUIRED_LIST"; printf '/etc/passwd\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf '../escape.txt\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf '.\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf 'e2e/*.log\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf './outcome.txt\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf 'artifact-manifest.sha256\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'reserved seal-phase manifest' || return 1
  # Comments and blank lines remain deterministic and are ignored.
  { printf '# trailing comment\n\n   \n'; cat "$REQUIRED_LIST"; } >"$bad"
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$bad" >/dev/null || return 1
}

# C08 — manifest exact-set and hash validation.
c08() {
  local root="$TMPROOT/c08-root" manifest="$TMPROOT/c08-manifest.sha256"
  local first='' digest=''
  populate_required_root "$root"
  (
    # shellcheck source=/dev/null
    source "$MANIFEST_LIB"
    m8_manifest_generate "$root" || return 1
  ) || return 1
  cp -f "$root/artifact-manifest.sha256" "$manifest"
  first="$(head -n1 "$manifest")"
  digest="$(printf 'manifest-probe' | sha256sum | cut -d' ' -f1)"
  # The generated manifest is exact-set clean and never hashes itself.
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" --manifest "$manifest" >/dev/null || return 1
  assert_no_contains "$manifest" 'artifact-manifest.sha256'
  assert_eq "$(grep -c '  \./' "$manifest")" \
    "$(grep -Ev '^[[:space:]]*(#|$)' "$REQUIRED_LIST" | wc -l)" 'manifest entry count'

  { cat "$manifest"; printf '%s\n' "$first"; } >"$TMPROOT/c08-dup"
  assert_manifest_reject "$root" "$TMPROOT/c08-dup" 'duplicates manifest entry' || return 1
  { cat "$manifest"; printf '%s  ./unexpected.txt\n' "$digest"; } >"$TMPROOT/c08-extra"
  assert_manifest_reject "$root" "$TMPROOT/c08-extra" 'outside the required set' || return 1
  tail -n +2 "$manifest" >"$TMPROOT/c08-missing"
  assert_manifest_reject "$root" "$TMPROOT/c08-missing" 'missing required entry' || return 1
  sed '1s/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
    "$manifest" >"$TMPROOT/c08-hash"
  assert_manifest_reject "$root" "$TMPROOT/c08-hash" 'manifest digest mismatch' || return 1
  { cat "$manifest"; printf '%s  ./artifact-manifest.sha256\n' "$digest"; } >"$TMPROOT/c08-self"
  assert_manifest_reject "$root" "$TMPROOT/c08-self" 'must not hash itself' || return 1
  { cat "$manifest"; printf '%s  ../escape.txt\n' "$digest"; } >"$TMPROOT/c08-traverse"
  assert_manifest_reject "$root" "$TMPROOT/c08-traverse" 'normalized relative path' || return 1
  { cat "$manifest"; printf '%s  /etc/passwd\n' "$digest"; } >"$TMPROOT/c08-absolute"
  assert_manifest_reject "$root" "$TMPROOT/c08-absolute" 'normalized relative path' || return 1
}

# C09 — reserved formal manifest is EXACTLY ONE root-relative path.
#
# Load-bearing and behavioral: it drives the real pre-seal checker, the real
# production manifest generator and the real sealed verifier over a tree that
# contains a nested same-basename artifact, plus the real archive helpers. It is
# deliberately not satisfied by source grep.
#
# R2E-B01 defect: exclusion keyed on the BASENAME let
# `rogue/artifact-manifest.sha256` exist in the evidence tree, vanish from
# actual-set accounting, vanish from the generated manifest, enter the archive,
# and still let completeness and manifest verification report PASS.

# C09-A — pre-seal: a nested same-basename artifact is an unexpected artifact.
c09_a() {
  local root="$TMPROOT/c09a-root" out='' rc=0
  populate_required_root "$root"
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" >/dev/null || return 1
  mkdir -p "$root/rogue"
  printf 'nested reserved-basename artifact\n' >"$root/rogue/artifact-manifest.sha256"
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" 2>&1)" || rc=$?
  (( rc != 0 )) ||
    { printf 'C09-A: pre-seal completeness accepted a nested reserved-basename artifact\n'; return 1; }
  grep -Fq 'unexpected unclassified artifact in the evidence root: rogue/artifact-manifest.sha256' \
    <<<"$out" ||
    { printf 'C09-A: wrong or missing diagnostic:\n%s\n' "$out"; return 1; }
  # The checker is read-only: it must not have removed the offending artifact.
  assert_file "$root/rogue/artifact-manifest.sha256"
  printf 'C09_A_PRESEAL=PASS\n'
}

# C09-B — post-seal: production manifest generation must not suppress it.
c09_b() {
  local root="$TMPROOT/c09b-root" out='' rc=0
  populate_required_root "$root"
  mkdir -p "$root/rogue"
  printf 'nested reserved-basename artifact\n' >"$root/rogue/artifact-manifest.sha256"
  (
    # shellcheck source=/dev/null
    source "$MANIFEST_LIB"
    m8_manifest_generate "$root" || return 1
  ) || return 1
  # Production manifest code must have classified the nested object.
  grep -Fq '  ./rogue/artifact-manifest.sha256' "$root/artifact-manifest.sha256" ||
    { printf 'C09-B: production manifest suppressed rogue/artifact-manifest.sha256\n'; return 1; }
  # ...while still never hashing the reserved root manifest itself.
  if grep -Fq '  ./artifact-manifest.sha256' "$root/artifact-manifest.sha256"; then
    printf 'C09-B: root manifest hashed itself\n'
    return 1
  fi
  assert_eq "$(grep -c '  \./' "$root/artifact-manifest.sha256")" '88' 'nested manifest entry count'
  # Sealed verification must FAIL: the nested object cannot be unclassified.
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" \
    --manifest "$root/artifact-manifest.sha256" 2>&1)" || rc=$?
  (( rc != 0 )) ||
    { printf 'C09-B: sealed verification accepted a nested reserved-basename artifact\n'; return 1; }
  grep -Fq 'rogue/artifact-manifest.sha256' <<<"$out" ||
    { printf 'C09-B: sealed diagnostic does not name the nested artifact:\n%s\n' "$out"; return 1; }
  printf 'C09_B_POSTSEAL=PASS\n'
}

# C09-C — the legitimate root manifest stays the one reserved path.
c09_c() {
  local root="$TMPROOT/c09c-root" required_count
  populate_required_root "$root"
  (
    # shellcheck source=/dev/null
    source "$MANIFEST_LIB"
    m8_manifest_generate "$root" || return 1
    m8_manifest_verify "$root" || return 1
  ) || return 1
  required_count="$(grep -Ev '^[[:space:]]*(#|$)' "$REQUIRED_LIST" | wc -l)"
  assert_eq "$required_count" '87' 'canonical required count'
  assert_eq "$(grep -c '  \./' "$root/artifact-manifest.sha256")" "$required_count" \
    'root manifest entry count'
  if grep -Fq '  ./artifact-manifest.sha256' "$root/artifact-manifest.sha256"; then
    printf 'C09-C: root manifest hashed itself\n'
    return 1
  fi
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" \
    --manifest "$root/artifact-manifest.sha256" >/dev/null || return 1
  # The reserved name is constrained to a plain basename, so neither a path nor a
  # glob can re-widen the exclusion back to basename-wide (or match-all) form.
  local bad_name
  for bad_name in 'rogue/artifact-manifest.sha256' '*' './artifact-manifest.sha256'; do
    if (
      # shellcheck source=/dev/null
      source "$MANIFEST_LIB"
      m8_manifest_generate "$root" "$bad_name"
    ) >/dev/null 2>&1; then
      printf 'C09-C: production manifest accepted a non-plain reserved name: %s\n' "$bad_name"
      return 1
    fi
  done
  printf 'C09_C_ROOT_MANIFEST=PASS\n'
}

# C09-D — classification invariant: a nested same-basename object can never be
# present in the archive candidate tree while absent from manifest accounting
# and accepted by completeness validation.
c09_d() {
  local work="$TMPROOT/c09d-root" evidence="$TMPROOT/c09d-root/proof-artifacts"
  local archive="$TMPROOT/c09d-archive.tar.gz" embedded="$TMPROOT/c09d-embedded"
  mkdir -p "$work"
  populate_required_root "$evidence"
  mkdir -p "$evidence/rogue"
  printf 'nested reserved-basename artifact\n' >"$evidence/rogue/artifact-manifest.sha256"
  (
    # shellcheck source=/dev/null
    source "$MANIFEST_LIB"
    m8_manifest_generate "$evidence" || return 1
    m8_archive_build "$work" 'proof-artifacts' "$archive" || return 1
    m8_archive_embedded_manifest "$archive" 'proof-artifacts' >"$embedded" || return 1
  ) || return 1
  # 1. physically present in the archive candidate tree
  tar -tzf "$archive" | grep -Fq 'proof-artifacts/rogue/artifact-manifest.sha256' ||
    { printf 'C09-D: nested object is absent from the archive\n'; return 1; }
  # 2. present in manifest classification (not suppressed)
  grep -Fq '  ./rogue/artifact-manifest.sha256' "$embedded" ||
    { printf 'C09-D: nested object was suppressed from the embedded manifest classification\n'; return 1; }
  # 3. production completeness verification refuses the tree
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$evidence" --required "$REQUIRED_LIST" \
    --manifest "$evidence/artifact-manifest.sha256" >/dev/null 2>&1; then
    printf 'C09-D: a rogue nested reserved-basename artifact was accepted\n'
    return 1
  fi
  printf 'C09_D_CLASSIFICATION=PASS\n'
}

# C09 — aggregate: all four sub-phases must hold.
c09() {
  c09_a || return 1
  c09_b || return 1
  c09_c || return 1
  c09_d || return 1
}

# ===========================================================================
printf '===== M8-HSDR-F02 R2E-B01 offline verification =====\n'
printf 'repo=%s\n' "$REPO_ROOT"

for f in "$WRAPPER" "$CORE" "$ADAPTER" "$PREFLIGHT" "$OSS_LIB" "$IDENTITY_LIB" \
  "$MANIFEST_LIB" "$SEAMS_LIB"; do
  bash -n "$f" || { printf 'SYNTAX FAILURE: %s\n' "$f"; exit 1; }
done

run_check static V01 'core never writes core-exit-code.txt; adapter owns that RC' v01
run_check static V02 'adapter captures the core RC immediately after the child returns' v02
run_check static V03 'adapter-exit-code.txt is written by the adapter EXIT trap' v03
run_check static V04 'wrapper captures formal-execution-rc.txt immediately after the adapter' v04
run_check static V05 'wrapper cross-checks the two RC records and fails closed' v05
run_check synth V06 'absent/empty/mismatched/non-numeric RC fixtures fail closed' v06
run_check synth V07 'SIGTERM yields a distinct numeric RC (143)' v07
run_check synth V08 'SIGKILL does not fabricate an in-process adapter RC' v08
run_check synth V09 'the closure receipt is the last mutating commit object' v09
run_check synth V10 'a sealed archive mutated after its digest fails durability' v10
run_check synth V11 'a durability failure produces no closure receipt' v11
run_check synth V12 'receipt read-back tamper fails closed without a formal RC' v12
run_check synth V13 'success: fetched receipt RC == terminal marker == wrapper success' v13
run_check synth V14 'ALREADY_COMMITTED re-invocation hard-refuses without a formal RC' v14
run_check synth V15 'the adapter refuses to run without wrapper formal context' v15
run_check synth V16 'a claim without a receipt cannot be re-consumed' v16
run_check static V17 'provider identity constants are single-sourced and guards fail closed' v17
run_check static V18 'wrapper order and fail-closed guards in condition contexts' v18
run_check static V19 'adapter re-verifies identity after the claim and creates no canonical object' v19
run_check static V20 'create-if-absent only; capability guard fails closed; no HEAD-then-PUT' v20
run_check synth V21 'versioning Enabled fails closed' v21
run_check synth V22 'versioning Suspended fails closed' v22
run_check synth V23 'versioning Null/Unversioned is eligible' v23
run_check synth V24 'unparseable and access-denied versioning fail closed' v24
run_check synth V25 'FileAlreadyExists never overwrites' v25
run_check synth V26 'the versioning guard precedes the first PutObject' v26
run_check synth V27 'valid Playwright JSON writes the exact effective-retries file' v27
run_check synth V28 'project retries != 0 fails closed' v28
run_check synth V29 'non-chromium project set fails closed' v29
run_check synth V30 'unexpected/flaky/skipped counts fail closed' v30
run_check synth V31 'missing or unparseable Playwright report fails closed' v31
run_check static V32 'core uses CI=1, one reporter option and an explicit JSON file' v32
run_check static V33 'core keeps retries=0, fail-on-flaky and the seven frozen specs' v33
run_check synth V34 'artifact completeness fails closed on missing artifacts' v34
run_check synth V35 'no receipt carries a redundant terminal_line field' v35
run_check synth V36 'receipt cross-binding/digest/provider fields are self-consistent' v36
run_check synth V37 'a receipt whose formal_command_rc is not 0 is rejected' v37
run_check synth V38 'issuer/executor split documented; no delete/versioning-write authority' v38
run_check synth V39 'a retry cannot regenerate a missing package-index' v39
run_check synth V40 'a retry never reruns core/adapter and writes only canonical objects' v40

printf '\n----- R2E-B01 correction regressions (C01..C09) -----\n'
run_check corr C01 'B1 token -> authorization_sha256; no issued.json self-reference' c01
run_check corr C02 'B1 mismatched issued.json.authorization_sha256 fails closed' c02
run_check corr C03 'B2 both production entrypoints reject all five synthetic seams' c03
run_check corr C04 'B3 JSON report uses the reporter rootDir-relative spec namespace' c04
run_check corr C05 'B4 every PutObject uses the official file:// body form' c05
run_check corr C06 'B5 completeness rejects unexpected/unclassified artifacts' c06
run_check corr C07 'B5 required-list duplicates/absolute/traversal/globs are rejected' c07
run_check corr C08 'B5 manifest exact-set, self-hash and digest validation' c08
run_check corr C09 'R2E-B01 reserved manifest is exactly one root-relative path' c09

printf '\n===== summary =====\n'
printf 'R2E_B01_LEGACY_V01_V40=%s/%s\n' \
  "$((STATIC_PASS + SYNTH_PASS))" "$((STATIC_TOTAL + SYNTH_TOTAL))"
printf 'R2E_B01_CORRECTION_REGRESSIONS=%s/%s\n' "$CORR_PASS" "$CORR_TOTAL"
printf 'R2E_B01_STATIC_CHECKS=%s/%s\n' "$STATIC_PASS" "$STATIC_TOTAL"
printf 'R2E_B01_SYNTHETIC_CHECKS=%s/%s\n' "$SYNTH_PASS" "$SYNTH_TOTAL"
if ((${#FAILED_CHECKS[@]})); then
  printf 'R2E_B01_OFFLINE_VERIFICATION=FAIL failed=%s\n' "${FAILED_CHECKS[*]}"
  exit 1
fi
printf 'R2E_B01_OFFLINE_VERIFICATION=PASS\n'
