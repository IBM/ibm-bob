#!/usr/bin/env bash

# Function to generate cluster-scoped resources
generate_cluster_resources() {
  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Check helm availability
  check_helm

  # Check oc login status
  check_oc_login

  local config_file="$BOB_CONFIG_FILE"

  if [[ ! -f "$config_file" ]]; then
    log_error "$config_file not found"
    log_warn "Create config.yaml by copying config-template.yaml and updating it with your environment settings:"
    log_info "  cp $BOB_DIR/config-template.yaml $BOB_DIR/config.yaml"
    exit 1
  fi

  local clusterChartDir="$BOB_DIR/charts/ibm-bob-cluster-scoped"

  # Create work directory if it doesn't exist
  mkdir -p "$BOB_WORK_DIR"

  local outputFile="$BOB_WORK_DIR/cluster-resources.yaml"

  log_info "Rendering cluster-scoped resources"
  log_info "  Chart: $clusterChartDir"
  log_info "  Output: $outputFile"

  log_info "Executing: helm template ibm-bob-cluster-scoped $clusterChartDir -f $config_file > $outputFile"
  helm template ibm-bob-cluster-scoped "$clusterChartDir" \
    -f "$config_file" \
    2>&1 | tee -a "$LOG_FILE" > "$outputFile"

  log_info "Cluster-scoped resources rendered to: $outputFile"
  log_info ""
  log_warn "IMPORTANT: The cluster-scoped resources must be applied manually:"
  # '--force-conflicts' avoids 'invalid: metadata.annotations: Too long'
  log_info "  oc apply -f $outputFile --force-conflicts --server-side"
}

