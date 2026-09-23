#!/usr/bin/env bash
# Synthetic ossutil stub for offline M8-HSDR-F02 verification.
#
# It implements ONLY the surface scripts/lib/m8-oss.sh depends on, backed by a
# local directory instead of Alibaba OSS. It NEVER touches a network or a real
# bucket. Behaviour is driven by M8_FAKE_OSS_* environment variables:
#
#   M8_FAKE_OSS_ROOT          required object-store root
#   M8_FAKE_OSS_VERSIONING    unversioned|live_namespace_timing|namespace_empty|
#                             no_namespace_empty|null|enabled|suspended|
#                             unknown_namespace|unexpected_child|duplicate_status|
#                             nested_status|root_attribute|wrong_root|
#                             malformed_xml|doctype|entity|trailing_garbage|
#                             double_timing_footer|unknown_status|
#                             xml_decl_valid|xml_decl_garbage|xml_decl_attribute|
#                             misplaced_declaration|leading_ws_root|comment_child|
#                             pi_child|outer_comment_before|outer_comment_after|
#                             outer_pi_before|outer_pi_after|footer_leading_space|
#                             footer_trailing_space|exact_footer|garbage|denied
#   M8_FAKE_OSS_LOCATION      cn-hongkong|wrong-region|denied|garbage|empty
#   M8_FAKE_OSS_CAPABILITY    full|no-forbid-overwrite|no-global-flags|no-location
#   M8_FAKE_OSS_MUTATION_LOG  append-only op log (READ/WRITE ordering)
#   M8_FAKE_OSS_BODY_LOG      append-only log of the exact --body argument
#   M8_FAKE_OSS_ARG_LOG       append-only log of canonical global arguments
#   M8_FAKE_OSS_FAIL_PUT_KEY  make put-object for this key fail
#   M8_FAKE_OSS_TAMPER_RECEIPT  path whose bytes are served for closure-receipt.json
#
# PutObject body contract: the stub accepts ONLY the official file-body form
# `--body file://<path>` and fails closed on a bare local path, so a regression
# back to `--body "$file"` is detected by the offline suite.
#
# R2I-C11/C4: the stub parses and records the five canonical CLI-pinned global
# arguments (--config-file, --region, --endpoint, --addressing-style,
# --ignore-env-var) AND the auth binding that now lives in the canonical config.
#
# Real ossutil 2.4.0 surface (proven live):
#   * `--ecs-role-name` is NOT a flag at all -> "unknown flag: --ecs-role-name";
#   * the captured 2.4.0 help declares the exact CLI --mode valid value set
#         valid value(s): "AK","StsToken","EcsRamRole","Anonymous"
#     so `Ali-EcsRamRole` AND `RamRoleArn` are rejected
#                                            -> "invalid value for flag(s) mode";
#   * the working binding is config `mode=Ali-EcsRamRole` + `ecsRoleName=<role>`.
# The stub therefore REJECTS an explicit CLI --ecs-role-name and REJECTS both
# `Ali-EcsRamRole` and `RamRoleArn` through CLI --mode exactly as the real parser
# does, while accepting exactly the CLI mode values the captured help lists
# (AK, StsToken, EcsRamRole, Anonymous) -- no invented mode. It advertises only
# the five pinned flags and distinguishes CLI mode/role from CONFIG mode/role in
# its argument log. For the auth-path surface this harness depends on, the stub is
# never more permissive than the real binary.
set -Eeuo pipefail

FAKE_ROOT="${M8_FAKE_OSS_ROOT:?M8_FAKE_OSS_ROOT is required}"
LOG="${M8_FAKE_OSS_MUTATION_LOG:-/dev/null}"
VERSIONING="${M8_FAKE_OSS_VERSIONING:-unversioned}"
LOCATION="${M8_FAKE_OSS_LOCATION:-cn-hongkong}"
CAPABILITY="${M8_FAKE_OSS_CAPABILITY:-full}"

log() { printf '%s\n' "$*" >>"$LOG"; }
object_path() { printf '%s/objects/%s/%s' "$FAKE_ROOT" "$1" "$2"; }

