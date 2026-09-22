#!/usr/bin/env bash
# LinguaGraph M8 provider-neutral semantic proof core.
#
# M8 proof-source preparation. The Product pins below target the exact reviewed
# M8 candidate. This file MUST NOT be executed without separate Human approval
# of the exact proof commit, an exact live provider binding, and a fresh M8
# one-shot run authorization through the formal wrapper
# (scripts/run-m8-proof.sh).
#
# RC ownership: this core MUST NOT write core-exit-code.txt. That file is the
# process RC of this script as observed by its parent adapter, and is written
# only by scripts/run-m8-proof-alibaba-ecs.sh immediately after this child
# returns. The formal wrapper then captures the adapter's RC as
# formal-execution-rc.txt.
set -Eeuo pipefail

M8_CORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=lib/m8-manifest.sh
source "$M8_CORE_LIB_DIR/m8-manifest.sh"

readonly PROOF_ROOT="${M8_PROOF_ROOT:-$(git rev-parse --show-toplevel)}"
readonly EVIDENCE="${M8_PROOF_EVIDENCE_DIR:-$PROOF_ROOT/proof-artifacts}"
readonly CANDIDATE="$PROOF_ROOT/candidate"

# Exact Product binding for the M8-HSDR-F02 test-only successor candidate.
readonly APP_BRANCH='m8-alignment-connector-obstacle-avoiding-routing'
readonly APP_SHA='2441f9cf60b7cc9402c5b257be010b559b39b717'
readonly APP_TREE='5d1b7c7cc104cd365b0ea629d9ead7677d17f2be'
readonly APP_PARENT='e4b1cc66f540ab74c0ef9bd014b0a0da3a2d9c1d'
readonly MAIN_SHA='cf26ea557bd746a518ff32b8b7e7a7542be7f7ae'
readonly ALEMBIC_HEAD='0006'
readonly APP_URL='https://github.com/Pacchifans69/LinguaGraph.git'

# Exact expected suite counts for this bound tree. These are preparation-time
# guards, not proof results. A formal run must still actually execute and pass.
readonly EXPECTED_PYTEST_PASSED='602'
readonly EXPECTED_VITEST_PASSED='533'
readonly EXPECTED_PLAYWRIGHT_PASSED='34'

readonly POSTGRES_CONTAINER='linguagraph-m8-proof-postgres'
readonly DB_URL='postgresql+psycopg://postgres:postgres@127.0.0.1:5432/postgres'

# Frozen seven-spec Playwright release surface. These paths are relative to the
# reporter rootDir ($CANDIDATE/apps/web) and are exactly the JSON reporter's
# suite `file` namespace.
readonly -a PLAYWRIGHT_SPECS=(
  'e2e/golden-path.spec.ts'
  'e2e/unicode.spec.ts'
  'e2e/segmentation.spec.ts'
  'e2e/token-segmentation.spec.ts'
  'e2e/lemma-annotation.spec.ts'
  'e2e/pos-annotation.spec.ts'
  'e2e/workbench-information-architecture.spec.ts'
)

# Emit the frozen static binding for the formal wrapper. This mode must not
# create, read or mutate any evidence or checkout state.
emit_static_binding() {
  printf 'candidate_sha=%s\n' "$APP_SHA"
  printf 'candidate_tree=%s\n' "$APP_TREE"
  printf 'candidate_parent=%s\n' "$APP_PARENT"
  printf 'frozen_main=%s\n' "$MAIN_SHA"
  printf 'alembic_head=%s\n' "$ALEMBIC_HEAD"
  printf 'expected_pytest_passed=%s\n' "$EXPECTED_PYTEST_PASSED"
  printf 'expected_vitest_passed=%s\n' "$EXPECTED_VITEST_PASSED"
  printf 'expected_playwright_passed=%s\n' "$EXPECTED_PLAYWRIGHT_PASSED"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == '--emit-static-binding' ]]; then
  emit_static_binding
  exit 0
fi

mkdir -p "$EVIDENCE"
completed=0
DOCKER_MODE=''

die() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
expect() { [[ "$1" == "$2" ]] || die "Mismatch: $3 (expected $2; got $1)"; }
record() { printf '%s=%s\n' "$1" "$2" >> "$EVIDENCE/provenance.txt"; }

probe_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die 'docker client is absent from PATH'
    return 1
  fi
  if docker info >/dev/null 2>&1; then
    DOCKER_MODE=direct
  elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER_MODE=sudo
  else
    die 'Docker is unusable without interactive elevation'
    return 1
  fi
  printf '%s' "$DOCKER_MODE"
}

