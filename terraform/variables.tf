variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "taxidb"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "pgpilot_admin"
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form, e.g. 203.0.113.4/32"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class (free-tier eligible)"
  type        = string
  default     = "db.t3.micro"
}
