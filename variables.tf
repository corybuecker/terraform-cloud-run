variable "base" {
  type    = string
  default = "houston"
}

variable "project" {
  type    = string
  default = "bueckered-272522"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "secrets" {
  type    = list(any)
  default = ["admin", "user"]
}