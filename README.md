# LinguaGraph M8 external proof

This repository is independent proof infrastructure for **M8 — Alignment
Connector Obstacle-Avoiding Routing**. It must not modify the LinguaGraph
Product repository.

## Status

```text
checkpoint:           M8
proof path:           M8-EXI-01 — Alibaba ECS alternate hosted Gate 2
proof source:         SUCCESSOR-REBOUND / PROVIDER-BOUND
provider binding:     ESTABLISHED / REVIEWED
prior formal run:     PREDECESSOR FAILED 33/34 PLAYWRIGHT / AUTH SPENT
formal run auth:      NOT ISSUED FOR SUCCESSOR
successor execution:  NOT EXECUTED
Gate 2:               NOT ESTABLISHED
```

The Product's canonical GitHub Actions run for this exact successor candidate
failed before every repository-defined step (`runner_id=0`, `runner_name=""`,
`steps=[]`). That is provider/pre-step diagnostic evidence, not application/test
evidence.

The predecessor candidate `078d3ed11f33716578bcee6a3f4801319c79fe8d` completed
one formal hosted proof attempt: all backend, migration, routing, Vitest and
build evidence passed, while Playwright finished 33/34 on a body-scroll
assertion later classified as a contract false positive. Its one-shot
authorization is spent and is not valid for this successor.

## Exact Product binding

```text
repository:     Pacchifans69/LinguaGraph
branch:         m8-alignment-connector-obstacle-avoiding-routing
candidate SHA:  2441f9cf60b7cc9402c5b257be010b559b39b717
candidate tree: 5d1b7c7cc104cd365b0ea629d9ead7677d17f2be
unique parent:  e4b1cc66f540ab74c0ef9bd014b0a0da3a2d9c1d
frozen main:    cf26ea557bd746a518ff32b8b7e7a7542be7f7ae
Alembic head:   0006
```

These pins live once, in `scripts/run-m8-proof-core.sh`. The formal wrapper and
the preflight read them back through the core's `--emit-static-binding` mode, so
no second independent copy exists.

The provider-neutral core fails closed unless the remote Product branch, remote
main, detached checkout, tree, unique parent, frozen-main ancestry, and reviewed
15-file candidate scope all match these exact values.

## R2B formal lifecycle

There is exactly **one** formal entrypoint:

```text
scripts/run-m8-proof.sh
```

`scripts/run-m8-proof-alibaba-ecs.sh` is a thin execution adapter, not an
independent formal runner. Without wrapper-issued formal context and the durable
single-use claim it refuses to consume any authorization, refuses to invoke the
semantic core, and is reported as `NONFORMAL / NOT_APPLICABLE`.

```text
pre-claim guards -> OSS trust-target establishment (read-only) -> atomic claim
                 -> PHASE A execution -> PHASE B seal -> PHASE C durability
                 -> PHASE D commit -> terminal RC marker
```

Every pre-claim guard, and every trust-target establishment step, is read-only.
No `PutObject` may occur before all of them succeed; the first permitted mutating
call of a formal run is the atomic claim.

### Frozen RC contract

Four distinct statuses exist and none may substitute for another:

| Artifact | Meaning | Writer |
| --- | --- | --- |
| `core-exit-code.txt` | actual process RC of `run-m8-proof-core.sh` as observed by its parent adapter | adapter, immediately after the core child returns |
| `adapter-exit-code.txt` | adapter's final self-declared RC after all adapter work | adapter `EXIT` trap |
| `formal-execution-rc.txt` | actual adapter-child RC observed by the wrapper | wrapper, immediately after the adapter child returns |
| `closure-receipt.json.formal_command_rc` | final successful formal wrapper RC (must be 0) | wrapper, PHASE D |

The semantic core never writes `core-exit-code.txt`, and refuses to start if a
stale one already exists.

