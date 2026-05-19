# ecs-to-eks-migration Skill

## Purpose
This skill helps AI agents work productively in the `ecs-to-eks-migration` repository by codifying the repository’s migration-focused conventions and safe change boundaries.

## When to use
- Making infrastructure changes in `terraform/`
- Updating service deployment manifests in `helm/charts/` or `k8s/`
- Adjusting platform tooling under `helm/platform/`
- Working on secret migration or migration helper scripts in `scripts/`
- Answering questions about repo conventions, migration workflow, or safe cutover patterns

## Core workflow
1. Read `README.md` and `docs/runbook-migration.md` first.
2. Identify the target area:
   - `terraform/` for cluster and platform infrastructure
   - `helm/charts/<service>/` for service deployment and rollout values
   - `k8s/` for Argo Rollouts, ExternalSecrets, network policies, and platform manifests
   - `scripts/` for migration automation and operational helpers
3. Preserve the migration safety model:
   - EKS must remain in the same VPC as ECS
   - Traffic shifts use Route53 weighted routing and `scripts/traffic-shift.sh`
   - Argo Rollouts control canary promotion and rollback
   - ExternalSecrets sync secrets from AWS Secrets Manager
4. Prefer existing patterns over new abstractions.
5. Follow the repo’s per-service migration sequence:
   1. Generate Kubernetes manifests with `scripts/ecs-task-to-k8s-manifest.py`.
   2. Create or update `k8s/external-secrets/<service>.yaml`.
   3. Deploy the service with `helm upgrade --install <service> ./helm/charts/<service>`.
   4. Validate rollout health with `scripts/validate-rollout.sh` and `kubectl` diagnostics.
   5. Shift traffic using `scripts/traffic-shift.sh`.
6. Validate infrastructure edits with `terraform fmt` and `terraform validate` in the relevant environment.

## Important conventions
- `terraform/environments/` contains environment-specific settings (`prod`, `staging`).
- `terraform/modules/` contains reusable modules for EKS, Karpenter, ALB Controller, External DNS, and VPC CNI.
- `helm/charts/<service>/` contains a service Helm chart and values file.
- `helm/platform/` contains cluster-level platform values for Prometheus, Argo Rollouts, KEDA, and External Secrets.
- `k8s/external-secrets/` holds ExternalSecret CRs that map Secrets Manager secrets into Kubernetes.
- `k8s/rollouts/` holds Argo Rollout definitions and analysis templates.
- `scripts/migrate-ssm-to-secrets.sh` is the approved secret migration path.

## What to avoid
- Do not treat this repo as a generic app repo with Java/Maven build steps.
- Do not assume there is a Java/Maven build pipeline in this repository.
- Do not add broad changes that violate the migration safety model.
- Do not create service charts, namespaces, or rollout CRs without following the existing Helm and `k8s/` structure.

## Example prompts
- "Add a new Helm values file for `billing-service` to use Argo Rollouts and ExternalSecrets."
- "Update the EKS module to expose the node security group ID for EFS access."
- "Fix the `scripts/traffic-shift.sh` logic to handle zero-weight rollback safely."

## Related customizations to add next
- `.github/copilot-instructions.md` for GitHub-hosted agent behavior
- A focused skill for `terraform/` changes only
- A focused skill for `helm/charts/` and `k8s/` migration deployment changes
