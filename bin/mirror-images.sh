#!/usr/bin/env bash

# Default source registry
SRC_REGISTRY=${SRC_REGISTRY:-cp.icr.io}

# Auth file location
AUTH_FILE="$BOB_WORK_DIR/auth.json"

# Setup trap to cleanup auth.json file on exit
# Append to existing trap if one exists (e.g., from bobctl)
if [[ -n "$(trap -p EXIT)" ]]; then
  # Extract existing trap command and append our cleanup
  # Use bash string manipulation instead of sed
  existing_trap=$(trap -p EXIT)
  existing_trap="${existing_trap#trap -- \'}"
  existing_trap="${existing_trap%\' EXIT}"
  # shellcheck disable=SC2064
  trap "rm -vf \"$AUTH_FILE\"; $existing_trap" EXIT
else
  trap 'rm -vf "$AUTH_FILE"' EXIT
fi

# Check if oc command is available
check_oc_command() {
  if ! command -v oc >/dev/null 2>&1; then
    log_error "'oc' command not found"
    log_info "Please install the OpenShift CLI (oc) and ensure it's in your PATH"
    exit 1
  fi
}


# Function to get default enabled value from values.yaml for a chart
# Returns 0 (true) if enabled by default, 1 (false) otherwise
# Defaults to true if values.yaml is missing or chart not found
get_default_enabled_value() {
  local chart_name="$1"
  local values_file="$BOB_DIR/charts/ibm-bob/values.yaml"

  # Return true if values.yaml doesn't exist (backward compatible)
  if [[ ! -f "$values_file" ]]; then
    return 0
  fi

  # Parse YAML: look for "chart_name:" followed by "enabled: true/false"
  # Pattern matches subchart enablement section like:
  #   ibm-usage-metering:
  #     enabled: true
  local default_value
  default_value=$(grep -A 5 "^${chart_name}:" "$values_file" | grep "enabled:" | head -1 | grep -o "true\|false")

  # Default to true if not found in values.yaml (backward compatible)
  if [[ -z "$default_value" ]]; then
    return 0
  fi

  # Return 0 for true, 1 for false
  [[ "$default_value" == "true" ]]
}


# Function to check if a chart is enabled in config.yaml
# Returns 0 (true) if enabled, 1 (false) otherwise
is_chart_enabled() {
  local chart_name="$1"
  local config_file="$BOB_CONFIG_FILE"

  # Return true if config file doesn't exist (default to including all)
  if [[ ! -f "$config_file" ]]; then
    return 0
  fi

  # Search for the enabled flag within the chart's section only
  # Stop at the next top-level key (non-indented line starting with a letter)
  local enabled_value=""
  local in_section=false

  while IFS= read -r line; do
    # Check if we found the chart section
    if [[ $line =~ ^${chart_name}: ]]; then
      in_section=true
      continue
    fi

    # If we're in the section and hit another top-level key, stop
    if [[ $in_section == true && $line =~ ^[a-zA-Z] ]]; then
      break
    fi

    # If we're in the section, look for enabled flag
    if [[ $in_section == true && $line =~ enabled:[[:space:]]*(true|false) ]]; then
      enabled_value="${BASH_REMATCH[1]}"
      break
    fi
  done < "$config_file"

  # Use default from values.yaml if not found in config
  if [[ -z "$enabled_value" ]]; then
    get_default_enabled_value "$chart_name"
    return $?
  fi

  # Return based on value
  [[ "$enabled_value" == "true" ]]
}