# --- synthetic global trust-target capture ----------------------------------
G_CONFIG=''; G_REGION=''; G_ENDPOINT=''
G_CLI_MODE=''; G_CLI_ROLE=''
G_CONFIG_MODE=''; G_CONFIG_ROLE=''
G_ADDRESSING=''; G_IGNORE_ENV='no'; G_FORBIDDEN=''

record_args() {
  local command=$1 operation=$2
  if [[ -n "${M8_FAKE_OSS_ARG_LOG:-}" ]]; then
    printf 'ARGS command=%s operation=%s config_file=%s region=%s endpoint=%s config_mode=%s config_role=%s cli_mode=%s cli_role=%s addressing_style=%s ignore_env_var=%s forbidden=%s\n' \
      "$command" "$operation" "$G_CONFIG" "$G_REGION" "$G_ENDPOINT" \
      "${G_CONFIG_MODE:-none}" "${G_CONFIG_ROLE:-none}" \
      "${G_CLI_MODE:-none}" "${G_CLI_ROLE:-none}" \
      "$G_ADDRESSING" "$G_IGNORE_ENV" "${G_FORBIDDEN:-none}" >>"$M8_FAKE_OSS_ARG_LOG"
  fi
}

note_forbidden() {
  if [[ -z "$G_FORBIDDEN" ]]; then G_FORBIDDEN="$1"; else G_FORBIDDEN="$G_FORBIDDEN,$1"; fi
}

# Extract the auth binding the real binary would read from the pinned config.
read_config_binding() {
  [[ -n "$G_CONFIG" && -f "$G_CONFIG" ]] || return 0
  G_CONFIG_MODE="$(sed -n 's/^mode=//p' "$G_CONFIG" | head -n1)"
  G_CONFIG_ROLE="$(sed -n 's/^ecsRoleName=//p' "$G_CONFIG" | head -n1)"
}

print_api_help() {
  printf 'ossutil api <operation> [parameters]\n'
  printf 'global options: --config-file --region --endpoint --addressing-style --ignore-env-var\n'
  printf 'operations: put-object get-object head-object get-bucket-versioning get-bucket-location\n'
  printf '  put-object: --bucket --key --body --forbid-overwrite\n'
  printf '  get-object: --bucket --key\n'
  printf '  head-object: --bucket --key\n'
  printf '  get-bucket-versioning: --bucket\n'
  printf '  get-bucket-location: --bucket\n'
}

print_global_only_help() {
  printf 'ossutil api <operation> [parameters]\n'
  printf 'operations: put-object get-object head-object get-bucket-versioning\n'
  printf '  put-object: --bucket --key --body --forbid-overwrite\n'
}

# Consume leading canonical global options in the CURRENT shell so the captured
# values survive.
while (($#)); do
  case "$1" in
    --config-file|-c)   G_CONFIG="$2"; shift 2 ;;
    --region)           G_REGION="$2"; shift 2 ;;
    --endpoint|-e)      G_ENDPOINT="$2"; shift 2 ;;
    # Exact ossutil 2.4.0 CLI --mode surface, taken from the captured live help:
    #     valid value(s): "AK","StsToken","EcsRamRole","Anonymous"
    # The C11 synthetic surface must not invent a CLI mode the real binary
    # rejects, and must not accept `Ali-EcsRamRole` (or `RamRoleArn`) through CLI
    # --mode. This models the parser surface only: the stub is a local directory
    # and never reads, prints or persists credentials, so accepting the
    # credential-free `Anonymous` parser value weakens no credential boundary.
    --mode)
      (($# >= 2)) || { printf 'Error: missing value for --mode\n' >&2; exit 1; }
      case "$2" in
        AK|StsToken|EcsRamRole|Anonymous) G_CLI_MODE="$2"; shift 2 ;;
        *)
          printf 'Error: invalid value for flag(s) "mode"\n' >&2
          exit 1
          ;;
      esac
      ;;
    # The real ossutil 2.4.0 has no such flag. Reject it exactly as the real
    # binary does, so a regression back to a CLI role pin fails loudly.
    --ecs-role-name)
      printf 'Error: unknown flag: --ecs-role-name\n' >&2
      exit 1
      ;;
    --addressing-style) G_ADDRESSING="$2"; shift 2 ;;
    --ignore-env-var)   G_IGNORE_ENV='yes'; shift ;;
    --profile)          shift 2 ;;
    --skip-verify-cert) note_forbidden 'skip-verify-cert'; shift ;;
    -i|--access-key-id) note_forbidden 'access-key-id'; shift 2 ;;
    -k|--access-key-secret) note_forbidden 'access-key-secret'; shift 2 ;;
    -t|--sts-token)     note_forbidden 'sts-token'; shift 2 ;;
    --ram-role-arn)     note_forbidden 'ram-role-arn'; shift 2 ;;
    --role-session-name) note_forbidden 'role-session-name'; shift 2 ;;
    -*)                 shift ;;
    *)                  break ;;
  esac
