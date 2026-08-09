terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Generate the DB password in Terraform (no Secrets Manager, no monthly cost) ---
# Excludes characters RDS disallows in a master password (/, @, ", and spaces).
resource "random_password" "db" {
  length           = 20
  special          = true
  override_special = "!#$%^&*()-_=+[]{}"
}

# --- Use the default VPC and its subnets to keep this lean ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_db_subnet_group" "pgpilot" {
  name       = "pgpilot-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

# --- Security group: Postgres reachable only from my IP ---
resource "aws_security_group" "pgpilot_db" {
  name        = "pgpilot-db-sg"
  description = "Allow PostgreSQL from my IP only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "PostgreSQL from my IP"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = "PGPilot" }
}

# --- The managed PostgreSQL instance ---
resource "aws_db_instance" "pgpilot" {
  identifier     = "pgpilot"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.db_username

  # Self-managed password generated above — avoids the Secrets Manager charge.
  # It lands in Terraform state, so keep state local and gitignored.
  password = random_password.db.result

  allocated_storage = 20
  storage_type      = "gp3"

  db_subnet_group_name   = aws_db_subnet_group.pgpilot.name
  vpc_security_group_ids = [aws_security_group.pgpilot_db.id]
  publicly_accessible    = true # reachable from your machine; the SG restricts it to your IP

  multi_az            = false # single-AZ keeps it free-tier friendly
  skip_final_snapshot = true  # portfolio convenience — never do this in production
  apply_immediately   = true

  tags = { Project = "PGPilot" }
}
