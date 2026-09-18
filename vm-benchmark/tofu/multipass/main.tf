terraform {
  required_providers {
    multipass = {
      source  = "larstobi/multipass"
      version = "~> 1.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

variable "ssh_public_key_file" {
  description = "Path to SSH public key file to inject into the VM"
  type        = string
  default     = "~/.ssh/id_rsa_yubikey.pub"
}

# Multipass VMs have a single address, so the internal outputs mirror the
# public ones and hostnames equal instance names.

variable "agent_count" {
  description = "Number of elastic-agent VMs to provision"
  type        = number
  default     = 3

  validation {
    condition     = var.agent_count >= 0 && var.agent_count <= 8
    error_message = "agent_count must be between 0 and 8; the per-index outputs only go to 7."
  }
}

locals {
  ssh_public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "local_file" "cloud_init" {
  content  = templatefile("${path.module}/../cloud-init.tftpl", { ssh_public_key = local.ssh_public_key })
  filename = "${path.module}/cloud-init.yaml"
}

resource "multipass_instance" "elasticsearch" {
  name           = "bench-elasticsearch"
  image          = "lts"
  memory         = "8G"
  disk           = "30G"
  cloudinit_file = local_file.cloud_init.filename
}

resource "multipass_instance" "kibana" {
  name           = "bench-kibana"
  image          = "lts"
  cpus           = 2
  memory         = "6G"
  disk           = "30G"
  cloudinit_file = local_file.cloud_init.filename
}

resource "multipass_instance" "fleet_server" {
  name           = "bench-fleet-server"
  image          = "lts"
  memory         = "2G"
  disk           = "30G"
  cloudinit_file = local_file.cloud_init.filename
}

resource "multipass_instance" "elastic_agent" {
  count          = var.agent_count
  name           = "bench-elastic-agent-${count.index}"
  image          = "lts"
  memory         = "2G"
  disk           = "30G"
  cloudinit_file = local_file.cloud_init.filename
}

# One generator VM (vegeta + loggen) per elastic-agent VM.
resource "multipass_instance" "generator" {
  count          = var.agent_count
  name           = "bench-generator-${count.index}"
  image          = "lts"
  memory         = "2G"
  disk           = "30G"
  cloudinit_file = local_file.cloud_init.filename
}

locals {
  all_ips = concat(
    [
      multipass_instance.elasticsearch.ipv4,
      multipass_instance.kibana.ipv4,
      multipass_instance.fleet_server.ipv4,
    ],
    multipass_instance.elastic_agent[*].ipv4,
    multipass_instance.generator[*].ipv4,
  )
}

output "elasticsearch_ip" {
  value = multipass_instance.elasticsearch.ipv4

  precondition {
    condition     = length(distinct(local.all_ips)) == length(local.all_ips)
    error_message = "multipass assigned duplicate IPs (${join(", ", local.all_ips)}); stale DHCP leases in /var/db/dhcpd_leases are the usual cause, see README."
  }
}

output "elasticsearch_internal_ip" {
  value = multipass_instance.elasticsearch.ipv4
}

output "kibana_ip" {
  value = multipass_instance.kibana.ipv4
}

output "kibana_internal_ip" {
  value = multipass_instance.kibana.ipv4
}

output "fleet_server_ip" {
  value = multipass_instance.fleet_server.ipv4
}

output "fleet_server_internal_ip" {
  value = multipass_instance.fleet_server.ipv4
}

output "elastic_agent_ip_0" {
  value = var.agent_count > 0 ? multipass_instance.elastic_agent[0].ipv4 : ""
}

output "elastic_agent_internal_ip_0" {
  value = var.agent_count > 0 ? multipass_instance.elastic_agent[0].ipv4 : ""
}

output "elastic_agent_hostname_0" {
  value = var.agent_count > 0 ? multipass_instance.elastic_agent[0].name : ""
}

output "elastic_agent_ip_1" {
  value = var.agent_count > 1 ? multipass_instance.elastic_agent[1].ipv4 : ""
}

output "elastic_agent_internal_ip_1" {
  value = var.agent_count > 1 ? multipass_instance.elastic_agent[1].ipv4 : ""
}

output "elastic_agent_hostname_1" {
  value = var.agent_count > 1 ? multipass_instance.elastic_agent[1].name : ""
}

output "elastic_agent_ip_2" {
  value = var.agent_count > 2 ? multipass_instance.elastic_agent[2].ipv4 : ""
}

output "elastic_agent_internal_ip_2" {
  value = var.agent_count > 2 ? multipass_instance.elastic_agent[2].ipv4 : ""
}

output "elastic_agent_hostname_2" {
  value = var.agent_count > 2 ? multipass_instance.elastic_agent[2].name : ""
}

output "elastic_agent_ip_3" {
  value = var.agent_count > 3 ? multipass_instance.elastic_agent[3].ipv4 : ""
}

output "elastic_agent_internal_ip_3" {
  value = var.agent_count > 3 ? multipass_instance.elastic_agent[3].ipv4 : ""
}

output "elastic_agent_hostname_3" {
  value = var.agent_count > 3 ? multipass_instance.elastic_agent[3].name : ""
}

output "elastic_agent_ip_4" {
  value = var.agent_count > 4 ? multipass_instance.elastic_agent[4].ipv4 : ""
}

output "elastic_agent_internal_ip_4" {
  value = var.agent_count > 4 ? multipass_instance.elastic_agent[4].ipv4 : ""
}

output "elastic_agent_hostname_4" {
  value = var.agent_count > 4 ? multipass_instance.elastic_agent[4].name : ""
}

output "elastic_agent_ip_5" {
  value = var.agent_count > 5 ? multipass_instance.elastic_agent[5].ipv4 : ""
}

output "elastic_agent_internal_ip_5" {
  value = var.agent_count > 5 ? multipass_instance.elastic_agent[5].ipv4 : ""
}

output "elastic_agent_hostname_5" {
  value = var.agent_count > 5 ? multipass_instance.elastic_agent[5].name : ""
}

output "elastic_agent_ip_6" {
  value = var.agent_count > 6 ? multipass_instance.elastic_agent[6].ipv4 : ""
}

output "elastic_agent_internal_ip_6" {
  value = var.agent_count > 6 ? multipass_instance.elastic_agent[6].ipv4 : ""
}

output "elastic_agent_hostname_6" {
  value = var.agent_count > 6 ? multipass_instance.elastic_agent[6].name : ""
}

output "elastic_agent_ip_7" {
  value = var.agent_count > 7 ? multipass_instance.elastic_agent[7].ipv4 : ""
}

output "elastic_agent_internal_ip_7" {
  value = var.agent_count > 7 ? multipass_instance.elastic_agent[7].ipv4 : ""
}

output "elastic_agent_hostname_7" {
  value = var.agent_count > 7 ? multipass_instance.elastic_agent[7].name : ""
}

output "generator_ip_0" {
  value = var.agent_count > 0 ? multipass_instance.generator[0].ipv4 : ""
}

output "generator_internal_ip_0" {
  value = var.agent_count > 0 ? multipass_instance.generator[0].ipv4 : ""
}

output "generator_hostname_0" {
  value = var.agent_count > 0 ? multipass_instance.generator[0].name : ""
}

output "generator_ip_1" {
  value = var.agent_count > 1 ? multipass_instance.generator[1].ipv4 : ""
}

output "generator_internal_ip_1" {
  value = var.agent_count > 1 ? multipass_instance.generator[1].ipv4 : ""
}

output "generator_hostname_1" {
  value = var.agent_count > 1 ? multipass_instance.generator[1].name : ""
}

output "generator_ip_2" {
  value = var.agent_count > 2 ? multipass_instance.generator[2].ipv4 : ""
}

output "generator_internal_ip_2" {
  value = var.agent_count > 2 ? multipass_instance.generator[2].ipv4 : ""
}

output "generator_hostname_2" {
  value = var.agent_count > 2 ? multipass_instance.generator[2].name : ""
}

output "generator_ip_3" {
  value = var.agent_count > 3 ? multipass_instance.generator[3].ipv4 : ""
}

output "generator_internal_ip_3" {
  value = var.agent_count > 3 ? multipass_instance.generator[3].ipv4 : ""
}

output "generator_hostname_3" {
  value = var.agent_count > 3 ? multipass_instance.generator[3].name : ""
}

output "generator_ip_4" {
  value = var.agent_count > 4 ? multipass_instance.generator[4].ipv4 : ""
}

output "generator_internal_ip_4" {
  value = var.agent_count > 4 ? multipass_instance.generator[4].ipv4 : ""
}

output "generator_hostname_4" {
  value = var.agent_count > 4 ? multipass_instance.generator[4].name : ""
}

output "generator_ip_5" {
  value = var.agent_count > 5 ? multipass_instance.generator[5].ipv4 : ""
}

output "generator_internal_ip_5" {
  value = var.agent_count > 5 ? multipass_instance.generator[5].ipv4 : ""
}

output "generator_hostname_5" {
  value = var.agent_count > 5 ? multipass_instance.generator[5].name : ""
}

output "generator_ip_6" {
  value = var.agent_count > 6 ? multipass_instance.generator[6].ipv4 : ""
}

output "generator_internal_ip_6" {
  value = var.agent_count > 6 ? multipass_instance.generator[6].ipv4 : ""
}

output "generator_hostname_6" {
  value = var.agent_count > 6 ? multipass_instance.generator[6].name : ""
}

output "generator_ip_7" {
  value = var.agent_count > 7 ? multipass_instance.generator[7].ipv4 : ""
}

output "generator_internal_ip_7" {
  value = var.agent_count > 7 ? multipass_instance.generator[7].ipv4 : ""
}

output "generator_hostname_7" {
  value = var.agent_count > 7 ? multipass_instance.generator[7].name : ""
}
