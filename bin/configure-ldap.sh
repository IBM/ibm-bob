#!/usr/bin/env bash

# Function to read a top-level scalar key from the LDAP config file.
# For nested keys (e.g. bindPasswordSecret.name) use read_ldap_nested_value.
# For list keys (e.g. domains) use has_ldap_key to check presence.
read_ldap_value() {
  local key="$1"
  local config_file="$2"
  local raw value
  raw=$(grep -E "^[[:space:]]*${key}:" "$config_file" | head -1 | cut -d':' -f2-)
  # strip leading whitespace
  value="${raw#"${raw%%[! ]*}"}"
  # strip inline comment
  value="${value%%#*}"
  # strip trailing whitespace
  while [[ "${value: -1}" == " " || "${value: -1}" == $'\t' ]]; do
    value="${value%?}"
  done
  printf '%s' "$value"
}

# Function to check a key exists in the config file (works for both scalar and list keys).
has_ldap_key() {
  local key="$1"
  local config_file="$2"
  grep -qE "^[[:space:]]*${key}:" "$config_file"
}

# Function to read a key nested one level under a parent block.
# E.g. read_ldap_nested_value "bindPasswordSecret" "name" config.yaml
read_ldap_nested_value() {
  local parent="$1"
  local key="$2"
  local config_file="$3"
  local in_parent=false line raw value
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*${parent}: ]]; then
      in_parent=true
      continue
    fi
    if [[ $in_parent == true ]]; then
      # Stop if we've left the indented block (hit a top-level key)
      if [[ $line =~ ^[^[:space:]] && ! $line =~ ^[[:space:]] ]]; then
        break
      fi
      if [[ $line =~ ^[[:space:]]+${key}: ]]; then
        raw="${line#*:}"
        value="${raw#"${raw%%[! ]*}"}"
        value="${value%%#*}"
        while [[ "${value: -1}" == " " || "${value: -1}" == $'\t' ]]; do
          value="${value%?}"
        done
        printf '%s' "$value"
        return
      fi
    fi
  done < "$config_file"
}

