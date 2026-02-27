# These three variables are NEVER stored in files.
# Set locally:   export TF_VAR_db_password="..."
# In CI/CD:      stored as GitHub Secrets (see ci-cd.yml)

variable "db_password" {
  type        = string
  sensitive   = true
  description = "RDS master password. Set via TF_VAR_db_password env var."
}

variable "grafana_admin_password" {
  type        = string
  sensitive   = true
  description = "Grafana admin password. Set via TF_VAR_grafana_admin_password env var."
}

variable "app_image" {
  type        = string
  description = "Full ECR image URI. Built and set automatically by CI/CD."
  default     = "public.ecr.aws/nginx/nginx:latest" # placeholder until first real build
}

variable "admin_user_arns" {
  type        = list(string)
  description = "IAM user ARNs to grant EKS cluster admin access (kubectl)"
  default     = ["arn:aws:iam::139592264087:user/veljko-admin"]
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}
