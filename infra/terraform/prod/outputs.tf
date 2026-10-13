output "public_ip" {
  description = "Static public IP of the node"
  value       = aws_eip.node.public_ip
}

output "ssh" {
  description = "Command to log in"
  value       = "ssh ubuntu@${aws_eip.node.public_ip}"
}