# Function to render a BobLDAP CR YAML to a file.
# Reads the LDAP config file and writes a BobLDAP CR to output_file.
render_ldap_cr() {
  local config_file="$1"
  local namespace="$2"
  local output_file="$3"

  local cr_name vendor connection_url users_dn username_attr rdn_attr uuid_attr user_classes
  cr_name=$(read_ldap_value "name" "$config_file")
  vendor=$(read_ldap_value "vendor" "$config_file")
  connection_url=$(read_ldap_value "connectionUrl" "$config_file")
  users_dn=$(read_ldap_value "usersDn" "$config_file")
  username_attr=$(read_ldap_value "usernameLDAPAttribute" "$config_file")
  rdn_attr=$(read_ldap_value "rdnLDAPAttribute" "$config_file")
  uuid_attr=$(read_ldap_value "uuidLDAPAttribute" "$config_file")
  user_classes=$(read_ldap_value "userObjectClasses" "$config_file")

  # Optional scalar fields
  local bind_dn use_truststore_spi search_scope custom_filter import_enabled priority
  bind_dn=$(read_ldap_value "bindDn" "$config_file")
  use_truststore_spi=$(read_ldap_value "useTruststoreSpi" "$config_file")
  search_scope=$(read_ldap_value "searchScope" "$config_file")
  custom_filter=$(read_ldap_value "customUserSearchFilter" "$config_file")
  import_enabled=$(read_ldap_value "importEnabled" "$config_file")
  priority=$(read_ldap_value "priority" "$config_file")

  # Optional secret refs
  local bind_secret_name bind_secret_key ca_secret_name ca_secret_key
  bind_secret_name=$(read_ldap_nested_value "bindPasswordSecret" "name" "$config_file")
  bind_secret_key=$(read_ldap_nested_value "bindPasswordSecret" "key" "$config_file")
  ca_secret_name=$(read_ldap_nested_value "ldapsCACertSecret" "name" "$config_file")
  ca_secret_key=$(read_ldap_nested_value "ldapsCACertSecret" "key" "$config_file")

  # Build CR into output file
  cat > "$output_file" <<YAML
apiVersion: bob.ibm.com/v1beta1
kind: BobLDAP
metadata:
  name: ${cr_name}
  namespace: ${namespace}
spec:
  vendor: ${vendor}
  connectionUrl: ${connection_url}
  usersDn: ${users_dn}
  usernameLDAPAttribute: ${username_attr}
  rdnLDAPAttribute: ${rdn_attr}
  uuidLDAPAttribute: ${uuid_attr}
  userObjectClasses: ${user_classes}
YAML

  # Helper: emit a simple string-list field from config into the CR.
  # Skips the field entirely if the key is absent from the config.
  render_cr_list_field() {
    local list_key="$1"
    local out="$2"
    echo "  ${list_key}:" >> "$out"
    local in_list=false line
    while IFS= read -r line; do
      if [[ $line =~ ^[[:space:]]*${list_key}: ]]; then
        in_list=true
        continue
      fi
      if [[ $in_list == true ]]; then
        if [[ $line =~ ^[[:space:]]*-[[:space:]](.+)$ ]]; then
          echo "  - ${BASH_REMATCH[1]}" >> "$out"
        elif [[ $line =~ ^[^[:space:]-] ]]; then
          break
        fi
      fi
    done < "$config_file"
  }

  # domains list (required)
  render_cr_list_field "domains" "$output_file"

  # Optional adminEmails list
  if has_ldap_key "adminEmails" "$config_file"; then
    render_cr_list_field "adminEmails" "$output_file"
  fi

  # Optional scalar fields
  [[ -n "$bind_dn" ]]           && echo "  bindDn: ${bind_dn}"                         >> "$output_file"
  [[ -n "$use_truststore_spi" ]] && echo "  useTruststoreSpi: ${use_truststore_spi}"   >> "$output_file"
  [[ -n "$search_scope" ]]      && echo "  searchScope: ${search_scope}"               >> "$output_file"
  [[ -n "$custom_filter" ]]     && echo "  customUserSearchFilter: ${custom_filter}"   >> "$output_file"
  [[ -n "$import_enabled" ]]    && echo "  importEnabled: ${import_enabled}"           >> "$output_file"
  [[ -n "$priority" ]]          && echo "  priority: ${priority}"                     >> "$output_file"

  # Optional secret refs
  if [[ -n "$bind_secret_name" ]]; then
    printf '  bindPasswordSecret:\n    name: %s\n    key: %s\n' \
      "$bind_secret_name" "$bind_secret_key" >> "$output_file"
  fi
  if [[ -n "$ca_secret_name" ]]; then
    printf '  ldapsCACertSecret:\n    name: %s\n    key: %s\n' \
      "$ca_secret_name" "$ca_secret_key" >> "$output_file"
  fi

  # Optional userAttributeMappings — entries have sub-keys so extract the raw block,
  # strip source indentation, and re-indent uniformly preserving relative sub-key depth.
  local in_mappings=false mappings_lines=() line
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*userAttributeMappings: ]]; then
      in_mappings=true
      continue
    fi
    if [[ $in_mappings == true ]]; then
      # stop on next top-level key
      if [[ $line =~ ^[^[:space:]] ]]; then
        break
      fi
      # skip comment-only lines
      [[ $line =~ ^[[:space:]]*# ]] && continue
      mappings_lines+=("$line")
    fi
  done < "$config_file"

  if [[ ${#mappings_lines[@]} -gt 0 ]]; then
    # Determine base indentation from first non-empty line
    local first_line="${mappings_lines[0]}"
    local stripped="${first_line#"${first_line%%[! ]*}"}"
    local base_indent=$(( ${#first_line} - ${#stripped} ))
    echo "  userAttributeMappings:" >> "$output_file"
    for line in "${mappings_lines[@]}"; do
      # Re-indent: replace leading base_indent spaces with two spaces
      printf '  %s\n' "${line:$base_indent}" >> "$output_file"
    done
  fi

  log_info "CR written to: ${output_file}"
}

# Creates or validates a secret in the cluster namespace.
# If a value is provided, the secret is created (or replaced). Otherwise the
# secret must already exist.
ensure_ldap_secret() {
  local field_label="$1"   # human label for error messages
  local secret_name="$2"   # metadata.name of the Secret
  local secret_key="$3"    # key inside the Secret
  local secret_value="$4"  # raw value (password string or file path)
  local value_type="$5"    # "literal" or "file"
  local namespace="$6"

  if [[ -z "$secret_name" ]]; then
    return 0
  fi

  if [[ -n "$secret_value" ]]; then
    local create_flag
    if [[ "$value_type" == "file" ]]; then
      if [[ ! -f "$secret_value" ]]; then
        log_error "${field_label}: file not found: $secret_value"
        exit 1
      fi
      create_flag="--from-file=${secret_key}=${secret_value}"
    else
      # Redact literal value (e.g. bind password) from logs
      create_flag="--from-literal=${secret_key}=***REDACTED***"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry_run "Would execute: oc create secret generic ${secret_name} ${create_flag} -n ${namespace}"
    else
      log_info "Creating secret '${secret_name}' in namespace '${namespace}'"
      # Use server-side apply so re-runs are idempotent.
      # Reconstruct the real create_flag with the actual value for the actual oc call.
      local real_create_flag
      if [[ "$value_type" == "file" ]]; then
        real_create_flag="--from-file=${secret_key}=${secret_value}"
      else
        real_create_flag="--from-literal=${secret_key}=${secret_value}"
      fi
      # Suppress the dry-run manifest output — it contains base64-encoded secret
      # data. Only log the result of oc apply (e.g. "secret/name configured").
      oc create secret generic "${secret_name}" "${real_create_flag}" \
        -n "${namespace}" --dry-run=client -o yaml 2>/dev/null \
        | oc apply -f - -n "${namespace}" 2>&1 | tee -a "$LOG_FILE"
    fi
  else
    # No value supplied — secret must already exist
    if [[ "$DRY_RUN" != "true" ]]; then
      if ! oc get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
        log_error "${field_label} secret '${secret_name}' does not exist in namespace '${namespace}'"
        log_info "Pass the value via CLI flag or pre-create the secret manually"
        exit 1
      fi
    fi
  fi
}

# Polls a BobLDAP CR until all three status conditions are True (or a timeout is
# reached).  Exits non-zero if any condition is still False / Unknown at timeout.
#
# Conditions surfaced by the operator:
#   Ready            – provider registered in Keycloak
#   LDAPReachable    – LDAP server is network-reachable
#   LDAPAuthenticated – bind (anonymous or credential) succeeded
wait_for_ldap_ready() {
  local cr_name="$1"
  local namespace="$2"
  local timeout="${3:-300}"   # seconds; override via $BOB_LDAP_WAIT_TIMEOUT
  local interval=5

  local conditions=("Ready" "LDAPReachable" "LDAPAuthenticated")

  log_info "Waiting for BobLDAP '${cr_name}' to become ready (timeout: ${timeout}s)..."

  # Track which conditions have already been printed so each appears only once.
  # Stored as a colon-delimited string for bash 3.2 compatibility (no associative arrays).
  local printed=""

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local all_true=true

    # Single API call per poll — fetch all conditions at once as tab-separated lines
    local conditions_json
    conditions_json=$(oc get bobldap "$cr_name" -n "$namespace" \
      -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}' \
      2>/dev/null || true)

    for cond in "${conditions[@]}"; do
      local cond_line cond_status cond_message
      cond_line=$(printf '%s' "$conditions_json" | grep "^${cond}"$'\t' || true)
      cond_status=$(printf '%s' "$cond_line" | cut -f2)
      cond_message=$(printf '%s' "$cond_line" | cut -f3)

      if [[ "$cond_status" == "True" ]]; then
        # Print each passing condition only the first time it becomes True
        if [[ ":${printed}:" != *":${cond}:"* ]]; then
          log_info "  ✓ ${cond}: ${cond_message}"
          printed="${printed}:${cond}"
        fi
      else
        # False or Unknown — keep waiting (transient failures are normal post-install)
        all_true=false
      fi
    done

    if [[ "$all_true" == "true" ]]; then
      log_info "BobLDAP '${cr_name}' is ready"
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
    log_info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done

  log_error "Timed out after ${timeout}s waiting for BobLDAP '${cr_name}' to become ready"
  log_info "Current status:"
  oc get bobldap "$cr_name" -n "$namespace" -o yaml 2>&1 | tee -a "$LOG_FILE" || true
  exit 1
}

# Main add-ldap subcommand
add_ldap() {
  local ldap_config=""
  local bind_password=""
  local ca_cert_file=""
  local DRY_RUN=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        if [[ -z "${2:-}" ]]; then
          log_error "--config requires a file path argument"
          usage
        fi
        ldap_config="$2"
        shift 2
        ;;
      --bind-password)
        if [[ -z "${2:-}" ]]; then
          log_error "--bind-password requires a value"
          usage
        fi
        bind_password="$2"
        shift 2
        ;;
      --ca-cert-file)
        if [[ -z "${2:-}" ]]; then
          log_error "--ca-cert-file requires a file path argument"
          usage
        fi
        ca_cert_file="$2"
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

  # Validate CLI args
  if [[ -z "$ldap_config" ]]; then
    log_error "--config is required"
    usage
  fi

  if [[ ! -f "$ldap_config" ]]; then
    log_error "Config file not found: $ldap_config"
    exit 1
  fi

  # Check oc login status
  check_oc_login

  # Resolve the instance namespace from the main config.yaml
  local namespace
  namespace=$(validate_namespace "instanceNamespace" "$BOB_CONFIG_FILE")

  log_info "Using namespace: $namespace"
  log_info "Using LDAP config: $ldap_config"

  # Validate required scalar fields are present in the config file.
  # Capture cr_name directly from the validation loop to avoid reading it twice.
  local cr_name
  for field in name vendor connectionUrl usersDn usernameLDAPAttribute rdnLDAPAttribute uuidLDAPAttribute userObjectClasses; do
    local val
    val=$(read_ldap_value "$field" "$ldap_config")
    if [[ -z "$val" ]]; then
      log_error "Missing required field '${field}' in ${ldap_config}"
      log_info "Refer to config-ldap-template.yaml for all available options"
      exit 1
    fi
    [[ "$field" == "name" ]] && cr_name="$val"
  done

  # Validate required list fields are present in the config file
  if ! has_ldap_key "domains" "$ldap_config"; then
    log_error "Missing required field 'domains' in ${ldap_config}"
    log_info "Refer to config-ldap-template.yaml for all available options"
    exit 1
  fi

  # Read optional secret refs from config
  local bind_dn bind_secret_name bind_secret_key ca_secret_name ca_secret_key
  bind_dn=$(read_ldap_value "bindDn" "$ldap_config")
  bind_secret_name=$(read_ldap_nested_value "bindPasswordSecret" "name" "$ldap_config")
  bind_secret_key=$(read_ldap_nested_value "bindPasswordSecret" "key" "$ldap_config")
  ca_secret_name=$(read_ldap_nested_value "ldapsCACertSecret" "name" "$ldap_config")
  ca_secret_key=$(read_ldap_nested_value "ldapsCACertSecret" "key" "$ldap_config")

  # Auto-derive secret name/key when CLI flag is provided but config block is omitted,
  # then write the derived values back into the config file for future reference.
  if [[ -n "$bind_password" ]] && [[ -z "$bind_secret_name" ]]; then
    bind_secret_name="${cr_name}-bind-password"
    bind_secret_key="password"
    log_info "bindPasswordSecret not set in config — using auto-derived name: ${bind_secret_name}"
    printf '\nbindPasswordSecret:\n  name: %s\n  key: %s\n' "$bind_secret_name" "$bind_secret_key" >> "$ldap_config"
    log_info "Updated ${ldap_config} with bindPasswordSecret name/key"
  fi
  if [[ -n "$ca_cert_file" ]] && [[ -z "$ca_secret_name" ]]; then
    ca_secret_name="${cr_name}-ca-cert"
    ca_secret_key="ca.crt"
    log_info "ldapsCACertSecret not set in config — using auto-derived name: ${ca_secret_name}"
    printf '\nldapsCACertSecret:\n  name: %s\n  key: %s\n' "$ca_secret_name" "$ca_secret_key" >> "$ldap_config"
    log_info "Updated ${ldap_config} with ldapsCACertSecret name/key"
  fi

  if [[ -n "$bind_dn" ]] && [[ -z "$bind_secret_name" ]]; then
    log_error "bindDn is set but bindPasswordSecret is not configured in ${ldap_config}"
    log_info "Add a bindPasswordSecret block to the config or pass --bind-password"
    exit 1
  fi

  # Ensure secrets exist — created from CLI flags or validated as pre-existing
  ensure_ldap_secret "bindPasswordSecret" "$bind_secret_name" "$bind_secret_key" \
    "$bind_password" "literal" "$namespace"
  ensure_ldap_secret "ldapsCACertSecret" "$ca_secret_name" "$ca_secret_key" \
    "$ca_cert_file" "file" "$namespace"

  # Render CR to work directory
  mkdir -p "$BOB_WORK_DIR"
  local cr_file="$BOB_WORK_DIR/bobldap-${cr_name}.yaml"

  log_info "Rendering BobLDAP CR: $cr_file"
  render_ldap_cr "$ldap_config" "$namespace" "$cr_file" 2>&1 | tee -a "$LOG_FILE"

  # Apply or dry-run
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would execute: oc apply -f $cr_file -n $namespace"
    log_dry_run "CR preview:"
    while IFS= read -r line; do
      log_dry_run "  $line"
    done < "$cr_file"
    log_dry_run "Skipping status validation (dry-run mode)"
  else
    log_info "Executing: oc apply -f $cr_file -n $namespace"
    if ! oc apply -f "$cr_file" -n "$namespace" 2>&1 | tee -a "$LOG_FILE"; then
      log_error "oc apply failed — BobLDAP CR was not created"
      exit 1
    fi

    # Wait for the operator to reconcile and validate all three status conditions:
    #   Ready, LDAPReachable, LDAPAuthenticated
    local wait_timeout="${BOB_LDAP_WAIT_TIMEOUT:-180}"
    wait_for_ldap_ready "$cr_name" "$namespace" "$wait_timeout"
  fi
}
