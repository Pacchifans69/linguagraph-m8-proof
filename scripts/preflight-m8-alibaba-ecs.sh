#!/usr/bin/env bash
# M8-EXI-01 Alibaba ECS provider-binding preflight.
#
# Read-only discovery only: no formal proof, no one-shot authorization, no
# package installation, no Docker bootstrap, no Product/proof repository write.
set -Eeuo pipefail

readonly IMDS_BASE='http://100.100.100.200/latest'
readonly IMDS_TOKEN_URL="$IMDS_BASE/api/token"
readonly IMDS_TTL='21600'
readonly PRODUCT_URL='https://github.com/Pacchifans69/LinguaGraph.git'
readonly PROOF_URL='https://github.com/Pacchifans69/linguagraph-m8-proof.git'
readonly PRODUCT_BRANCH='m8-alignment-connector-obstacle-avoiding-routing'
readonly PRODUCT_SHA='2441f9cf60b7cc9402c5b257be010b559b39b717'
readonly PRODUCT_MAIN='cf26ea557bd746a518ff32b8b7e7a7542be7f7ae'

die() { printf 'PREFLIGHT_FAIL: %s\n' "$*" >&2; exit 1; }

imds_plain_code() {
  curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "$IMDS_BASE/$1"
}

imds_token() {
  curl --fail --silent --show-error --max-time 5 -X PUT \
    -H "X-aliyun-ecs-metadata-token-ttl-seconds: $IMDS_TTL" \
    "$IMDS_TOKEN_URL"
}

imds_get() {
  local token=$1 rel=$2
  curl --fail --silent --show-error --max-time 5 \
    -H "X-aliyun-ecs-metadata-token: $token" \
    "$IMDS_BASE/$rel"
}

optional_imds() {
  local token=$1 rel=$2 value=''
  if value=$(imds_get "$token" "$rel" 2>/dev/null) && [[ -n "$value" ]]; then
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

tokenless=$(imds_plain_code meta-data/instance-id)
printf 'imds_tokenless_instance_id_http_status=%s\n' "$tokenless"
[[ "$tokenless" == '403' ]] || die 'tokenless IMDS instance-id request did not return 403'

token=$(imds_token) || die 'unable to obtain Alibaba IMDS token'
[[ -n "$token" ]] || die 'Alibaba IMDS token is empty'
printf 'imds_token_mode=successful\n'

instance_id=$(imds_get "$token" meta-data/instance-id)
region_id=$(imds_get "$token" meta-data/region-id)
zone_id=$(imds_get "$token" meta-data/zone-id)
if ! instance_type=$(imds_get "$token" meta-data/instance/instance-type 2>/dev/null); then
  instance_type=$(imds_get "$token" meta-data/instance-type)
fi
image_id=$(imds_get "$token" meta-data/image-id)

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

identity_document=$(imds_get "$token" dynamic/instance-identity/document) || die 'instance identity document unavailable'
identity_pkcs7=$(imds_get "$token" dynamic/instance-identity/pkcs7) || die 'instance identity PKCS7 unavailable'
[[ -n "$identity_document" ]] || die 'instance identity document is empty'
[[ -n "$identity_pkcs7" ]] || die 'instance identity PKCS7 is empty'
printf 'identity_document_sha256=%s\n' "$(printf '%s\n' "$identity_document" | sha256sum | cut -d' ' -f1)"
printf 'identity_pkcs7_sha256=%s\n' "$(printf '%s\n' "$identity_pkcs7" | sha256sum | cut -d' ' -f1)"

product_remote=$(git ls-remote "$PRODUCT_URL" "refs/heads/$PRODUCT_BRANCH" | awk '{print $1}')
main_remote=$(git ls-remote "$PRODUCT_URL" refs/heads/main | awk '{print $1}')
proof_remote=$(git ls-remote "$PROOF_URL" refs/heads/main | awk '{print $1}')
printf 'product_candidate_remote=%s\n' "$product_remote"
printf 'product_main_remote=%s\n' "$main_remote"
printf 'proof_main_remote=%s\n' "$proof_remote"
[[ "$product_remote" == "$PRODUCT_SHA" ]] || die 'Product candidate remote moved'
[[ "$main_remote" == "$PRODUCT_MAIN" ]] || die 'Product main moved'

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

printf 'm8_host_state_exists=%s\n' "$([[ -e "$account_home/.local/state/linguagraph-m8-proof" ]] && printf yes || printf no)"
printf 'candidate_path_exists=%s\n' "$([[ -e "$PWD/candidate" ]] && printf yes || printf no)"
printf 'proof_artifacts_path_exists=%s\n' "$([[ -e "$PWD/proof-artifacts" ]] && printf yes || printf no)"
printf 'PREFLIGHT_OUTCOME=PASS\n'
