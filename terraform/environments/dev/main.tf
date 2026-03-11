
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket  = "veljko-tfstate-139592264087"
    key     = "veljko/dev/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

locals {
  common_tags = {
    Project     = "veljko"
    Environment = "dev"
    ManagedBy   = "terraform"
    Owner       = "veljko"
  }
}

# VPC
module "vpc" {
  source       = "../../modules/vpc"
  name         = "veljko"
  vpc_cidr     = "10.0.0.0/16"
  cluster_name = "veljko-eks-dev"
  tags         = local.common_tags
}

# EKS
module "eks" {
  source             = "../../modules/eks"
  cluster_name       = "veljko-eks-dev"
  kubernetes_version = "1.29"
  admin_user_arns    = var.admin_user_arns
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  # Allowed instance types: t3.small, t3.medium, t3a.small, t3a.medium
  node_instance_types = ["t3.medium"]
  node_desired_size   = 2
  node_min_size       = 1
  node_max_size       = 4
  tags                = local.common_tags
}

# RDS PostgreSQL
module "rds" {
  source                     = "../../modules/rds"
  name                       = "veljko-dev"
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id

  instance_class = "db.t3.micro"
  vpc_cidr       = "10.0.0.0/16"

  db_name     = "appdb"
  db_username = "appuser"
  db_password = var.db_password
  tags        = local.common_tags
}

# K8s Apps
module "k8s_apps" {
  source = "../../modules/k8s-apps"

  cluster_name           = module.eks.cluster_name
  aws_region             = "us-east-1"
  oidc_provider_arn      = module.eks.oidc_provider_arn
  oidc_issuer_url        = module.eks.cluster_oidc_issuer_url
  app_image              = var.app_image
  grafana_admin_password = var.grafana_admin_password

  db_host                = module.rds.db_host
  db_port                = module.rds.db_port
  db_name                = module.rds.db_name
  db_username            = module.rds.db_username
  db_password            = var.db_password

  tags       = local.common_tags
  depends_on = [module.eks, module.rds]
}
