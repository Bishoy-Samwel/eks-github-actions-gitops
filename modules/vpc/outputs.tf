output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.main.cidr_block
}

output "availability_zones" {
  description = "AZs the subnets were created in."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered by AZ. NAT lives here; the load balancer will too."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered by AZ. EKS control plane, nodes, and pods live here."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs (one, or one per AZ when single_nat_gateway is false)."
  value       = aws_nat_gateway.main[*].id
}

output "nat_gateway_public_ips" {
  description = "Public IPs of the NAT gateways. Useful when someone asks for your egress range."
  value       = aws_eip.nat[*].public_ip
}

output "internet_gateway_id" {
  description = "Internet gateway ID."
  value       = aws_internet_gateway.main.id
}