The wrapper requires `adapter-exit-code.txt == formal-execution-rc.txt`, both
present and numeric. Absent, empty, non-numeric or mismatching records **FAIL
CLOSED**. `SIGTERM` is recorded as its own numeric RC; `SIGKILL` cannot run an
in-process trap, so the adapter RC is simply absent and the wrapper fails closed
rather than fabricating it.

### Pre-claim provider identity

`scripts/lib/m8-provider-identity.sh` is the single source of truth for the
reviewed immutable execution identity and for the read-only IMDS verification:

```text
instance ID:   i-j6c9854oyawy89fcdxy2
region:        cn-hongkong
zone:          cn-hongkong-d
instance type: ecs.g9i.xlarge
image ID:      ubuntu_24_04_x64_20G_alibase_20260916.vhd

identity document SHA-256:
60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d
identity PKCS7 SHA-256:
89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211
```

Required order: local token syntax (the presented token is hashed to
`authorization_sha256` and is never echoed), durable `issued.json` retrieval and
binding validation, static bindings, read-only provider identity verification,
and only then the atomic claim. The adapter independently repeats the same
read-only verification after the claim and requires the observed tuple to equal
the claim's, as defence in depth before invoking the core.

Network addresses (VPC, vSwitch, private IPv4, EIP) are recorded as provenance
but are not part of the immutable execution identity.

The same library performs the read-only ECS RAM **role-name** observation used to
pin the OSS auth mode, querying only the role-name LIST endpoint
(`meta-data/ram/security-credentials/`) and never the credential-payload
endpoint. The observed name is a live binding: it is never hard-coded here or in
the harness, and it must be a single plain role name.

### OSS object model

```text
authorizations/<authorization_sha256>/issued.json
authorizations/<authorization_sha256>/claim.json
runs/<proof_sha>/<semantic_auth_sha256>/<archive_name>
runs/<proof_sha>/<semantic_auth_sha256>/package-index.json
runs/<proof_sha>/<semantic_auth_sha256>/closure-receipt.json
```

`<authorization_sha256>` is `SHA256(exact Human-issued authorization TOKEN)`.
The Human supplies the exact token string in `M8_PROOF_RUN_AUTHORIZATION`
(semantic) or `M8_PROOF_RETRY_AUTHORIZATION` (durability retry); the wrapper
hashes it locally and only the digest becomes an object-path component. The token
itself is never printed, persisted, uploaded, recorded in a receipt or package
index, or written into `ossutil` command output. `issued.json` must **declare**
the same `authorization_sha256`, and a mismatched declaration **FAILS CLOSED**.

`authorization_sha256` is deliberately **not** a digest of the `issued.json`
bytes: there is no self-reference, and a document can never contain a correct
digest of its own bytes. Exact issued-document byte identity, when wanted, is
carried by the separate and semantically distinct `issued_document_sha256` field
of the closure receipt, which the wrapper computes over the exact retrieved
bytes and cross-binds in both directions. Run paths and archive names are
derived canonically, never supplied by the caller.

Every write is atomic create-if-absent through the official ossutil API, and
every upload body uses the official **file form**:

```bash
ossutil api put-object --bucket "$BUCKET" --key "$KEY" \
  --body "file://$FILE" --forbid-overwrite true
```

A bare local path (`--body "$FILE"`) is not the file-body form and is never
used. For an absolute path such as `/tmp/foo.tar.gz` the resulting argument is
`file:///tmp/foo.tar.gz`.

`HEAD`-then-unconditional-`PUT` is never used as the locking primitive, ETag is
never treated as SHA-256, and `FileAlreadyExists` is never overwritten.
`GetObject` stays byte-exact: response bytes travel directly from ossutil stdout
into a file and never through shell command substitution or a shell variable.
The manifest and archive digests are computed over those exact file bytes.

The proof harness **never installs ossutil**; host provisioning supplies it. A
capability guard must demonstrate support for
`ossutil api put-object --forbid-overwrite true`, `get-object`, `head-object`,
`get-bucket-versioning` and `get-bucket-location`, **and** for the seven pinned
global flags listed under *OSS trust target* below; otherwise the wrapper fails
closed.

