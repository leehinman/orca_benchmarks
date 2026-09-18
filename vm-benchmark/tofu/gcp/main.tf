terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

variable "gcp_project" {
  description = "GCP project ID"
  type        = string
  default     = "elastic-platform-ingest"
}

variable "gcp_region" {
  type    = string
  default = "us-central1"
}

variable "gcp_zone" {
  type    = string
  default = "us-central1-a"
}

variable "owner" {
  description = "Resource name prefix and value of the project label"
  type        = string
  default     = "leeehinman"
}

variable "operator_cidr" {
  description = "CIDR allowed to reach SSH, Elasticsearch, and Kibana; defaults to the caller's public IP"
  type        = string
  default     = ""
}

variable "ssh_public_key_file" {
  type    = string
  default = "~/.ssh/id_rsa_yubikey.pub"
}

variable "agent_count" {
  type    = number
  default = 3

  validation {
    condition     = var.agent_count >= 0 && var.agent_count <= 8
    error_message = "agent_count must be between 0 and 8; the per-index outputs only go to 7."
  }
}

variable "image" {
  description = "Boot image for the Elasticsearch, Kibana, and Fleet Server VMs"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "agent_image" {
  description = "Boot image for the agent VMs; must match the agent machine type architecture"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "elasticsearch_machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "kibana_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "fleet_server_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "agent_machine_type" {
  description = "Agent VM type; e2-highcpu-2 (2 vCPU, 2 GB, shared-core) is E2's broadest, most-available shape and matches the memory of the multipass agents. n2d-highcpu-2 is faster (one physical AMD core, two hyperthreads) but its fleet is smaller and more prone to zone stockouts; t2d-standard-1 and n1-standard-1 are smaller/slower fleets still. For arm64 use c4a-highcpu-1 or n4a-highcpu-1 with the arm64 image and hyperdisk-balanced"
  type        = string
  default     = "e2-highcpu-2"
}

variable "disk_type" {
  description = "Boot disk type for the stack VMs"
  type        = string
  default     = "pd-balanced"
}

variable "agent_disk_type" {
  description = "Boot disk type for the agent VMs; C4A and N4A require hyperdisk-balanced"
  type        = string
  default     = "pd-balanced"
}

variable "elasticsearch_disk_gb" {
  type    = number
  default = 100
}

variable "disk_gb" {
  type    = number
  default = 30
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
  zone    = var.gcp_zone
}

data "http" "my_ip" {
  count = var.operator_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  prefix         = "${var.owner}-bench"
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
  operator_cidr  = var.operator_cidr != "" ? var.operator_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"
  labels = {
    division  = "engineering"
    org       = "obs"
    team      = "elastic-agent"
    project   = var.owner
    ephemeral = "true"
  }
  user_data = templatefile("${path.module}/../cloud-init.tftpl", { ssh_public_key = local.ssh_public_key })
  roles = {
    elasticsearch = { machine_type = var.elasticsearch_machine_type, disk_gb = var.elasticsearch_disk_gb }
    kibana        = { machine_type = var.kibana_machine_type, disk_gb = var.disk_gb }
    fleet_server  = { machine_type = var.fleet_server_machine_type, disk_gb = var.disk_gb }
  }
}

resource "google_compute_network" "bench" {
  name                    = "${local.prefix}-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "bench" {
  name          = "${local.prefix}-subnet"
  network       = google_compute_network.bench.id
  ip_cidr_range = "10.80.0.0/24"
  region        = var.gcp_region
}

resource "google_compute_firewall" "internal" {
  name    = "${local.prefix}-allow-internal"
  network = google_compute_network.bench.name

  allow {
    protocol = "all"
  }
  source_tags = [local.prefix]
  target_tags = [local.prefix]
}

resource "google_compute_firewall" "operator" {
  name    = "${local.prefix}-allow-operator"
  network = google_compute_network.bench.name

  allow {
    protocol = "tcp"
    ports    = ["22", "9200", "5601"]
  }
  source_ranges = [local.operator_cidr]
  target_tags   = [local.prefix]
}

resource "google_compute_instance" "stack" {
  for_each     = local.roles
  name         = "${local.prefix}-${replace(each.key, "_", "-")}"
  machine_type = each.value.machine_type
  zone         = var.gcp_zone
  tags         = [local.prefix]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image  = var.image
      size   = each.value.disk_gb
      type   = var.disk_type
      labels = local.labels
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.bench.id
    access_config {}
  }

  metadata = {
    user-data = local.user_data
  }
}

