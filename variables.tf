variable "name" {
  type = "string"
}
variable "environment" {
  description = "The environment that generally corresponds to the account you are deploying into."
}

variable "tags" {
  description = "Tags that are appended"
  type        = map(string)
}

//variable "private_subnets" {
//  type = list(string)
//}

variable "instance_type" {}
variable "root_volume_size" {}
variable "volume_path" {}

//variable "local_private_key" {} # TODO Only needed for remote calls but commented out now

variable "azs" {
  description = "The availablity zones to deploy each ebs volume into."
  type        = list(string)
}

variable "ebs_volume_size" {
  description = "...."
}

//-----

variable "key_name" {}

variable "security_groups" {
  type = list
}
variable "subnet_id" {}

variable "instance_profile_id" {}

//variable "file_system_id" {
//  description = "The EFS file system id"
//}


variable "log_config_bucket" {}
variable "log_config_key" {}


variable "user_data_script" {
  type = string
  default = "user_data_ubuntu_ebs.sh"
}
