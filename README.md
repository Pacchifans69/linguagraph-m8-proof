# LinguaGraph M8 external proof

This repository is independent proof infrastructure for **M8 — Alignment
Connector Obstacle-Avoiding Routing**. It must not modify the LinguaGraph
Product repository.

## Status

```text
checkpoint:           M8
proof path:           M8-EXI-01 — Alibaba ECS alternate hosted Gate 2
proof source:         PREPARED
provider binding:     NOT YET ESTABLISHED
formal run auth:      NOT ISSUED
formal execution:     NOT EXECUTED
Gate 2:               NOT ESTABLISHED
```

The Product's canonical GitHub Actions run for this exact candidate was retried
and again failed before every repository-defined step (`runner_id=0`,
`runner_name=""`, `steps=[]`). That is provider/pre-step diagnostic evidence,
not application/test evidence.

## Exact Product binding

```text
repository:     Pacchifans69/LinguaGraph
branch:         m8-alignment-connector-obstacle-avoiding-routing
candidate SHA:  078d3ed11f33716578bcee6a3f4801319c79fe8d
candidate tree: 2d7903158406349cc2c70d45b5cf496e4b2bf495
unique parent:  72398371c605f909ff8f02aedcc521e8c2ba6a23
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

## Provider binding boundary

This preparation source is intentionally **not executable as a formal Alibaba
proof**. The adapter contains `PROVIDER_BINDING_READY=NO` and immutable provider
identity fields set to `UNBOUND`.

The next stage is an independent static audit of this proof-source commit, then
a live Alibaba ECS preflight that establishes exact immutable identity:

```text
instance ID
region
zone
instance type
image ID
```

A later bounded proof-repo commit may bind only that reviewed identity. Formal
execution still requires separate Human approval of the resulting exact proof
SHA/tree and a fresh one-shot M8 run authorization.

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