docker_run() {
  if [[ -z "$DOCKER_MODE" ]]; then
    probe_docker >/dev/null || return 1
  fi
  if [[ "$DOCKER_MODE" == direct ]]; then
    docker "$@"
  else
    sudo -n docker "$@"
  fi
}

finish() {
  local exit_code=$? cleanup_code=0
  trap - EXIT
  if [[ -e "$EVIDENCE/docker-owned-marker" ]]; then
    if [[ -z "$DOCKER_MODE" ]]; then
      probe_docker >/dev/null 2>&1 || cleanup_code=1
    fi
    if (( cleanup_code == 0 )); then
      docker_run rm -f "$POSTGRES_CONTAINER" >/dev/null 2>&1 || cleanup_code=1
    fi
  fi
  if [[ "$cleanup_code" != 0 ]]; then
    printf 'FAIL: PostgreSQL container cleanup failed\n' >&2
    (( exit_code == 0 )) && exit_code=1
  fi
  if [[ -d "$CANDIDATE" ]] && git -C "$CANDIDATE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$CANDIDATE" status --porcelain=v1 --untracked-files=all > "$EVIDENCE/candidate-final-status.txt" || true
  fi
  if [[ "$completed" == 1 && "$exit_code" == 0 ]]; then
    printf 'PASS\n' > "$EVIDENCE/outcome.txt"
  else
    printf 'FAIL exit=%s cleanup=%s\n' "$exit_code" "$cleanup_code" > "$EVIDENCE/outcome.txt"
  fi
  # The core owns its own evidence manifest. The formal wrapper re-derives the
  # same deterministic manifest at seal time before the canonical archive is
  # created; the algorithm is shared through scripts/lib/m8-manifest.sh.
  m8_manifest_generate "$EVIDENCE" || exit_code=1
  exit "$exit_code"
}
trap finish EXIT