### OSS trust target (CLI-pinned, EcsRamRole only)

The trust model identifier is `CLI_PINNED_PROOF_TREE_CONFIG_ECS_RAM_ROLE`. Every
network-capable `ossutil` invocation is issued through one canonical CLI trust
target; ambient configuration is impossible by construction:

```bash
ossutil --config-file <proof-tree config> \
  --region cn-hongkong \
  --endpoint https://oss-cn-hongkong-internal.aliyuncs.com \
  --mode EcsRamRole --ecs-role-name <observed live role> \
  --addressing-style virtual --ignore-env-var \
  api <operation> ...
```

- **Endpoint.** The frozen endpoint is the HTTPS **in-region internal** endpoint
  (`endpoint_class=INTERNAL`, `network_policy=SAME_REGION_INTERNAL_ONLY`). No
  public, cross-region or caller-selected endpoint is ever used.
- **Authentication.** `EcsRamRole` only. The harness never carries an
  AK/SK, STS token or explicit RAM role ARN: `--access-key-id`,
  `--access-key-secret`, `--sts-token`, `--ram-role-arn` and
  `--role-session-name` are structurally absent, and TLS verification is never
  disabled (`--skip-verify-cert` is never used).
- **Role name.** The role name is **observed read-only at runtime** from the
  IMDS role-name LIST endpoint
  (`meta-data/ram/security-credentials/`). Zero roles, multiple roles, control
  characters, a CR or a path-like value all fail closed. The credential-payload
  endpoint is never requested.
- **Configuration.** `scripts/config/m8-ossutil-formal.ini` is a **proof-tree
  inert config** (22 bytes, `[default]` + `language=EN` only) with a frozen
  SHA-256. It must be a regular, non-symlinked, in-worktree file with exactly
  that byte identity, and it must declare no other key. There is **no fallback**
  to `~/.ossutilconfig` or to any caller-selected profile.
- **Closed environment.** Nineteen ambient OSS/credential/proxy variable names
  constitute a closed trust environment
  (`m8-oss-env-closed/v1`). If any one is set — including
  `M8_OSSUTIL_CONFIG_FILE`, every `OSS_*` credential and endpoint selector,
  `OSSUTIL_CONFIG_FILE`, `OSSUTIL_PROFILE`, `ALIBABA_CLOUD_ECS_METADATA` and the
  upper- and lower-case proxy families — the entrypoint **FAILS CLOSED** before
  any provider access, authorization processing, host-state or evidence write,
  naming the offending variable but never echoing its value. This is a separate
  authority from the seven synthetic override seams; the two lists are never
  merged. `--ignore-env-var` additionally makes the pinned CLI ignore
  `OSS_`-prefixed variables.
- **ossutil identity.** The resolved `ossutil` must be an executable regular
  file; its absolute path, parsed `major.minor.patch` version and SHA-256 of the
  resolved bytes are recorded at runtime. Versions below **2.2.0** (the floor
  for `--ignore-env-var`) and unparseable banners fail closed.
- **Bucket location.** A read-only `GetBucketLocation` must report the frozen
  region; otherwise the run fails closed **before any `PutObject`**.

#### OSS trust profile

The observed bindings are serialized into an 18-record `key=value` profile
(`linguagraph-m8-oss-trust-profile/v1`) in a frozen field order, UTF-8, one LF
per record and exactly one final LF, with no CR, NUL or BOM. Its digest is
`SHA256` of those exact bytes — never a caller-supplied value and never a JSON
canonicalization. The digest is bound before the claim:

1. the future Human-issued authorization must declare the same
   `oss_trust_profile_sha256` (missing, malformed or different fails closed);
2. the atomic `claim.json`, the sealed `package-index.json` and the
   `closure-receipt.json` all carry it, the receipt both at top level and in
   `cross_binding`;
