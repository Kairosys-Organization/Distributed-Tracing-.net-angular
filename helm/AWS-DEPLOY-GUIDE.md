# AWS EKS Deployment Guide

## ✅ Prerequisites

| Tool | Install |
|---|---|
| AWS CLI | `brew install awscli` → `aws configure` |
| kubectl | `brew install kubectl` |
| Helm | `brew install helm` |
| eksctl (optional) | `brew install eksctl` |

---

## 🔧 Step 1 — Fill in `aws-deploy.sh`

Open `helm/aws-deploy.sh` and fill in the variables at the top:

```bash
ECR_REGISTRY=""    # e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com
DOMAIN=""          # e.g. pathfinder.mycompany.com
CERT_ARN=""        # ACM cert ARN for HTTPS (see Step 3)
```

Also fill in all the **Ops-Agent secrets** (OpenAI, Azure, etc.) the same way you did in `local-deploy.sh`.

---

## 📦 Step 2 — Push Images to ECR

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

# Create repos (first time only)
aws ecr create-repository --repository-name pathfinder/api
aws ecr create-repository --repository-name pathfinder/ui-zoneless
aws ecr create-repository --repository-name pathfinder/newapp
aws ecr create-repository --repository-name pathfinder/ops-agent

# Tag and push
docker tag pathfinder/api:dev-1.0.0        $ECR_REGISTRY/pathfinder/api:latest
docker tag pathfinder/ui-zoneless:dev-1.0.0 $ECR_REGISTRY/pathfinder/ui-zoneless:latest
docker tag pathfinder/newapp:dev-1.0.0      $ECR_REGISTRY/pathfinder/newapp:latest
docker tag ops-agent:local                  $ECR_REGISTRY/pathfinder/ops-agent:latest

docker push $ECR_REGISTRY/pathfinder/api:latest
docker push $ECR_REGISTRY/pathfinder/ui-zoneless:latest
docker push $ECR_REGISTRY/pathfinder/newapp:latest
docker push $ECR_REGISTRY/pathfinder/ops-agent:latest
```

---

## 🔐 Step 3 — Get an ACM Certificate

1. Go to **AWS Console → Certificate Manager → Request a certificate**
2. Add your domain: `*.mycompany.com` (wildcard covers all subdomains)
3. Validate via DNS (add CNAME to your domain registrar)
4. Copy the **Certificate ARN** → paste into `aws-deploy.sh` as `CERT_ARN`

---

## ⚙️ Step 4 — Install the AWS Load Balancer Controller

The ALB ingress class requires this controller on your EKS cluster:

```bash
# Add the EKS chart repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the controller (replace CLUSTER_NAME and REGION)
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

> **Note:** The controller also requires an IAM role attached to its service account.
> Follow the [official guide](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html) for the full IAM setup.

---

## 🚀 Step 5 — Deploy

```bash
chmod +x helm/aws-deploy.sh
./helm/aws-deploy.sh
```

---

## 🌐 Step 6 — Configure DNS

After deploy, get the ALB address:

```bash
kubectl get ingress -n pathfinder
```

Copy the `ADDRESS` value (e.g. `xxxx.us-east-1.elb.amazonaws.com`) and create **CNAME records** in your DNS registrar:

| Record | Type | Value |
|---|---|---|
| `pathfinder.mycompany.com` | CNAME | `xxxx.us-east-1.elb.amazonaws.com` |
| `api.pathfinder.mycompany.com` | CNAME | `xxxx.us-east-1.elb.amazonaws.com` |
| `jaeger.pathfinder.mycompany.com` | CNAME | `xxxx.us-east-1.elb.amazonaws.com` |
| `otel.pathfinder.mycompany.com` | CNAME | `xxxx.us-east-1.elb.amazonaws.com` |

---

## 🔄 What Changes vs. Local?

| Setting | Local (nginx) | AWS (ALB) |
|---|---|---|
| `ingress.className` | `nginx` | `alb` |
| Ingress annotations | nginx timeout only | ALB scheme, target-type, SSL redirect, cert ARN |
| Hosts | `*.pathfinder.localhost` | `*.yourdomain.com` |
| UI `API_URL` | `http://api.pathfinder.localhost/api` | `https://api.yourdomain.com/api` |
| UI `OTEL_URL` | `http://otel.pathfinder.localhost/v1/traces` | `https://otel.yourdomain.com/v1/traces` |
| UI `JAEGER_URL` | `http://jaeger.pathfinder.localhost` | `https://jaeger.yourdomain.com` |
| `imagePullPolicy` | `IfNotPresent` | `Always` |
| Image source | Local Docker | ECR |
| TLS | None | ACM certificate via ALB |

---

## 🩺 Verify

```bash
kubectl get pods -n pathfinder
kubectl get ingress -n pathfinder
kubectl logs -n pathfinder -l app=ops-agent --tail=50
```

Services should be live at:
- UI → `https://pathfinder.yourdomain.com`
- API → `https://api.pathfinder.yourdomain.com/api/swagger`
- Jaeger → `https://jaeger.pathfinder.yourdomain.com`
