#!/usr/bin/env bash

LOG_TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_COMMAND="${1:-help}"
LOG_FILE="$BOB_LOG_DIR/bobctl-${LOG_COMMAND}-${LOG_TIMESTAMP}.log"

mkdir -p "$BOB_LOG_DIR"
touch "$LOG_FILE"

if [[ -n "${NOCOLOR:-}" ]]; then
  LOG_COLOR_INFO=""
  LOG_COLOR_WARN=""
  LOG_COLOR_ERROR=""
  LOG_COLOR_RESET=""
else
  LOG_COLOR_INFO=$'\033[0;32m'
  LOG_COLOR_WARN=$'\033[0;33m'
  LOG_COLOR_ERROR=$'\033[0;31m'
  LOG_COLOR_RESET=$'\033[0m'
fi

write_log_entry() {
  local level="$1"
  shift
  printf '%s %s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$level" "$*" >> "$LOG_FILE"
}

log_info() {
  write_log_entry "INFO" "$@"
  printf '%b\n' "${LOG_COLOR_INFO}$*${LOG_COLOR_RESET}"
}

log_dry_run() {
  write_log_entry "DRY-RUN" "$@"
  printf '%b\n' "${LOG_COLOR_WARN}[DRY-RUN] $*${LOG_COLOR_RESET}"
}

log_warn() {
  write_log_entry "WARN" "$@"
  printf '%b\n' "${LOG_COLOR_WARN}$*${LOG_COLOR_RESET}"
}

log_error() {
  write_log_entry "ERROR" "$@"
  printf '%b\n' "${LOG_COLOR_ERROR}$*${LOG_COLOR_RESET}" >&2
}

usage() {
  log_info "Usage: $0 <command> [options]"
  log_info ""
  log_info "Commands:"
  log_info ""
  log_info "  generate-cluster-resources"
  log_info "          Render cluster-scoped resources to release/work directory"
  log_info ""
  log_info "  install [--registry-creds <username:password>] [--model-config <filepath>] [--dry-run]"
  log_info "          Install IBM Bob using Helm with config.yaml values"
  log_info "          Options:"
  log_info "            --registry-creds <username:password>   Registry credentials for image pull secret"
  log_info "            --model-config <filepath>              Optional: File path to model config to use for installation (file path must exist)"
  log_info ""
  log_info "  upgrade [--dry-run]"
  log_info "          Upgrade IBM Bob using Helm with config.yaml values"
  log_info "          Note: Uses imagePullSecret from config.yaml (does not accept --registry-creds)"
  log_info ""
  log_info "  add-ldap --config <file> [--bind-password <password>] [--ca-cert-file <path>] [--dry-run]"
  log_info "          Create a BobLDAP CR to integrate an LDAP/AD user federation provider"
  log_info "          Options:"
  log_info "            --config <file>            Required: Path to the LDAP configuration file"
  log_info "                                       Copy config-ldap-template.yaml to get started"
  log_info "            --bind-password <password> Optional: Creates the bindPasswordSecret in the cluster"
  log_info "            --ca-cert-file <path>      Optional: Creates the ldapsCACertSecret from a PEM file"
  log_info ""
  log_info "  get-ca-cert [--output <file>]"
  log_info "          Extract the CA certificate used by IBM Bob and print distribution instructions"
  log_info "          Options:"
  log_info "            --output <file>   Optional: Write the certificate to a file instead of printing it inline"
  log_info ""
  log_info "  setup-route --tls-secret <secret> [--no-wait] [--dry-run]"
  log_info "          Install a custom TLS certificate for IBM Bob"
  log_info "          Options:"
  log_info "            --tls-secret <secret>  Required: Name of the secret containing the TLS certificate"
  log_info "            --no-wait              Optional: Skip waiting for the change to take effect"
  log_info ""
  log_info "  reset-route [--no-wait] [--dry-run]"
  log_info "          Remove the custom TLS certificate and revert to the IBM Bob default"
  log_info "          Options:"
  log_info "            --no-wait  Optional: Skip waiting for the change to take effect"
  log_info ""
  log_info "  mirror-images --dest-registry <registry> --src-creds <username:password> [--arch ( amd64 | s390x )] [--dest-creds <username:password>] [--dry-run]"
  log_info "          Mirror images directly from source to destination registry"
  log_info "          Options:"
  log_info "            --dest-registry <registry>       Required: Target registry URL for mirrored images"
  log_info "            --src-creds <username:password>  Required: Source registry credentials"
  log_info "            --arch ( amd64 | s390x )         Optional: Filter images by cluster architecture"
  log_info "            --dest-creds <username:password> Optional: Destination registry credentials"
  log_info ""
  log_info "  download-images --to-dir <directory> --src-creds <username:password> [--arch ( amd64 | s390x )] [--dry-run]"
  log_info "          Download images from source registry to filesystem"
  log_info "          Options:"
  log_info "            --to-dir <directory>             Required: Directory path to download images to"
  log_info "            --src-creds <username:password>  Required: Source registry credentials"
  log_info "            --arch ( amd64 | s390x )         Optional: Filter images by cluster architecture"
  log_info ""
  log_info "  upload-images --from-dir <directory> --dest-registry <registry> [--dest-creds <username:password>] [--dry-run]"
  log_info "          Upload images from filesystem to destination registry"
  log_info "          Options:"
  log_info "            --from-dir <directory>           Required: Directory path containing downloaded images"
  log_info "            --dest-registry <registry>       Required: Target registry URL"
  log_info "            --dest-creds <username:password> Optional: Destination registry credentials"
  log_info ""
  log_info "Common Options:"
  log_info "  --dry-run                        Show what would be executed without actually executing"
  exit 1
}

