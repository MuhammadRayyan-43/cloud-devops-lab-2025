terraform {
  backend "s3" {
    bucket         = "rayyan-devops-lab-tfstate"
    key            = "infra/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
  }
}
