#!/usr/bin/env bash
# LinguaGraph M8 Alibaba ECS provider-binding preflight.
#
# Read-only discovery only: no formal proof, no one-shot authorization, no
# package installation, no Docker bootstrap, no Product/proof repository write,
# no OSS mutation.
#
# All immutable provider identity constants and the read-only IMDS verification
# live in scripts/lib/m8-provider-identity.sh; this script owns no private copy.
# Frozen Product pins are read back from the semantic core's
# --emit-static-binding mode for the same reason.
set -Eeuo pipefail

M8_PREFLIGHT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=lib/m8-provider-identity.sh
source "$M8_PREFLIGHT_LIB_DIR/m8-provider-identity.sh"

readonly PRODUCT_URL='https://github.com/Pacchifans69/LinguaGraph.git'
readonly PROOF_URL='https://github.com/Pacchifans69/linguagraph-m8-proof.git'
readonly PRODUCT_BRANCH='m8-alignment-connector-obstacle-avoiding-routing'

die() { printf 'PREFLIGHT_FAIL: %s\n' "$*" >&2; exit 1; }

optional_imds() {
  local token=$1 rel=$2 value=''
  if value=$(m8_imds_get "$token" "$rel" 2>/dev/null) && [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf 'unavailable'
  fi
}

printf '===== M8 ALIBABA ECS PROVIDER-BINDING PREFLIGHT =====\n'
printf 'timestamp_utc=%s\n' "$(date -u +%FT%TZ)"
printf 'user=%s\n' "$(id -un)"
printf 'uid=%s\n' "$(id -u)"
printf 'home_env=%s\n' "${HOME:-}"
account_home=$(getent passwd "$(id -u)" | awk -F: 'NR == 1 {print $6}')
printf 'account_home=%s\n' "$account_home"
[[ -n "$account_home" ]] || die 'account home could not be resolved'
[[ "${HOME:-}" == "$account_home" ]] || die 'HOME differs from account home'

os_id=$(. /etc/os-release; printf '%s' "$ID")
os_version=$(. /etc/os-release; printf '%s' "$VERSION_ID")
printf 'os=%s:%s\n' "$os_id" "$os_version"
printf 'arch=%s\n' "$(uname -m)"
printf 'cpu_count=%s\n' "$(nproc)"
mem_kib=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
printf 'mem_total_kib=%s\n' "$mem_kib"
printf 'kernel=%s\n' "$(uname -r)"
printf 'boot_time_local=%s\n' "$(uptime -s 2>/dev/null || printf unavailable)"
printf 'root_fs=%s\n' "$(df -Pk / | awk 'NR==2 {print $2":"$3":"$4":"$5}')"

[[ "$os_id:$os_version" == 'ubuntu:24.04' ]] || die 'host is not Ubuntu 24.04'
[[ "$(uname -m)" == 'x86_64' ]] || die 'host architecture is not x86_64'
(( $(nproc) >= 4 )) || die 'host has fewer than four CPUs'
(( mem_kib >= 15000000 )) || die 'host has less than ~16 GB RAM'

# ---------------------------------------------------------------------------
# Shared reviewed provider identity tuple (single source of truth).
# ---------------------------------------------------------------------------
printf '\n--- reviewed provider identity authority ---\n'
m8_provider_identity_expected_lines
printf 'm8_provider_executor_id=%s\n' "$(m8_provider_identity_executor_id)"
m8_provider_binding_ready || die 'reviewed provider identity tuple is not fully bound'

# ---------------------------------------------------------------------------
# Live read-only metadata observation.
# ---------------------------------------------------------------------------
printf '\n--- live read-only IMDS observation ---\n'
tokenless=$(m8_imds_plain_status meta-data/instance-id)
printf 'imds_tokenless_instance_id_http_status=%s\n' "$tokenless"
[[ "$tokenless" == '403' ]] || die 'tokenless IMDS instance-id request did not return 403'

token=$(m8_imds_obtain_token) || die 'unable to obtain Alibaba IMDS token'
[[ -n "$token" ]] || die 'Alibaba IMDS token is empty'
printf 'imds_token_mode=successful\n'

# R2I-C7: the seven immutable provider inputs are read through the shared
# byte-safe authority in m8-provider-identity.sh. No raw immutable response body
# is captured with command substitution here; only validated scalars and
# canonical digests leave the classifier.
instance_id=$(m8_provider_identity_scalar_read "$token" meta-data/instance-id) ||
  die 'instance-id read failed (byte-safe)'
region_id=$(m8_provider_identity_scalar_read "$token" meta-data/region-id) ||
  die 'region-id read failed (byte-safe)'
zone_id=$(m8_provider_identity_scalar_read "$token" meta-data/zone-id) ||
  die 'zone-id read failed (byte-safe)'

# Instance type: the fallback endpoint is used ONLY for a failed primary REQUEST.
# A malformed primary response fails closed and never falls back.
instance_type=''
itype_rc=0
instance_type=$(m8_provider_identity_scalar_read "$token" meta-data/instance/instance-type) || itype_rc=$?
if (( itype_rc == M8_PROVIDER_SCALAR_REQUEST_FAILED )); then
  itype_rc=0
  instance_type=$(m8_provider_identity_scalar_read "$token" meta-data/instance-type) || itype_rc=$?
fi
(( itype_rc == 0 )) || die 'instance-type read failed (byte-safe)'

image_id=$(m8_provider_identity_scalar_read "$token" meta-data/image-id) ||
  die 'image-id read failed (byte-safe)'

printf 'instance_id=%s\n' "$instance_id"
printf 'region_id=%s\n' "$region_id"
printf 'zone_id=%s\n' "$zone_id"
printf 'instance_type=%s\n' "$instance_type"
printf 'image_id=%s\n' "$image_id"
printf 'vpc_id=%s\n' "$(optional_imds "$token" meta-data/vpc-id)"
printf 'vswitch_id=%s\n' "$(optional_imds "$token" meta-data/vswitch-id)"
printf 'private_ipv4=%s\n' "$(optional_imds "$token" meta-data/private-ipv4)"
printf 'public_ipv4=%s\n' "$(optional_imds "$token" meta-data/public-ipv4)"
printf 'eipv4=%s\n' "$(optional_imds "$token" meta-data/eipv4)"

document_sha=$(m8_provider_identity_digest_read "$token" dynamic/instance-identity/document -) ||
  die 'instance identity document read failed (byte-safe)'
pkcs7_sha=$(m8_provider_identity_digest_read "$token" dynamic/instance-identity/pkcs7 -) ||
  die 'instance identity PKCS7 read failed (byte-safe)'
printf 'identity_document_sha256=%s\n' "$document_sha"
printf 'identity_pkcs7_sha256=%s\n' "$pkcs7_sha"

# The live tuple is compared through the shared library, not a private copy.
set +e
m8_provider_identity_assert "$instance_id" "$region_id" "$zone_id" \
  "$instance_type" "$image_id" "$document_sha" "$pkcs7_sha"
identity_rc=$?
set -e
if (( identity_rc == 0 )); then
  printf 'provider_identity_match=PASS\n'
else
  printf 'provider_identity_match=FAIL\n'
  die 'live provider identity does not match the reviewed immutable tuple'
fi

# ---------------------------------------------------------------------------
# Frozen Product pins are read back from the semantic core.
# ---------------------------------------------------------------------------
printf '\n--- frozen static binding (from semantic core) ---\n'
static_binding=$(bash "$PWD/scripts/run-m8-proof-core.sh" --emit-static-binding) ||
  die 'semantic core could not emit its static binding'
printf '%s\n' "$static_binding"
candidate_sha=$(printf '%s\n' "$static_binding" | sed -n 's/^candidate_sha=//p')
frozen_main=$(printf '%s\n' "$static_binding" | sed -n 's/^frozen_main=//p')

product_remote=$(git ls-remote "$PRODUCT_URL" "refs/heads/$PRODUCT_BRANCH" | awk '{print $1}')
main_remote=$(git ls-remote "$PRODUCT_URL" refs/heads/main | awk '{print $1}')
proof_remote=$(git ls-remote "$PROOF_URL" refs/heads/main | awk '{print $1}')
printf 'product_candidate_remote=%s\n' "$product_remote"
printf 'product_main_remote=%s\n' "$main_remote"
printf 'proof_main_remote=%s\n' "$proof_remote"
[[ "$product_remote" == "$candidate_sha" ]] || die 'Product candidate remote moved'
[[ "$main_remote" == "$frozen_main" ]] || die 'Product main moved'

# ---------------------------------------------------------------------------
# Host readiness (discovery only).
# ---------------------------------------------------------------------------
printf '\n--- host readiness ---\n'
if command -v docker >/dev/null 2>&1; then
  printf 'docker_command=present\n'
  if docker info >/dev/null 2>&1; then
    printf 'docker_mode=direct\n'
  elif sudo -n docker info >/dev/null 2>&1; then
    printf 'docker_mode=sudo\n'
  else
    printf 'docker_mode=present_but_not_noninteractive\n'
  fi
else
  printf 'docker_command=absent_formal_adapter_may_bootstrap\n'
fi

if sudo -n true >/dev/null 2>&1; then
  printf 'passwordless_sudo=true\n'
else
  printf 'passwordless_sudo=false\n'
fi

# ossutil is supplied by host provisioning; the proof harness never installs
# it. This section is diagnostic only and never mutates OSS state.
printf '\n--- ossutil availability (diagnostic) ---\n'
ossutil_bin="${M8_OSSUTIL_BIN:-ossutil}"
if command -v "$ossutil_bin" >/dev/null 2>&1; then
  printf 'ossutil_bin=%s\n' "$ossutil_bin"
  printf 'ossutil_version=%s\n' "$("$ossutil_bin" version 2>&1 | head -n1 || printf 'unavailable')"
else
  printf 'ossutil_bin=%s\n' "$ossutil_bin"
  printf 'ossutil_present=no_the_formal_wrapper_will_fail_closed_until_provisioned\n'
fi
if [[ -n "${M8_OSS_BUCKET:-}" ]]; then
  printf 'oss_bucket_configured=yes\n'
else
  printf 'oss_bucket_configured=no\n'
fi

printf 'm8_host_state_exists=%s\n' "$([[ -e "$account_home/.local/state/linguagraph-m8-proof" ]] && printf yes || printf no)"
printf 'candidate_path_exists=%s\n' "$([[ -e "$PWD/candidate" ]] && printf yes || printf no)"
printf 'proof_artifacts_path_exists=%s\n' "$([[ -e "$PWD/proof-artifacts" ]] && printf yes || printf no)"
printf 'PREFLIGHT_OUTCOME=PASS\n'