done
read_config_binding

command="${1:-}"
shift || true

case "$command" in
  version)
    printf 'ossutil version 2.2.0-synthetic-stub\n'
    exit 0
    ;;
  help)
    if [[ "$CAPABILITY" == 'no-forbid-overwrite' ]]; then
      printf 'ossutil api <operation> [parameters]\n'
      printf 'global options: --config-file --region --endpoint --addressing-style --ignore-env-var\n'
      printf 'operations: put-object get-object head-object get-bucket-versioning get-bucket-location\n'
      printf '  put-object: --bucket --key --body\n'
    elif [[ "$CAPABILITY" == 'no-global-flags' ]]; then
      print_global_only_help
    elif [[ "$CAPABILITY" == 'no-location' ]]; then
      printf 'ossutil api <operation> [parameters]\n'
      printf 'global options: --config-file --region --endpoint --addressing-style --ignore-env-var\n'
      printf 'operations: put-object get-object head-object get-bucket-versioning\n'
      printf '  put-object: --bucket --key --body --forbid-overwrite\n'
    else
      print_api_help
    fi
    exit 0
    ;;
  api) ;;
  *)
    printf 'Error: unsupported synthetic ossutil command: %s\n' "$command" >&2
    exit 1
    ;;
esac

declare -A FLAG=()
operation="${1:-}"
shift || true
while (($#)); do
  case "$1" in
    --help|-h)
      FLAG[help]=1
      shift
      ;;
    --bucket|--key|--body|--forbid-overwrite|--output)
      (($# >= 2)) || { printf 'Error: missing value for %s\n' "$1" >&2; exit 1; }
      FLAG["${1#--}"]="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

record_args api "$operation"

if [[ -n "${FLAG[help]:-}" ]]; then
  case "$operation" in
    put-object)
      if [[ "$CAPABILITY" == 'no-forbid-overwrite' ]]; then
        printf 'put-object: --bucket --key --body\n'
      else
        printf 'put-object: --bucket --key --body --forbid-overwrite\n'
      fi
      ;;
    get-object) printf 'get-object: --bucket --key\n' ;;
    head-object) printf 'head-object: --bucket --key\n' ;;
    get-bucket-versioning) printf 'get-bucket-versioning: --bucket\n' ;;
    get-bucket-location) printf 'get-bucket-location: --bucket\n' ;;
    *) print_api_help ;;
  esac
  exit 0
fi

