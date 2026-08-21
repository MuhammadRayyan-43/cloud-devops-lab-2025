resource "aws_ssm_parameter" "dockerhub_username" {
  name  = "/devops-lab/dockerhub/username"
  type  = "String"
  value = "placeholder"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "dockerhub_token" {
  name  = "/devops-lab/dockerhub/token"
  type  = "SecureString"
  value = "placeholder"

  lifecycle {
    ignore_changes = [value]
  }
}