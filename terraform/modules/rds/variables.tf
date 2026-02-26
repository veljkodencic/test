variable "name"                      { type = string }
variable "vpc_id"                     { type = string }
variable "private_subnet_ids"         { type = list(string) }
variable "eks_node_security_group_id" { type = string }

# Allowed: db.t2.micro, db.t2.small, db.t3.micro, db.t3.small, db.t4g.micro, db.t4g.small
variable "instance_class" { type = string; default = "db.t3.micro" }

variable "db_name"     { type = string; default = "appdb" }
variable "db_username" { type = string; default = "appuser" }
variable "db_password" { type = string; sensitive = true }
variable "tags"        { type = map(string); default = {} }
