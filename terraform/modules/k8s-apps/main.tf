################################################################################
# k8s-apps module
# Deploys: AWS LBC, External Secrets Operator, Prometheus stack,
#          Fluent Bit, demo app (backed by RDS PostgreSQL)
################################################################################

# ── Namespaces ─────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "demo" {
  metadata { name = "demo" }
}

resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "kubernetes_namespace" "logging" {
  metadata { name = "logging" }
}

resource "kubernetes_namespace" "external_secrets" {
  metadata { name = "external-secrets" }
}

# ── IRSA: AWS Load Balancer Controller ────────────────────────────────────────
data "aws_iam_policy_document" "albc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "albc" {
  name               = "${var.cluster_name}-albc-role"
  assume_role_policy = data.aws_iam_policy_document.albc_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "albc" {
  name   = "${var.cluster_name}-albc-policy"
  role   = aws_iam_role.albc.id
  policy = file("${path.module}/albc-iam-policy.json")
}

# ── IRSA: External Secrets Operator ───────────────────────────────────────────
data "aws_iam_policy_document" "eso_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

# ── IRSA: Fluent Bit ──────────────────────────────────────────────────────────
data "aws_iam_policy_document" "fluentbit_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:logging:fluent-bit"]
    }
  }
}

resource "aws_iam_role" "fluentbit" {
  name               = "${var.cluster_name}-fluentbit-role"
  assume_role_policy = data.aws_iam_policy_document.fluentbit_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "fluentbit" {
  role       = aws_iam_role.fluentbit.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/eks/${var.cluster_name}/app"
  retention_in_days = 30
  tags              = var.tags
}

# ── Helm: AWS Load Balancer Controller ────────────────────────────────────────
resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.1"
  namespace  = "kube-system"

  set { name = "clusterName"; value = var.cluster_name }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.albc.arn
  }
  set { name = "replicaCount"; value = "1" }
}

# ── Helm: External Secrets Operator ───────────────────────────────────────────
resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "0.9.13"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso.arn
  }
}

# ── Helm: kube-prometheus-stack ───────────────────────────────────────────────
resource "helm_release" "prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "57.2.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 600

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention = "15d"
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "gp2"
              resources        = { requests = { storage = "10Gi" } }
            }
          }
        }
      }
    }
    grafana = {
      adminPassword = var.grafana_admin_password
      persistence   = { enabled = true, size = "5Gi" }
      sidecar       = { dashboards = { enabled = true, searchNamespace = "ALL" } }
    }
    alertmanager = {
      alertmanagerSpec = {
        storage = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "gp2"
              resources        = { requests = { storage = "2Gi" } }
            }
          }
        }
      }
    }
  })]
}

# ── Helm: Fluent Bit ──────────────────────────────────────────────────────────
resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = "0.43.0"
  namespace  = kubernetes_namespace.logging.metadata[0].name

  values = [yamlencode({
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.fluentbit.arn
      }
    }
    config = {
      outputs = <<-EOF
        [OUTPUT]
            Name               cloudwatch_logs
            Match              kube.*
            region             ${var.aws_region}
            log_group_name     ${aws_cloudwatch_log_group.app_logs.name}
            log_stream_prefix  pod/
            auto_create_group  true
      EOF
    }
  })]
}

# ── External Secrets: sync DB password from Secrets Manager ───────────────────
resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "aws-secrets-manager" }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.external_secrets]
}

resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "db-credentials"
      namespace = kubernetes_namespace.demo.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
      target          = { name = "db-credentials", creationPolicy = "Owner" }
      data = [{
        secretKey = "password"
        remoteRef = { key = var.db_secret_arn, property = "" }
      }]
    }
  }
  depends_on = [kubernetes_manifest.cluster_secret_store]
}

# ── Demo App: Deployment ───────────────────────────────────────────────────────
resource "kubernetes_deployment" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = kubernetes_namespace.demo.metadata[0].name
    labels    = { app = "demo-app" }
  }

  spec {
    replicas = 2

    selector { match_labels = { app = "demo-app" } }

    template {
      metadata {
        labels = { app = "demo-app" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8080"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        container {
          name  = "demo-app"
          image = var.app_image

          port { container_port = 8080 }

          env { name = "DB_HOST"; value = var.db_host }
          env { name = "DB_PORT"; value = tostring(var.db_port) }
          env { name = "DB_NAME"; value = var.db_name }
          env { name = "DB_USER"; value = var.db_username }

          env_from {
            secret_ref { name = "db-credentials" }
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          liveness_probe {
            http_get { path = "/health"; port = 8080 }
            initial_delay_seconds = 15
            period_seconds        = 15
            failure_threshold     = 3
          }

          readiness_probe {
            http_get { path = "/health"; port = 8080 }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 3
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.db_external_secret]
}

# ── Demo App: Service ──────────────────────────────────────────────────────────
resource "kubernetes_service" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }
  spec {
    selector = { app = "demo-app" }
    type     = "ClusterIP"
    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

# ── Demo App: Ingress (ALB) ────────────────────────────────────────────────────
resource "kubernetes_ingress_v1" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = kubernetes_namespace.demo.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                = "alb"
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/health"
    }
  }
  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.demo_app.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.aws_lbc]
}

# ── Demo App: HPA ──────────────────────────────────────────────────────────────
resource "kubernetes_horizontal_pod_autoscaler_v2" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.demo_app.metadata[0].name
    }
    min_replicas = 2
    max_replicas = 6
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}
