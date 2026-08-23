

output "app_private_ip" {
  value = aws_instance.app.private_ip
}

output "bastion_public_ip" {
  value = aws_eip.bastion.public_ip
}