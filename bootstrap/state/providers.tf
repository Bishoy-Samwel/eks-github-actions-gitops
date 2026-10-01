provider "aws" {
  region = var.region

  # Fails fast on a typo'd or wrong-region lookup instead of silently falling back.
  default_tags {
    tags = var.tags
  }
}