# Function to install IBM Bob
install_bob() {
  local registry_username=""
  local registry_password=""
  local model_config_filepath=""
  export DRY_RUN=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-creds)
        if [[ -z "${2:-}" ]]; then
          log_error "--registry-creds requires a 'username:password' argument"
          usage
        fi
        # Parse username:password format
        registry_username="${2%%:*}"
        registry_password="${2#*:}"
        if [[ -z "$registry_username" || -z "$registry_password" || "$registry_username" == "$registry_password" ]]; then
          log_error "--registry-creds must be in 'username:password' format"
          usage
        fi
        shift 2
        ;;
      --model-config)
        if [[ -z "$2" ]]; then
          log_error "--model-config requires a file path argument"
          usage
        fi

        model_config_filepath="$2"
        if [ ! -f "$model_config_filepath" ]; then
            log_error "Model Config Filepath $2 does not exist."
            usage
        fi
        shift 2
        ;;
      --dry-run)
        export DRY_RUN=true
        shift
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Check helm availability
  check_helm

  # Check oc login status
  check_oc_login

  # Check cert-manager is installed
  check_cert_manager

  local helmRelease=ibm-bob
  local chartDir="$BOB_DIR/charts/$helmRelease"

  if [[ -z "$chartDir" ]]; then
    log_error "Could not find operator chart in $BOB_DIR/charts/"
    exit 1
  fi

  local config_file="$BOB_CONFIG_FILE"

  if [[ ! -f "$config_file" ]]; then
    log_error "$config_file not found"
    log_warn "Create config.yaml by copying config-template.yaml and updating it with your environment settings:"
    log_info "  cp $BOB_DIR/config-template.yaml $BOB_DIR/config.yaml"
    exit 1
  fi

  # Validate namespaces from config.yaml
  local instanceNamespace
  local operatorNamespace

  instanceNamespace=$(validate_namespace "instanceNamespace" "$config_file")
  operatorNamespace=$(validate_namespace "operatorNamespace" "$config_file")

  # Validate storage classes from config.yaml
  local fileStorageClass
  local blockStorageClass

  fileStorageClass=$(validate_storageclass "fileStorageClass" "$config_file")
  blockStorageClass=$(validate_storageclass "blockStorageClass" "$config_file")

  # Validate image pull secret if registry credentials not provided
  if [[ -z "$registry_username" || -z "$registry_password" ]]; then
    local imagePullSecret
    imagePullSecret=$(read_config_value "imagePullSecret" "$config_file")

    if [[ -z "$imagePullSecret" ]]; then
      log_error "imagePullSecret not found in $config_file"
      log_info "Please set global.imagePullSecret in $config_file"
      exit 1
    fi

    validate_imagepullsecret "$imagePullSecret" "$instanceNamespace"
    validate_imagepullsecret "$imagePullSecret" "$operatorNamespace"
  fi

  log_info "Installing IBM Bob"
  log_info "  Chart: $chartDir"
  log_info "  Config file: $config_file"
  log_info "  Instance namespace: $instanceNamespace"
  log_info "  Operator namespace: $operatorNamespace"
  log_info "  File storage class: $fileStorageClass"
  log_info "  Block storage class: $blockStorageClass"
  if [[ -n "$model_config_filepath" ]]; then
    log_info "  Model Config file: $model_config_filepath"
  fi

  # Build helm command with optional registry credentials
  local helm_args=(
    upgrade --install
    -n "$instanceNamespace"
    --reset-then-reuse-values
    -f "$config_file"
  )

  if [[ -n "$registry_username" ]]; then
    helm_args+=(--set "global.registryUsername=$registry_username")
  fi

  if [[ -n "$registry_password" ]]; then
    helm_args+=(--set "global.registryPassword=$registry_password")
  fi

  # Get file content of model config and add as an argument to helm
  if [[ -n "$model_config_filepath" ]]; then
    helm_args+=(--set-file "bob.modelGateway.modelConfig=$model_config_filepath")
  fi


  helm_args+=("$helmRelease" "$chartDir/")

  # Build sanitized command for logging (redact password)
  local helm_args_sanitized=("${helm_args[@]}")
  for i in "${!helm_args_sanitized[@]}"; do
    if [[ "${helm_args_sanitized[$i]}" == *"global.registryPassword="* ]]; then
      helm_args_sanitized[$i]="global.registryPassword=***REDACTED***"
    fi
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would execute: helm ${helm_args_sanitized[*]}"
  else
    log_info "Executing: helm ${helm_args_sanitized[*]}"
    helm "${helm_args[@]}" 2>&1 | tee -a "$LOG_FILE"
  fi
}

# Function to upgrade IBM Bob
upgrade_bob() {
  export DRY_RUN=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        export DRY_RUN=true
        shift
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Check helm availability
  check_helm

  # Check oc login status
  check_oc_login

  local helmRelease=ibm-bob
  local chartDir="$BOB_DIR/charts/$helmRelease"

  if [[ -z "$chartDir" ]]; then
    log_error "Could not find operator chart in $BOB_DIR/charts/"
    exit 1
  fi

  local config_file="$BOB_CONFIG_FILE"

  if [[ ! -f "$config_file" ]]; then
    log_error "$config_file from existing installation not found"
    exit 1
  fi

  # Validate namespaces from config.yaml
  local instanceNamespace
  local operatorNamespace

  instanceNamespace=$(validate_namespace "instanceNamespace" "$config_file")
  operatorNamespace=$(validate_namespace "operatorNamespace" "$config_file")

  log_info "Upgrading IBM Bob"
  log_info "  Chart: $chartDir"
  log_info "  Config file: $config_file"
  log_info "  Instance namespace: $instanceNamespace"
  log_info "  Operator namespace: $operatorNamespace"

  # Build helm command without registry credentials
  local helm_args=(
    upgrade
    -n "$instanceNamespace"
    --reset-then-reuse-values
    -f "$config_file"
    "$helmRelease"
    "$chartDir/"
  )

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would execute: helm ${helm_args[*]}"
  else
    log_info "Executing: helm ${helm_args[*]}"
    helm "${helm_args[@]}" 2>&1 | tee -a "$LOG_FILE"
  fi
}
