#!/usr/bin/env bash

# configure-tls.sh — TLS certificate management for bobctl.
# effectiveSecret = spec.externalCertificate.secretName if set, else "bob-external-tls"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Decode a base64-encoded field from a cluster secret.
_decode_secret_field() {
  local secret_name="$1" field_key="$2" namespace="$3"
  oc get secret "$secret_name" -n "$namespace" \
    -o jsonpath="{.data.${field_key}}" 2>/dev/null | base64 --decode
}

# SHA-256 fingerprint of a PEM cert, first 16 hex chars.
_cert_fingerprint() {
  local raw
  raw=$(printf '%s' "$1" | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
  # raw looks like "SHA256 Fingerprint=AA:BB:CC:..."
  raw="${raw##*=}"          # strip everything up to and including '='
  raw="${raw//:/}"          # remove ':' separators
  printf '%s' "${raw:0:16}"
}

# Print cert expiry; warn if within $2 days (default 30).
# Compare fingerprint against BOB_CA_CERT_FILE if set (rotation detection).
_check_rotation() {
  local ca_pem="$1" warn_days="${2:-30}"
  local end_date not_after_epoch now_epoch days_left

  local raw_end
  raw_end=$(printf '%s' "$ca_pem" | openssl x509 -noout -enddate 2>/dev/null)
  end_date="${raw_end#notAfter=}"
  [[ -z "$end_date" ]] && return 0

  not_after_epoch=$(date -d "$end_date" +%s 2>/dev/null \
    || date -j -f "%b %d %T %Y %Z" "$end_date" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  days_left=$(( (not_after_epoch - now_epoch) / 86400 ))

  log_info "Certificate expires: ${end_date} (${days_left} days from now)"

  if [[ $days_left -le $warn_days ]]; then
    log_warn "WARNING: Certificate expires in ${days_left} days."
    log_warn "         Re-run: ./bobctl get-ca-cert --output bob-ca.crt and redistribute."
  fi

  local saved_file="${BOB_CA_CERT_FILE:-}"
  if [[ -n "$saved_file" && -f "$saved_file" ]]; then
    local cluster_fp saved_fp
    cluster_fp=$(_cert_fingerprint "$ca_pem")
    saved_fp=$(_cert_fingerprint "$(cat "$saved_file")")
    if [[ "$cluster_fp" != "$saved_fp" ]]; then
      log_warn ""
      log_warn "┌──────────────────────────────────────────────────────────────────┐"
      log_warn "│  CA ROTATION DETECTED                                            │"
      log_warn "│  The CA cert on the cluster differs from: ${saved_file}          │"
      log_warn "│  Re-run:  ./bobctl get-ca-cert --output bob-ca.crt               │"
      log_warn "│  Then redistribute bob-ca.crt to all users.                     │"
      log_warn "└──────────────────────────────────────────────────────────────────┘"
    else
      log_info "CA fingerprint matches saved copy — no rotation detected."
    fi
  fi
}

# Prints the Bob CR name in the given namespace, or exits with an error.
_get_bob_cr_name() {
  local namespace="$1"
  local cr_name
  local full_name
  full_name=$(oc get bob -n "$namespace" -o name 2>/dev/null | head -1)
  cr_name="${full_name#*/}"
  if [[ -z "$cr_name" ]]; then
    log_error "No Bob CR found in namespace '${namespace}'"
    log_info "Ensure the Bob operator has completed installation."
    exit 1
  fi
  printf '%s' "$cr_name"
}

# Prints the name of the secret backing the Bob external TLS certificate.
# Returns spec.externalCertificate.secretName if set, else "bob-external-tls".
_resolve_effective_secret() {
  local cr_name="$1" namespace="$2"
  local custom
  custom=$(oc get bob "$cr_name" -n "$namespace" \
    -o jsonpath='{.spec.externalCertificate.secretName}' 2>/dev/null)
  printf '%s' "${custom:-bob-external-tls}"
}

# Extracts ca.crt from the given secret and prints scenario-appropriate output.
# Called by get-ca-cert, setup-route and reset-route after a successful reconcile.
_print_cert_summary() {
  local secret_name="$1" namespace="$2" output_file="${3:-}"
  local ca_pem=""

  if oc get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    ca_pem=$(_decode_secret_field "$secret_name" "ca\.crt" "$namespace")
  fi

  if [[ "$secret_name" == "bob-external-tls" ]]; then
    # Scenario A: default self-signed
    if [[ -z "$ca_pem" ]]; then
      log_info "secret/${secret_name} does not contain ca.crt — operator may still be reconciling."
      return 0
    fi
    _check_rotation "$ca_pem"
    log_warn ""
    log_warn "┌──────────────────────────────────────────────────────────────────┐"
    log_warn "│  Scenario A: Default self-signed certificate in use              │"
    log_warn "│  This CA is NOT publicly trusted. Distribute it to every user    │"
    log_warn "│  workstation that connects to IBM Bob (see instructions below).  │"
    log_warn "│                                                                  │"
    log_warn "│  To replace with your own certificate, run:                      │"
    log_warn "│    ./bobctl setup-route --tls-secret <secret>                    │"
    log_warn "└──────────────────────────────────────────────────────────────────┘"
    log_info ""
    if [[ -n "$output_file" ]]; then
      printf '%s\n' "$ca_pem" > "$output_file"
      log_info "CA certificate written to: $output_file"
    else
      log_info "$ca_pem"
    fi
    log_info ""
    log_info "Next steps:"
    log_info "  1. Save: ./bobctl get-ca-cert --output bob-ca.crt"
    log_info "  2. Distribute bob-ca.crt to all users who connect to IBM Bob."
    log_info "  3. To detect when cert-manager has rotated the CA, re-run with:"
    log_info "     BOB_CA_CERT_FILE=./bob-ca.crt ./bobctl get-ca-cert"
    log_info "     A warning is printed if the cluster cert differs from the saved copy."
    log_info ""
  else
    # Scenario B: customer-provided
    log_info ""
    log_info "┌──────────────────────────────────────────────────────────────────┐"
    log_info "│  Scenario B: Customer-provided certificate in use                │"
    log_info "│  secret/${secret_name}"
    log_info "└──────────────────────────────────────────────────────────────────┘"
    log_info ""
    if [[ -z "$ca_pem" ]]; then
      log_info "secret/${secret_name} does not contain ca.crt — nothing to extract."
      log_info "If your certificate was issued by a publicly-trusted CA (e.g. Let's Encrypt),"
      log_info "no distribution is needed — clients already trust it."
      log_info "If users see TLS errors, have them install the issuing CA in their trust store."
      return 0
    fi
    _check_rotation "$ca_pem"
    log_info "ca.crt is present in secret/${secret_name}."
    log_info "If this is your organisation's CA it is likely already trusted"
    log_info "org-wide — distribution is optional."
    log_info ""
    if [[ -n "$output_file" ]]; then
      printf '%s\n' "$ca_pem" > "$output_file"
      log_info "CA certificate written to: $output_file"
    else
      log_info "$ca_pem"
    fi
  fi
}

# ---------------------------------------------------------------------------
# get-ca-cert
# ---------------------------------------------------------------------------
# Resolves the effectiveSecret from the Bob CR, extracts ca.crt (never tls.key),
# and prints trust instructions (Scenario A: default self-signed; Scenario B:
# customer-provided).
get_ca_cert() {
  local output_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)
        if [[ -z "${2:-}" ]]; then
          log_error "--output requires a file path argument"
          usage
        fi
        output_file="$2"
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  check_oc_login

  local namespace
  namespace=$(validate_namespace "instanceNamespace" "$BOB_CONFIG_FILE")

  local cr_name effective_secret
  cr_name=$(_get_bob_cr_name "$namespace")
  effective_secret=$(_resolve_effective_secret "$cr_name" "$namespace")

  log_info "Bob CR: ${cr_name}"
  log_info "Effective edge-cert secret: ${effective_secret}"

  if ! oc get secret "$effective_secret" -n "$namespace" >/dev/null 2>&1; then
    if [[ "$effective_secret" == "bob-external-tls" ]]; then
      log_error "secret/${effective_secret} not found in namespace '${namespace}'"
      log_info "Ensure the Bob operator has completed TLS reconciliation."
      log_info "Check operator logs: oc logs -n <operator-ns> deploy/ibm-bob-operator"
    else
      log_error "secret/${effective_secret} not found in namespace '${namespace}'"
      log_info "Verify the secret name set in spec.externalCertificate.secretName on bob/${cr_name}."
    fi
    exit 1
  fi

  _print_cert_summary "$effective_secret" "$namespace" "$output_file"
}

# ---------------------------------------------------------------------------
# setup-route
# ---------------------------------------------------------------------------
# Patches spec.externalCertificate.secretName on the Bob CR with the supplied
# secret, then polls until the operator reconciles the Ingress (secretName matches
# and cert-manager issuer annotation is removed). Mirrors CPD's setup-route.
setup_route() {
  local tls_secret=""
  export DRY_RUN=false
  local no_wait=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tls-secret)
        if [[ -z "${2:-}" ]]; then
          log_error "--tls-secret requires a secret name argument"
          usage
        fi
        tls_secret="$2"
        shift 2
        ;;
      --no-wait)
        no_wait=true
        shift
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

  if [[ -z "$tls_secret" ]]; then
    log_error "--tls-secret is required"
    usage
  fi

  check_oc_login

  local namespace
  namespace=$(validate_namespace "instanceNamespace" "$BOB_CONFIG_FILE")

  log_info "Configuring Bob external TLS certificate in namespace: $namespace"

  # ── 1. Validate the named secret ────────────────────────────────────────
  if [[ "$DRY_RUN" != "true" ]]; then
    if ! oc get secret "$tls_secret" -n "$namespace" >/dev/null 2>&1; then
      log_error "Secret '${tls_secret}' not found in namespace '${namespace}'"
      log_info "Create it first:"
      log_info "  oc create secret generic ${tls_secret} \\"
      log_info "    --from-file=tls.crt=/path/to/tls.crt \\"
      log_info "    --from-file=tls.key=/path/to/tls.key \\"
      log_info "    --from-file=ca.crt=/path/to/ca.crt \\"
      log_info "    -n ${namespace}"
      exit 1
    fi

    local secret_type missing_keys=()
    secret_type=$(oc get secret "$tls_secret" -n "$namespace" -o jsonpath='{.type}' 2>/dev/null)

    for key in "tls.crt" "tls.key"; do
      local val
      val=$(oc get secret "$tls_secret" -n "$namespace" \
        -o jsonpath="{.data.${key/\./\\.}}" 2>/dev/null)
      if [[ -z "$val" ]]; then
        missing_keys+=("$key")
      fi
    done

    if [[ ${#missing_keys[@]} -gt 0 ]]; then
      log_error "Secret '${tls_secret}' is missing required keys: ${missing_keys[*]}"
      log_info "The secret must contain tls.crt and tls.key."
      exit 1
    fi

    # Warn if ca.crt is absent — get-ca-cert will have nothing to extract (Scenario B).
    local ca_val
    ca_val=$(oc get secret "$tls_secret" -n "$namespace" \
      -o jsonpath="{.data.ca\.crt}" 2>/dev/null)
    if [[ -z "$ca_val" ]]; then
      log_warn "Secret '${tls_secret}' does not contain ca.crt."
      log_warn "If your CA is publicly trusted this is fine. Otherwise add ca.crt so"
      log_warn "'bobctl get-ca-cert' can extract it for distribution."
    fi

    log_info "Secret '${tls_secret}' validated (type: ${secret_type})"
  else
    log_dry_run "Would validate secret '${tls_secret}' (tls.crt, tls.key present; ca.crt optional)"
  fi

  # ── 2. Resolve the Bob CR name ───────────────────────────────────────────
  local cr_name
  if [[ "$DRY_RUN" != "true" ]]; then
    cr_name=$(_get_bob_cr_name "$namespace")
  else
    cr_name="bob-cr"
  fi

  # ── 3. Patch spec.externalCertificate.secretName on the Bob CR ──────────
  local patch
  patch=$(printf '{"spec":{"externalCertificate":{"secretName":"%s"}}}' "$tls_secret")

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would patch bob/${cr_name}: spec.externalCertificate.secretName=${tls_secret}"
    log_dry_run "Would wait for operator to reconcile ingress/bob-gateway (secretName + annotations)"
    return 0
  fi

  log_info "Patching bob/${cr_name}: spec.externalCertificate.secretName=${tls_secret}"
  if ! oc patch bob "$cr_name" -n "$namespace" \
      --type=merge -p "$patch" 2>&1 | tee -a "$LOG_FILE"; then
    log_error "Failed to patch bob/${cr_name}"
    exit 1
  fi

  if [[ "$no_wait" == "true" ]]; then
    log_info "CR patched. Skipping reconcile wait (--no-wait)."
    log_info "Verify with: oc get ingress bob-gateway -n ${namespace} -o jsonpath='{.spec.tls[0].secretName}'"
    return 0
  fi

  # ── 4. Poll until the operator reconciles ───────────────────────────────
  # Success: Ingress spec.tls[0].secretName == tls_secret AND cert-manager
  # issuer annotation is absent (operator stripped it).
  local max_retries="${BOB_ROUTE_WAIT_RETRIES:-30}"
  local retry_delay="${BOB_ROUTE_WAIT_DELAY:-10}"
  local attempts=0

  log_info "Waiting for operator to reconcile ingress/bob-gateway (up to $((max_retries * retry_delay))s)..."

  while [[ $attempts -lt $max_retries ]]; do
    local ingress_secret cm_issuer
    ingress_secret=$(oc get ingress bob-gateway -n "$namespace" \
      -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)
    cm_issuer=$(oc get ingress bob-gateway -n "$namespace" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/issuer}' 2>/dev/null)

    if [[ "$ingress_secret" == "$tls_secret" && -z "$cm_issuer" ]]; then
      log_info "Operator reconcile complete."
      log_info "  ingress/bob-gateway → spec.tls[0].secretName: ${ingress_secret}"
      log_info "  cert-manager.io/issuer annotation: removed"
      log_info ""
      log_info "Certificate installed successfully."
      log_info ""
      _print_cert_summary "$tls_secret" "$namespace"
      return 0
    fi

    attempts=$((attempts + 1))
    log_info "  [${attempts}/${max_retries}] ingress secretName='${ingress_secret}', cert-manager issuer='${cm_issuer:-<removed>}' — waiting ${retry_delay}s..."
    sleep "$retry_delay"
  done

  log_error "Operator did not reconcile ingress/bob-gateway within the timeout."
  log_info "Current ingress secretName: $(oc get ingress bob-gateway -n "${namespace}" -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)"
  log_info "Check operator logs: oc logs -n <operator-ns> deploy/ibm-bob-operator"
  exit 1
}

# ---------------------------------------------------------------------------
# reset-route
# ---------------------------------------------------------------------------
# Removes spec.externalCertificate from the Bob CR, handing the external TLS
# certificate back to the operator (cert-manager). Polls until
# the operator reconciles — Ingress secretName == "bob-external-tls" and
# the cert-manager issuer annotation is restored.
reset_route() {
  export DRY_RUN=false
  local no_wait=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-wait)
        no_wait=true
        shift
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

  check_oc_login

  local namespace
  namespace=$(validate_namespace "instanceNamespace" "$BOB_CONFIG_FILE")

  log_info "Reverting external TLS certificate to operator-managed default in namespace: $namespace"

  # ── 1. Resolve the Bob CR name ───────────────────────────────────────────
  local cr_name
  if [[ "$DRY_RUN" != "true" ]]; then
    cr_name=$(_get_bob_cr_name "$namespace")

    # Check whether a custom cert is actually set — nothing to do if not.
    local current_secret
    current_secret=$(_resolve_effective_secret "$cr_name" "$namespace")
    if [[ "$current_secret" == "bob-external-tls" ]]; then
      log_info "No custom certificate is configured — already using the IBM Bob default."
      return 0
    fi
    log_info "Current custom certificate secret: ${current_secret}"
  else
    cr_name="bob-cr"
  fi

  # ── 2. Remove spec.externalCertificate from the Bob CR ──────────────────
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "Would patch bob/${cr_name}: remove spec.externalCertificate"
    log_dry_run "Would wait for operator to reconcile ingress/bob-gateway back to bob-external-tls"
    return 0
  fi

  log_info "Patching bob/${cr_name}: removing spec.externalCertificate"
  if ! oc patch bob "$cr_name" -n "$namespace" \
      --type=json -p '[{"op":"remove","path":"/spec/externalCertificate"}]' \
      2>&1 | tee -a "$LOG_FILE"; then
    log_error "Failed to patch bob/${cr_name}"
    exit 1
  fi

  if [[ "$no_wait" == "true" ]]; then
    log_info "CR patched. Skipping reconcile wait (--no-wait)."
    log_info "Verify with: oc get ingress bob-gateway -n ${namespace} -o jsonpath='{.spec.tls[0].secretName}'"
    return 0
  fi

  # ── 3. Poll until the operator reconciles ───────────────────────────────
  # Success: Ingress secretName == "bob-external-tls" AND cert-manager issuer
  # annotation is restored (operator re-took ownership).
  local max_retries="${BOB_ROUTE_WAIT_RETRIES:-30}"
  local retry_delay="${BOB_ROUTE_WAIT_DELAY:-10}"
  local attempts=0

  log_info "Waiting for operator to reconcile ingress/bob-gateway (up to $((max_retries * retry_delay))s)..."

  while [[ $attempts -lt $max_retries ]]; do
    local ingress_secret cm_issuer
    ingress_secret=$(oc get ingress bob-gateway -n "$namespace" \
      -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)
    cm_issuer=$(oc get ingress bob-gateway -n "$namespace" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/issuer}' 2>/dev/null)

    if [[ "$ingress_secret" == "bob-external-tls" && -n "$cm_issuer" ]]; then
      log_info "Operator reconcile complete."
      log_info "  ingress/bob-gateway → spec.tls[0].secretName: ${ingress_secret}"
      log_info "  cert-manager.io/issuer annotation: restored"
      log_info ""
      log_info "Certificate reverted to IBM Bob default successfully."
      log_info ""
      _print_cert_summary "bob-external-tls" "$namespace"
      return 0
    fi

    attempts=$((attempts + 1))
    log_info "  [${attempts}/${max_retries}] ingress secretName='${ingress_secret}', cert-manager issuer='${cm_issuer:-<pending>}' — waiting ${retry_delay}s..."
    sleep "$retry_delay"
  done

  log_error "Operator did not reconcile ingress/bob-gateway within the timeout."
  log_info "Current ingress secretName: $(oc get ingress bob-gateway -n "${namespace}" -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)"
  log_info "Check operator logs: oc logs -n <operator-ns> deploy/ibm-bob-operator"
  exit 1
}