# Function to get list of CSV files to process based on config
get_csv_files_to_process() {
  local csv_files=()
  local chart_yaml="$BOB_DIR/charts/ibm-bob/Chart.yaml"

  # Always include IBM Bob images
  csv_files+=("$BOB_DIR/etc/ibm-bob-images.csv")

  # Read dependencies from Chart.yaml if it exists
  if [[ -f "$chart_yaml" ]]; then
    # Extract dependency names from Chart.yaml
    # Pattern: look for "- name: <chart-name>" under dependencies section
    local in_dependencies=false
    while IFS= read -r line; do
      if [[ $line =~ ^dependencies: ]]; then
        in_dependencies=true
        continue
      fi

      # Exit dependencies section when we hit a non-indented line
      if [[ $in_dependencies == true && $line =~ ^[a-zA-Z] ]]; then
        break
      fi

      # Extract chart name from "- name: <chart-name>"
      if [[ $in_dependencies == true && $line =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*([a-zA-Z0-9_-]+) ]]; then
        local chart_name="${BASH_REMATCH[1]}"

        # Check if chart is enabled in config
        if is_chart_enabled "$chart_name"; then
          csv_files+=("$BOB_DIR/etc/${chart_name}-images.csv")
        fi
      fi
    done < "$chart_yaml"
  fi

  # Return array
  printf '%s\n' "${csv_files[@]}"
}

# Function to perform registry login and create auth.json
registry_login() {
  local registry="$1"
  local creds="$2"

  if [[ -z "$creds" ]]; then
    return 0
  fi

  log_info "Logging into registry: $registry"

  local login_cmd="oc registry login --auth-basic $creds --insecure --registry $registry -a $AUTH_FILE"

  # Sanitize credentials in log output
  local sanitized_cmd="${login_cmd//--auth-basic $creds/--auth-basic ***REDACTED***}"

  log_info "Executing: $sanitized_cmd"
  if ! eval "$login_cmd" 2>&1 | tee -a "$LOG_FILE"; then
    log_error "Failed to login to registry: $registry"
    exit 1
  fi
}

# Helper function to execute oc image mirror command
# Returns 0 on success, 1 on failure (does not exit)
execute_mirror() {
  local mapping_file="$1"
  local error_message="$2"
  local extra_args="${3:-}"

  local mirror_cmd="oc image mirror -f $mapping_file --keep-manifest-list --insecure --skip-multiple-scopes --max-per-registry=1"

  if [[ -n "$extra_args" ]]; then
    mirror_cmd="$mirror_cmd $extra_args"
  fi

  if [[ -f "$AUTH_FILE" ]]; then
    mirror_cmd="$mirror_cmd -a $AUTH_FILE"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    mirror_cmd="$mirror_cmd --dry-run"
    log_dry_run "Executing: $mirror_cmd"
  else
    log_info "Executing: $mirror_cmd"
  fi

  # Use PIPESTATUS to capture exit code of mirror command, not tee
  eval "$mirror_cmd" 2>&1 | tee -a "$LOG_FILE"
  local exit_code="${PIPESTATUS[0]}"

  if [[ $exit_code -ne 0 ]]; then
    log_error "$error_message"
    return 1
  fi

  return 0
}

# Helper function to parse CSV and build image mappings
parse_images_csv() {
  local images_list="$1"
  local mapping_type="$2"  # "direct" or "filesystem"
  local mapping_file="$3"
  local from_fs_mapping="${4:-}"

  # Default to manifest list for most images
  local target_arch=list
  # Only ibm-bob and rhbk-operator support arch-specific mirroring
  if [[ -n "$ARCH" && ($images_list == *ibm-bob-images.csv || $images_list == *rhbk-operator-images.csv) ]]; then
    target_arch=$ARCH
  fi

  # Clear or create the mapping file(s)
  true > "$mapping_file"
  if [[ -n "$from_fs_mapping" ]]; then
    true > "$from_fs_mapping"
  fi

  # Process each line from the images list
  while IFS=',' read -r registry image_path tag digest arch; do
    # Skip empty lines
    [[ -z "$registry" ]] && continue

    # Filter by architecture
    if [[ "$arch" != "$target_arch" ]]; then
      continue
    fi

    if [[ "$mapping_type" == "direct" ]]; then
      # Build the mapping: source@digest=target:tag
      local source="${registry}/${image_path}@${digest}"
      local target="${DEST_REGISTRY}/${image_path}:${tag}"
      echo "${source}=${target}" >> "$mapping_file"
    elif [[ "$mapping_type" == "filesystem" ]]; then
      # Build mapping for filesystem-based mirroring
      local source="${registry}/${image_path}@${digest}"
      local fs_target="file:///${image_path}:${tag}"
      local dest_target="${DEST_REGISTRY}/${image_path}:${tag}"

      # To filesystem: source@digest=file:///path:tag
      echo "${source}=${fs_target}" >> "$mapping_file"

      # From filesystem: file:///path@digest=registry/path:tag
      echo "file:///${image_path}@${digest}=${dest_target}" >> "$from_fs_mapping"
    fi
  done < "$images_list"
}



