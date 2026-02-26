variable "cluster_name"        { type = string }
variable "kubernetes_version"  { type = string; default = "1.29" }
variable "vpc_id"              { type = string }
variable "public_subnet_ids"   { type = list(string) }
variable "private_subnet_ids"  { type = list(string) }

# Allowed instance types: t3.small, t3.medium, t3a.small, t3a.medium
variable "node_instance_types" { type = list(string); default = ["t3.small"] }
variable "node_desired_size"   { type = number; default = 2 }
variable "node_min_size"       { type = number; default = 1 }
variable "node_max_size"       { type = number; default = 4 }
variable "tags"                { type = map(string); default = {} }
