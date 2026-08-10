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

# --- Force SSL at the server, not just request it from the client ---
# Now that the security group is open to 0.0.0.0/0, PGSSLMODE=require on the
# client side alone isn't a real boundary — a client could still choose plain
# TCP unless the server refuses it. rds.force_ssl=1 makes SSL mandatory,
# not optional, for every connection regardless of client settings.
resource "aws_db_parameter_group" "pgpilot" {
  name   = "pgpilot-pg16-force-ssl"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = { Project = "PGPilot" }
}

# --- Security group: open to the internet on 5432, secured by password + SSL instead of IP-lock ---
# Phase 3 locked this to a single home IP. Phase 4's CD job runs on GitHub-hosted
# runners, which have no fixed IP range, so an IP allowlist can't work here. The
# security boundary is now the master password (Terraform-generated, never
# committed) plus PGSSLMODE=require, the same posture a public endpoint like
# Neon's uses by default.
resource "aws_security_group" "pgpilot_db" {
  name        = "pgpilot-db-sg"
  description = "Allow PostgreSQL from anywhere; secured by password + SSL, not network ACLs"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "PostgreSQL from anywhere (password + SSL enforced at the DB layer)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
  parameter_group_name   = aws_db_parameter_group.pgpilot.name
  publicly_accessible    = true # reachable from anywhere; password + SSL are the real boundary (see security group above)

  multi_az            = false # single-AZ keeps it free-tier friendly
  skip_final_snapshot = true  # portfolio convenience — never do this in production
  apply_immediately   = true

  tags = { Project = "PGPilot" }
}
