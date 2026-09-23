moved {
  from = module.vpc
  to   = module.network
}

module "network" {
  source = "../../modules/network"

  project_name        = var.project_name
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs

  tags = {
    Project     = var.project_name
    Environment = "dev"
  }
}