case "$operation" in
  get-bucket-location)
    log "READ get-bucket-location ${FLAG[bucket]:-}"
    case "$LOCATION" in
      cn-hongkong) printf '<?xml version="1.0" encoding="UTF-8"?>\n<LocationConstraint>oss-cn-hongkong</LocationConstraint>\n' ;;
      wrong-region) printf '<?xml version="1.0" encoding="UTF-8"?>\n<LocationConstraint>oss-cn-hangzhou</LocationConstraint>\n' ;;
      empty) printf '<?xml version="1.0" encoding="UTF-8"?>\n<LocationConstraint></LocationConstraint>\n' ;;
      garbage) printf 'this is not a location document at all\n' ;;
      denied)
        printf 'Error: AccessDenied: no permission to get bucket location\n' >&2
        exit 1
        ;;
      *)
        printf 'Error: synthetic bucket location state is not configured: %s\n' "$LOCATION" >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
  get-bucket-versioning)
    log "READ get-bucket-versioning ${FLAG[bucket]:-}"
    # R2I-C12: the exact live ossutil 2.4.0 XML+timing surface, plus the frozen
    # structured-XML positive/negative matrix consumed by the C12 regressions.
    # The stub is deterministic and never more permissive than the production
    # classifier: it only emits response bytes, it classifies nothing.
    case "$VERSIONING" in
      unversioned) exit 0 ;;
      # Exact live-captured bytes: official default namespace + ONE terminal
      # timing footer. 94 bytes / SHA 68b07ea885b0284072d2ed8c29181aaa049a7f6c86034ef508fa0d277a9a5dd4
      live_namespace_timing)
        printf '<VersioningConfiguration xmlns="http://doc.oss-cn-hangzhou.aliyuncs.com"/>\n0.087913(s) elapsed\n'
        ;;
      namespace_empty)
        printf '<VersioningConfiguration xmlns="http://doc.oss-cn-hangzhou.aliyuncs.com"></VersioningConfiguration>\n'
        ;;
      no_namespace_empty) printf '<VersioningConfiguration/>\n' ;;
      null) printf '<VersioningConfiguration><Status>Null</Status></VersioningConfiguration>\n' ;;
      enabled) printf '<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>\n' ;;
      suspended) printf '<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>\n' ;;
      unknown_namespace)
        printf '<VersioningConfiguration xmlns="http://evil.example/ns"/>\n'
        ;;
      unexpected_child)
        printf '<VersioningConfiguration><Foo/></VersioningConfiguration>\n'
        ;;
      duplicate_status)
        printf '<VersioningConfiguration><Status>Null</Status><Status>Null</Status></VersioningConfiguration>\n'
        ;;
      nested_status)
        printf '<VersioningConfiguration><Status><Inner/></Status></VersioningConfiguration>\n'
        ;;
      root_attribute)
        printf '<VersioningConfiguration foo="bar"/>\n'
        ;;
      wrong_root) printf '<VersioningConfig/>\n' ;;
      malformed_xml) printf '<VersioningConfiguration><Status>Null</Status>\n' ;;
      doctype)
        printf '<!DOCTYPE VersioningConfiguration><VersioningConfiguration/>\n'
        ;;
      entity)
        printf '<!ENTITY m8synth "x"><VersioningConfiguration/>\n'
        ;;
      trailing_garbage)
        printf '<VersioningConfiguration/>\nsome unexpected trailing diagnostic\n'
        ;;
      double_timing_footer)
        printf '<VersioningConfiguration/>\n0.1(s) elapsed\n0.2(s) elapsed\n'
        ;;
      unknown_status)
        printf '<VersioningConfiguration><Status>Bogus</Status></VersioningConfiguration>\n'
        ;;
      # R2I-C12-A1: XML declaration / comment / PI / footer-grammar surface.
      xml_decl_valid) printf '<?xml version="1.0"?>\n<VersioningConfiguration/>\n' ;;
      xml_decl_garbage) printf '<?xml garbage?><VersioningConfiguration/>\n' ;;
      xml_decl_attribute) printf '<?xml version="1.0" foo="bar"?><VersioningConfiguration/>\n' ;;
      misplaced_declaration) printf '  <?xml version="1.0"?><VersioningConfiguration/>\n' ;;
      leading_ws_root) printf '  <VersioningConfiguration/>\n' ;;
      comment_child) printf '<VersioningConfiguration><!--comment--></VersioningConfiguration>\n' ;;
      pi_child) printf '<VersioningConfiguration><?m8 x?></VersioningConfiguration>\n' ;;
      outer_comment_before) printf '<!--c--><VersioningConfiguration/>\n' ;;
      outer_comment_after) printf '<VersioningConfiguration/><!--c-->\n' ;;
      outer_pi_before) printf '<?pi x?><VersioningConfiguration/>\n' ;;
      outer_pi_after) printf '<VersioningConfiguration/><?pi x?>\n' ;;
      footer_leading_space) printf '<VersioningConfiguration/>\n  0.1(s) elapsed\n' ;;
      footer_trailing_space) printf '<VersioningConfiguration/>\n0.1(s) elapsed  \n' ;;
      exact_footer) printf '<VersioningConfiguration/>\n0.087913(s) elapsed\n' ;;
      garbage) printf 'this is not a versioning document at all\n' ;;
      denied)
        printf 'Error: AccessDenied: no permission to get bucket versioning\n' >&2
        exit 1
        ;;
      *)
        printf 'Error: synthetic versioning state is not configured: %s\n' "$VERSIONING" >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
  put-object)
    bucket="${FLAG[bucket]:-}"; key="${FLAG[key]:-}"; body_arg="${FLAG[body]:-}"
    [[ -n "$bucket" && -n "$key" && -n "$body_arg" ]] ||
      { printf 'Error: put-object requires --bucket --key --body\n' >&2; exit 1; }
    if [[ -n "${M8_FAKE_OSS_BODY_LOG:-}" ]]; then
      printf '%s\n' "$body_arg" >>"$M8_FAKE_OSS_BODY_LOG"
    fi
    case "$body_arg" in
      file://*)
        body="${body_arg#file://}"
        ;;
      *)
        printf 'Error: put-object body must use the official file form file://<path>: %s\n' \
          "$body_arg" >&2
        exit 1
        ;;
    esac
    [[ -n "$body" ]] || { printf 'Error: put-object file body path is empty\n' >&2; exit 1; }
    [[ -f "$body" ]] || { printf 'Error: body file is not readable: %s\n' "$body" >&2; exit 1; }
    if [[ -n "${M8_FAKE_OSS_FAIL_PUT_KEY:-}" && "$key" == "$M8_FAKE_OSS_FAIL_PUT_KEY" ]]; then
      printf 'Error: synthetic injected put-object failure for %s\n' "$key" >&2
      exit 1
    fi
    destination="$(object_path "$bucket" "$key")"
    if [[ -f "$destination" ]]; then
      if [[ "${FLAG[forbid-overwrite]:-}" == 'true' ]]; then
        printf 'Error: FileAlreadyExists: object %s already exists (HTTP 409)\n' "$key" >&2
        exit 1
      fi
    fi
    mkdir -p "$(dirname "$destination")"
    cp -f "$body" "$destination"
    log "WRITE put-object $key"
    exit 0
    ;;
  head-object)
    bucket="${FLAG[bucket]:-}"; key="${FLAG[key]:-}"
    destination="$(object_path "$bucket" "$key")"
    if [[ -f "$destination" ]]; then
      log "READ head-object $key"
      printf 'Content-Length: %s\n' "$(wc -c <"$destination")"
      printf 'ETag: 00000000000000000000000000000000\n'
      exit 0
    fi
    printf 'Error: NoSuchKey: object %s does not exist (HTTP 404)\n' "$key" >&2
    exit 1
    ;;
  get-object)
    bucket="${FLAG[bucket]:-}"; key="${FLAG[key]:-}"
    destination="$(object_path "$bucket" "$key")"
    if [[ "$key" == *closure-receipt.json && -n "${M8_FAKE_OSS_TAMPER_RECEIPT:-}" ]]; then
      log "READ get-object $key (tampered)"
      if [[ -n "${FLAG[output]:-}" ]]; then
        cp -f "$M8_FAKE_OSS_TAMPER_RECEIPT" "${FLAG[output]}"
      else
        cat "$M8_FAKE_OSS_TAMPER_RECEIPT"
      fi
      exit 0
    fi
    if [[ -f "$destination" ]]; then
      log "READ get-object $key"
      if [[ -n "${FLAG[output]:-}" ]]; then
        cp -f "$destination" "${FLAG[output]}"
      else
        cat "$destination"
      fi
      exit 0
    fi
    printf 'Error: NoSuchKey: object %s does not exist (HTTP 404)\n' "$key" >&2
    exit 1
    ;;
  *)
    printf 'Error: unsupported synthetic ossutil api operation: %s\n' "$operation" >&2
    exit 1
    ;;
esac
