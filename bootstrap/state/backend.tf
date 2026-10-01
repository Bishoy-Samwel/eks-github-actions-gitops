// Remote backend for this config's own state.
//
// This file can only take concrete values: a backend block is read before variables and
// data sources are available, so it cannot reference var.bucket_name or the account ID.
// That is why the bucket name is spelled out here instead of being derived.
//
// First-time setup on a brand new account, where the bucket does not exist yet:
//
//     terraform init -backend=false    # local state, no backend
//     terraform apply                  # creates the bucket
//     terraform init                   # migrates local state into the bucket
//
// Every run after that is a plain `terraform init`.

terraform {
  backend "s3" {
    bucket         = "myapp-tfstate-042617239394"
    key            = "bootstrap/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "myapp-tflock"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:eu-central-1:042617239394:key/9c2a2d41-5b14-4968-8862-339509379ec8"
  }
}
