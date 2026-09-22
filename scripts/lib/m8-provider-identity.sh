#!/usr/bin/env bash
# shellcheck shell=bash
# LinguaGraph M8 shared Alibaba ECS provider identity authority.
#
# This file is the SINGLE SOURCE OF TRUTH for the reviewed immutable execution
# identity of the M8 hosted proof host. It is sourced (never executed) by:
#
#   scripts/run-m8-proof.sh                 pre-claim provider identity verification
#   scripts/run-m8-proof-alibaba-ecs.sh     post-claim defence-in-depth re-verification
#   scripts/preflight-m8-alibaba-ecs.sh     read-only discovery / binding report
#
# Contract:
#   * read-only IMDS access only (no provider mutation, no credential provisioning);
#   * no independent duplicate copies of these constants anywhere else in the repo;
#   * the reviewed tuple may only be changed by a separately authorized Human
#     provider re-binding, never by a runtime value.
#
# The functions here are pure with respect to provider state. Only
# m8_provider_identity_verify() writes, and it writes exclusively inside the
# caller-supplied evidence capture directory.

if [[ -n "${M8_PROVIDER_IDENTITY_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
M8_PROVIDER_IDENTITY_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Reviewed immutable provider tuple (established by the read-only M8 provider
# preflight; recorded in README.md).
# ---------------------------------------------------------------------------
readonly EXPECTED_INSTANCE_ID='i-j6c9854oyawy89fcdxy2'
readonly EXPECTED_REGION_ID='cn-hongkong'
readonly EXPECTED_ZONE_ID='cn-hongkong-d'
readonly EXPECTED_INSTANCE_TYPE='ecs.g9i.xlarge'
readonly EXPECTED_IMAGE_ID='ubuntu_24_04_x64_20G_alibase_20260916.vhd'
readonly EXPECTED_IDENTITY_DOCUMENT_SHA256='60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d'
readonly EXPECTED_IDENTITY_PKCS7_SHA256='89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211'

readonly M8_PROVIDER_BINDING_READY='YES'
readonly M8_PROVIDER_EXECUTOR_ID="alibaba-ecs:${EXPECTED_INSTANCE_ID}"

readonly M8_IMDS_DEFAULT_BASE='http://100.100.100.200/latest'
readonly M8_IMDS_TOKEN_TTL_DEFAULT='21600'

m8_provider_die() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
m8_provider_expect() {
  [[ "$1" == "$2" ]] || { m8_provider_die "Mismatch: $3 (expected $2; got $1)"; return 1; }
}

# ---------------------------------------------------------------------------
# Configuration seams.
#
# M8_IMDS_BASE_URL / M8_IMDS_CURL_BIN exist so that offline synthetic tests can
# drive the same code paths without touching a real metadata service. Formal
# execution never sets them; the wrapper records them in provenance so a
# redirected metadata source is always visible in evidence.
# ---------------------------------------------------------------------------
m8_imds_base_url() { printf '%s' "${M8_IMDS_BASE_URL:-$M8_IMDS_DEFAULT_BASE}"; }
m8_imds_curl_bin() { printf '%s' "${M8_IMDS_CURL_BIN:-curl}"; }
m8_imds_token_ttl() { printf '%s' "${M8_IMDS_TOKEN_TTL:-$M8_IMDS_TOKEN_TTL_DEFAULT}"; }

m8_provider_identity_executor_id() { printf '%s' "$M8_PROVIDER_EXECUTOR_ID"; }

# Fail closed unless the reviewed tuple is fully bound (no placeholder values).
m8_provider_binding_ready() {
  [[ "$M8_PROVIDER_BINDING_READY" == 'YES' ]] || { m8_provider_die 'M8 Alibaba provider binding is not established'; return 1; }
  local name value
  for name in EXPECTED_INSTANCE_ID EXPECTED_REGION_ID EXPECTED_ZONE_ID \
    EXPECTED_INSTANCE_TYPE EXPECTED_IMAGE_ID \
    EXPECTED_IDENTITY_DOCUMENT_SHA256 EXPECTED_IDENTITY_PKCS7_SHA256; do
    value="${!name}"
    [[ -n "$value" && "$value" != 'UNBOUND' && "$value" != 'unbound' ]] || { m8_provider_die "$name is unbound"; return 1; }
  done
  [[ "$EXPECTED_IDENTITY_DOCUMENT_SHA256" =~ ^[0-9a-f]{64}$ ]] || { m8_provider_die 'EXPECTED_IDENTITY_DOCUMENT_SHA256 is not a SHA-256'; return 1; }
  [[ "$EXPECTED_IDENTITY_PKCS7_SHA256" =~ ^[0-9a-f]{64}$ ]] || { m8_provider_die 'EXPECTED_IDENTITY_PKCS7_SHA256 is not a SHA-256'; return 1; }
}

# Emit the expected tuple as deterministic key=value lines.
m8_provider_identity_expected_lines() {
  printf 'instance_id=%s\n' "$EXPECTED_INSTANCE_ID"
  printf 'region_id=%s\n' "$EXPECTED_REGION_ID"
  printf 'zone_id=%s\n' "$EXPECTED_ZONE_ID"
  printf 'instance_type=%s\n' "$EXPECTED_INSTANCE_TYPE"
  printf 'image_id=%s\n' "$EXPECTED_IMAGE_ID"
  printf 'identity_document_sha256=%s\n' "$EXPECTED_IDENTITY_DOCUMENT_SHA256"
  printf 'identity_pkcs7_sha256=%s\n' "$EXPECTED_IDENTITY_PKCS7_SHA256"
}

# ---------------------------------------------------------------------------
# Read-only IMDS access.
# ---------------------------------------------------------------------------
m8_imds_plain_status() {
  local rel=$1
  "$(m8_imds_curl_bin)" --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 5 "$(m8_imds_base_url)/$rel"
}

m8_imds_obtain_token() {
  "$(m8_imds_curl_bin)" --fail --silent --show-error --max-time 5 -X PUT \
    -H "X-aliyun-ecs-metadata-token-ttl-seconds: $(m8_imds_token_ttl)" \
    "$(m8_imds_base_url)/api/token"
}

m8_imds_get() {
  local token=$1 rel=$2
  "$(m8_imds_curl_bin)" --fail --silent --show-error --max-time 5 \
    -H "X-aliyun-ecs-metadata-token: $token" \
    "$(m8_imds_base_url)/$rel"
}

# Capture a single optional IMDS value; absence is recorded, never fatal.
m8_imds_capture() {
  local token=$1 rel=$2 out=$3 value=''
  if value=$(m8_imds_get "$token" "$rel" 2>/dev/null) && [[ -n "$value" ]]; then
    printf '%s\n' "$value" > "$out"
  else
    printf 'unavailable\n' > "$out"
  fi
}

# ---------------------------------------------------------------------------
# Pure tuple comparison. No I/O, no writes: the reviewed constants are compared
# to caller-supplied observed values. Used directly by offline synthetic tests.
# ---------------------------------------------------------------------------
m8_provider_identity_assert() {
  local instance_id=$1 region=$2 zone=$3 itype=$4 image=$5 doc_sha=$6 pkcs7_sha=$7
  m8_provider_binding_ready
  m8_provider_expect "$instance_id" "$EXPECTED_INSTANCE_ID" provider_instance_id || return 1
  m8_provider_expect "$region" "$EXPECTED_REGION_ID" provider_region_id || return 1
  m8_provider_expect "$zone" "$EXPECTED_ZONE_ID" provider_zone_id || return 1
  m8_provider_expect "$itype" "$EXPECTED_INSTANCE_TYPE" provider_instance_type || return 1
  m8_provider_expect "$image" "$EXPECTED_IMAGE_ID" provider_image_id || return 1
  m8_provider_expect "$doc_sha" "$EXPECTED_IDENTITY_DOCUMENT_SHA256" provider_identity_document_sha256 || return 1
  m8_provider_expect "$pkcs7_sha" "$EXPECTED_IDENTITY_PKCS7_SHA256" provider_identity_pkcs7_sha256 || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Full read-only verification.
#
# m8_provider_identity_verify <capture_dir|-> [label]
#
#   capture_dir  directory receiving raw observed values and their digests
#                ('-' disables capture)
#   label        optional sub-directory name for the capture (used for the
#                post-claim defence-in-depth second pass)
#
# Returns 0 only when the observed live tuple AND both identity digests match the
# reviewed constants exactly.
# ---------------------------------------------------------------------------
m8_provider_identity_verify() {
  local capture_dir=${1:-'-'} label=${2:-primary}
  local target='' token='' status=''
  local instance_id region zone itype image mac
  local identity_document='' identity_pkcs7='' doc_sha='' pkcs7_sha=''

  m8_provider_binding_ready

  if [[ "$capture_dir" != '-' ]]; then
    target="$capture_dir/$label"
    mkdir -p "$target" || { m8_provider_die "cannot create identity capture directory $target"; return 1; }
  fi

  status=$(m8_imds_plain_status meta-data/instance-id) || { m8_provider_die 'Alibaba IMDS tokenless probe failed'; return 1; }
  m8_provider_expect "$status" '403' imds_tokenless_instance_id_http_status || return 1

  token=$(m8_imds_obtain_token) || { m8_provider_die 'Alibaba IMDS token mode request failed'; return 1; }
  [[ -n "$token" ]] || { m8_provider_die 'Alibaba IMDS token mode returned an empty token'; return 1; }

  instance_id=$(m8_imds_get "$token" meta-data/instance-id) || { m8_provider_die 'Alibaba IMDS token-mode instance-id request failed'; return 1; }
  region=$(m8_imds_get "$token" meta-data/region-id) || { m8_provider_die 'Alibaba IMDS region-id request failed'; return 1; }
  zone=$(m8_imds_get "$token" meta-data/zone-id) || { m8_provider_die 'Alibaba IMDS zone-id request failed'; return 1; }
  if ! itype=$(m8_imds_get "$token" meta-data/instance/instance-type 2>/dev/null); then
    itype=$(m8_imds_get "$token" meta-data/instance-type) || { m8_provider_die 'Alibaba IMDS instance-type request failed'; return 1; }
  fi
  image=$(m8_imds_get "$token" meta-data/image-id) || { m8_provider_die 'Alibaba IMDS image-id request failed'; return 1; }

  identity_document=$(m8_imds_get "$token" dynamic/instance-identity/document) || { m8_provider_die 'Alibaba instance identity document request failed'; return 1; }
  [[ -n "$identity_document" ]] || { m8_provider_die 'Alibaba instance identity document is empty'; return 1; }
  identity_pkcs7=$(m8_imds_get "$token" dynamic/instance-identity/pkcs7) || { m8_provider_die 'Alibaba instance identity PKCS7 request failed'; return 1; }
  [[ -n "$identity_pkcs7" ]] || { m8_provider_die 'Alibaba instance identity PKCS7 response is empty'; return 1; }

  if [[ "$capture_dir" != '-' ]]; then
    printf '%s\n' "$instance_id" > "$target/instance-id.txt"
    printf '%s\n' "$region" > "$target/region-id.txt"
    printf '%s\n' "$zone" > "$target/zone-id.txt"
    printf '%s\n' "$itype" > "$target/instance-type.txt"
    printf '%s\n' "$image" > "$target/image-id.txt"
    printf '%s\n' "$identity_document" > "$target/instance-identity-document.json"
    printf '%s\n' "$identity_pkcs7" > "$target/instance-identity-pkcs7.txt"
    m8_imds_capture "$token" meta-data/instance/instance-name "$target/instance-name.txt"
    m8_imds_capture "$token" meta-data/hostname "$target/hostname.txt"
    m8_imds_capture "$token" meta-data/serial-number "$target/serial-number.txt"
    m8_imds_capture "$token" meta-data/vpc-id "$target/vpc-id.txt"
    m8_imds_capture "$token" meta-data/vswitch-id "$target/vswitch-id.txt"
    m8_imds_capture "$token" meta-data/private-ipv4 "$target/private-ipv4.txt"
    m8_imds_capture "$token" meta-data/public-ipv4 "$target/public-ipv4.txt"
    m8_imds_capture "$token" meta-data/eipv4 "$target/eipv4.txt"
    m8_imds_capture "$token" meta-data/mac "$target/primary-mac.txt"
    mac=$(cat "$target/primary-mac.txt" 2>/dev/null || printf '')
    if [[ -n "$mac" && "$mac" != 'unavailable' ]]; then
      m8_imds_capture "$token" \
        "meta-data/network/interfaces/macs/$mac/network-interface-id" "$target/primary-eni.txt"
      m8_imds_capture "$token" \
        "meta-data/network/interfaces/macs/$mac/primary-ip-address" "$target/primary-eni-private-ipv4.txt"
    else
      printf 'unavailable\n' > "$target/primary-eni.txt"
      printf 'unavailable\n' > "$target/primary-eni-private-ipv4.txt"
    fi
    doc_sha=$(sha256sum "$target/instance-identity-document.json" | cut -d' ' -f1)
    pkcs7_sha=$(sha256sum "$target/instance-identity-pkcs7.txt" | cut -d' ' -f1)
  else
    doc_sha=$(printf '%s\n' "$identity_document" | sha256sum | cut -d' ' -f1)
    pkcs7_sha=$(printf '%s\n' "$identity_pkcs7" | sha256sum | cut -d' ' -f1)
  fi

  m8_provider_identity_assert \
    "$instance_id" "$region" "$zone" "$itype" "$image" "$doc_sha" "$pkcs7_sha" ||
    return 1

  if [[ "$capture_dir" != '-' ]]; then
    printf '%s\n' "$doc_sha" > "$target/instance-identity-document.sha256"
    printf '%s\n' "$pkcs7_sha" > "$target/instance-identity-pkcs7.sha256"
    {
      printf 'observed_utc=%s\n' "$(date -u +%FT%TZ)"
      printf 'imds_endpoint=%s\n' "$(m8_imds_base_url)"
      printf 'imds_tokenless_instance_id_http_status=%s\n' "$status"
      printf 'imds_token_mode=successful\n'
      m8_provider_identity_expected_lines
      printf 'note=public IP, ENI, hostname, kernel and boot observations are provenance, not immutable execution identity\n'
    } > "$target/provider-identity-result.txt"
  fi

  return 0
}

# Read-only discovery report for the preflight: prints observed values and the
# match/mismatch verdict for each element of the reviewed tuple. Never fails on
# mismatch by itself; the caller decides.
m8_provider_identity_report() {
  local capture_dir=${1:-'-'}
  if m8_provider_identity_verify "$capture_dir" preflight; then
    printf 'provider_identity_match=PASS\n'
  else
    printf 'provider_identity_match=FAIL\n'
    return 1
  fi
}