3. `verify-m8-closure-receipt.py` checks both carriers and accepts
   `--expect-oss-trust-profile-sha256` for an independent Human expectation; and
4. a durability retry must observe the same profile as the sealed semantic run,
   and fails closed on any mismatch.

No `PutObject` may occur before every trust-target step has succeeded; the first
permitted mutating call of a formal run is the atomic claim.

#### Live bindings this repository does NOT establish

The following eight values are **live, unbound and unproven** here. They are
resolved at runtime and are deliberately never hard-coded in this repository or
in this document: the canonical OSS **bucket name**; the **ECS RAM role name**;
the **observed role identity**; the **RAM policy result**; the **ossutil path**;
the **ossutil version**; the **ossutil binary SHA-256**; and the **live
capability result** (including bucket location and versioning).

Nothing in this repository asserts that the bucket exists, that a role is
attached to any instance, that any RAM policy has been proven, that `ossutil` is
installed, or what its live path, version or binary hash is. No Gate 2 claim is
made, no authorization has been issued for a formal run, and no formal run has
been executed or completed. The profile digest shown by any local verification
run is a synthetic fixture value, not a live binding.

### Critical OSS versioning guard

`x-oss-forbid-overwrite` is only correct on an **unversioned** bucket. Before
any claim, archive, index or receipt `PutObject`, the wrapper queries bucket
versioning read-only and accepts only Unversioned / Null / an equivalent
empty-status API response. `Enabled`, `Suspended`, unknown, unparseable and
access-denied all **FAIL CLOSED**. The harness never changes versioning: it has
no `PutBucketVersioning` authority.

### ISSUER / EXECUTOR authority split (documented, not provisioned)

```text
ISSUER
  may create immutable authorizations/<sha>/issued.json
  needs no other OSS permission

EXECUTOR
  may read issued.json
  may create exactly the claim/run/index/receipt objects required by its
    authorization, with create-if-absent semantics
  may Get / Head objects
  may GetBucketVersioning
  MUST NOT require DeleteObject
  MUST NOT require PutBucketVersioning
  MUST NOT require creation or overwrite of issued.json
```

No RAM/provider policy mutation is authorized or performed by this repository.

### Single-use claim

Before any semantic execution the wrapper retrieves `issued.json` and validates
the authorization kind, the `authorization_sha256` binding to the presented
token digest, proof SHA/tree, candidate SHA/tree/parent, frozen main, provider
identity tuple, authorized executor ID and `single_use=true`. It then creates
`claim.json` atomically. An existing claim **FAILS CLOSED**: there is no expiry,
takeover, lease, fencing-token renewal or re-arming. A claim with no valid
receipt is **INDETERMINATE** for authorization-governance purposes, and the same
semantic authorization can never be rerun.

### Execution / seal / durability / commit

* **PHASE A** executes the adapter, cross-checks the RC records, requires a
  `PASS` outcome and validates strict artifact closure: the actual regular files
  in the evidence root, minus the seal-phase `artifact-manifest.sha256`, must
  equal the canonical required set exactly. A missing required artifact and an
  unexpected/unclassified artifact are both fatal.
* **PHASE B** generates `artifact-manifest.sha256`, validates that the manifest
  entry set equals the required set exactly and that every recorded digest
  matches the file on disk, creates exactly one deterministic canonical archive,
  and generates `package-index.json` locally exactly once. The pre-existing
  deterministic tar/gzip semantics are retained; archive file modes are **not**
  normalised in R2. After the archive digest is fixed, the archive, manifest,
  execution artifacts, `outcome.txt` and `package-index.json` are never mutated
  or rebuilt.
* **PHASE C** uploads create-if-absent and reads back: object size, archive
  SHA-256, embedded artifact manifest, and `package-index.json` contents. A
  durability failure produces **no** receipt.
