// Remote state for the dev environment.
//
// A backend block is read before variables and data sources exist, so these values are
// written out rather than derived. They come from `terraform output backend_config` in
// bootstrap/state.
//
// `key` MUST differ per environment. Two environments that share a key share state and
// will overwrite each other's resources.

terraform {
  backend "s3" {
    bucket         = "myapp-tfstate-042617239394"
    key            = "dev/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "myapp-tflock"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:eu-central-1:042617239394:key/9c2a2d41-5b14-4968-8862-339509379ec8"
  }
}
