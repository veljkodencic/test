output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}"
}

output "app_url" {
  value = "http://${module.k8s_apps.app_ingress_hostname}"
}

output "db_endpoint" {
  value = module.rds.db_endpoint
}

output "grafana_port_forward" {
  value = "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
}
