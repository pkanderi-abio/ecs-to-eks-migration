#!/usr/bin/env python3
"""
ecs-task-to-k8s-manifest.py
============================
Converts ECS Task Definitions → Kubernetes Deployment + Service YAML manifests.
Used to generate the initial k8s manifests during the ECS → EKS migration.

Real usage: 47 ECS task definitions → 47 Deployment manifests in ~3 minutes

Usage:
    # Convert all services in a cluster
    python3 ecs-task-to-k8s-manifest.py \\
        --cluster prod-ecs-cluster \\
        --region us-east-1 \\
        --output-dir ./k8s-generated

    # Convert a single task definition
    python3 ecs-task-to-k8s-manifest.py \\
        --task-def api-gateway:42 \\
        --region us-east-1 \\
        --output-dir ./k8s-generated
"""
import argparse
import json
import os
import sys
from pathlib import Path

import boto3
import yaml

# Mapping: ECS CPU units → K8s resource strings
# ECS uses integer units; K8s uses millicores for requests, cores for limits
def ecs_cpu_to_k8s(cpu_units: int) -> dict:
    """Convert ECS CPU units to K8s request/limit."""
    millicores = cpu_units  # 1024 ECS units = 1 vCPU = 1000m
    return {
        "requests": f"{millicores}m",
        "limits":   f"{millicores * 2}m",  # allow burst to 2x request
    }

def ecs_mem_to_k8s(mem_mib: int) -> dict:
    """Convert ECS memory MiB to K8s request/limit."""
    return {
        "requests": f"{mem_mib}Mi",
        "limits":   f"{int(mem_mib * 1.5)}Mi",  # allow 1.5x burst
    }

def convert_env_vars(env_list: list) -> list:
    """Convert ECS environment array to K8s env format."""
    k8s_env = []
    for e in env_list or []:
        k8s_env.append({"name": e["name"], "value": e["value"]})
    return k8s_env

def convert_secrets(secrets_list: list, service_name: str) -> list:
    """
    Convert ECS secrets (SSM references) to K8s secretKeyRef.
    Assumes migrate-ssm-to-secrets.sh has already created SM secrets.
    """
    env_from_secret = []
    for s in secrets_list or []:
        # ECS: arn:aws:ssm:us-east-1:123:parameter/prod/svc/KEY
        # K8s: secretKeyRef pointing to ExternalSecret-synced K8s secret
        key_name = s["name"]
        env_from_secret.append({
            "name": key_name,
            "valueFrom": {
                "secretKeyRef": {
                    "name": f"{service_name}-secrets",  # ExternalSecret target name
                    "key":  key_name,
                }
            }
        })
    return env_from_secret

def convert_port_mappings(port_mappings: list) -> list:
    """Convert ECS port mappings to K8s container ports."""
    ports = []
    for pm in port_mappings or []:
        port_entry = {"containerPort": pm.get("containerPort", pm.get("hostPort", 80))}
        if pm.get("protocol"):
            port_entry["protocol"] = pm["protocol"].upper()
        ports.append(port_entry)
    return ports

def convert_health_check(health_check: dict) -> dict:
    """Convert ECS healthCheck to K8s livenessProbe."""
    if not health_check:
        return {}
    command = health_check.get("command", [])
    # ECS: ["CMD", "curl", "-f", "http://localhost/health"]
    # Strip "CMD" or "CMD-SHELL" prefix
    if command and command[0] in ("CMD", "CMD-SHELL"):
        command = command[1:]
    return {
        "exec": {"command": command},
        "initialDelaySeconds": health_check.get("startPeriod", 30),
        "intervalSeconds": health_check.get("interval", 30),
        "timeoutSeconds": health_check.get("timeout", 5),
        "retries": health_check.get("retries", 3),
    }

