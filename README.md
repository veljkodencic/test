# veljko-infra

AWS EKS + RDS infrastructure for the SRE assessment.
All resources prefixed `veljko-*`, deployed in `us-east-1`.

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
├── .github/workflows/
│   ├── ci-cd.yaml
│   └── destroy.yaml
├── app/
│   ├── app.py
│   ├── Dockerfile
│   └── requirements.txt
├── k8s/monitoring/
│   ├── prometheus-rules.yaml
│   └── grafana-dashboard.yaml
│   └── service-monitor.yaml
└── terraform/
    ├── environments/dev/
    │   ├── main.tf                
    │   ├── variables.tf
    │   └── outputs.tf
    └── modules/
        ├── vpc/
        │   ├── main.tf                
        │   ├── variables.tf
        │   └── outputs.tf
        ├── eks/
        │   ├── main.tf                
        │   ├── variables.tf
        │   └── outputs.tf
        ├── rds/
        │   ├── main.tf                
        │   ├── variables.tf
        │   └── outputs.tf
        └── k8s-apps/
            ├── main.tf                
            ├── variables.tf
            └── outputs.tf
```
