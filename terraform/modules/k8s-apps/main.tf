
# Namespaces
resource "kubernetes_namespace" "demo" {
  metadata { name = "demo" }
}

resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "kubernetes_namespace" "logging" {
  metadata { name = "logging" }
}

# IRSA: AWS Load Balancer Controller
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



#IRSA: Fluent Bit
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

# Kubernetes Secret: DB password
resource "kubernetes_secret" "db_credentials" {
  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  data = {
    password = var.db_password
  }
}

#Helm: AWS Load Balancer Controller

resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.1"
  namespace  = "kube-system"

  wait            = true
  wait_for_jobs   = true
  timeout         = 300

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.albc.arn
  }
  set {
    name  = "replicaCount"
    value = "1"
  }
}

# Helm: kube-prometheus-stack

resource "helm_release" "prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "57.2.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 900
  wait       = false
  wait_for_jobs = false

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention = "7d"
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
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
      persistence   = { enabled = true, size = "2Gi" }
      sidecar       = { dashboards = { enabled = true, searchNamespace = "ALL" } }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }
    alertmanager = {
      alertmanagerSpec = {
        resources = {
          requests = { cpu = "20m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
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

    prometheusOperator = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
    kubeStateMetrics = {
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "100m", memory = "64Mi" }
      }
    }
    nodeExporter = {
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "100m", memory = "64Mi" }
      }
    }

    prometheusOperator = {
      admissionWebhooks = {
        enabled = false
        patch   = { enabled = false }
      }
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
  })]

  depends_on = [helm_release.aws_lbc]
}

# Helm: Fluent Bit
resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = "0.43.0"
  namespace  = kubernetes_namespace.logging.metadata[0].name
  wait       = true
  timeout    = 180

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

  depends_on = [helm_release.aws_lbc]
}

# Demo App: Deployment
resource "kubernetes_deployment" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = kubernetes_namespace.demo.metadata[0].name
    labels    = { app = "demo-app" }
  }

  wait_for_rollout = false

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

          port {
            container_port = 8080
          }

          env {
            name  = "DB_HOST"
            value = var.db_host
          }
          env {
            name  = "DB_PORT"
            value = tostring(var.db_port)
          }
          env {
            name  = "DB_NAME"
            value = var.db_name
          }
          env {
            name  = "DB_USER"
            value = var.db_username
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.db_credentials.metadata[0].name
            }
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 60
            period_seconds        = 15
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 5
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret.db_credentials,
    helm_release.aws_lbc,
  ]
}

# Demo App: Service
resource "kubernetes_service" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = kubernetes_namespace.demo.metadata[0].name
    labels    = { app = "demo-app" }
  }

  spec {
    selector = { app = "demo-app" }
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }

  depends_on = [helm_release.aws_lbc]
}

# Demo App: Ingress (ALB)
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
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.aws_lbc]
}

# Demo App: HPA
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