def task_def_to_deployment(task_def: dict, service_name: str, namespace: str = "platform") -> dict:
    """Convert an ECS task definition to a Kubernetes Deployment manifest."""
    # Use the first container definition (primary container)
    containers = task_def.get("containerDefinitions", [])
    if not containers:
        raise ValueError(f"No container definitions in task: {service_name}")

    main_container = containers[0]

    # Build K8s container spec
    k8s_container = {
        "name": service_name,
        "image": main_container.get("image", f"123456789.dkr.ecr.us-east-1.amazonaws.com/{service_name}:latest"),
        "imagePullPolicy": "Always",
        "ports": convert_port_mappings(main_container.get("portMappings", [])),
        "env": (
            convert_env_vars(main_container.get("environment", [])) +
            convert_secrets(main_container.get("secrets", []), service_name)
        ),
        "resources": {
            "requests": {
                "cpu":    ecs_cpu_to_k8s(task_def.get("cpu", 512))["requests"],
                "memory": ecs_mem_to_k8s(task_def.get("memory", 1024))["requests"],
            },
            "limits": {
                "cpu":    ecs_cpu_to_k8s(task_def.get("cpu", 512))["limits"],
                "memory": ecs_mem_to_k8s(task_def.get("memory", 1024))["limits"],
            },
        },
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 1000,
            "readOnlyRootFilesystem": True,
            "allowPrivilegeEscalation": False,
            "capabilities": {"drop": ["ALL"]},
        },
        "lifecycle": {
            "preStop": {"exec": {"command": ["/bin/sh", "-c", "sleep 10"]}}
        },
    }

    # Add health checks if defined
    hc = convert_health_check(main_container.get("healthCheck"))
    if hc:
        k8s_container["livenessProbe"] = hc
        k8s_container["readinessProbe"] = {
            **hc,
            "initialDelaySeconds": max(hc.get("initialDelaySeconds", 30) - 10, 5),
        }
    else:
        # Default HTTP health check — adjust path per service
        k8s_container["readinessProbe"] = {
            "httpGet": {"path": "/health/ready", "port": 8080},
            "initialDelaySeconds": 10,
            "periodSeconds": 5,
            "failureThreshold": 3,
        }
        k8s_container["livenessProbe"] = {
            "httpGet": {"path": "/health/live", "port": 8080},
            "initialDelaySeconds": 30,
            "periodSeconds": 15,
            "failureThreshold": 3,
        }

    # Add sidecar containers if present (e.g., envoy, fluentbit)
    sidecars = []
    for sidecar in containers[1:]:
        sidecars.append({
            "name": sidecar.get("name", "sidecar"),
            "image": sidecar.get("image", ""),
            "resources": {
                "requests": {"cpu": "50m", "memory": "64Mi"},
                "limits":   {"cpu": "200m", "memory": "256Mi"},
            },
        })

    deployment = {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": service_name,
            "namespace": namespace,
            "labels": {
                "app": service_name,
                "app.kubernetes.io/name": service_name,
                "app.kubernetes.io/managed-by": "ecs-migration-tool",
                "migration.source": "ecs",
            },
            "annotations": {
                "migration.ecs/task-definition": task_def.get("taskDefinitionArn", ""),
                "migration.ecs/family": task_def.get("family", service_name),
                "migration.ecs/revision": str(task_def.get("revision", 0)),
            },
        },
        "spec": {
            "replicas": 2,  # start conservative; KEDA/HPA takes over
            "selector": {
                "matchLabels": {"app": service_name}
            },
            "template": {
                "metadata": {
                    "labels": {
                        "app": service_name,
                        "version": "migrated",
                    },
                    "annotations": {
                        "prometheus.io/scrape": "true",
                        "prometheus.io/port":   "9090",
                    },
                },
                "spec": {
                    "serviceAccountName": service_name,
                    "terminationGracePeriodSeconds": 60,
                    "securityContext": {
                        "runAsNonRoot": True,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "topologySpreadConstraints": [
                        {
                            "maxSkew": 1,
                            "topologyKey": "topology.kubernetes.io/zone",
                            "whenUnsatisfiable": "DoNotSchedule",
                            "labelSelector": {"matchLabels": {"app": service_name}},
                        }
                    ],
                    "containers": [k8s_container] + sidecars,
                },
            },
            "strategy": {
                "type": "RollingUpdate",
                "rollingUpdate": {
                    "maxSurge": "25%",
                    "maxUnavailable": 0,
                },
            },
        },
    }
    return deployment

