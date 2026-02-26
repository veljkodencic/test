output "app_ingress_hostname" {
  value = try(kubernetes_ingress_v1.demo_app.status[0].load_balancer[0].ingress[0].hostname, "pending")
}