stage() {
  local name=$1; shift
  local safe=${name//[^a-zA-Z0-9_-]/_} rc=0 tee_rc=0
  printf '\n--- %s ---\n' "$name"
  printf '%s started=%s\n' "$name" "$(date -u +%FT%TZ)" >> "$EVIDENCE/stages.txt"
  set +e
  (set -Eeuo pipefail; "$@") 2>&1 | tee "$EVIDENCE/${safe}.log"
  local -a statuses=("${PIPESTATUS[@]}")
  rc=${statuses[0]}
  tee_rc=${statuses[1]}
  set -e
  (( tee_rc == 0 )) || die "Evidence log for $name could not be stored"
  printf '%s finished=%s exit=%s\n' "$name" "$(date -u +%FT%TZ)" "$rc" >> "$EVIDENCE/stages.txt"
  (( rc == 0 )) || die "Stage $name failed with exit $rc"
}

guard_candidate_config() {
  expect "${EXPECTED_CANDIDATE_SHA:-$APP_SHA}" "$APP_SHA" configured_candidate_sha
  expect "${EXPECTED_CANDIDATE_TREE:-$APP_TREE}" "$APP_TREE" configured_candidate_tree
  expect "${EXPECTED_CANDIDATE_PARENT:-$APP_PARENT}" "$APP_PARENT" configured_candidate_parent
  expect "${EXPECTED_FROZEN_MAIN:-$MAIN_SHA}" "$MAIN_SHA" configured_frozen_main
  expect "${EXPECTED_ALEMBIC_HEAD:-$ALEMBIC_HEAD}" "$ALEMBIC_HEAD" configured_alembic_head
  expect "${EXPECTED_PYTEST_PASSED_GUARD:-$EXPECTED_PYTEST_PASSED}" "$EXPECTED_PYTEST_PASSED" configured_pytest_count
  expect "${EXPECTED_VITEST_PASSED_GUARD:-$EXPECTED_VITEST_PASSED}" "$EXPECTED_VITEST_PASSED" configured_vitest_count
  expect "${EXPECTED_PLAYWRIGHT_PASSED_GUARD:-$EXPECTED_PLAYWRIGHT_PASSED}" "$EXPECTED_PLAYWRIGHT_PASSED" configured_playwright_count
}

guard_approved_proof() {
  [[ "${APPROVED_PROOF_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die 'Missing separately approved proof commit'
  expect "$(git -C "$PROOF_ROOT" rev-parse HEAD)" "$APPROVED_PROOF_SHA" approved_proof_checkout
  [[ -z "$(git -C "$PROOF_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || die 'Dirty proof source'
}

# core-exit-code.txt is the core process RC observed by the adapter. The core
# never writes it, and refuses to run if a stale one already exists.
guard_core_rc_ownership() {
  [[ ! -e "$EVIDENCE/core-exit-code.txt" ]] ||
    die 'core-exit-code.txt exists; it belongs to the parent adapter and must never be written by the core'
}

guard_core() {
  guard_candidate_config
  guard_approved_proof
  guard_core_rc_ownership
  probe_docker >/dev/null
  record proof_sha "$APPROVED_PROOF_SHA"
  record proof_tree "$(git -C "$PROOF_ROOT" rev-parse HEAD^{tree})"
  record candidate_sha "$APP_SHA"
  record candidate_tree "$APP_TREE"
  record candidate_parent "$APP_PARENT"
  record frozen_main "$MAIN_SHA"
  record alembic_head "$ALEMBIC_HEAD"
  record expected_pytest_passed "$EXPECTED_PYTEST_PASSED"
  record expected_vitest_passed "$EXPECTED_VITEST_PASSED"
  record expected_playwright_passed "$EXPECTED_PLAYWRIGHT_PASSED"
  record docker_mode "$DOCKER_MODE"
  record date_utc "$(date -u +%FT%TZ)"
}

guard_remote() {
  local app_remote main_remote
  app_remote=$(git ls-remote "$APP_URL" "refs/heads/$APP_BRANCH")
  main_remote=$(git ls-remote "$APP_URL" refs/heads/main)
  expect "${app_remote%%[[:space:]]*}" "$APP_SHA" candidate_remote_ref
  expect "${main_remote%%[[:space:]]*}" "$MAIN_SHA" frozen_main_remote_ref
}

fetch_candidate() {
  [[ ! -e "$CANDIDATE" ]] || die 'Candidate checkout path already exists'
  git init -q "$CANDIDATE"
  git -C "$CANDIDATE" remote add origin "$APP_URL"
  git -C "$CANDIDATE" fetch --no-tags origin     "refs/heads/$APP_BRANCH:refs/remotes/origin/$APP_BRANCH"     'refs/heads/main:refs/remotes/origin/main'
  expect "$(git -C "$CANDIDATE" rev-parse "refs/remotes/origin/$APP_BRANCH")" "$APP_SHA" fetched_branch
  expect "$(git -C "$CANDIDATE" rev-parse refs/remotes/origin/main)" "$MAIN_SHA" fetched_main
  git -C "$CANDIDATE" checkout --detach -q "$APP_SHA"
  expect "$(git -C "$CANDIDATE" rev-parse HEAD)" "$APP_SHA" candidate_checkout
  expect "$(git -C "$CANDIDATE" rev-parse HEAD^{tree})" "$APP_TREE" candidate_tree
  expect "$(git -C "$CANDIDATE" rev-list --parents -n 1 HEAD)" "$APP_SHA $APP_PARENT" candidate_unique_parent
  expect "$(git -C "$CANDIDATE" merge-base "$APP_SHA" "$MAIN_SHA")" "$MAIN_SHA" frozen_main_ancestor
  [[ ! -e "$CANDIDATE/.circleci/config.yml" ]] || die 'Candidate carries proof configuration'
  [[ -z "$(git -C "$CANDIDATE" status --porcelain=v1 --untracked-files=all)" ]] || die 'Dirty candidate checkout'
  git -C "$CANDIDATE" diff --check "$MAIN_SHA" "$APP_SHA"
  git -C "$CANDIDATE" diff --name-status "$MAIN_SHA" "$APP_SHA" > "$EVIDENCE/candidate-file-scope.txt"
  git -C "$CANDIDATE" diff --name-only "$MAIN_SHA" "$APP_SHA" | sort > "$EVIDENCE/candidate-files.txt"
  cat <<'EOF' | sort > "$EVIDENCE/expected-candidate-files.txt"
AGENTS.md
README.md
apps/web/e2e/golden-path.spec.ts
apps/web/e2e/unicode.spec.ts
apps/web/e2e/workbench-information-architecture.spec.ts
apps/web/src/features/workspace/ConnectorOverlay.test.tsx
apps/web/src/features/workspace/ConnectorOverlay.tsx
apps/web/src/shared/rendering/connectorRouting.test.ts
apps/web/src/shared/rendering/connectorRouting.ts
apps/web/src/shared/rendering/domRects.ts
apps/web/src/shared/rendering/geometry.test.ts
apps/web/src/shared/rendering/geometry.ts
apps/web/src/styles.css
docs/adr/ADR-016-panel-perimeter-obstacle-avoiding-alignment-routing.md
docs/development/CURRENT_STATE.md
EOF
  cmp "$EVIDENCE/expected-candidate-files.txt" "$EVIDENCE/candidate-files.txt" || die 'M8 candidate file scope differs from the reviewed exact set'
}

install_runtimes() {
  [[ "$(. /etc/os-release; printf '%s' "$ID:$VERSION_ID")" == 'ubuntu:24.04' ]] || die 'Hosted Linux must be Ubuntu 24.04'
  (( $(nproc) >= 4 )) || die 'Hosted resource has fewer than four CPUs'
  (( $(awk '/MemTotal:/ {print $2}' /proc/meminfo) >= 15000000 )) || die 'Hosted resource has less than ~16 GB RAM'
  [[ -n "$DOCKER_MODE" ]] || probe_docker >/dev/null

  curl --fail --location --silent --show-error https://astral.sh/uv/0.12.10/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  uv python install 3.13

  curl --fail --location --silent --show-error https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  # shellcheck source=/dev/null
  source "$NVM_DIR/nvm.sh"
  nvm install 24.17.0
  nvm use 24.17.0

  docker_run pull postgres:18
  [[ -z "$(docker_run ps -aq --filter "name=^/${POSTGRES_CONTAINER}$")" ]] || die 'Proof container name already in use'
  docker_run run -d --name "$POSTGRES_CONTAINER"     -e POSTGRES_PASSWORD=postgres     -e POSTGRES_DB=postgres     -p 127.0.0.1:5432:5432 postgres:18
  : > "$EVIDENCE/docker-owned-marker"
  for _ in $(seq 1 60); do
    if docker_run exec "$POSTGRES_CONTAINER" pg_isready -q -U postgres; then
      break
    fi
    sleep 2
  done
  docker_run exec "$POSTGRES_CONTAINER" pg_isready -q -U postgres || die 'PostgreSQL not ready'
  [[ "$(docker_run exec "$POSTGRES_CONTAINER" psql -At -U postgres -d postgres -c 'SHOW server_version_num')" == 18* ]] || die 'PostgreSQL is not major 18'

  local uv_version_output uv_version
  uv_version_output=$(uv --version)
  if [[ "$uv_version_output" =~ ^uv[[:space:]]+([^[:space:]]+) ]]; then
    uv_version="${BASH_REMATCH[1]}"
  else
    die "Unable to parse uv version output: $uv_version_output"
  fi
  expect "$uv_version" '0.12.10' pinned_uv_version
  expect "$(node --version)" 'v24.17.0' pinned_node_version

  {
    uname -a
    cat /etc/os-release
    nproc
    grep MemTotal /proc/meminfo
    uv --version
    uv python find 3.13
    node --version
    npm --version
    printf 'docker_mode=%s\n' "$DOCKER_MODE"
    docker_run image inspect postgres:18 --format '{{json .RepoDigests}}'
    docker_run exec "$POSTGRES_CONTAINER" psql -At -U postgres -d postgres -c 'SELECT version()'
  } > "$EVIDENCE/runtime.txt"
}

activate_runtimes() {
  export PATH="$HOME/.local/bin:$PATH" NVM_DIR="$HOME/.nvm"
  # shellcheck source=/dev/null
  source "$NVM_DIR/nvm.sh"
  nvm use 24.17.0 >/dev/null
}

verify_m7_race_junit() {
  local xml=$1
  uv run --frozen python - "$xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
root = ET.parse(xml_path).getroot()
names = {node.attrib.get("name", "") for node in root.iter("testcase")}

required = {
    "test_c_r01_patch_patch_same_group_is_serial_equivalent",
    "test_c_r01_partial_patch_omission_preserves_other_serialized_field",
    "test_c_r02_patch_delete_same_group_has_stable_serial_outcome",
    "test_c_r03_delete_delete_same_group_is_ok_plus_not_found",
    "test_c_r04_create_vs_force_delete_text_version",
    "test_c_r05_patch_vs_force_delete_text_version",
    "test_c_r06_delete_alignment_vs_force_delete_text_version",
    "test_c_r07_create_vs_replace_content_uses_one_canonical_text",
    "test_c_r08_shared_span_survives_competing_topology_mutation",
    "test_c_r09_true_orphans_are_removed_under_competing_mutation",
    "test_c_a01_alignment_mutation_vs_delete_parallel_document_audit",
    "test_c_a01_delete_parallel_document_first_yields_not_found",
    "test_c_a02_alignment_mutation_vs_delete_project_audit",
    "test_c_a02_delete_project_first_yields_not_found",
    "test_cross_document_input_is_rejected_before_text_version_lock",
}
missing = sorted(required - names)
if missing:
    raise SystemExit("missing required M7 concurrency tests in JUnit: " + ", ".join(missing))
if (
    next(root.iter("failure"), None) is not None
    or next(root.iter("error"), None) is not None
    or next(root.iter("skipped"), None) is not None
):
    raise SystemExit("JUnit contains failure/error/skipped nodes")
print("M7 required concurrency tests present:", len(required))
for name in sorted(required):
    print(name)
PY
}

backend() {
  activate_runtimes
  export DATABASE_URL="$DB_URL" TEST_DATABASE_URL="$DB_URL"
  cd "$CANDIDATE/apps/api"

  uv sync --frozen
  [[ "$(uv run --frozen python --version)" == Python\ 3.13.* ]] || die 'Python is not 3.13'

  local before after current
  before=$(docker_run exec "$POSTGRES_CONTAINER" psql -At -U postgres -d postgres -c "SELECT count(*) FROM pg_tables WHERE schemaname='public'")
  expect "$before" 0 empty_migration_database

  uv run alembic upgrade head
  current=$(uv run alembic current)
  [[ "$current" == *"$ALEMBIC_HEAD (head)"* ]] || die "Alembic head mismatch: $current"
  after=$(docker_run exec "$POSTGRES_CONTAINER" psql -At -U postgres -d postgres -c "SELECT version_num FROM alembic_version")
  expect "$after" "$ALEMBIC_HEAD" database_revision
  uv run alembic check

  uv run pytest -q --junitxml="$EVIDENCE/pytest-junit.xml" 2>&1 | tee "$EVIDENCE/pytest-raw.log"
  grep -Eq "${EXPECTED_PYTEST_PASSED} passed" "$EVIDENCE/pytest-raw.log" || die "Expected ${EXPECTED_PYTEST_PASSED} passed pytest summary"
  ! grep -Eiq 'skipped|xfailed|xpassed|deselected' "$EVIDENCE/pytest-raw.log" || die 'Backend tests skipped/filtered'
  verify_m7_race_junit "$EVIDENCE/pytest-junit.xml" | tee "$EVIDENCE/m7-concurrency-junit-check.log"
}

verify_m8_routing_matrix() {
  local log=$1 label number
  for number in $(seq -w 1 21); do
    label="R-G$number"
    grep -Fq "$label" "$log" || die "Missing executed M8 routing case label: $label"
  done
  printf 'M8 routing matrix labels present: 21/21\n'
}

frontend() {
  activate_runtimes
  cd "$CANDIDATE/apps/web"
  npm ci
  npm run lint
  npm run typecheck
  npx vitest run \
    src/shared/rendering/connectorRouting.test.ts \
    src/shared/rendering/geometry.test.ts \
    src/features/workspace/ConnectorOverlay.test.tsx \
    --reporter=verbose 2>&1 | tee "$EVIDENCE/m8-routing-matrix-raw.log"
  verify_m8_routing_matrix "$EVIDENCE/m8-routing-matrix-raw.log" | tee "$EVIDENCE/m8-routing-matrix-check.log"
  npm run test 2>&1 | tee "$EVIDENCE/vitest-raw.log"
  grep -Eq "${EXPECTED_VITEST_PASSED} passed" "$EVIDENCE/vitest-raw.log" || die "Expected ${EXPECTED_VITEST_PASSED} passed Vitest summary"
  ! grep -Eiq 'Tests.*(skipped|todo|failed)' "$EVIDENCE/vitest-raw.log" || die 'Vitest incomplete'
  npm run build
}

# Frozen Playwright runtime evidence (M8-HSDR-F02 / R2B section 10).
#
# Exactly one --reporter option (list,json). CI=1 and an explicit JSON output
# file are exported. The exact JSON report is then parsed with Python stdlib and
# must prove: every project retries == 0, project names == {chromium},
# expected == 34, unexpected == 0, flaky == 0, skipped == 0, and that the set of
# spec files in the report equals the seven frozen specs exactly.
#
# Namespace: the reporter runs with rootDir = $CANDIDATE/apps/web, so the JSON
# reporter's suite `file` values are relative to that rootDir and are exactly
# `e2e/<name>.spec.ts`. The expected values passed to the verifier therefore use
# the SAME rootDir-relative namespace; `apps/web/e2e/...` is never expected
# inside the JSON report. Only then is playwright-effective-retries.txt written,
# with exact content PLAYWRIGHT_EFFECTIVE_RETRIES=0. Either the raw log count
# check or the JSON check failing is fatal; the JSON check is the authority.
browser_e2e() {
  activate_runtimes
  export DATABASE_URL="$DB_URL" TEST_DATABASE_URL="$DB_URL"
  export CI=1
  export PLAYWRIGHT_JSON_OUTPUT_FILE="$EVIDENCE/playwright-json-report.json"
  cd "$CANDIDATE/apps/web"
  npx playwright install --with-deps chromium
  rm -f "$EVIDENCE/playwright-json-report.json" "$EVIDENCE/playwright-effective-retries.txt"
  npx playwright test \
    "${PLAYWRIGHT_SPECS[@]}" \
    --retries=0 \
    --fail-on-flaky-tests \
    --reporter=list,json 2>&1 | tee "$EVIDENCE/playwright-raw.log"
  ! grep -Eiq '[1-9][0-9]* (skipped|flaky|failed)' "$EVIDENCE/playwright-raw.log" ||
    die 'Playwright raw log reports skipped/flaky/failed paths'
  local -a spec_args=()
  local spec
  for spec in "${PLAYWRIGHT_SPECS[@]}"; do
    # PLAYWRIGHT_SPECS are already reporter-rootDir-relative; do not re-prefix.
    spec_args+=(--spec "$spec")
  done
  "$PROOF_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$EVIDENCE/playwright-json-report.json" \
    --out "$EVIDENCE/playwright-effective-retries.txt" \
    --expected-tests "$EXPECTED_PLAYWRIGHT_PASSED" \
    "${spec_args[@]}" | tee "$EVIDENCE/playwright-json-check.log"
  grep -Eq "${EXPECTED_PLAYWRIGHT_PASSED} passed" "$EVIDENCE/playwright-raw.log" ||
    printf 'NOTE: raw-log count guard is secondary; JSON report is the authority\n' |
      tee -a "$EVIDENCE/playwright-json-check.log"
}

hash_manifest() {
  local path=$1 rel=$2
  printf '%s  %s\n' "$(sha256sum "$path" | cut -d' ' -f1)" "$rel"
}

dependency_hashes() {
  local label=$1 path
  for path in apps/api/pyproject.toml apps/api/uv.lock apps/web/package.json apps/web/package-lock.json; do
    hash_manifest "$CANDIDATE/$path" "$path"
  done > "$EVIDENCE/deps-${label}.sha256"
}

integrity() {
  local path committed now leftovers
  dependency_hashes post
  cmp "$EVIDENCE/deps-pre.sha256" "$EVIDENCE/deps-post.sha256" || die 'Dependency hashes changed'

  for path in apps/api/pyproject.toml apps/api/uv.lock apps/web/package.json apps/web/package-lock.json; do
    committed=$(git -C "$CANDIDATE" rev-parse "HEAD:$path")
    now=$(git hash-object "$CANDIDATE/$path")
    expect "$now" "$committed" "committed blob $path"
  done

  [[ -z "$(git -C "$CANDIDATE" status --porcelain=v1 --untracked-files=all)" ]] || die 'Candidate worktree modified'
  expect "$(git -C "$CANDIDATE" rev-parse HEAD^{tree})" "$APP_TREE" final_candidate_tree
  git -C "$CANDIDATE" diff --check

  leftovers=$(docker_run exec "$POSTGRES_CONTAINER" psql -At -U postgres -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE 'linguagraph_%' ORDER BY datname")
  printf '%s\n' "$leftovers" > "$EVIDENCE/disposable-db-residual.txt"
  [[ -z "$leftovers" ]] || die 'Disposable PostgreSQL databases remain'

  # Final remote guards prove the exact Product candidate and frozen main did
  # not move during execution.
  guard_remote
}

stage guard_core guard_core
stage guard_remote guard_remote
stage fetch_candidate fetch_candidate
stage deps_pre dependency_hashes pre
stage install_runtimes install_runtimes
stage backend backend
stage frontend frontend
stage playwright browser_e2e
stage integrity integrity
completed=1
