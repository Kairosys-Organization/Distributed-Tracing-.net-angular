# kubectl & EKS Operations Cheatsheet

## 1. Connect kubectl to the EKS Cluster

### Prerequisites
- AWS CLI installed and SSO credentials exported (see below)
- `kubectl` installed
- `eksctl` installed (optional, used for cluster management)

### Export AWS SSO credentials

Each SSO session lasts ~1 hour. Get a fresh set from the AWS Console → your account → **Access keys** (short-term credentials).

```bash
export AWS_ACCESS_KEY_ID="ASIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
```

Verify identity:
```bash
aws sts get-caller-identity
```

### Update kubeconfig

Registers the EKS cluster as a context in `~/.kube/config`:
```bash
aws eks update-kubeconfig --name pathfinder --region us-east-1
```

Verify the context was set:
```bash
kubectl config current-context
# Output: arn:aws:eks:us-east-1:002823001366:cluster/pathfinder
```

---

## 2. Namespace & Context

All Pathfinder workloads live in the `pathfinder` namespace.

```bash
# List all namespaces
kubectl get namespaces

# Set default namespace for current session (avoids typing -n pathfinder every time)
kubectl config set-context --current --namespace=pathfinder
```

---

## 3. Pods

```bash
# List all pods (all namespaces)
kubectl get pods -A

# List pods in pathfinder namespace
kubectl get pods -n pathfinder

# Wide output — shows node name and IP
kubectl get pods -n pathfinder -o wide

# Watch pods in real time
kubectl get pods -n pathfinder -w

# Describe a specific pod (events, image, resource requests, etc.)
kubectl describe pod <pod-name> -n pathfinder

# Describe all pods with a label
kubectl describe pod -n pathfinder -l app=ops-agent
```

---

## 4. Logs

```bash
# Logs for a specific pod
kubectl logs <pod-name> -n pathfinder

# Last N lines
kubectl logs <pod-name> -n pathfinder --tail=100

# Follow (stream) logs live
kubectl logs <pod-name> -n pathfinder -f

# Logs by label (all replicas)
kubectl logs -n pathfinder -l app=ops-agent --tail=100
kubectl logs -n pathfinder -l app=api --tail=50 -f

# Logs from a previous (crashed) container
kubectl logs <pod-name> -n pathfinder --previous

# All containers in a pod
kubectl logs <pod-name> -n pathfinder --all-containers=true
```

**App labels in pathfinder namespace:**

| Label (`-l app=`) | Component |
|---|---|
| `api` | PathfinderApi (.NET) |
| `newapp` | NewApp (.NET) |
| `ui` | Angular UI |
| `ops-agent` | AI trace consumer (Python) |
| `otel-collector` | OpenTelemetry Collector |
| `jaeger` | Jaeger UI + trace store |
| `rabbitmq` | RabbitMQ broker |

---

## 5. Exec into a Pod

```bash
# Open a shell in a running pod
kubectl exec -it <pod-name> -n pathfinder -- /bin/sh

# If the container has bash
kubectl exec -it <pod-name> -n pathfinder -- /bin/bash

# Run a one-off command without interactive shell
kubectl exec <pod-name> -n pathfinder -- env
kubectl exec <pod-name> -n pathfinder -- cat /etc/otelcol-contrib/config.yaml

# Exec into a specific container in a multi-container pod
kubectl exec -it <pod-name> -n pathfinder -c <container-name> -- /bin/sh
```

---

## 6. Services & Ingress

```bash
# List services
kubectl get svc -n pathfinder

# List ingress (ALB)
kubectl get ingress -n pathfinder

# Get ALB DNS hostname
kubectl get ingress -n pathfinder -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'

# Describe ingress (shows routing rules, annotations, events)
kubectl describe ingress pathfinder-ingress -n pathfinder
```

---

## 7. Deployments & Rollouts

```bash
# List deployments
kubectl get deployments -n pathfinder

# Check rollout status
kubectl rollout status deployment/api -n pathfinder

# Rollout history
kubectl rollout history deployment/api -n pathfinder

# Rollback to previous revision
kubectl rollout undo deployment/api -n pathfinder

# Restart a deployment (triggers a rolling redeploy)
kubectl rollout restart deployment/api -n pathfinder
```

---

## 8. ConfigMaps & Secrets

```bash
# List configmaps
kubectl get configmap -n pathfinder

# View a configmap
kubectl get configmap otel-collector-config -n pathfinder -o yaml

# List secrets
kubectl get secrets -n pathfinder

# Decode a secret value
kubectl get secret <secret-name> -n pathfinder -o jsonpath='{.data.<key>}' | base64 -d
```

---

## 9. Nodes

```bash
# List nodes with status
kubectl get nodes

# Wide output (shows instance type, internal IP)
kubectl get nodes -o wide

# Node resource usage (requires metrics-server)
kubectl top nodes

# Pod resource usage
kubectl top pods -n pathfinder

# Describe a node (capacity, allocatable, events)
kubectl describe node <node-name>
```

---

## 10. Events & Troubleshooting

```bash
# All events in namespace, sorted by time
kubectl get events -n pathfinder --sort-by='.lastTimestamp'

# Events for a specific pod
kubectl describe pod <pod-name> -n pathfinder | grep -A 20 Events

# Check why a pod is pending/crashlooping
kubectl describe pod <pod-name> -n pathfinder
kubectl logs <pod-name> -n pathfinder --previous
```

**Common pod statuses:**

| Status | Meaning |
|---|---|
| `Pending` | No node available or image not pulled yet |
| `ImagePullBackOff` | Wrong image name or missing ECR permissions |
| `CrashLoopBackOff` | Container keeps crashing — check logs |
| `OOMKilled` | Out of memory — increase resource limits |
| `Running` | Healthy |
| `Terminating` | Being deleted (force with `--grace-period=0` if stuck) |

---

## 11. Force Delete Stuck Resources

```bash
# Force delete a stuck pod
kubectl delete pod <pod-name> -n pathfinder --force --grace-period=0

# Force delete all pods in namespace
kubectl delete pod --all -n pathfinder --force --grace-period=0

# Remove finalizer from a stuck namespace
kubectl get namespace pathfinder -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw /api/v1/namespaces/pathfinder/finalize -f -
```

---

## 12. Helm Operations

```bash
# List releases in all namespaces
helm list -A

# Show rendered Helm values for current release
helm get values pathfinder -n pathfinder

# Show all rendered manifests for current release
helm get manifest pathfinder -n pathfinder

# Diff a pending upgrade (requires helm-diff plugin)
helm diff upgrade pathfinder ./pathfinder -n pathfinder

# Uninstall release
helm uninstall pathfinder -n pathfinder
```

---

## 13. Pathfinder Script Reference

| Script | Purpose |
|---|---|
| `helm/create-cluster.sh` | Create EKS cluster + AWS Load Balancer Controller |
| `helm/aws-deploy.sh` | Deploy / upgrade Pathfinder stack via Helm |
| `helm/undeploy-pathfinder.sh` | Remove Pathfinder workloads, keep cluster |
| `helm/destroy-cluster.sh` | Tear down entire cluster (keeps ECR) |

---

## 14. ALB Endpoints (current deployment)

| Service | URL |
|---|---|
| UI | `http://<ALB_DNS>/` |
| API Swagger | `http://<ALB_DNS>/api/swagger` |
| Jaeger | `http://<ALB_DNS>/jaeger` |
| OTel HTTP | `http://<ALB_DNS>/v1/traces` |

Get the current ALB DNS:
```bash
kubectl get ingress -n pathfinder -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```
