provider "google" {
  project = var.project
  region  = var.region
}

provider "google-beta" {
  project = var.project
  region  = var.region
}

resource "google_service_account" "main" {
  account_id   = "${var.base}-main"
  display_name = "Main service account"
  description  = "Main service account"
}

resource "google_service_account" "developer" {
  account_id   = "${var.base}-developer"
  display_name = "Developer service account"
  description  = "Developer service account"
}

resource "google_compute_network" "network" {
  auto_create_subnetworks         = false
  delete_default_routes_on_create = true
  name                            = "${var.base}-network"
}

resource "google_compute_global_address" "peering-ip-range" {
  name          = "peering-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = google_compute_network.network.id
}

resource "google_service_networking_connection" "default" {
  network                 = google_compute_network.network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.peering-ip-range.name]
}

resource "google_sql_database_instance" "simple-budget-db" {
  name                = "simple-budget-db"
  database_version    = "POSTGRES_15"
  region              = "us-central1"
  deletion_protection = "false"

  depends_on = [google_service_networking_connection.default]

  settings {
    tier = "db-f1-micro"

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    ip_configuration {
      ipv4_enabled    = "false"
      private_network = google_compute_network.network.id
    }
  }
}

resource "google_compute_network_peering_routes_config" "peering_routes" {
  peering              = google_service_networking_connection.default.peering
  network              = google_compute_network.network.name
  import_custom_routes = true
  export_custom_routes = true
}

resource "google_project_iam_member" "developer-cloudsql-client-role" {
  project = var.project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.developer.email}"
}

resource "google_project_iam_member" "developer-cloudsql-instance-role" {
  project = var.project
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.developer.email}"
}

resource "google_sql_user" "developer-user" {
  name     = replace(google_service_account.developer.email, ".gserviceaccount.com", "")
  instance = google_sql_database_instance.simple-budget-db.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_compute_subnetwork" "database-connector-subnetwork" {
  ip_cidr_range            = "10.11.0.0/28"
  name                     = "${var.base}-database-connector-subnetwork"
  network                  = google_compute_network.network.id
  private_ip_google_access = true
}

resource "google_vpc_access_connector" "database-connector" {
  name = "database-connector"
  subnet {
    name = google_compute_subnetwork.database-connector-subnetwork.name
  }
  machine_type  = "e2-micro"
  max_instances = 3
  min_instances = 2
}

resource "google_compute_route" "internet-gateway" {
  name             = "${var.base}-internet-gateway"
  dest_range       = "0.0.0.0/0"
  network          = google_compute_network.network.name
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_compute_instance" "bastion-instance" {
  name         = "bastion"
  machine_type = "e2-micro"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-2304-lunar-amd64-v20230530"
      type  = "pd-standard"
    }
  }

  depends_on = [google_service_networking_connection.default]

  tags = ["${var.base}-bastion"]

  allow_stopping_for_update = true

  network_interface {
    subnetwork = google_compute_subnetwork.database-connector-subnetwork.name
    access_config {}
  }

  service_account {
    email  = google_service_account.developer.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_firewall" "bastion-ssh" {
  name    = "bastion-ssh"
  network = google_compute_network.network.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["136.62.241.113/32"]
  target_tags   = ["${var.base}-bastion"]
}

resource "google_secret_manager_secret" "database-secrets" {
  for_each = toset(var.secrets)

  secret_id = "database-${each.key}"
  replication {
    automatic = true
  }
}

resource "google_artifact_registry_repository" "docker-repository" {
  location      = "us-central1"
  repository_id = var.base
  format        = "DOCKER"
}