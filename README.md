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
again failed before every repository-defined step (`runner_id=0`,
`runner_name=""`, `steps=[]`). That is provider/pre-step diagnostic evidence,
not application/test evidence.

The predecessor candidate `078d3ed11f33716578bcee6a3f4801319c79fe8d` completed one formal hosted
proof attempt: all backend, migration, routing, Vitest, and build evidence passed,
while Playwright finished 33/34 on a body-scroll assertion later classified as a
contract false positive. Its one-shot authorization is spent and is not valid
for this successor.

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

The provider-neutral core fails closed unless the remote Product branch, remote
main, detached checkout, tree, unique parent, frozen-main ancestry, and reviewed
15-file candidate scope all match these exact values.

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
executed test output.

The backend JUnit proof retains all 15 M7 PostgreSQL concurrency cases because
they remain part of the inherited release baseline.

## Harness

```text
scripts/run-m8-proof-core.sh
  provider-neutral semantic Gate 2 core

scripts/run-m8-proof-alibaba-ecs.sh
  Alibaba ECS identity / one-shot authorization adapter
```

The core owns:

- exact Product SHA/tree/parent/main guards and clean detached checkout;
- exact reviewed M8 candidate file-scope guard;
- Python 3.13, Node 24.17.0, uv 0.12.10, PostgreSQL 18;
- frozen dependency installation;
- empty database → Alembic 0006, current, and alembic check;
- full PostgreSQL pytest with zero skipped/xfailed/xpassed/deselected tests;
- retained M7 concurrency JUnit presence checks;
- lint/typecheck;
- targeted M8 R-G01…R-G21 execution evidence;
- full Vitest count guard;
- production build;
- full seven-spec Playwright release surface with retries=0 and 34-path guard;
- dependency hashes, candidate-tree cleanliness, disposable-DB cleanup;
- final remote Product guards.

Independent M8 namespaces:

```text
evidence env:       M8_PROOF_EVIDENCE_DIR
run auth env:       M8_PROOF_RUN_AUTHORIZATION
host state env:     M8_PROOF_HOST_STATE
fixed host state:   ~/.local/state/linguagraph-m8-proof
PostgreSQL name:    linguagraph-m8-proof-postgres
authorization:      M8-EXI-01-RUN-<approved-proof-sha-prefix>-<nonce>
```

No M6/M7 authorization or spent-token namespace is valid here.

## Provider binding

The read-only Alibaba ECS preflight passed at
`2026-09-20T08:11:52Z` and established the reviewed immutable execution
identity:

```text
instance ID:   i-j6c9854oyawy89fcdxy2
region:        cn-hongkong
zone:          cn-hongkong-d
instance type: ecs.g9i.xlarge
image ID:      ubuntu_24_04_x64_20G_alibase_20260916.vhd
```

Additional observed provenance:

```text
identity document SHA-256:
60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d

identity PKCS7 SHA-256:
89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211

VPC:           vpc-j6cgz9a4frhl3oxxbecsj
vSwitch:       vsw-j6c9f1ch565yr60wzx2rc
private IPv4:  172.23.68.216
EIP:           47.238.211.55
```

The adapter now fails closed unless the immutable provider tuple and identity
hashes match these reviewed values. Network addresses are recorded as
provenance but are not used as immutable execution identity.

Formal execution of the successor is still **not authorized**. It requires
separate Human approval of the rebound exact proof SHA/tree and a fresh one-shot
M8 run authorization. The predecessor authorization remains spent and must not
be reused.

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
```

## Alibaba ECS provider-binding preflight

After this preparation source is independently audited, clone the exact proof
repository on the intended ECS host and run:

```bash
bash scripts/preflight-m8-alibaba-ecs.sh
```

The preflight is discovery-only. It does not install packages, bootstrap
Docker, consume a one-shot run authorization, create formal proof evidence, or
mutate either GitHub repository. The reviewed preflight above is now the
provider-binding authority for this proof source. Re-running it is diagnostic
only and does not itself authorize formal execution.
