variable "name_prefix" {
  description = "Prefix for the VPC and its subnets, route tables, and gateways."
  type        = string
  default     = "myapp"
}

variable "vpc_cidr" {
  description = <<-EOT
    IPv4 CIDR for the VPC. Split in half: the lower half is public subnets, the upper half
    is private ones, so the two can never overlap.
  EOT
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across. Empty means the first `az_count` AZs in the region."
  type        = list(string)
  default     = []
}

variable "az_count" {
  description = "Number of AZs to use when `availability_zones` is empty. Two is the MVP default."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    One NAT gateway shared by every private subnet, instead of one per AZ.

    Cheaper (~$33/mo instead of ~$33 per AZ) but a single point of failure: if that AZ's
    NAT goes down, all private egress stops. Fine for dev, not for production.
  EOT
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = <<-EOT
    EKS cluster name to tag subnets for. Empty skips the tag. EKS uses the tag to discover
    which subnets to place the control plane and load balancers in, so set it from step 3 on.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource that supports them."
  type        = map(string)
  default     = {}
}
