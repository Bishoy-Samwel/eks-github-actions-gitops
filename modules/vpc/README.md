# module: vpc

Networking for one environment: a VPC, public and private subnets across two AZs, a NAT
gateway for private egress, and free S3/DynamoDB gateway endpoints.

```hcl
module "vpc" {
  source = "../../../modules/vpc"

  name_prefix  = "myapp"
  cluster_name = "myapp-dev"   # tags subnets so EKS can find them
  tags         = local.tags
}
```

Everything else (EKS security groups, the cluster) is created by the EKS module. This module
is networking only.

## Layout

```
10.0.0.0/16
├── public   10.0.0.0/20, 10.0.16.0/20   (netnum 0..7)   NAT, load balancer
└── private  10.0.128.0/20, 10.0.144.0/20 (netnum 8..15) EKS nodes, pods, RDS
```

Public subnets route `0.0.0.0/0` to an internet gateway. Private subnets route it to a NAT
gateway, so workloads can pull images and reach AWS APIs but cannot be reached from outside.

**Why the halves are offset.** Computing public from `netnum 0` and private from `netnum 0`
as well puts `10.0.0.0/24` inside `10.0.0.0/20`. AWS rejects overlapping subnets in one VPC.
Starting private at `netnum 8` puts it entirely in the upper half, so the two can never
collide no matter how many AZs are added.

## Subnet tags

| Tag | On | Why |
| --- | --- | --- |
| `kubernetes.io/cluster/<cluster_name>` = `shared` | public + private | lets EKS discover subnets |
| `kubernetes.io/role/elb` = `1` | public | where internet-facing load balancers go |
| `kubernetes.io/role/internal-elb` = `1` | private | where internal load balancers go |

Forgetting the `internal-elb` tag is why internal load balancers stay `<pending>` forever.

## NAT gateways

`single_nat_gateway = true` (default) shares one NAT across every private subnet: about
$33/month, but all private egress stops if that AZ fails. `false` creates one per AZ
(one per AZ in cost) and is the production setting. Set it to `false` in `infra/envs/prod`.

## Gateway endpoints

S3 and DynamoDB endpoints are `Gateway` type, cost nothing, and keep image pulls and state
reads off the NAT gateway — which is billed per GB. They are attached to every route table.
Adding them later means touching every route table, so they are here from the start.

Interface endpoints (ECR API, ECR Docker, STS, Secrets Manager) also keep traffic off NAT but
cost ~$7/month each per AZ; they are deliberately not created at MVP.

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `name_prefix` | `myapp` | Prefix for resource names |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR; split in half public/private |
| `availability_zones` | `[]` | Explicit AZs; empty uses the first `az_count` |
| `az_count` | `2` | AZs to use when `availability_zones` is empty |
| `single_nat_gateway` | `true` | One shared NAT, or one per AZ |
| `cluster_name` | `""` | EKS cluster to tag subnets for |
| `tags` | `{}` | Tags applied to every resource |

## Outputs

| Name | Use |
| --- | --- |
| `vpc_id` | Passed to the EKS module |
| `vpc_cidr` | Reference |
| `availability_zones` | Reference |
| `public_subnet_ids` | Load balancer subnets |
| `private_subnet_ids` | EKS control plane, nodes, and RDS |
| `nat_gateway_ids`, `nat_gateway_public_ips` | Reference / egress ranges |
| `internet_gateway_id` | Reference |

## Cost

| Item | Monthly |
| --- | --- |
| NAT gateway (730h) | ~$33 |
| NAT data processing | usage-based |
| VPC, subnets, IGW, gateway endpoints | $0 |
| **Total** | **~$33+/mo** |

The NAT gateway is the first real recurring cost in the project. It is billed whether or not
anything uses it.

## Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| `CreateNatGateway ... UnknownError` | Transient; AWS sometimes returns this immediately after the EIP is allocated | Re-run `terraform apply`. It succeeded on the second attempt here |
| `CIDR block overlaps` | Public and private subnets derived from the same `netnum` | Offset private by 8 (`netnum i + 8`) |
| Internal load balancer stuck `<pending>` | Missing `kubernetes.io/role/internal-elb` tag | Tag private subnets, then let the controller reconcile |
| EKS nodes `NotReady` | Subnets missing the `kubernetes.io/cluster/<name>` tag | Pass `cluster_name` to this module |
| NAT created but egress fails | IGW not attached to the public route table yet | Confirm with `describe-route-tables`; `depends_on` normally prevents this |

## Verify

```bash
terraform output private_subnet_ids
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'Subnets[].{Az:AvailabilityZone,Cidr:CidrBlock,Public:MapPublicIpOnLaunch}'
```

Private subnets must not overlap public ones, and only public subnets should have
`MapPublicIpOnLaunch: true`.
