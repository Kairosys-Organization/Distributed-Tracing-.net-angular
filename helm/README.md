# Pathfinder Helm Chart

Deploy the entire Pathfinder distributed tracing stack to Kubernetes.

## Directory Structure

```
helm/
├── pathfinder/
│   ├── Chart.yaml              # Chart metadata
│   ├── values.yaml             # Default values (edit image names, env vars here)
│   └── templates/
│       ├── api.yaml            # .NET API (Deployment + Service)
│       ├── ui.yaml             # Angular UI (Deployment + Service)
│       ├── newapp.yaml         # NewApp .NET service (Deployment + Service)
│       ├── rabbitmq.yaml       # RabbitMQ (Deployment + Service)
│       ├── jaeger.yaml         # Jaeger tracing UI (Deployment + Service)
│       ├── otel-collector.yaml # OTel Collector (Deployment + Service)
│       ├── ops-agent.yaml      # Ops-Agent AI Trace Consumer (Deploy+Svc+ConfigMap+Secret)
│       ├── otel-collector-configmap.yaml  # OTel config
│       ├── ingress.yaml        # Ingress routing rules
│       ├── configmap.yaml      # Shared config
│       └── namespace.yaml      # Namespace creation
└── values-localdocker.yaml     # Local Docker Desktop overrides
```

## What to Change in `values.yaml`

| What | Where | Example |
|---|---|---|
| **Image name** | `api.image`, `ui.image`, `newapp.image`, `opsAgent.image.repository` | `pathfinder/api` or `myrepo/ops-agent` |
| **Image tag** | `api.tag`, `ui.tag`, `newapp.tag`, `opsAgent.image.tag` | `latest` or `local` |
| **LLM API Key** | `opsAgent.secrets.OPENAI_API_KEY` | `sk-...` |
| **ECR registry** | `registry` | `123456789012.dkr.ecr.us-east-1.amazonaws.com` |
| **Replicas** | `api.replicas`, `ui.replicas` | `2` |
| **CORS origins** | `api.env.CORS_ORIGINS` | `http://pathfinder.localhost` |
| **API URL (frontend)** | `ui.env.API_URL` | `http://api.pathfinder.localhost/api` |
| **Ingress hosts** | `ingress.hosts.ui`, `.api`, `.jaeger`, `.otel` | `pathfinder.yourdomain.com` |
| **Ingress class** | `ingress.className` | `nginx` (local) or `alb` (AWS) |

---

## Local Docker Desktop Kubernetes

### Prerequisites

1. Docker Desktop with Kubernetes enabled (Settings → Kubernetes → Enable)
2. Helm installed: `brew install helm`
3. Nginx Ingress Controller:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/cloud/deploy.yaml
   ```
4. Add to `/etc/hosts`:
   ```
   127.0.0.1 pathfinder.localhost api.pathfinder.localhost jaeger.pathfinder.localhost otel.pathfinder.localhost
   ```

### Build Images

```bash
docker build -t pathfinder/api:dev-1.0.0 ./PathfinderApi
docker build -t pathfinder/ui-zoneless:dev-1.0.0 ./pathfinder-ui-zoneless
docker build -t pathfinder/newapp:dev-1.0.0 ./NewApp
docker build -t ops-agent:local /Users/sanzar/Documents/ops-agent
```

### Deploy

```bash
helm upgrade --install pathfinder ./helm/pathfinder \
  -n pathfinder --create-namespace \
  --set opsAgent.image.repository=ops-agent \
  --set opsAgent.image.tag=local \
  --set opsAgent.image.pullPolicy=IfNotPresent \
  --set opsAgent.secrets.OPENAI_API_KEY=sk-...
```

### Verify

```bash
kubectl get pods -n pathfinder
```

### Access

| Service | URL |
|---|---|
| UI | http://pathfinder.localhost |
| API Swagger | http://api.pathfinder.localhost/api/swagger |
| Jaeger | http://jaeger.pathfinder.localhost |

### Teardown

```bash
helm uninstall pathfinder -n pathfinder
kubectl delete ns pathfinder
```

---

## AWS EKS Deployment

### Prerequisites

1. AWS CLI configured (`aws configure`)
2. EKS cluster running + `kubectl` connected
3. ECR repositories created:
   ```bash
   aws ecr create-repository --repository-name pathfinder/api
   aws ecr create-repository --repository-name pathfinder/ui-zoneless
   aws ecr create-repository --repository-name pathfinder/newapp
   ```
4. AWS Load Balancer Controller installed on the cluster

### Push Images to ECR

```bash
ECR=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$(aws configure get region).amazonaws.com
aws ecr get-login-password | docker login --username AWS --password-stdin $ECR

docker tag pathfinder/api:latest $ECR/pathfinder/api:latest
docker tag pathfinder/ui-zoneless:latest $ECR/pathfinder/ui-zoneless:latest
docker tag pathfinder/newapp:latest $ECR/pathfinder/newapp:latest

docker push $ECR/pathfinder/api:latest
docker push $ECR/pathfinder/ui-zoneless:latest
docker push $ECR/pathfinder/newapp:latest
```

### Create AWS Values Override

```bash
cat > helm/values-aws.yaml << EOF
registry: "$ECR"

api:
  env:
    CORS_ORIGINS: https://pathfinder.yourdomain.com

ui:
  env:
    API_URL: https://api.yourdomain.com/api
    OTEL_URL: https://otel.yourdomain.com/v1/traces
    JAEGER_URL: https://jaeger.yourdomain.com

ingress:
  className: alb
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:REGION:ACCOUNT:certificate/CERT-ID
  hosts:
    ui: pathfinder.yourdomain.com
    api: api.yourdomain.com
    jaeger: jaeger.yourdomain.com
    otel: otel.yourdomain.com
EOF
```

### Deploy to EKS

```bash
helm upgrade --install pathfinder ./helm/pathfinder \
  -f helm/values-aws.yaml \
  -n pathfinder --create-namespace
```

### Verify

```bash
kubectl get pods -n pathfinder
kubectl get ingress -n pathfinder
```

---

## Architecture

```
                    Ingress (ALB / Nginx)
                         │
          ┌──────────────┼──────────────┐──────────────┐
          │              │              │              │
     pathfinder      api.pathfinder  jaeger        otel
          │              │              │              │
      ┌───┴───┐     ┌────┴────┐    ┌────┴────┐   ┌────┴────────┐
      │  UI   │     │   API   │    │ Jaeger  │   │ OTel Coll.  │
      │ :80   │     │  :8080  │    │ :16686  │   │ :4317/:4318 │
      └───────┘     └────┬────┘    └─────────┘   └──────┬──────┘
                         │                              │ gRPC (:4313)
               ┌─────────┼─────────┐             ┌──────┴──────┐
               │         │         │             │  Ops-Agent  │
          ┌────┴────┐ ┌──┴──┐ ┌───┴────────┐     │    :8080    │
          │ NewApp  │ │ RMQ │ │ OTel Coll. │     └─────────────┘
          │  :8080  │ │5672 │ │ 4317/4318  │
          └─────────┘ └─────┘ └────────────┘
```
