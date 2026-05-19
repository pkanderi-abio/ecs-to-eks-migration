# AI Agent Guidance for ecs-to-eks-migration

## What this repository is
- A migration toolkit for moving 47 services from AWS ECS to AWS EKS.
- Infrastructure is managed with Terraform under `terraform/`.
- Kubernetes workloads are deployed with Helm charts in `helm/charts/` and platform tooling under `helm/platform/`.
- Runtime Kubernetes manifests and rollout policy templates live in `k8s/`.
- Migration helper scripts are in `scripts/`.
- Operational runbooks and incident postmortems are in `docs/`.

## Primary agent responsibilities
- Prefer editing `terraform/` for infra changes, `helm/charts/` for service deployment, and `k8s/` for cluster manifests and rollout policies.
- Use `README.md` and `docs/runbook-migration.md` as the main source of repository context and migration process.
- Preserve the migration safety model: EKS in the same VPC as ECS, canary traffic shifting via Route53, Argo Rollouts for auto-rollback, and ExternalSecrets for secrets sync.

## Key conventions
- `terraform/environments/` contains environment-specific cluster configuration.
- `terraform/modules/` contains reusable infrastructure modules like `eks-cluster`, `karpenter`, `alb-controller`, `external-dns`, and `vpc-cni-addon`.
- `helm/charts/<service>/` contains service-specific Helm charts.
- `helm/platform/` contains platform tooling configuration for Prometheus, Argo Rollouts, KEDA, and External Secrets.
- `k8s/external-secrets/` contains ExternalSecrets CRs that bridge AWS Secrets Manager to Kubernetes.
- `k8s/rollouts/` contains Argo Rollout analysis templates and rollout CRs.
- `scripts/traffic-shift.sh` and `scripts/validate-rollout.sh` are the supported migration workflow helpers.

## Useful workflows
- Infrastructure changes: edit Terraform code, then run `terraform fmt` and `terraform validate` in the relevant environment.
- Service deployment changes: update the matching Helm chart and values file, and account for platform-wide rollout semantics in `k8s/rollouts/`.
- Secret migration: do not invent a new secret workflow; use `scripts/migrate-ssm-to-secrets.sh` and the ExternalSecrets patterns already present.
- Migration workflow: generate Kubernetes manifests with `scripts/ecs-task-to-k8s-manifest.py`, create/update `k8s/external-secrets/<service>.yaml`, deploy with `helm upgrade --install`, validate with `scripts/validate-rollout.sh`, and shift traffic with `scripts/traffic-shift.sh`.
- Tenant deployment: use `helm/charts/tenant-template/helmfile.yaml` for per-tenant Helmfile deployments.

## What to avoid
- Do not treat this repo like a generic app repo with Java/Maven build steps; it is primarily Terraform/Helm/Kubernetes/shell/Python.
- Do not assume there is a Java/Maven build or artifact pipeline in this repo.
- Do not add broad infrastructure changes without considering the migration safety line: ECS and EKS must coexist during cutover.
- Do not create new service charts or namespaces without matching the existing `helm/charts` and `k8s/namespaces` conventions.

## Important references for the agent
- `README.md` — overall architecture, prerequisites, Quick Start, and repo structure.
- `docs/runbook-migration.md` — the migration playbook and per-service migration steps.
- `docs/incident-001-coredns.md`, `docs/incident-002-pvc-mount.md` — real incident prevention lessons.
- `.github/workflows/` — CI/CD patterns for terraform plan, Helm deploy, and rollback.

## When answering user questions
- Be explicit about which files or directories should be changed.
- If the user asks for commands, use the repo’s documented Terraform/Helm/kubectl/script workflow.
- If the user requests a new feature, map it to this repo’s scope: infra module, Helm service chart, rollout policy, or migration script.
