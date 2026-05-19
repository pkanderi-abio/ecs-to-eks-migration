# GitHub Copilot Instructions for ecs-to-eks-migration

This repository is an AWS ECS → EKS migration toolkit, not a Java application project.

## How to behave
- Use `AGENTS.md` and `SKILL.md` as the primary guidance sources.
- Focus on Terraform, Helm, Kubernetes, and shell/Python migration scripts.
- Avoid assuming any Java/Maven build or artifact pipeline exists in this repo.
- Preserve the migration safety model: same-VPC EKS, Route53 weighted traffic shift, Argo Rollouts, and ExternalSecrets.

## Where to make changes
- `terraform/` for cluster and platform infrastructure
- `helm/charts/` for service deployments
- `helm/platform/` for platform-level chart values
- `k8s/` for rollout and secret manifest CRs
- `scripts/` for migration automation and operational helpers

## Useful references
- `README.md` for architecture, repo structure, and quick start
- `docs/runbook-migration.md` for the migration process and per-service steps
- `docs/incident-001-coredns.md` and `docs/incident-002-pvc-mount.md` for incident prevention lessons
