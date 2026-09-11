# IBM Bob Installation Guide

IBM Bob is a code assistant service that can be deployed on OpenShift clusters.

## Prerequisites

- OpenShift cluster with the following installed:
  - [cert-manager](https://cert-manager.io/) through [cert-manager Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift#cert-manager-operator-install)
- Bash 3.2 or later (required to run the installation scripts)
- Helm 3.14.0 or later installed ([Download](https://github.com/helm/helm/releases))
- `oc` CLI tool ([Download](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.22/))
- Registry credentials for accessing IBM container images
- Sufficient cluster resources for your deployment

## Installation Methods

### Method 1: Direct Installation (Connected Environment)

Use this method when your cluster has direct access to the IBM container registry.

#### Step 1: Configure Installation

Edit the `config.yaml` file to customize your installation:

```bash
cp config-template.yaml config.yaml
# Edit config.yaml with your specific values
```

#### Step 2: Generate Cluster-Scoped Resources

Generate cluster-scoped resources before installation:

```bash
./bobctl generate-cluster-resources
```

This generates resources in `release/work` directory that you can review and apply manually if needed.

#### Step 3: Install IBM Bob

```bash
./bobctl install --registry-creds <username:password>
```

Options:

- `--registry-creds <username:password>`: Required. Registry credentials for image pull secret
- `--dry-run`: Optional. Preview what would be installed without actually installing

### Method 2: Air-Gapped Installation with Direct Image Mirroring

Use this method when your client workstation can connect to the internet and to the private container registry.

#### Step 1: Mirror Images

Mirror images directly from source to destination registry (requires network access to both):

```bash
./bobctl mirror-images \
  --dest-registry <your-registry> \
  --src-creds <username:password> \
  --dest-creds <username:password> \
  --arch amd64
```

Options:

- `--dest-registry <registry>`: Required. Target registry URL for mirrored images
- `--src-creds <username:password>`: Required. Source registry credentials
- `--arch amd64`: Optional. Filter images by cluster architecture
- `--dest-creds <username:password>`: Optional. Destination registry credentials

#### Step 2: Generate Cluster-Scoped Resources

Generate cluster-scoped resources before installation:

```bash
./bobctl generate-cluster-resources
```

This generates resources in `release/work` directory that you can review and apply manually if needed.

#### Step 3: Install IBM Bob

Update `config.yaml` to point to your private registry, then install:

```bash
./bobctl install --registry-creds <username:password>
```

### Method 3: Air-Gapped Installation with Indirect Image Mirroring

Use this method when your client workstation cannot connect to the internet and to the private container registry at the same time. This method requires downloading images on a machine with internet access, then transferring and uploading them from a machine with access to the private registry.

#### Step 1: Download Images (Connected Environment)

On a machine with internet access, download all required images:

```bash
./bobctl download-images \
  --to-dir /path/to/images \
  --src-creds <username:password> \
  --arch amd64
```

Options:

- `--to-dir <directory>`: Required. Directory path to download images to
- `--src-creds <username:password>`: Required. Source registry credentials
- `--arch amd64`: Optional. Filter images by cluster architecture

#### Step 2: Transfer Images

Transfer the downloaded images directory to your air-gapped environment.

#### Step 3: Upload Images to Private Registry

In your air-gapped environment, upload images to your private registry:

```bash
./bobctl upload-images \
  --from-dir /path/to/images \
  --dest-registry <your-registry> \
  --dest-creds <username:password>
```

Options:

- `--from-dir <directory>`: Required. Directory path containing downloaded images
- `--dest-registry <registry>`: Required. Target registry URL
- `--dest-creds <username:password>`: Optional. Destination registry credentials

#### Step 4: Generate Cluster-Scoped Resources

Generate cluster-scoped resources before installation:

```bash
./bobctl generate-cluster-resources
```

This generates resources in `release/work` directory that you can review and apply manually if needed.

#### Step 5: Install IBM Bob

Update `config.yaml` to point to your private registry, then install:

```bash
./bobctl install --registry-creds <username:password>
```

## Upgrading IBM Bob

To upgrade an existing IBM Bob installation to a newer version:

```bash
./bobctl upgrade
```

The upgrade command uses the same `config.yaml` file that was used for the initial installation.

Options:

- `--dry-run`: Optional. Preview what would be upgraded without actually upgrading

**Prerequisites for Upgrade:**

- Existing IBM Bob installation
- `config.yaml` file from the existing IBM Bob installation
- If upgrading to a version with new images, ensure images are available in your registry

**Upgrade Process:**

1. If using a private registry, mirror new images first (see air-gapped installation methods)
2. Re-generate cluster-scoped resources (see "Generate Cluster-Scoped Resources" sections above)
3. Run the upgrade command:

```bash
./bobctl upgrade
```

The upgrade command will:
- Validate cluster connectivity and namespaces
- Verify image pull secrets exist
- Apply Helm chart updates using `helm upgrade --install`
- Preserve existing configuration values with `--reset-then-reuse-values`

**Verification After Upgrade:**

```bash
# Check operator status
oc get pods -n <operator-namespace>

# Check IBM Bob instance status and version
oc get bob -n <instance-namespace>

# View operator logs
oc logs -n <operator-namespace> deployment/ibm-bob-operator -f
```

## TLS / CA Certificate Trust

### Background

`get-ca-cert` resolves the *effectiveSecret* — `spec.externalCertificate.secretName`
on the Bob CR if set, otherwise `bob-external-tls` — and extracts only `ca.crt`
from that secret (never `tls.key`). Two scenarios arise:

| Scenario | When it applies | What you need to do |
|---|---|---|
| **A — Default self-signed** | No custom cert installed (`bob-external-tls` is in use) | Extract the CA cert and distribute it to every user workstation |
| **B — Customer certificate** | `setup-route` was run with a custom secret | `ca.crt` is likely already trusted org-wide — distribution optional |

---

### Scenario A — Extracting and distributing the default CA cert

After installation, the cluster admin runs:

```bash
./bobctl get-ca-cert --output bob-ca.crt
```

`bobctl` resolves `bob-external-tls` as the effectiveSecret, extracts `ca.crt`,
writes it to `bob-ca.crt`, and prints distribution instructions.

Options:

- `--output <file>`: Write the certificate to a file instead of printing it inline

Distribute `bob-ca.crt` to all users who connect to IBM Bob and direct them to
add it to their OS or application trust store. Refer to IBM Bob documentation
for client-specific setup instructions.

**CA rotation**: cert-manager rotates the CA automatically. `bobctl get-ca-cert`
always prints the expiry date and warns when the cert is within 30 days. To
detect rotation proactively, set `BOB_CA_CERT_FILE` to your previously saved copy:

```bash
BOB_CA_CERT_FILE=./bob-ca.crt ./bobctl get-ca-cert --output bob-ca-new.crt
```

If the cluster cert differs from the saved copy, `bobctl` prints a **CA
ROTATION DETECTED** warning. Redistribute the new cert to all users.

---

### Scenario B — Customer-provided certificate

If `spec.externalCertificate.secretName` is set on the Bob CR, `get-ca-cert`
reads `ca.crt` from that secret. If `ca.crt` is present and the CA is
private/corporate, distribute it the same way as Scenario A. If it is absent
(publicly-trusted CA), no distribution is needed.

---

### Installing a custom TLS certificate (`setup-route`)

Replace the default self-signed certificate clients use to connect to IBM Bob
with your own. The secret must exist in the instance namespace and contain `tls.crt` and
`tls.key` (PEM, unencrypted). Including `ca.crt` is recommended — it enables
`get-ca-cert` to extract the CA cert for distribution (Scenario B). Omit it
only when your certificate was issued by a publicly-trusted CA (e.g. Let's
Encrypt, DigiCert) where clients already trust the issuer.

Create the secret:

```bash
# With CA cert (recommended when using a private/corporate CA)
oc create secret generic my-tls-secret \
  --from-file=tls.crt=/path/to/tls.crt \
  --from-file=tls.key=/path/to/tls.key \
  --from-file=ca.crt=/path/to/ca.crt \
  -n <instance-namespace>

# Without CA cert (publicly-trusted CA only)
oc create secret tls my-tls-secret \
  --cert=/path/to/tls.crt \
  --key=/path/to/tls.key \
  -n <instance-namespace>
```

Install the certificate:

```bash
./bobctl setup-route --tls-secret my-tls-secret
```

`bobctl` validates the secret, patches `spec.externalCertificate.secretName`
on the Bob CR, then polls until the operator confirms the Ingress
`spec.tls.secretName` matches and the cert-manager issuer annotation is removed.
If `ca.crt` is absent, a warning is printed but the command succeeds.

Options:

- `--tls-secret <secret>`: Required. Secret containing `tls.crt` and `tls.key` (`ca.crt` optional)
- `--no-wait`: Optional. Skip polling for operator reconciliation
- `--dry-run`: Optional. Preview changes without applying them

**Timeouts**: default 30 retries × 10 s = 5 min. Override with
`BOB_ROUTE_WAIT_RETRIES` and `BOB_ROUTE_WAIT_DELAY`.

---

### Reverting to the default certificate (`reset-route`)

Remove the custom certificate and let the operator resume managing the
external TLS certificate automatically via cert-manager:

```bash
./bobctl reset-route
```

`bobctl` removes `spec.externalCertificate` from the Bob CR and polls until
the operator reconciles — confirming the Ingress `spec.tls.secretName` is back
to `bob-external-tls` and the cert-manager issuer annotation is restored. The
self-signed CA cert is printed on success (Scenario A), ready to distribute.

If no custom certificate is configured, the command exits cleanly with no changes.

Options:

- `--no-wait`: Optional. Skip polling for operator reconciliation
- `--dry-run`: Optional. Preview changes without applying them

---

## LDAP Integration

To connect an LDAP/AD server as a user federation provider, create an
LDAP configuration file from the provided template:

```bash
cp config-ldap-template.yaml <filename>.yaml
# Edit <filename>.yaml with your LDAP server details
```

Then apply the LDAP configuration:

```bash
./bobctl add-ldap --config <filename>.yaml \
  --bind-password '<bind-password>' \
  --ca-cert-file /path/to/ca.crt
```

`bobctl` creates the Secrets in the cluster automatically, named after the values set in
`bindPasswordSecret` and `ldapsCACertSecret` in your config file. If the secrets already
exist (e.g. on a re-run), they are replaced in-place.

Omit `--bind-password` for anonymous bind, or `--ca-cert-file` when using a publicly-trusted CA
or plain `ldap://`. If a flag is omitted but the config references a secret name, that secret
must already exist in the cluster.

Options:

- `--config <file>`: Required. Path to the LDAP configuration file
- `--bind-password <password>`: Optional. Creates the `bindPasswordSecret` in the cluster
- `--ca-cert-file <path>`: Optional. Creates the `ldapsCACertSecret` from a local PEM file
- `--dry-run`: Optional. Preview what would be applied without making any changes

After applying, `bobctl` automatically waits for the operator to reconcile the BobLDAP CR
and validates all three status conditions:

| Condition | What it checks |
|---|---|
| `Ready` | Provider successfully registered in Keycloak |
| `LDAPReachable` | LDAP server is network-reachable from the cluster |
| `LDAPAuthenticated` | Bind succeeded (anonymous or credential-based) |

Each condition's status message is printed as it resolves. The command exits non-zero if
any condition becomes `False`, surfacing the operator's error message directly in the terminal.

The default wait timeout is **180 seconds**. Override it with the `BOB_LDAP_WAIT_TIMEOUT`
environment variable:

```bash
BOB_LDAP_WAIT_TIMEOUT=300 ./bobctl add-ldap --config my-ldap.yaml
```

To configure multiple LDAP providers, use separate configuration files with distinct `name` values:

```bash
./bobctl add-ldap --config ldap-corp.yaml
./bobctl add-ldap --config ldap-subsidiary.yaml
```

To inspect the full CR status at any time:

```bash
oc get bobldap -n <instance-namespace>
oc get bobldap <name> -n <instance-namespace> -o yaml
```

## Configuration File

The `config.yaml` file controls your IBM Bob installation. Key configuration options include:

- **Namespace**: Target namespace for IBM Bob deployment
- **Registry**: Container registry settings
- **License**: License acceptance and configuration
- **Dependencies**: PostgreSQL, Redis, OpenSearch, Keycloak settings

Refer to `config-template.yaml` for all available configuration options.

## Verification

After installation, verify the deployment:

```bash
# Check operator status
oc get pods -n <operator-namespace>

# Check IBM Bob instance status
oc get bob -n <instance-namespace>

# View operator logs
oc logs -n <operator-namespace> deployment/ibm-bob-operator -f
```

## Troubleshooting

### Logs

All bobctl operations create log files in `release/logs/` directory. Check these logs for detailed information about operations.

### Dry Run Mode

Use `--dry-run` flag with any command to preview what would be executed without actually executing:

```bash
./bobctl install --registry-creds <username:password> --dry-run
```

### Common Issues

1. **Image Pull Errors**: Verify registry credentials are correct
2. **Insufficient Resources**: Check cluster has enough CPU/memory for your deployment
3. **Namespace Issues**: Ensure target namespaces exist and have proper permissions

## Architecture Support

IBM Bob supports the following architectures:

- `amd64` (x86_64)

Specify architecture using `--arch` flag when downloading or mirroring images.
