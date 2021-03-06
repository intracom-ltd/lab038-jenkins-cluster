terraform {
  required_version = ">= 0.13.0"
  required_providers {
    aws            = {
      source       = "hashicorp/aws"
      version      = "2.69.0"
    }
  }
}

provider "aws" {
  region           = var.aws_region
}

locals {
  ami-mapping      = {
    true           = aws_ami.my-ami.id
    false          = data.aws_ami.amazon_linux.id, 
    
  }
}
data "aws_availability_zones" "available" {
  state            = "available"
}

module "vpc" {
  source           = "terraform-aws-modules/vpc/aws"
  version          = "2.44.0"

  cidr = var.vpc_cidr_block

  azs              = data.aws_availability_zones.available.names
  private_subnets  = slice(var.private_subnet_cidr_blocks, 0, var.private_subnets_per_vpc)
  public_subnets   = slice(var.public_subnet_cidr_blocks, 0, var.public_subnets_per_vpc)

  enable_nat_gateway = true
  enable_vpn_gateway = false
}

module "app_security_group" {
  source             = "terraform-aws-modules/security-group/aws//modules/web"
  version            = "3.12.0"

  name        = "web-server-sg-${var.project_name}-${var.environment}"
  description = "Security group for web-servers with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = module.vpc.public_subnets_cidr_blocks
}

module "lb_security_group" {
  source  = "terraform-aws-modules/security-group/aws//modules/web"
  version = "3.12.0"

  name = "load-balancer-sg-${var.project_name}-${var.environment}"

  description = "Security group for load balancer with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
}

resource "random_string" "lb_id" {
  length  = 4
  special = false
}

module "elb_http" {
  source  = "terraform-aws-modules/elb/aws"
  version = "2.4.0"

  # Comply with ELB name restrictions 
  # https://docs.aws.amazon.com/elasticloadbalancing/2012-06-01/APIReference/API_CreateLoadBalancer.html
  name     = trimsuffix(substr(replace(join("-", ["lb", random_string.lb_id.result, var.project_name, var.environment]), "/[^a-zA-Z0-9-]/", ""), 0, 32), "-")
  internal = false

  security_groups = [module.lb_security_group.this_security_group_id]
  subnets         = module.vpc.public_subnets

  number_of_instances = length(aws_instance.app)
  instances           = aws_instance.app.*.id

  listener = [{
    instance_port     = "80"
    instance_protocol = "HTTP"
    lb_port           = "80"
    lb_protocol       = "HTTP"
  },
  
  {
    instance_port     = 8080
    instance_protocol = "TCP"
    lb_port           = 8080
    lb_protocol       = "TCP"
  },
  ]

  health_check = {
    target              = "HTTP:80/index.html"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
  }
}








data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}



data "aws_ebs_snapshot" "my-existing-snapshot" {
  most_recent            = true
  owners                 = ["self"]

  filter {
    name                 = "tag:Name"
    values               = ["my-snapshot-latest"]
  }
}
resource "aws_ami" "my-ami" {
  # count                  = var.use-snapshot ? 1 : 0
  name                   = "my-snapshot-ami"
  virtualization_type    = "hvm"
  root_device_name       = "/dev/sda1"

  ebs_block_device {
    snapshot_id          = data.aws_ebs_snapshot.my-existing-snapshot.id
    device_name          = "/dev/sda1"
  }
}




resource "aws_instance" "app" {
  count                  = var.instances_per_subnet * length(module.vpc.private_subnets)
  ami                    = "${lookup(local.ami-mapping, var.use-snapshot, "No way this should happen")}"
  

  instance_type          = var.instance_type
  subnet_id              = module.vpc.private_subnets[count.index % length(module.vpc.private_subnets)]
  vpc_security_group_ids = [module.app_security_group.this_security_group_id]
  user_data              = data.template_file.my-ec2-script.rendered
  
  tags = {
    Terraform   = "true"
    Project     = var.project_name
    Environment = var.environment
  }
}