* **PHASE D** constructs the canonical `closure-receipt.json` locally, creates it
  with no-overwrite, reads it back and requires the fetched bytes/SHA-256 to
  equal the locally constructed receipt exactly. Only then is
  `formal_command_rc` parsed, required to be `0`, and
  `HSDR_F02_FORMAL_RUN_COMMAND_RC=0` printed. Any byte/hash mismatch fails closed
  and prints no formal RC.

The receipt records only `closure_outcome=PASS`; there is no FAIL or
INDETERMINATE receipt. Failure state is "claim exists, receipt absent". The
receipt carries no redundant `terminal_line` field: the terminal marker is
emitted once by the wrapper process and is not embedded in the receipt.

Receipt self-consistency is enforced by `cross_binding.*` fields which mirror
the sealed archive digest, the archive digest recorded inside the package index,
the manifest digest, the exact issued-document digest and the claim digest.
`authorization_sha256` itself is the token identity and is never mirrored as an
"authorization object" digest, because it is not one.

### Artifact completeness (strict set closure)

`scripts/verify-m8-artifact-completeness.py` owns two explicit responsibilities;
presence-only checking is not sufficient and is not what is implemented.

```text
A. required-set validation (pre-seal)
   scripts/lib/m8-required-artifacts.txt is parsed as a canonical EXPLICIT
   relative-path set. Duplicate entries, absolute paths, '.', '..', any '..'
   traversal component, empty components, './' prefixes, backslash separators
   and shell-glob entries are rejected. Blank/comment lines are ignored
   deterministically. The reserved manifest name may not be listed.

B. pre-seal actual-set closure
   actual regular files under the evidence root, minus artifact-manifest.sha256,
   must EQUAL the required set exactly:
     * missing required file            -> FAIL CLOSED
     * unexpected/unclassified file     -> FAIL CLOSED
   The archive, archive sidecar, package-index.json and closure-receipt.json are
   seal/commit outputs outside the evidence root and are never members.

C. manifest set/hash validation (post-manifest)
   every manifest path must be relative, normalized, non-traversing and
   non-duplicated; the manifest must not hash itself; the manifest entry set
   must equal the required set exactly; and every recorded digest must equal the
   SHA-256 of the actual file. Any mismatch -> FAIL CLOSED.
```

The Python verifier is the completeness authority. `m8_manifest_verify` in
`scripts/lib/m8-manifest.sh` remains as an additional byte-identical recompute
defence after sealing; it does not replace the set/hash validation above.

### Committed re-invocation

If a valid closure receipt already exists for an authorization, the wrapper does
not re-execute, does not re-emit the formal RC marker and does not return a
synthetic success: it hard-refuses with a distinct `ALREADY_COMMITTED`
diagnostic and a non-zero status. Read-only historical verification belongs to
`scripts/verify-m8-closure-receipt.py`, not to the wrapper.

### Durability retry

A durability retry requires a distinct authorization with
`authorization_kind=DURABILITY_RETRY` and a new authorization hash, whose
`issued.json` binds the semantic authorization SHA, proof SHA/tree, exact
canonical run path, expected archive SHA-256, expected package-index SHA-256 and
authorized executor ID. A retry may only read the pre-existing exact sealed
archive and package index, verify the bound digests, upload missing canonical
objects create-if-absent, read back, verify and create the one canonical closure
receipt if eligible. It must never rerun the core or adapter, modify evidence or
outcome, modify the manifest, rebuild the archive, regenerate the package index,
or reuse a semantic authorization. If the package index is missing locally, or
the archive is missing locally and not already durably present, the retry is not
eligible and stops for Human reconciliation.

## Playwright runtime evidence

The Product's `playwright.config.ts` is not touched. Formal invocation keeps the
seven frozen specs and exports:

```bash
export CI=1
export PLAYWRIGHT_JSON_OUTPUT_FILE="$EVIDENCE/playwright-json-report.json"

npx playwright test \
  <seven exact specs> \
  --retries=0 --fail-on-flaky-tests --reporter=list,json
```