def task_def_to_service(service_name: str, port: int = 8080, namespace: str = "platform") -> dict:
    """Generate a K8s Service manifest."""
    return {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": service_name,
            "namespace": namespace,
            "labels": {"app": service_name},
        },
        "spec": {
            "selector": {"app": service_name},
            "ports": [
                {"name": "http", "port": 80, "targetPort": port, "protocol": "TCP"},
                {"name": "metrics", "port": 9090, "targetPort": 9090, "protocol": "TCP"},
            ],
            "type": "ClusterIP",
        },
    }

def get_ecs_services(cluster_name: str, region: str) -> list:
    """List all ECS services in a cluster."""
    ecs = boto3.client("ecs", region_name=region)
    paginator = ecs.get_paginator("list_services")
    service_arns = []
    for page in paginator.paginate(cluster=cluster_name, launchType="FARGATE"):
        service_arns.extend(page["serviceArns"])
    for page in paginator.paginate(cluster=cluster_name, launchType="EC2"):
        service_arns.extend(page["serviceArns"])
    return service_arns

def get_task_definition(task_def_arn: str, region: str) -> dict:
    """Fetch a task definition from ECS."""
    ecs = boto3.client("ecs", region_name=region)
    response = ecs.describe_task_definition(taskDefinition=task_def_arn)
    return response["taskDefinition"]

def main():
    parser = argparse.ArgumentParser(description="Convert ECS Task Definitions to K8s Deployment manifests")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--cluster",  help="ECS cluster name (converts all services)")
    group.add_argument("--task-def", help="Single ECS task definition ARN or name:revision")
    parser.add_argument("--region",     default="us-east-1")
    parser.add_argument("--namespace",  default="platform")
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    converted = 0; errors = 0

    def process_task_def(task_def_arn: str, service_name: str):
        nonlocal converted, errors
        try:
            task_def = get_task_definition(task_def_arn, args.region)
            deployment = task_def_to_deployment(task_def, service_name, args.namespace)
            service    = task_def_to_service(service_name, namespace=args.namespace)

            output_file = output_dir / f"{service_name}.yaml"
            with open(output_file, "w") as f:
                yaml.dump(deployment, f, default_flow_style=False, sort_keys=False)
                f.write("---\n")
                yaml.dump(service, f, default_flow_style=False, sort_keys=False)

            print(f"✅ {service_name} → {output_file}")
            converted += 1
        except Exception as e:
            print(f"❌ {service_name}: {e}", file=sys.stderr)
            errors += 1

    if args.cluster:
        ecs = boto3.client("ecs", region_name=args.region)
        service_arns = get_ecs_services(args.cluster, args.region)
        print(f"Found {len(service_arns)} services in cluster '{args.cluster}'")

        # Batch describe (max 10 per call)
        for i in range(0, len(service_arns), 10):
            batch = service_arns[i:i+10]
            response = ecs.describe_services(cluster=args.cluster, services=batch)
            for svc in response["services"]:
                svc_name  = svc["serviceName"]
                task_arn  = svc["taskDefinition"]
                process_task_def(task_arn, svc_name)
    else:
        svc_name = args.task_def.split(":")[0].split("/")[-1]
        process_task_def(args.task_def, svc_name)

    print(f"\n── Summary ──")
    print(f"Converted: {converted}")
    print(f"Errors:    {errors}")
    sys.exit(1 if errors > 0 else 0)

if __name__ == "__main__":
    main()