resource "google_compute_instance" "elastic_agent" {
  count        = var.agent_count
  name         = "${local.prefix}-elastic-agent-${count.index}"
  machine_type = var.agent_machine_type
  zone         = var.gcp_zone
  tags         = [local.prefix]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image  = var.agent_image
      size   = var.disk_gb
      type   = var.agent_disk_type
      labels = local.labels
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.bench.id
    access_config {}
  }

  metadata = {
    user-data = local.user_data
  }
}

resource "google_compute_instance" "generator" {
  count        = var.agent_count
  name         = "${local.prefix}-generator-${count.index}"
  machine_type = var.agent_machine_type
  zone         = var.gcp_zone
  tags         = [local.prefix]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image  = var.agent_image
      size   = var.disk_gb
      type   = var.agent_disk_type
      labels = local.labels
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.bench.id
    access_config {}
  }

  metadata = {
    user-data = local.user_data
  }
}

output "operator_cidr" {
  value = local.operator_cidr
}

output "elasticsearch_ip" {
  value = google_compute_instance.stack["elasticsearch"].network_interface[0].access_config[0].nat_ip
}

output "elasticsearch_internal_ip" {
  value = google_compute_instance.stack["elasticsearch"].network_interface[0].network_ip
}

output "kibana_ip" {
  value = google_compute_instance.stack["kibana"].network_interface[0].access_config[0].nat_ip
}

output "kibana_internal_ip" {
  value = google_compute_instance.stack["kibana"].network_interface[0].network_ip
}

output "fleet_server_ip" {
  value = google_compute_instance.stack["fleet_server"].network_interface[0].access_config[0].nat_ip
}

output "fleet_server_internal_ip" {
  value = google_compute_instance.stack["fleet_server"].network_interface[0].network_ip
}

output "elastic_agent_ip_0" {
  value = var.agent_count > 0 ? google_compute_instance.elastic_agent[0].network_interface[0].access_config[0].nat_ip : ""
}

output "elastic_agent_internal_ip_0" {
  value = var.agent_count > 0 ? google_compute_instance.elastic_agent[0].network_interface[0].network_ip : ""
}

output "elastic_agent_hostname_0" {
  value = var.agent_count > 0 ? google_compute_instance.elastic_agent[0].name : ""
}

output "elastic_agent_ip_1" {
  value = var.agent_count > 1 ? google_compute_instance.elastic_agent[1].network_interface[0].access_config[0].nat_ip : ""
}

output "elastic_agent_internal_ip_1" {
  value = var.agent_count > 1 ? google_compute_instance.elastic_agent[1].network_interface[0].network_ip : ""
}

output "elastic_agent_hostname_1" {
  value = var.agent_count > 1 ? google_compute_instance.elastic_agent[1].name : ""
}

output "elastic_agent_ip_2" {
  value = var.agent_count > 2 ? google_compute_instance.elastic_agent[2].network_interface[0].access_config[0].nat_ip : ""
}

output "elastic_agent_internal_ip_2" {
  value = var.agent_count > 2 ? google_compute_instance.elastic_agent[2].network_interface[0].network_ip : ""
}

output "elastic_agent_hostname_2" {
  value = var.agent_count > 2 ? google_compute_instance.elastic_agent[2].name : ""
}

output "elastic_agent_ip_3" {
  value = var.agent_count > 3 ? google_compute_instance.elastic_agent[3].network_interface[0].access_config[0].nat_ip : ""
}

output "elastic_agent_internal_ip_3" {
  value = var.agent_count > 3 ? google_compute_instance.elastic_agent[3].network_interface[0].network_ip : ""
}

output "elastic_agent_hostname_3" {
  value = var.agent_count > 3 ? google_compute_instance.elastic_agent[3].name : ""
}

output "elastic_agent_ip_4" {
  value = var.agent_count > 4 ? google_compute_instance.elastic_agent[4].network_interface[0].access_config[0].nat_ip : ""
}

output "elastic_agent_internal_ip_4" {
  value = var.agent_count > 4 ? google_compute_instance.elastic_agent[4].network_interface[0].network_ip : ""
}

output "elastic_agent_hostname_4" {
  value = var.agent_count > 4 ? google_compute_instance.elastic_agent[4].name : ""
}

output "elastic_agent_ip_5" {
  value = var.agent_count > 5 ? google_compute_instance.elastic_agent[5].network_interface[0].access_config[0].nat_ip : ""
}

output "elastic_agent_internal_ip_5" {
  value = var.agent_count > 5 ? google_compute_instance.elastic_agent[5].network_interface[0].network_ip : ""
}