Exactly one `--reporter` option is used. The reporter runs with rootDir
`<candidate>/apps/web`, so the JSON reporter's suite `file` values are relative
to that rootDir and are exactly `e2e/<name>.spec.ts`; `apps/web/e2e/...` is never
expected inside the JSON report. The exact JSON report is parsed with Python
stdlib by `scripts/verify-m8-playwright-json.py`, which requires every
`config.projects[*].retries == 0`, project names `== {"chromium"}`,
`stats.expected == 34`, `stats.unexpected == 0`, `stats.flaky == 0` and
`stats.skipped == 0`, and that the report's normalized spec-file **set equals**
the seven frozen spec paths exactly — never a suffix or basename match, so a
duplicated basename elsewhere cannot be accepted. Only then is
`playwright-effective-retries.txt` atomically written with exactly
`PLAYWRIGHT_EFFECTIVE_RETRIES=0`. A missing, unparseable or mismatching report
fails closed. Raw-log count guards are secondary only.

## Preparation-time suite guards

These are guards for the bound Product tree, not proof results:

```text
pytest:       602 passed
Vitest:       533 passed
Playwright:    34 passed
```

A formal run must actually produce those results. The frontend stage also runs
the three M8 routing-focused Vitest files with the verbose reporter and fails
closed unless every frozen routing label `R-G01` through `R-G21` appears in
executed test output. The backend JUnit proof retains all 15 M7 PostgreSQL
concurrency cases.

## Harness

```text
scripts/run-m8-proof.sh                 THE formal entrypoint (phases A-D)
scripts/run-m8-proof-alibaba-ecs.sh     formal execution adapter (no authority)
scripts/run-m8-proof-core.sh            provider-neutral semantic Gate 2 core
scripts/preflight-m8-alibaba-ecs.sh     read-only provider-binding preflight

scripts/lib/m8-synthetic-seams.sh       offline seam set + production rejection
scripts/lib/m8-provider-identity.sh     reviewed identity + read-only IMDS verify
scripts/lib/m8-oss.sh                   ossutil api client, guards, no-overwrite
scripts/lib/m8-manifest.sh              manifest / archive / canonical JSON
scripts/lib/m8-required-artifacts.txt   canonical required PHASE A artifact set
scripts/lib/m8-receipt-fields.txt       required closure-receipt fields

scripts/verify-m8-playwright-json.py    frozen Playwright runtime evidence
scripts/verify-m8-artifact-completeness.py  required-artifact completeness
scripts/verify-m8-closure-receipt.py    read-only historical receipt verification

tests/run-static-verification.sh        offline V01-V40 + R2D C01-C08 checks
tests/fixtures/                         synthetic ossutil stub + Playwright JSON
```

Independent M8 namespaces:

```text
evidence env:       M8_PROOF_EVIDENCE_DIR
semantic auth env:  M8_PROOF_RUN_AUTHORIZATION       (exact authorization TOKEN)
retry auth env:     M8_PROOF_RETRY_AUTHORIZATION     (exact retry TOKEN)
executor env:       M8_EXECUTOR_ID                   (alibaba-ecs:<instance-id>)
host state env:     M8_PROOF_HOST_STATE
fixed host state:   ~/.local/state/linguagraph-m8-proof
PostgreSQL name:    linguagraph-m8-proof-postgres
```

No M6/M7 authorization or spent-token namespace is valid here.

## Offline / synthetic verification

```bash
bash tests/run-static-verification.sh
```

This runs only `bash -n` checks, structural invariants, Python stdlib fixture
tests, and synthetic shell fixtures against a local stub ossutil. It never calls
a provider API, Alibaba OSS, Playwright, pytest, Vitest or a Product build, and
installs nothing.

The harness exposes a closed set of seven offline synthetic seams, all owned by
`scripts/lib/m8-synthetic-seams.sh`:

