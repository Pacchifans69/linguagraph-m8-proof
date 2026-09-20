#!/usr/bin/env bash
# M8-EXI-01 Alibaba ECS thin adapter.
#
# Provider-bound M8 proof source. Product pins and one-shot/replay protections
# remain frozen. The Alibaba provider identity below was established by the
# read-only M8-EXI-01 preflight on 2026-09-20T08:11:52Z. Formal execution still
# requires Human approval of this exact proof commit and a fresh one-shot M8
# run authorization.
set -Eeuo pipefail

readonly PROOF_ROOT="$(git rev-parse --show-toplevel)"
readonly CORE="$PROOF_ROOT/scripts/run-m8-proof-core.sh"

readonly INHERITED_EVIDENCE_DIR="${M8_PROOF_EVIDENCE_DIR:-}"
readonly FIXED_EVIDENCE="$PROOF_ROOT/proof-artifacts"
readonly EVIDENCE="$FIXED_EVIDENCE"
export M8_PROOF_EVIDENCE_DIR="$EVIDENCE"

readonly PROOF_ORIGIN_URL='https://github.com/Pacchifans69/linguagraph-m8-proof.git'

readonly INHERITED_HOME="${HOME:-}"
ACCOUNT_HOME=''
if ! ACCOUNT_HOME="$(getent passwd "$(id -u)" | awk -F: 'NR == 1 { print $6 }')"; then
  printf 'FAIL: unable to resolve account home from passwd database\n' >&2
  exit 1
fi
[[ -n "$ACCOUNT_HOME" ]] || { printf 'FAIL: resolved account home is empty\n' >&2; exit 1; }
readonly ACCOUNT_HOME
readonly INHERITED_HOST_STATE="${M8_PROOF_HOST_STATE:-}"
readonly FIXED_HOST_STATE="$ACCOUNT_HOME/.local/state/linguagraph-m8-proof"
readonly HOST_STATE="$FIXED_HOST_STATE"
readonly SPENT_DIR="$HOST_STATE/spent"
readonly ARCHIVE_DIR="$HOST_STATE/artifacts"

readonly IMDS_BASE='http://100.100.100.200/latest'
readonly IMDS_TOKEN_URL="$IMDS_BASE/api/token"
readonly IMDS_TTL='21600'

# Exact fresh provider binding established by the separately authorized M8
# successor P3A/P3B/P3C provider preflight. Keep this fail-closed: do not replace
# these constants with wildcards or runtime-supplied arbitrary host identity.
readonly EXPECTED_INSTANCE_ID='i-j6c9854oyawy89fcdxy2'
readonly EXPECTED_REGION_ID='cn-hongkong'
readonly EXPECTED_ZONE_ID='cn-hongkong-d'
readonly EXPECTED_INSTANCE_TYPE='ecs.g9i.xlarge'
readonly EXPECTED_IMAGE_ID='ubuntu_24_04_x64_20G_alibase_20260916.vhd'
readonly EXPECTED_IDENTITY_DOCUMENT_SHA256='60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d'
readonly EXPECTED_IDENTITY_PKCS7_SHA256='89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211'

readonly PROVIDER_BINDING_READY='YES'
readonly RUN_AUTH_NAMESPACE_DESCRIPTION='M8-EXI-01-RUN-<approved-proof-sha-prefix>-<nonce>'

IMDS_TOKEN=''
AUTHORIZATION_SHA256=''
core_rc=0

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { [[ "$1" == "$2" ]] || die "Mismatch: $3 (expected $2; got $1)"; }
record() { printf '%s=%s\n' "$1" "$2" >> "$EVIDENCE/provenance.txt"; }