output "elastic_agent_hostname_5" {
  value = var.agent_count > 5 ? google_compute_instance.elastic_agent[5].name : ""
}

output "elastic_agent_ip_6" {
  value = var.agent_count > 6 ? google_compute_instance.elastic_agent[6].network_interface[0].access_config[0].nat_ip : ""
}

output "elastic_agent_internal_ip_6" {
  value = var.agent_count > 6 ? google_compute_instance.elastic_agent[6].network_interface[0].network_ip : ""
}

output "elastic_agent_hostname_6" {
  value = var.agent_count > 6 ? google_compute_instance.elastic_agent[6].name : ""
}

output "elastic_agent_ip_7" {
  value = var.agent_count > 7 ? google_compute_instance.elastic_agent[7].network_interface[0].access_config[0].nat_ip : ""
}

output "elastic_agent_internal_ip_7" {
  value = var.agent_count > 7 ? google_compute_instance.elastic_agent[7].network_interface[0].network_ip : ""
}

output "elastic_agent_hostname_7" {
  value = var.agent_count > 7 ? google_compute_instance.elastic_agent[7].name : ""
}

output "generator_ip_0" {
  value = var.agent_count > 0 ? google_compute_instance.generator[0].network_interface[0].access_config[0].nat_ip : ""
}

output "generator_internal_ip_0" {
  value = var.agent_count > 0 ? google_compute_instance.generator[0].network_interface[0].network_ip : ""
}

output "generator_hostname_0" {
  value = var.agent_count > 0 ? google_compute_instance.generator[0].name : ""
}

output "generator_ip_1" {
  value = var.agent_count > 1 ? google_compute_instance.generator[1].network_interface[0].access_config[0].nat_ip : ""
}

output "generator_internal_ip_1" {
  value = var.agent_count > 1 ? google_compute_instance.generator[1].network_interface[0].network_ip : ""
}

output "generator_hostname_1" {
  value = var.agent_count > 1 ? google_compute_instance.generator[1].name : ""
}

output "generator_ip_2" {
  value = var.agent_count > 2 ? google_compute_instance.generator[2].network_interface[0].access_config[0].nat_ip : ""
}

output "generator_internal_ip_2" {
  value = var.agent_count > 2 ? google_compute_instance.generator[2].network_interface[0].network_ip : ""
}

output "generator_hostname_2" {
  value = var.agent_count > 2 ? google_compute_instance.generator[2].name : ""
}

output "generator_ip_3" {
  value = var.agent_count > 3 ? google_compute_instance.generator[3].network_interface[0].access_config[0].nat_ip : ""
}

output "generator_internal_ip_3" {
  value = var.agent_count > 3 ? google_compute_instance.generator[3].network_interface[0].network_ip : ""
}

output "generator_hostname_3" {
  value = var.agent_count > 3 ? google_compute_instance.generator[3].name : ""
}

output "generator_ip_4" {
  value = var.agent_count > 4 ? google_compute_instance.generator[4].network_interface[0].access_config[0].nat_ip : ""
}

output "generator_internal_ip_4" {
  value = var.agent_count > 4 ? google_compute_instance.generator[4].network_interface[0].network_ip : ""
}

output "generator_hostname_4" {
  value = var.agent_count > 4 ? google_compute_instance.generator[4].name : ""
}

output "generator_ip_5" {
  value = var.agent_count > 5 ? google_compute_instance.generator[5].network_interface[0].access_config[0].nat_ip : ""
}

output "generator_internal_ip_5" {
  value = var.agent_count > 5 ? google_compute_instance.generator[5].network_interface[0].network_ip : ""
}

output "generator_hostname_5" {
  value = var.agent_count > 5 ? google_compute_instance.generator[5].name : ""
}

output "generator_ip_6" {
  value = var.agent_count > 6 ? google_compute_instance.generator[6].network_interface[0].access_config[0].nat_ip : ""
}

output "generator_internal_ip_6" {
  value = var.agent_count > 6 ? google_compute_instance.generator[6].network_interface[0].network_ip : ""
}

output "generator_hostname_6" {
  value = var.agent_count > 6 ? google_compute_instance.generator[6].name : ""
}

output "generator_ip_7" {
  value = var.agent_count > 7 ? google_compute_instance.generator[7].network_interface[0].access_config[0].nat_ip : ""
}

output "generator_internal_ip_7" {
  value = var.agent_count > 7 ? google_compute_instance.generator[7].network_interface[0].network_ip : ""
}

output "generator_hostname_7" {
  value = var.agent_count > 7 ? google_compute_instance.generator[7].name : ""
}