```text
M8_SYNTHETIC_TEST_MODE       umbrella offline mode
M8_IMDS_BASE_URL             redirected metadata endpoint
M8_IMDS_CURL_BIN             redirected metadata client executable
M8_OSSUTIL_BIN               stub object-store client
M8_OSSUTIL_GET_OUTPUT_FLAG   alternative get-object response-body flag
M8_ADAPTER_SCRIPT_OVERRIDE   synthetic formal-execution adapter
M8_PYTHON_BIN                alternative interpreter for verifier programs
```

They exist only so the offline verification can drive the same code paths
without a provider. Formal eligibility is exactly:

```text
all listed variables unset      -> eligible
any listed variable non-empty   -> FAIL CLOSED (no claim, no evidence tree,
                                   no canonical object, no formal marker)
```

This synthetic seam authority is **separate** from the nineteen-name closed OSS
trust-environment authority described under *OSS trust target*. Both live in the
same shared library as two distinct arrays and are never merged; the trust
environment is additionally rejected in production, where the synthetic seams
are not.

Both production entrypoints call `m8_reject_synthetic_overrides()` before any
external I/O or host-state mutation: the formal wrapper
(`scripts/run-m8-proof.sh`) as its first action, and the formal execution
adapter (`scripts/run-m8-proof-alibaba-ecs.sh`) before its formal-context
guards, so a redirected metadata client/endpoint or a stub object store can
never impersonate the formal provider identity. Only the offending variable name
is reported; no seam value is printed.

`M8_SYNTHETIC_TEST_MODE=1` additionally requires an explicit `M8_OSSUTIL_BIN`
override (so it cannot silently use the provisioned binary), permits redirected
evidence/host-state paths, and **never** prints
`HSDR_F02_FORMAL_RUN_COMMAND_RC`; it prints `M8_SYNTHETIC_OUTCOME=OK` instead. It
must never be used with real credentials, and it does not bypass the durable
single-use claim.

The suite reports its results as independent counters so that a green legacy
baseline can never be mistaken for trust-target evidence:

```text
R2E_B01_LEGACY_V01_V40=40/40
R2E_B01_CORRECTION_REGRESSIONS=9/9
R2E_B01_STATIC_CHECKS=11/11
R2E_B01_SYNTHETIC_CHECKS=29/29
R2I_C1_REGRESSIONS=2/2
R2I_C4_B03_REGRESSIONS=12/12
```

`T01..T12` are the R2I-C4/B03 trust-target regressions: the closed
trust-environment set, CLI trust-target pinning, canonical config identity,
ossutil identity and version floor, bucket-location guard, read-only role-name
observation, trust-profile canonicalization and digest sensitivity,
authorization/claim/package-index/receipt binding, receipt verification, retry
trust-target identity, and pre-claim ordering. Each is separately load-bearing:
removing its production mechanism in a scratch copy makes that check fail.

## Mutation boundary

This repository may contain proof harness/evidence logic only. Preparation and
later proof execution do not authorize:

```text
NO Product repository mutation
NO Product main/branch movement
NO PR
NO merge
NO reuse of M6/M7 run authorization
NO unreviewed provider identity substitution
NO OSS bucket/object mutation outside a formally authorized run
NO credential provisioning or RAM policy mutation
```

## Preflight

After this preparation source is independently audited, clone the exact proof
repository on the intended ECS host and run:

```bash
bash scripts/preflight-m8-alibaba-ecs.sh
```

The preflight is discovery-only. It does not install packages, bootstrap Docker,
consume a one-shot run authorization, create formal proof evidence, or mutate
either GitHub repository or any OSS object. Re-running it is diagnostic only and
does not itself authorize formal execution.

Formal execution of the successor is still **not authorized**. It requires
separate Human approval of the exact proof commit/tree and a fresh one-shot
authorization issued into the durable authorization namespace.