# Function to perform direct registry-to-registry mirroring
# Returns 0 if all succeeded, 1 if any failed
mirror_to_registry() {
  local csv_files=()
  while IFS= read -r _line; do csv_files+=("$_line"); done < <(get_csv_files_to_process)

  log_info "Processing ${#csv_files[@]} image CSV file(s)"

  # Arrays to track errors
  local -a failed_csv_files=()
  local -a error_messages=()

  for images_list in "${csv_files[@]}"; do
    if [[ ! -f "$images_list" ]]; then
      log_warn "Images list not found, skipping: $images_list"
      continue
    fi

    local base_name
    base_name=$(basename "$images_list")
    local mapping_file="$BOB_WORK_DIR/${base_name%-images.*}-mapping.lst"

    log_info "Creating image mapping file: $mapping_file"
    parse_images_csv "$images_list" "direct" "$mapping_file"
    log_info "Mapping file created with $(grep -c '=' "$mapping_file") entries"

    if ! execute_mirror "$mapping_file" "Failed to mirror images from $images_list"; then
      failed_csv_files+=("$base_name")
      error_messages+=("Failed to mirror images from $images_list")
      log_warn "Continuing with next image list..."
    fi
  done

  # Print error summary if any errors occurred
  if [[ ${#failed_csv_files[@]} -gt 0 ]]; then
    log_error ""
    log_error "=========================================="
    log_error "MIRRORING ERROR SUMMARY"
    log_error "=========================================="
    log_error "Failed to mirror ${#failed_csv_files[@]} image list(s):"
    log_error ""

    local i
    for i in "${!failed_csv_files[@]}"; do
      log_error "  [$((i+1))] ${failed_csv_files[$i]}"
      log_error "      ${error_messages[$i]}"
    done

    log_error ""
    log_error "=========================================="

    return 1
  fi

  return 0
}

# Function to perform filesystem-based mirroring (step 1)
# Returns 0 if all succeeded, 1 if any failed
mirror_to_filesystem() {
  local csv_files=()
  while IFS= read -r _line; do csv_files+=("$_line"); done < <(get_csv_files_to_process)

  log_info "Processing ${#csv_files[@]} image CSV file(s)"

  # Arrays to track errors
  local -a failed_csv_files=()
  local -a error_messages=()

  for images_list in "${csv_files[@]}"; do
    if [[ ! -f "$images_list" ]]; then
      log_warn "Images list not found, skipping: $images_list"
      continue
    fi

    local base_name
    base_name=$(basename "$images_list")
    local to_fs_mapping="$BOB_WORK_DIR/${base_name%-images.*}-to-filesystem-mapping.lst"
    local from_fs_mapping="$BOB_WORK_DIR/${base_name%-images.*}-from-filesystem-mapping.lst"

    log_info "Creating filesystem mapping files for $base_name"
    parse_images_csv "$images_list" "filesystem" "$to_fs_mapping" "$from_fs_mapping"
    log_info "To-filesystem mapping created with $(grep -c '=' "$to_fs_mapping") entries"
    log_info "From-filesystem mapping created with $(grep -c '=' "$from_fs_mapping") entries"

    if ! execute_mirror "$to_fs_mapping" "Failed to mirror images to filesystem from $images_list" "--dir=$TO_DIR"; then
      failed_csv_files+=("$base_name")
      error_messages+=("Failed to mirror images to filesystem from $images_list")
      log_warn "Continuing with next image list..."
    fi
  done

  # Print error summary if any errors occurred
  if [[ ${#failed_csv_files[@]} -gt 0 ]]; then
    log_error ""
    log_error "=========================================="
    log_error "MIRRORING ERROR SUMMARY"
    log_error "=========================================="
    log_error "Failed to mirror ${#failed_csv_files[@]} image list(s) to filesystem:"
    log_error ""

    local i
    for i in "${!failed_csv_files[@]}"; do
      log_error "  [$((i+1))] ${failed_csv_files[$i]}"
      log_error "      ${error_messages[$i]}"
    done

    log_error ""
    log_error "=========================================="

    return 1
  fi

  log_info ""
  log_warn "IMPORTANT: To complete the mirroring process on the target system:"
  log_info "  1. Copy the directory: $TO_DIR"
  log_info "  2. Copy the mapping files: $BOB_WORK_DIR/*-from-filesystem-mapping.lst"
  log_info "  3. Run: bobctl upload-images --from-dir <copied-directory> --dest-registry <registry> [--dest-creds <username:password>]"

  return 0
}

# Function to mirror from filesystem to registry (step 2)
# Returns 0 if all succeeded, 1 if any failed
mirror_from_filesystem() {
  local csv_files=()
  while IFS= read -r _line; do csv_files+=("$_line"); done < <(get_csv_files_to_process)

  log_info "Processing ${#csv_files[@]} image CSV file(s)"

  # Arrays to track errors
  local -a failed_csv_files=()
  local -a error_messages=()

  for images_list in "${csv_files[@]}"; do
    local base_name
    base_name=$(basename "$images_list")
    local from_fs_mapping="$BOB_WORK_DIR/${base_name%-images.*}-from-filesystem-mapping.lst"

    if [[ ! -f "$from_fs_mapping" ]]; then
      log_warn "From-filesystem mapping file not found, skipping: $from_fs_mapping"
      continue
    fi

    log_info "Using from-filesystem mapping file: $from_fs_mapping"
    log_info "Mapping file contains $(grep -c '=' "$from_fs_mapping") entries"

    if ! execute_mirror "$from_fs_mapping" "Failed to mirror images from filesystem using $from_fs_mapping" "--from-dir=$FROM_DIR"; then
      failed_csv_files+=("$base_name")
      error_messages+=("Failed to mirror images from filesystem using $from_fs_mapping")
      log_warn "Continuing with next image list..."
    fi
  done

  # Print error summary if any errors occurred
  if [[ ${#failed_csv_files[@]} -gt 0 ]]; then
    log_error ""
    log_error "=========================================="
    log_error "MIRRORING ERROR SUMMARY"
    log_error "=========================================="
    log_error "Failed to mirror ${#failed_csv_files[@]} image list(s) from filesystem:"
    log_error ""

    local i
    for i in "${!failed_csv_files[@]}"; do
      log_error "  [$((i+1))] ${failed_csv_files[$i]}"
      log_error "      ${error_messages[$i]}"
    done

    log_error ""
    log_error "=========================================="

    return 1
  fi

  return 0
}

# Function to download images to filesystem
download_images() {
  # Check if oc command is available
  check_oc_command

  local TO_DIR=""
  local ARCH=""
  local SRC_CREDS=""
  local DRY_RUN=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to-dir)
        if [[ -z "${2:-}" ]]; then
          log_error "--to-dir requires a directory path argument"
          usage
        fi
        TO_DIR="$2"
        shift 2
        ;;
      --arch)
        if [[ -z "${2:-}" ]]; then
          log_error "--arch requires an architecture argument"
          usage
        fi
        ARCH="$2"
        shift 2
        ;;
      --src-creds)
        if [[ -z "${2:-}" ]]; then
          log_error "--src-creds requires a 'username:password' argument"
          usage
        fi
        if [[ ! "$2" =~ ^[^:]+:.+$ ]]; then
          log_error "--src-creds must be in 'username:password' format"
          usage
        fi
        SRC_CREDS="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Validate required parameters
  if [[ -z "$TO_DIR" ]]; then
    log_error "--to-dir parameter is required"
    usage
  fi

  if [[ -z "$SRC_CREDS" ]]; then
    log_error "--src-creds parameter is required"
    usage
  fi

  mkdir -p "$BOB_WORK_DIR"

  # Login to source registry
  registry_login "$SRC_REGISTRY" "$SRC_CREDS"

  # Set DEST_REGISTRY for parse_images_csv (needed for from-filesystem mapping)
  DEST_REGISTRY="placeholder"

  if ! mirror_to_filesystem; then
    exit 1
  fi
}

# Function to upload images from filesystem to registry
upload_images() {
  # Check if oc command is available
  check_oc_command

  local FROM_DIR=""
  local DEST_REGISTRY=""
  local DEST_CREDS=""
  local DRY_RUN=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-dir)
        if [[ -z "${2:-}" ]]; then
          log_error "--from-dir requires a directory path argument"
          usage
        fi
        FROM_DIR="$2"
        shift 2
        ;;
      --dest-registry)
        if [[ -z "${2:-}" ]]; then
          log_error "--dest-registry requires a registry URL argument"
          usage
        fi
        DEST_REGISTRY="$2"
        shift 2
        ;;
      --dest-creds)
        if [[ -z "${2:-}" ]]; then
          log_error "--dest-creds requires a 'username:password' argument"
          usage
        fi
        if [[ ! "$2" =~ ^[^:]+:.+$ ]]; then
          log_error "--dest-creds must be in 'username:password' format"
          usage
        fi
        DEST_CREDS="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Validate required parameters
  if [[ -z "$FROM_DIR" ]]; then
    log_error "--from-dir parameter is required"
    usage
  fi

  if [[ -z "$DEST_REGISTRY" ]]; then
    log_error "--dest-registry parameter is required"
    usage
  fi

  mkdir -p "$BOB_WORK_DIR"

  # Login to destination registry
  registry_login "$DEST_REGISTRY" "$DEST_CREDS"

  if ! mirror_from_filesystem; then
    exit 1
  fi
}

# Function to mirror IBM Bob images directly to registry
mirror_images() {
  # Check if oc command is available
  check_oc_command

  local DEST_REGISTRY=""
  local ARCH=""
  local SRC_CREDS=""
  local DEST_CREDS=""
  local DRY_RUN=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest-registry)
        if [[ -z "${2:-}" ]]; then
          log_error "--dest-registry requires a registry URL argument"
          usage
        fi
        DEST_REGISTRY="$2"
        shift 2
        ;;
      --arch)
        if [[ -z "${2:-}" ]]; then
          log_error "--arch requires an architecture argument"
          usage
        fi
        ARCH="$2"
        shift 2
        ;;
      --src-creds)
        if [[ -z "${2:-}" ]]; then
          log_error "--src-creds requires a 'username:password' argument"
          usage
        fi
        if [[ ! "$2" =~ ^[^:]+:.+$ ]]; then
          log_error "--src-creds must be in 'username:password' format"
          usage
        fi
        SRC_CREDS="$2"
        shift 2
        ;;
      --dest-creds)
        if [[ -z "${2:-}" ]]; then
          log_error "--dest-creds requires a 'username:password' argument"
          usage
        fi
        if [[ ! "$2" =~ ^[^:]+:.+$ ]]; then
          log_error "--dest-creds must be in 'username:password' format"
          usage
        fi
        DEST_CREDS="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Validate required parameters
  if [[ -z "$DEST_REGISTRY" ]]; then
    log_error "--dest-registry parameter is required"
    usage
  fi

  if [[ -z "$SRC_CREDS" ]]; then
    log_error "--src-creds parameter is required"
    usage
  fi

  mkdir -p "$BOB_WORK_DIR"

  # Login to both registries
  registry_login "$SRC_REGISTRY" "$SRC_CREDS"
  registry_login "$DEST_REGISTRY" "$DEST_CREDS"

  if ! mirror_to_registry; then
    exit 1
  fi
}
