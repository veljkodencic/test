# veljko-infra

Production-grade AWS infrastructure for a Flask CRUD demo app, deployed on EKS with RDS PostgreSQL, full observability stack, and a GitHub Actions CI/CD pipeline.

---

## Table of Contents

- [Stack](#stack)
- [Folder Structure](#folder-structure)
- [Architecture](#architecture)
- [CI/CD Pipeline](#cicd-pipeline)
- [Destroy](#destroy)

---

## Stack

### Cloud & Infrastructure

| Component | Details |
|---|---|
| **AWS EKS** | Kubernetes 1.29, 2× t3.small nodes |
| **AWS RDS** | PostgreSQL 15.7, db.t3.micro, private subnets |
| **AWS VPC** | Public + private subnets across 2 AZs, NAT Gateway |
| **AWS ECR** | Private Docker image registry |
| **AWS ALB** | Application Load Balancer via AWS Load Balancer Controller |
| **AWS CloudWatch** | EKS control plane logs + pod logs via Fluent Bit |
| **AWS S3** | Terraform remote state backend |
| **AWS IAM** | OIDC-based roles for GitHub Actions and IRSA for pods |

### Application

| Component | Details |
|---|---|
| **Flask** | Python web framework, gunicorn WSGI server (timeout 120s) |
| **SQLAlchemy** | ORM for PostgreSQL, connection pooling, background DB init thread |
| **Prometheus Client** | Exposes `/metrics` — request counters, latency histograms, DB query latency |
| **Docker** | Python 3.11-slim, non-root user (appuser, UID 1001) |

### Kubernetes

| Component | Details |
|---|---|
| **AWS Load Balancer Controller** | Provisions ALB from Ingress resources via IRSA |
| **kube-prometheus-stack** | Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics |
| **Fluent Bit** | Log shipping from pods to CloudWatch Logs |
| **HorizontalPodAutoscaler** | Scales demo-app pods based on CPU |
| **ServiceMonitor** | CRD telling Prometheus to scrape `/metrics` every 15s |

### IaC & CI/CD

| Component | Details |
|---|---|
| **Terraform** | v1.7.5, modular, S3 remote backend |
| **GitHub Actions** | OIDC auth — no long-lived AWS keys stored as secrets |
| **Helm** | v3, used for LBC, kube-prometheus-stack, Fluent Bit |

---

## Folder Structure

```
veljko-infra/
├── app/
│   ├── app.py                        # Flask app — routes, DB, Prometheus metrics, embedded UI
│   ├── Dockerfile                    # Python 3.11-slim, gunicorn, non-root user
│   └── requirements.txt
├── k8s/
│   └── monitoring/
│       ├── grafana-dashboard.yaml    # Auto-imported Grafana dashboard
│       └── service-monitor.yaml     # Prometheus scrape config
├── terraform/
│   ├── environments/dev/
│   │   ├── main.tf                   # Root module — providers, wiring
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── modules/
│       ├── vpc/                      # VPC, subnets, IGW, NAT GW
│       ├── eks/                      # EKS cluster, node group, OIDC, access entries
│       ├── rds/                      # RDS PostgreSQL, subnet group, security group
│       └── k8s-apps/                 # Helm releases + K8s manifests
│           ├── main.tf
│           └── albc-iam-policy.json  # Full ALBC IAM policy
└── .github/workflows/
    ├── ci-cd.yml                     # Build → Plan → Apply → Smoke test
    └── destroy.yml                   # Manual destroy with approval + pre-cleanup
```

---

## Architecture

```
                    Internet
                       │
                       ▼
┌──────────────────────────────────────────────────┐
│  AWS Application Load Balancer                   │
│  provisioned by AWS Load Balancer Controller     │
└──────────────────────┬───────────────────────────┘
                       │  HTTP :80
                       ▼
┌──────────────────────────────────────────────────┐
│  EKS Cluster — veljko-eks-dev                    │
│                                                  │
│  ┌──────────────────────────────────────────┐    │
│  │  namespace: demo                         │    │
│  │                                          │    │
│  │  demo-app Deployment (2 replicas)        │    │
│  │  ┌─────────────────────────────────────┐ │    │
│  │  │  Flask + gunicorn  :8080            │ │    │
│  │  │                                     │ │    │
│  │  │  GET  /          Web UI (HTML+JS)   │ │    │
│  │  │  GET  /items     List items (JSON)  │ │    │
│  │  │  POST /items     Create item        │ │    │
│  │  │  DEL  /items/:id Delete item        │ │    │
│  │  │  GET  /health    Health check       │ │    │
│  │  │  GET  /metrics   Prometheus metrics │ │    │
│  │  └──────────────────┬──────────────────┘ │    │
│  └────────────────────┬┼────────────────────┘    │
│                       ││ SQLAlchemy / port 5432  │
│  ┌────────────────────┼┼─────────────────────┐   │
│  │  namespace: monitoring                    │   │
│  │                    │                      │   │
│  │  Prometheus ◄── ServiceMonitor            │   │
│  │       │         (scrapes /metrics :15s)   │   │
│  │       ▼                                   │   │
│  │  Grafana  (dashboard auto-imported)       │   │
│  │  Alertmanager                             │   │
│  │  kube-state-metrics                       │   │
│  │  node-exporter (DaemonSet)                │   │
│  └───────────────────────────────────────────┘   │
│                                                  │
│  ┌──────────────────────────────────────────┐    │
│  │  namespace: logging                      │    │
│  │  Fluent Bit DaemonSet → CloudWatch Logs  │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  ┌──────────────────────────────────────────┐    │
│  │  namespace: kube-system                  │    │
│  │  AWS Load Balancer Controller (IRSA)     │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  Node group: 2× t3.small (2 vCPU, 2GB RAM each)  │
└──────────────────────────────────────────────────┘
                       │
                       │  Private subnets only
                       ▼
┌──────────────────────────────────────────────────┐
│  RDS PostgreSQL 15.7  (db.t3.micro)              │
│  Port: 5432  |  Storage: 20GB gp2                │
└──────────────────────────────────────────────────┘
```

### Network Layout

```
VPC 10.0.0.0/16
├── us-east-1a
│   ├── Public subnet  10.0.1.0/24    — EKS nodes, NAT GW, ALB
│   └── Private subnet 10.0.64.0/18  — RDS
└── us-east-1b
    ├── Public subnet  10.0.2.0/24    — EKS nodes, ALB
    └── Private subnet 10.0.128.0/18 — RDS standby
```

### Security

- RDS security group allows inbound :5432 from VPC CIDR only (10.0.0.0/16)
- DB credentials stored as a Kubernetes Secret, injected as env vars into pods
- GitHub Actions uses OIDC federation — no static AWS access keys anywhere
- LBC pod uses IRSA scoped to ELB + WAF + EC2 permissions
- EKS access entries grant `kubectl` access to specific IAM users
- App pods run as non-root UID 1001

---

## CI/CD Pipeline

Triggered manually: **GitHub Actions → CI/CD — veljko-infra → Run workflow**

```
┌───────────┐     ┌─────────────────┐     ┌──────────────────────┐     ┌────────────────┐
│   Build   │────▶│ Terraform Plan  │────▶│  Terraform Apply     │────▶│  Smoke Test    │
│           │     │                 │     │                      │     │                │
│ docker    │     │ tf validate     │     │ 1. Clean failed Helm │     │ apply          │
│ build     │     │ tf plan         │     │ 2. Delete CW logs    │     │ ServiceMonitor │
│           │     │                 │     │ 3. Import EKS access │     │                │
│ push :sha │     │                 │     │    entry if exists   │     │ wait rollout   │
│ push :lat │     │                 │     │ 4. tf apply          │     │                │
│ est → ECR │     │                 │     │                      │     │ curl /health   │
└───────────┘     └─────────────────┘     └──────────────────────┘     └────────────────┘
```

### Accessing services

```bash
# App UI
kubectl get ingress demo-app -n demo

# Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000 
# Dashboard: Dashboards → Browse → "veljko — Demo App"

# Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9091:9090
# http://localhost:9091/targets
```

### Grafana Dashboard Panels

| Panel | Metric |
|---|---|
| Request Rate | Requests/sec by endpoint, success vs errors |
| Latency Percentiles | p50, p95, p99 over time |
| Total Requests/s | Sum of all requests |
| Error Rate % | 5xx / total × 100 |
| p95 Latency | 95th percentile response time |
| Items in DB | Total rows in items table |
| DB Connection Errors | Errors in last 5 minutes |
| DB Query Latency | p95 per operation (select/insert/delete) |
| Pod CPU Usage | Per pod over time |
| Pod Memory Usage | Per pod over time |
| HTTP by Status Code | 200/201/503 breakdown |
| Active Pods | Pods in Ready state |

---

## Destroy

Triggered manually: **GitHub Actions → Destroy — veljko-infra → Run workflow**
Requires approval from the `destroy` GitHub environment (Settings → Environments → destroy → required reviewers).

The workflow cleans up in order to avoid stuck resources:

1. Deletes Ingress + HPA — clears finalizers that block namespace termination
2. Uninstalls Helm releases — LBC, Prometheus, Fluent Bit
3. Force-removes namespaces stuck in `Terminating`
4. Deletes ALB, security groups, ENIs — created by LBC outside Terraform state
5. Deletes CloudWatch log groups — prevents `ResourceAlreadyExistsException` on redeploy
6. Runs `terraform destroy -auto-approve`