read_config_value() {
  local key="$1"
  local config_file="$2"
  local value

  value=$(grep -E -e "^\s*${key}:" "$config_file" | head -1 | cut -d':' -f2 | cut -d'#' -f1 | tr -d ' ')

  echo "$value"
}

check_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    log_error "'helm' command not found"
    log_info "Please install Helm and ensure it's in your PATH"
    exit 1
  fi

  local helm_version
  helm_version=$(helm version --short 2>/dev/null || helm version 2>/dev/null | head -1)
  log_info "Helm version: ${helm_version}"

  # Extract version string (e.g., "3.14.0" from "v3.14.0+g...")
  local version_string="${helm_version#*v}"
  version_string="${version_string%%[+~-]*}"

  # Extract major, minor, patch using parameter expansion
  local major="${version_string%%.*}"
  local rest="${version_string#*.}"
  local minor="${rest%%.*}"
  local patch="${rest#*.}"
  patch="${patch%%.*}"

  # Set defaults if extraction failed
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  # Check minimum version 3.14.0 for '--reset-then-reuse-values'
  if [[ "$major" -lt 3 ]] || \
     [[ "$major" -eq 3 && "$minor" -lt 14 ]]; then
    log_error "Helm version ${major}.${minor}.${patch} is not supported"
    log_info "Minimum required version is 3.14.0"
    log_info "Please upgrade Helm to version 3.14.0 or later"
    exit 1
  fi

  # Extract major version number for compatibility
  export HELM_MAJOR_VERSION="$major"
}

check_oc_login() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Skipping cluster connection check (dry-run mode)"
    return 0
  fi

  if ! command -v oc >/dev/null 2>&1; then
    log_error "'oc' command not found"
    log_info "Please install the OpenShift CLI (oc) and ensure it's in your PATH"
    exit 1
  fi

  if ! oc whoami >/dev/null 2>&1; then
    log_error "Not logged into an OpenShift cluster"
    log_info "Please login using: oc login <cluster-url>"
    exit 1
  fi

  log_info "Connected to cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"

  local oc_version
  oc_version=$(oc version --client 2>/dev/null || oc version 2>/dev/null | head -1)
  log_info "OpenShift CLI version: ${oc_version}"
}

check_cert_manager() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Skipping cert-manager check (dry-run mode)"
    return 0
  fi

  if ! oc api-resources --api-group=cert-manager.io --no-headers 2>/dev/null | grep -q .; then
    log_error "cert-manager is not installed in the cluster"
    log_info "Please install cert-manager before installing IBM Bob"
    log_info "  On OpenShift: Install 'cert-manager Operator for Red Hat OpenShift' from OperatorHub"
    log_info "    See: https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/cert-manager-operator-install.html"
    log_info "  Upstream cert-manager: https://cert-manager.io/docs/installation/"
    exit 1
  fi

  log_info "cert-manager is installed"
}

validate_namespace() {
  local namespace_key="$1"
  local config_file="$2"
  local namespace_value

  namespace_value=$(read_config_value "$namespace_key" "$config_file")

  if [[ -z "$namespace_value" ]]; then
    log_error "${namespace_key} not found in $config_file"
    log_info "Please set global.${namespace_key} in $config_file"
    exit 1
  fi

  if ! oc get namespace "$namespace_value" >/dev/null 2>&1; then
    log_error "Namespace '${namespace_value}' does not exist"
    log_info "Please create the namespace first or update $config_file"
    exit 1
  fi

  echo "$namespace_value"
}

validate_storageclass() {
  local sc_key="$1"
  local override_file="$2"
  local sc_value

  sc_value=$(read_config_value "$sc_key" "$override_file")

  if [[ -z "$sc_value" ]]; then
    log_error "${sc_key} not found in $config_file"
    log_info "Please set global.${sc_key} in $config_file"
    exit 1
  fi

  if ! oc get storageclass "$sc_value" >/dev/null 2>&1; then
    log_error "StorageClass '${sc_value}' does not exist"
    log_info "Please create the storage class first or update $config_file"
    exit 1
  fi

  echo "$sc_value"
}

validate_imagepullsecret() {
  local secret_name="$1"
  local namespace="$2"

  if ! oc get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    log_error "Image pull secret '${secret_name}' does not exist in namespace '${namespace}'"
    log_info "Please create the secret or provide --registry-creds"
    exit 1
  fi
}