write_manifest() {
  local tmp="$EVIDENCE/.artifact-manifest.sha256.tmp"
  rm -f "$tmp"
  if (
    cd "$EVIDENCE"
    find . -type f       ! -name artifact-manifest.sha256       ! -name .artifact-manifest.sha256.tmp       -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$tmp"; then
    mv -f "$tmp" "$EVIDENCE/artifact-manifest.sha256"
  else
    rm -f "$tmp"
    return 1
  fi
}

build_archive() {
  local archive_name=$1 archive=$2 sidecar=''
  sidecar="${archive}.sha256"

  # Reserve both canonical output paths without clobbering. This makes a
  # repeated authorization attempt incapable of overwriting the first archive.
  if ! (set -o noclobber; : > "$archive") 2>/dev/null; then
    return 2
  fi
  if ! (set -o noclobber; : > "$sidecar") 2>/dev/null; then
    rm -f "$archive"
    return 2
  fi

  if ! tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner        -C "$PROOF_ROOT" -cf - proof-artifacts | gzip -n > "$archive"; then
    rm -f "$archive" "$sidecar"
    return 1
  fi
  if ! (cd "$ARCHIVE_DIR" && sha256sum "$archive_name" > "$archive_name.sha256"); then
    rm -f "$archive" "$sidecar"
    return 1
  fi
}

finalize() {
  local exit_code=$? packaging_failed=0 archive_name='' archive='' first_line='' archive_rc=0
  trap - EXIT
  mkdir -p "$EVIDENCE" 2>/dev/null || true

  if [[ ! -e "$EVIDENCE/outcome.txt" ]]; then
    printf 'FAIL missing_outcome adapter_exit=%s\n' "$exit_code" > "$EVIDENCE/outcome.txt"
    if (( exit_code == 0 )); then exit_code=1; fi
  else
    first_line=$(head -n1 "$EVIDENCE/outcome.txt" 2>/dev/null || printf '')
    if [[ "$first_line" == 'PASS' && "$exit_code" != 0 ]]; then
      printf 'FAIL adapter_exit=%s\n' "$exit_code" > "$EVIDENCE/outcome.txt"
    elif [[ "$first_line" != 'PASS' && "$exit_code" == 0 ]]; then
      exit_code=1
    fi
  fi

  write_manifest || packaging_failed=1

  mkdir -p "$ARCHIVE_DIR" 2>/dev/null || packaging_failed=1
  if [[ -d "$ARCHIVE_DIR" ]]; then
    archive_name="m8-proof-artifacts-${APPROVED_PROOF_SHA:-unknown}-${AUTHORIZATION_SHA256:-no-authorization}.tar.gz"
    archive="$ARCHIVE_DIR/$archive_name"
    build_archive "$archive_name" "$archive" || {
      archive_rc=$?
      packaging_failed=1
      if (( archive_rc == 2 )); then
        printf 'archive_collision=%s\n' "$archive_name" >> "$EVIDENCE/adapter-packaging.txt"
      fi
    }
  fi

  if (( packaging_failed != 0 )); then
    printf 'FAIL packaging_failed=1 adapter_exit=%s\n' "$exit_code" > "$EVIDENCE/outcome.txt"
    exit_code=1
    write_manifest || true
    if [[ -d "$ARCHIVE_DIR" && -n "$archive_name" && ! -e "$archive" && ! -e "${archive}.sha256" ]]; then
      build_archive "$archive_name" "$archive" || true
    fi
  fi

  exit "$exit_code"
}

guard_provider_binding_ready() {
  [[ "$PROVIDER_BINDING_READY" == 'YES' ]] || die 'M8 Alibaba provider binding is not established; preparation source cannot execute formal proof'
  [[ "$EXPECTED_INSTANCE_ID" != 'UNBOUND' ]] || die 'M8 expected instance ID is unbound'
  [[ "$EXPECTED_REGION_ID" != 'UNBOUND' ]] || die 'M8 expected region is unbound'
  [[ "$EXPECTED_ZONE_ID" != 'UNBOUND' ]] || die 'M8 expected zone is unbound'
  [[ "$EXPECTED_INSTANCE_TYPE" != 'UNBOUND' ]] || die 'M8 expected instance type is unbound'
  [[ "$EXPECTED_IMAGE_ID" != 'UNBOUND' ]] || die 'M8 expected image is unbound'
}

guard_no_circleci() {
  local v
  for v in CIRCLE_PROJECT_USERNAME CIRCLE_PROJECT_REPONAME CIRCLE_BRANCH            CIRCLE_SHA1 CIRCLE_WORKFLOW_ID CIRCLE_BUILD_NUM; do
    [[ -z "${!v:-}" ]] || die "CircleCI identity variable $v is set; Alibaba execution must not be obtained by spoofing CircleCI"
  done
}

guard_evidence_path() {
  if [[ -n "$INHERITED_EVIDENCE_DIR" && "$INHERITED_EVIDENCE_DIR" != "$FIXED_EVIDENCE" ]]; then
    die "M8_PROOF_EVIDENCE_DIR must be unset or exactly $FIXED_EVIDENCE; refusing redirected evidence"
  fi
}

guard_host_state_path() {
  if [[ "$INHERITED_HOME" != "$ACCOUNT_HOME" ]]; then
    die "HOME must exactly match account home $ACCOUNT_HOME; refusing redirected spent-token authority"
  fi
  if [[ -n "$INHERITED_HOST_STATE" && "$INHERITED_HOST_STATE" != "$FIXED_HOST_STATE" ]]; then
    die "M8_PROOF_HOST_STATE must be unset or exactly $FIXED_HOST_STATE; refusing redirected spent-token authority"
  fi
}

guard_clean_start() {
  [[ ! -e "$EVIDENCE" ]] || die "Pre-existing proof evidence path exists: $EVIDENCE"
  [[ ! -e "$PROOF_ROOT/candidate" ]] || die "Pre-existing candidate checkout path exists: $PROOF_ROOT/candidate"
}

guard_proof_sha() {
  [[ "${APPROVED_PROOF_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die 'APPROVED_PROOF_SHA must be a full 40-character SHA'
  expect "$(git -C "$PROOF_ROOT" remote get-url origin 2>/dev/null || printf '')" "$PROOF_ORIGIN_URL" proof_origin_url
  expect "$(git -C "$PROOF_ROOT" rev-parse --abbrev-ref HEAD)" 'main' proof_branch
  expect "$(git -C "$PROOF_ROOT" rev-parse HEAD)" "$APPROVED_PROOF_SHA" approved_proof_head
  expect "$(git -C "$PROOF_ROOT" ls-remote origin refs/heads/main | awk '{print $1}')" "$APPROVED_PROOF_SHA" approved_proof_remote_main
  [[ -z "$(git -C "$PROOF_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || die 'Dirty proof worktree before evidence creation'
}

guard_run_authorization() {
  local token="${M8_PROOF_RUN_AUTHORIZATION:-}"
  [[ -n "$token" ]] || die "Missing one-shot Human run authorization ($RUN_AUTH_NAMESPACE_DESCRIPTION)"

  local prefix=''
  if [[ "$token" =~ ^M8-EXI-01-RUN-([A-Fa-f0-9]{7,40})-[A-Za-z0-9_-]+$ ]]; then
    prefix="${BASH_REMATCH[1]}"
  else
    die "Run authorization must match $RUN_AUTH_NAMESPACE_DESCRIPTION"
  fi

  local lower_prefix="${prefix,,}" token_hash
  token_hash=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
  AUTHORIZATION_SHA256="$token_hash"
  expect "${APPROVED_PROOF_SHA:0:${#lower_prefix}}" "$lower_prefix" authorization_proof_sha_prefix

  mkdir -p "$SPENT_DIR"
  if ! mkdir "$SPENT_DIR/$token_hash" 2>/dev/null; then
    die "Run authorization was already spent ($token_hash); a rerun requires fresh Human authorization"
  fi

  record proof_provider alibaba-ecs
  record authorization_namespace M8-EXI-01
  record authorization_sha256 "$AUTHORIZATION_SHA256"
  record approved_proof_sha "$APPROVED_PROOF_SHA"
  record date_utc "$(date -u +%FT%TZ)"
}

imds_plain() {
  curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "$IMDS_BASE/$1"
}
imds_request_token() {
  curl --fail --silent --show-error --max-time 5 -X PUT     -H "X-aliyun-ecs-metadata-token-ttl-seconds: $IMDS_TTL" "$IMDS_TOKEN_URL"
}
imds_get() {
  curl --fail --silent --show-error --max-time 5     -H "X-aliyun-ecs-metadata-token: $IMDS_TOKEN" "$IMDS_BASE/$1"
}
capture_imds() {
  local rel=$1 out=$2 value=''
  if value=$(imds_get "$rel" 2>/dev/null) && [[ -n "$value" ]]; then
    printf '%s\n' "$value" > "$EVIDENCE/$out"
  else
    printf 'unavailable\n' > "$EVIDENCE/$out"
  fi
}

guard_and_capture_imds() {
  local code instance_id region zone itype image mac
  local identity_document='' identity_pkcs7='' boot_epoch='' boot_utc=''

  code=$(imds_plain meta-data/instance-id)
  expect "$code" '403' imds_tokenless_instance_id_http_status

  IMDS_TOKEN=$(imds_request_token) || die 'Alibaba IMDS token mode request failed'
  [[ -n "$IMDS_TOKEN" ]] || die 'Alibaba IMDS token mode returned an empty token'

  instance_id=$(imds_get meta-data/instance-id) || die 'Alibaba IMDS token-mode instance-id request failed'
  region=$(imds_get meta-data/region-id)
  zone=$(imds_get meta-data/zone-id)
  if ! itype=$(imds_get meta-data/instance/instance-type 2>/dev/null); then
    itype=$(imds_get meta-data/instance-type)
  fi
  image=$(imds_get meta-data/image-id)

  expect "$instance_id" "$EXPECTED_INSTANCE_ID" imds_instance_id
  expect "$region" "$EXPECTED_REGION_ID" imds_region_id
  expect "$zone" "$EXPECTED_ZONE_ID" imds_zone_id
  expect "$itype" "$EXPECTED_INSTANCE_TYPE" imds_instance_type
  expect "$image" "$EXPECTED_IMAGE_ID" imds_image_id

  capture_imds meta-data/instance-id instance-id.txt
  capture_imds meta-data/instance/instance-name instance-name.txt
  capture_imds meta-data/hostname hostname.txt
  capture_imds meta-data/region-id region-id.txt
  capture_imds meta-data/zone-id zone-id.txt
  capture_imds meta-data/instance/instance-type instance-type.txt
  capture_imds meta-data/image-id image-id.txt
  capture_imds meta-data/serial-number serial-number.txt
  capture_imds meta-data/vpc-id vpc-id.txt
  capture_imds meta-data/vswitch-id vswitch-id.txt
  capture_imds meta-data/private-ipv4 private-ipv4.txt
  capture_imds meta-data/public-ipv4 public-ipv4.txt
  capture_imds meta-data/eipv4 eipv4.txt
  capture_imds meta-data/mac primary-mac.txt

  mac=$(cat "$EVIDENCE/primary-mac.txt" 2>/dev/null || printf '')
  if [[ -n "$mac" && "$mac" != 'unavailable' ]]; then
    capture_imds "meta-data/network/interfaces/macs/$mac/network-interface-id" primary-eni.txt
    capture_imds "meta-data/network/interfaces/macs/$mac/primary-ip-address" primary-eni-private-ipv4.txt
  else
    printf 'unavailable\n' > "$EVIDENCE/primary-eni.txt"
    printf 'unavailable\n' > "$EVIDENCE/primary-eni-private-ipv4.txt"
  fi

  identity_document=$(imds_get dynamic/instance-identity/document) || die 'Alibaba instance identity document request failed'
  [[ -n "$identity_document" ]] || die 'Alibaba instance identity document is empty'
  printf '%s\n' "$identity_document" > "$EVIDENCE/instance-identity-document.json"

  identity_pkcs7=$(imds_get dynamic/instance-identity/pkcs7) || die 'Alibaba instance identity PKCS7 request failed'
  [[ -n "$identity_pkcs7" ]] || die 'Alibaba instance identity PKCS7 response is empty'
  printf '%s\n' "$identity_pkcs7" > "$EVIDENCE/instance-identity-pkcs7.txt"

  sha256sum "$EVIDENCE/instance-identity-document.json" | cut -d' ' -f1 > "$EVIDENCE/instance-identity-document.sha256"
  sha256sum "$EVIDENCE/instance-identity-pkcs7.txt" | cut -d' ' -f1 > "$EVIDENCE/instance-identity-pkcs7.sha256"
  expect "$(cat "$EVIDENCE/instance-identity-document.sha256")" "$EXPECTED_IDENTITY_DOCUMENT_SHA256" identity_document_sha256
  expect "$(cat "$EVIDENCE/instance-identity-pkcs7.sha256")" "$EXPECTED_IDENTITY_PKCS7_SHA256" identity_pkcs7_sha256

  {
    printf 'os_release:\n'
    cat /etc/os-release
    printf '\nuname:\n'
    uname -a
    printf '\narchitecture=%s\n' "$(uname -m)"
    printf 'cpu_count=%s\n' "$(nproc)"
    grep MemTotal /proc/meminfo
    printf 'boot_time_local=%s\n' "$(uptime -s 2>/dev/null || printf unavailable)"
    boot_epoch=$(awk '$1 == "btime" {print $2}' /proc/stat)
    if [[ "$boot_epoch" =~ ^[0-9]+$ ]]; then
      boot_utc=$(date -u -d "@$boot_epoch" +%FT%TZ) || boot_utc='unavailable'
    else
      boot_utc='unavailable'
    fi
    printf 'boot_timestamp_utc=%s\n' "$boot_utc"
  } > "$EVIDENCE/host-facts.txt"

  {
    printf 'imds_endpoint=%s\n' "$IMDS_BASE"
    printf 'imds_tokenless_instance_id_http_status=403\n'
    printf 'imds_token_mode=successful\n'
    printf 'instance_id=%s\n' "$instance_id"
    printf 'region_id=%s\n' "$region"
    printf 'zone_id=%s\n' "$zone"
    printf 'instance_type=%s\n' "$itype"
    printf 'image_id=%s\n' "$image"
    printf 'observed_public_ip=%s\n' "$(cat "$EVIDENCE/public-ipv4.txt" 2>/dev/null || printf unavailable)"
    printf 'observed_eipv4=%s\n' "$(cat "$EVIDENCE/eipv4.txt" 2>/dev/null || printf unavailable)"
    printf 'note=public IP, kernel patch version, boot timestamp and runtime-assigned network observations are recorded but are not immutable execution identity\n'
  } > "$EVIDENCE/alibaba-ecs-provenance.txt"
}

bootstrap_host() {
  if command -v docker >/dev/null 2>&1 && { docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1; }; then
    printf 'docker_already_usable=true\n' > "$EVIDENCE/alibaba-bootstrap.txt"
    return 0
  fi

  sudo -n true 2>/dev/null || die 'passwordless sudo -n is required for Alibaba host bootstrap'
  printf 'docker_already_usable=false\n' > "$EVIDENCE/alibaba-bootstrap.txt"
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io

  if ! sudo -n docker info >/dev/null 2>&1; then
    sudo -n systemctl start docker >/dev/null 2>&1 || sudo -n service docker start >/dev/null 2>&1 || true
  fi
  sudo -n docker info >/dev/null 2>&1 || die 'Docker did not become usable after bootstrap'

  {
    printf 'docker_io_version=%s\n' "$(dpkg-query -W -f='${Version}' docker.io 2>/dev/null || printf unavailable)"
    sudo -n docker --version
  } >> "$EVIDENCE/alibaba-bootstrap.txt"
}

guard_no_circleci
guard_evidence_path
guard_host_state_path
guard_provider_binding_ready
guard_proof_sha
guard_clean_start
case "$HOST_STATE" in
  "$PROOF_ROOT"|"$PROOF_ROOT"/*) die 'Host state directory must be outside the git worktree' ;;
esac

# Only after all clean-start guards pass do failures become formal evidence
# lifecycle events. This prevents stale ignored evidence from being repackaged.
trap finalize EXIT
mkdir -p "$EVIDENCE"
guard_run_authorization
guard_and_capture_imds
bootstrap_host

bash "$CORE" || core_rc=$?
exit "$core_rc"
