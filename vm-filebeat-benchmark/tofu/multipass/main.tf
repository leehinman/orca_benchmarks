terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

variable "ssh_public_key_file" {
  description = "Path to SSH public key file to inject into the VM"
  type        = string
  default     = "~/.ssh/id_rsa_yubikey.pub"
}

variable "agent_cpus" {
  type    = number
  default = 1
}

variable "agent_memory" {
  type    = string
  default = "2G"
}

variable "agent_disk" {
  description = "Must hold the generated log files"
  type        = string
  default     = "30G"
}

locals {
  ssh_public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "local_file" "cloud_init" {
  content  = templatefile("${path.module}/../cloud-init.tftpl", { ssh_public_key = local.ssh_public_key })
  filename = "${path.module}/cloud-init.yaml"
}

# The larstobi/multipass provider mis-parses "Launched: <name> in <zone>" from
# multipass 1.17+, so the VM is managed with the multipass CLI directly.
locals {
  name = "bench-filebeat-agent"
}

variable "launch_timeout_seconds" {
  type    = number
  default = 600
}

locals {
  spec = {
    name       = local.name
    cpus       = var.agent_cpus
    memory     = var.agent_memory
    disk       = var.agent_disk
    cloud_init = local_file.cloud_init.content
  }
}

resource "terraform_data" "agent" {
  input            = local.spec
  triggers_replace = local.spec

  provisioner "local-exec" {
    command = "multipass launch lts --name ${local.name} --cpus ${var.agent_cpus} --memory ${var.agent_memory} --disk ${var.agent_disk} --cloud-init ${abspath(local_file.cloud_init.filename)} --timeout ${var.launch_timeout_seconds}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "multipass delete --purge ${self.input.name}"
  }
}

data "external" "agent" {
  program    = ["sh", "-c", "printf '{\"ip\":\"%s\"}' \"$(multipass info ${local.name} | awk '/^IPv4:/{print $2; exit}')\""]
  depends_on = [terraform_data.agent]
}

output "agent_ip" {
  value = data.external.agent.result.ip
}

output "agent_internal_ip" {
  value = data.external.agent.result.ip
}

output "agent_hostname" {
  value = local.name
}
