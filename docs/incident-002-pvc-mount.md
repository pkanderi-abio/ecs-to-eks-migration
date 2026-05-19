# Incident 002 — EFS PVC Mount Timeout

**Severity:** P2  
**Date:** 2024-10-02 11:42 UTC  
**Duration:** 13 minutes (11:42–11:55 UTC)  
**Customer Impact:** Report delivery delayed 22 minutes for ~43 enterprise customers  
**SLA Breach:** No (SLA = 4h delivery time)  
**Root Cause:** EFS Security Group missing inbound rule for EKS node security group

---

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 11:42 | Karpenter provisions new Spot node (m6i.xlarge, us-east-1b) |
| 11:44 | report-generation-service pod scheduled on new node, stuck ContainerCreating |
| 11:46 | `kubectl describe pod` → "Unable to mount volumes: timeout after 120s" |
| 11:48 | RCA: EFS SG allows TCP 2049 from old ECS SG only, not from EKS node SG |
| 11:52 | Fix: `aws ec2 authorize-security-group-ingress` on EFS SG → EKS node SG |
| 11:55 | Pod mounts EFS successfully. Report jobs drain. |
| 12:17 | ~1,200 queued report jobs fully processed |

## Root Cause

The EFS filesystem used by report-generation-service was created when the workload ran on ECS. Its Security Group had a single inbound rule:

```
Inbound TCP 2049 from sg-xxxxxxxx (ECS EC2 instances SG)
```

When Karpenter provisioned a new EKS node, it used the EKS-specific node security group (`module.eks.node_security_group_id`), which was not in the EFS allow list. Existing nodes worked because they had pre-mounted the EFS volume before the Karpenter churn. The new node couldn't mount.

## Fix Applied

**Immediate (CLI):**
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-<EFS_SG_ID> \
  --protocol tcp \
  --port 2049 \
  --source-group sg-<EKS_NODE_SG_ID> \
  --region us-east-1
```

**Permanent (Terraform — prevents recurrence on node churn):**
```hcl
resource "aws_security_group_rule" "efs_from_eks_nodes" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
  security_group_id        = var.efs_security_group_id
  description              = "EFS NFS from EKS nodes (INCIDENT-002 fix)"
}
```

Now in `terraform/modules/eks-cluster/main.tf` and `terraform/environments/prod/terraform.tfvars`.

## Prevention

1. **Checklist item added:** EFS SG rule verification before any stateful service migration
2. **Terraform variable** `efs_security_group_id` added to eks-cluster module — rule created automatically
3. **CI validation** added in `validate-rollout.sh` — checks PVC mount status
