variable "region" {
  default = "us-east-1"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  default = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  default = "10.0.2.0/24"
}

variable "my_ip" {
  description = "Your public IP for SSH access"
  default     = "124.29.216.35/32"
}

variable "enable_nat" {
  type    = bool
  default = true
}

variable "key_name" {
  default = "devops-lab"
}