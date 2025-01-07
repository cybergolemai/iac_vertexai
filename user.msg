terraform {
    required_providers {
      google = {
        source  = "hashicorp/google"
        version = "~> 5.0"
      }
    }
  }
  
  provider "google" {
    project = var.project_id
    region  = var.region
  }
  
  # Variables
  variable "project_id" {
    description = "GCP Project ID"
    type        = string
  }
  
  variable "region" {
    description = "GCP region"
    type        = string
    default     = "us-central1"
  }
  
  # Standard labels
  locals {
    labels = {
      environment = "prod"
      managed_by  = "terraform"
      service     = "vertex-ai"
    }
  }
  
  # Cloud Function source code
  resource "local_file" "function_source" {
    filename = "${path.module}/main.py"
    content  = <<-EOT
  from typing import Dict, Any
  import functions_framework
  from google.cloud import aiplatform
  from google.cloud.aiplatform.gapic.schema import predict
  import json
  import logging
  
  logging.basicConfig(level=logging.INFO)
  logger = logging.getLogger(__name__)
  
  @functions_framework.http
  def handle_request(request):
      # Enable CORS
      if request.method == 'OPTIONS':
          headers = {
              'Access-Control-Allow-Origin': '*',
              'Access-Control-Allow-Methods': 'POST',
              'Access-Control-Allow-Headers': 'Content-Type',
              'Access-Control-Max-Age': '3600'
          }
          return ('', 204, headers)
  
      headers = {'Access-Control-Allow-Origin': '*'}
  
      try:
          request_json = request.get_json()
          if not request_json or 'prompt' not in request_json:
              return (json.dumps({'error': 'prompt is required'}), 400, headers)
  
          prompt = request_json.get('prompt')
          max_tokens = request_json.get('max_tokens', 4000)
          temperature = request_json.get('temperature', 0.7)
          model_id = request_json.get('model_id', 'text-bison@002')
  
          logger.info(f"Processing request for model: {model_id}")
  
          # Initialize Vertex AI
          aiplatform.init(project=PROJECT_ID, location=LOCATION)
  
          # Get model endpoint
          model = aiplatform.Model.list(
              filter=f'display_name={model_id}',
              order_by='create_time desc',
              location=LOCATION
          )[0]
  
          instance = predict.instance.TextGenerationPredictionInstance(
              prompt=prompt,
          ).to_value()
  
          parameters = predict.params.TextGenerationParams(
              max_output_tokens=max_tokens,
              temperature=temperature,
          ).to_value()
  
          prediction = model.predict([instance], parameters=parameters)
          
          return (json.dumps({
              'completion': prediction.predictions[0],
              'model': model_id
          }), 200, headers)
  
      except Exception as e:
          logger.error(f"Error processing request: {str(e)}")
          return (json.dumps({'error': str(e)}), 500, headers)
  EOT
  }
  
  # Requirements file
  resource "local_file" "requirements" {
    filename = "${path.module}/requirements.txt"
    content  = <<-EOT
  functions-framework==3.*
  google-cloud-aiplatform==1.*
  EOT
  }
  
  # Cloud Storage bucket with versioning and lifecycle
  resource "google_storage_bucket" "function_bucket" {
    name          = "${var.project_id}-function-source"
    location      = var.region
    force_destroy = true
    
    versioning {
      enabled = true
    }
    
    lifecycle_rule {
      condition {
        age = 30
      }
      action {
        type = "Delete"
      }
    }
  
    labels = local.labels
  }
  
  # ZIP the function source
  data "archive_file" "function_zip" {
    type        = "zip"
    output_path = "${path.module}/function.zip"
    
    source {
      content  = local_file.function_source.content
      filename = "main.py"
    }
    
    source {
      content  = local_file.requirements.content
      filename = "requirements.txt"
    }
  }
  
  # Upload ZIP to bucket
  resource "google_storage_bucket_object" "function_code" {
    name   = "function-${data.archive_file.function_zip.output_md5}.zip"
    bucket = google_storage_bucket.function_bucket.name
    source = data.archive_file.function_zip.output_path
  }
  
  # Cloud Function with improved configuration
  resource "google_cloudfunctions2_function" "function" {
    name        = "vertex-ai-api"
    location    = var.region
    description = "Vertex AI API Gateway"
    labels      = local.labels
  
    build_config {
      runtime     = "python311"
      entry_point = "handle_request"
      source {
        storage_source {
          bucket = google_storage_bucket.function_bucket.name
          object = google_storage_bucket_object.function_code.name
        }
      }
    }
  
    service_config {
      max_instance_count = 10
      min_instance_count = 1
      available_memory   = "256M"
      timeout_seconds    = 60
      ingress_settings   = "ALLOW_ALL"
      all_traffic_on_latest_revision = true
      max_instance_request_concurrency = 1
      service_account = google_service_account.function_account.email
      
      environment_variables = {
        PROJECT_ID   = var.project_id
        LOCATION     = var.region
        RUNTIME_ENV  = "prod"
        LOG_LEVEL    = "INFO"
      }
    }
  }
  
  # Service account
  resource "google_service_account" "function_account" {
    account_id   = "vertex-function"
    display_name = "Vertex AI Function Service Account"
  }
  
  # IAM role bindings
  resource "google_project_iam_member" "ai_platform" {
    project = var.project_id
    role    = "roles/aiplatform.user"
    member  = "serviceAccount:${google_service_account.function_account.email}"
  }
  
  resource "google_project_iam_member" "logging" {
    project = var.project_id
    role    = "roles/logging.logWriter"
    member  = "serviceAccount:${google_service_account.function_account.email}"
  }
  
  # Enable required APIs
  resource "google_project_service" "required_apis" {
    for_each = toset([
      "cloudfunctions.googleapis.com",
      "cloudbuild.googleapis.com",
      "artifactregistry.googleapis.com",
      "aiplatform.googleapis.com",
      "logging.googleapis.com"
    ])
    
    service = each.key
    disable_on_destroy = false
  }
  
  # Outputs
  output "function_uri" {
    value = google_cloudfunctions2_function.function.url
  }
  
  output "service_account" {
    value = google_service_account.function_account.email
  }

I need to customize this GCP Cloud Functions deployment. Generate a set of questions to ask to modify the terraform infrastructure as code. Once you are done asking questions and I have answered them: I want you to regenerate the terraform config.

Here are the questions I want you to ask me sequentially:
"""
What is the current region of your GCP account, and do you want to keep it the same or switch to another region?
Do you want to use a different VPC for your AI backend?
Do you want to allow inbound traffic on any port, or restrict it to specific ports (e.g., HTTPS on port 443 and HTTP on port 80)?
What is the desired duration for your log retention?
Would you like to keep the existing output values (instance_public_ip and bedrock_endpoint) or change them?
Do you have any other resources (e.g., buckets, BigQuery tables) that need to be configured as part of this Terraform deployment?"""

After each question has been answered: move to the next question. These 7 questions are the only 7.

After all 6 questions are complete: propose an AMI appropriate for the instance type.

The default setting """# Latest Ubuntu ARM AMI lookup
data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}""" assumes t4g.small instance type with ARM cpu. Validate CPU / AMI compatibility before finalizing the terraform config.

Finally, generate a new single-file main.tf with the backend code defined in-line.