# veljko-infra

AWS EKS + RDS infrastructure for the SRE assessment.
All resources prefixed `veljko-*`, deployed in `us-east-1`.

> **Start here:** [WHAT_TO_CHANGE.md](WHAT_TO_CHANGE.md)

## Architecture

```
Internet
   │
   ▼
ALB  (AWS Load Balancer Controller)
   │
   ▼
EKS — veljko-eks-dev  (2x t3.small nodes, private subnets)
   ├── demo-app pods        Flask  /health  /metrics  /items
   ├── Prometheus + Grafana + Alertmanager
   └── Fluent Bit  ──►  CloudWatch Logs

RDS PostgreSQL — veljko-dev-postgres  (db.t3.micro, private subnet)
   └── password synced via External Secrets Operator ← Secrets Manager
```

## Sandbox constraints applied

| Constraint | Applied |
|---|---|
| Region | us-east-1 only, hard-coded throughout |
| EKS nodes | t3.small (allowed: t3/t3a small/medium) |
| RDS | db.t3.micro (allowed: db.t2/t3.micro/small, db.t4g.micro/small) |
| No DynamoDB | S3 backend without lock table |

## Folder structure

```
veljko-infra/
├── WHAT_TO_CHANGE.md              ← start here
├── .github/workflows/ci-cd.yml   ← change #2 and #3
├── app/
│   ├── app.py
│   ├── Dockerfile
│   └── requirements.txt
├── k8s/monitoring/
│   ├── prometheus-rules.yaml
│   └── grafana-dashboard.yaml
└── terraform/
    ├── environments/dev/
    │   ├── main.tf                ← change #1
    │   ├── variables.tf
    │   └── outputs.tf
    └── modules/
        ├── vpc/
        ├── eks/
        ├── rds/
        └── k8s-apps/
```
