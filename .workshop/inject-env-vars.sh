#!/bin/bash
# inject-env-vars.sh
# Injects workshop environment variables into Antora configuration
# Called by ocp4-workload-days-ops-track after showroom deployment
#
# Uses ifeval conditionals in nav.adoc:
#   ifeval::["{module_enable_virt}" == "true"]
# So attributes must be set as: module_enable_virt: 'true'

set -e

REPO_DIR="/showroom/repo"
SITE_FILE="${REPO_DIR}/default-site.yml"

echo "=== Injecting workshop environment variables ==="
echo "Working directory: ${REPO_DIR}"

# Check if default-site.yml exists
if [ ! -f "$SITE_FILE" ]; then
    echo "ERROR: ${SITE_FILE} not found"
    exit 1
fi

# Build asciidoc attributes based on MODULE_ENABLE_* environment variables
# These control which nav items are shown via ifeval conditionals

echo "Module settings (getting started):"
echo "  MODULE_ENABLE_INSTALL=${MODULE_ENABLE_INSTALL:-true}"
echo "Module settings (core operations):"
echo "  MODULE_ENABLE_APPMGMT=${MODULE_ENABLE_APPMGMT:-true}"
echo "  MODULE_ENABLE_INGRESS=${MODULE_ENABLE_INGRESS:-true}"
echo "  MODULE_ENABLE_NETSEC=${MODULE_ENABLE_NETSEC:-true}"
echo "  MODULE_ENABLE_DEBUGGING=${MODULE_ENABLE_DEBUGGING:-true}"
echo "  MODULE_ENABLE_GITOPS=${MODULE_ENABLE_GITOPS:-true}"
echo "Module settings (identity & access):"
echo "  MODULE_ENABLE_LDAP=${MODULE_ENABLE_LDAP:-true}"
echo "  MODULE_ENABLE_OIDC=${MODULE_ENABLE_OIDC:-true}"
echo "Module settings (day 2 operations):"
echo "  MODULE_ENABLE_OBSERVABILITY=${MODULE_ENABLE_OBSERVABILITY:-true}"
echo "  MODULE_ENABLE_PERFORMANCE=${MODULE_ENABLE_PERFORMANCE:-true}"
echo "Module settings (advanced topics):"
echo "  MODULE_ENABLE_VIRT=${MODULE_ENABLE_VIRT:-true}"
echo "  MODULE_ENABLE_DEVHUB=${MODULE_ENABLE_DEVHUB:-true}"
echo "  MODULE_ENABLE_OLS=${MODULE_ENABLE_OLS:-true}"
echo "  MODULE_ENABLE_ACM=${MODULE_ENABLE_ACM:-true}"
echo "  MODULE_ENABLE_SECURITY=${MODULE_ENABLE_SECURITY:-true}"
echo "  MODULE_ENABLE_ZTWIM=${MODULE_ENABLE_ZTWIM:-true}"
echo "  MODULE_ENABLE_VAULT=${MODULE_ENABLE_VAULT:-true}"

# Create attributes section for Antora
# ifeval checks: ifeval::["{module_enable_virt}" == "true"]
# So we set the attribute to 'true' or 'false'
ATTRS=""

# Module flags
# Getting Started
ATTRS="${ATTRS}    module_enable_install: '${MODULE_ENABLE_INSTALL:-true}'"$'\n'
# Core Operations
ATTRS="${ATTRS}    module_enable_appmgmt: '${MODULE_ENABLE_APPMGMT:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_ingress: '${MODULE_ENABLE_INGRESS:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_netsec: '${MODULE_ENABLE_NETSEC:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_debugging: '${MODULE_ENABLE_DEBUGGING:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_gitops: '${MODULE_ENABLE_GITOPS:-true}'"$'\n'
# Identity & Access
ATTRS="${ATTRS}    module_enable_ldap: '${MODULE_ENABLE_LDAP:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_oidc: '${MODULE_ENABLE_OIDC:-true}'"$'\n'
# Day 2 Operations
ATTRS="${ATTRS}    module_enable_observability: '${MODULE_ENABLE_OBSERVABILITY:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_performance: '${MODULE_ENABLE_PERFORMANCE:-true}'"$'\n'
# Advanced Topics
ATTRS="${ATTRS}    module_enable_virt: '${MODULE_ENABLE_VIRT:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_devhub: '${MODULE_ENABLE_DEVHUB:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_ols: '${MODULE_ENABLE_OLS:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_acm: '${MODULE_ENABLE_ACM:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_security: '${MODULE_ENABLE_SECURITY:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_ztwim: '${MODULE_ENABLE_ZTWIM:-true}'"$'\n'
ATTRS="${ATTRS}    module_enable_vault: '${MODULE_ENABLE_VAULT:-true}'"$'\n'

# TOC depth - only show main sections
ATTRS="${ATTRS}    toclevels: 2"$'\n'

# 보안 트랙 네임스페이스.
#
# 기본 구성은 참가자마다 클러스터를 하나씩 받는 방식이므로, 접두사 없는
# 이름을 씁니다. setup-security-track.sh 가 만드는 이름과 같습니다.
#
# 여러 참가자가 클러스터 하나를 공유하는 구성(setup-multiuser.sh deploy N)
# 에서만 아래 세 변수를 Showroom 인스턴스별로 넘기십시오:
#   REDPAY_NS=user1-redpay
#   SPIFFE_SERVER_NS=user1-postgresql-spiffe
#   SPIFFE_CLIENT_NS=user1-postgresql-spiffe-client
LAB_USER_VALUE="${LAB_USER:-${USER_NAME:-user1}}"
ATTRS="${ATTRS}    lab_user: '${LAB_USER_VALUE}'"$'\n'
ATTRS="${ATTRS}    lab_user_password: '${LAB_USER_PASSWORD:-${ADMIN_PASSWORD:-}}'"$'\n'
ATTRS="${ATTRS}    redpay_ns: '${REDPAY_NS:-redpay}'"$'\n'
ATTRS="${ATTRS}    spiffe_server_ns: '${SPIFFE_SERVER_NS:-postgresql-spiffe}'"$'\n'
ATTRS="${ATTRS}    spiffe_client_ns: '${SPIFFE_CLIENT_NS:-postgresql-spiffe-client}'"$'\n'

# Standard workshop variables
ATTRS="${ATTRS}    api_url: '${API_URL:-}'"$'\n'
ATTRS="${ATTRS}    master_url: '${MASTER_URL:-}'"$'\n'
ATTRS="${ATTRS}    admin_password: '${ADMIN_PASSWORD:-}'"$'\n'
ATTRS="${ATTRS}    ssh_username: '${SSH_USERNAME:-}'"$'\n'
ATTRS="${ATTRS}    ssh_password: '${SSH_PASSWORD:-}'"$'\n'
ATTRS="${ATTRS}    bastion_fqdn: '${BASTION_FQDN:-}'"$'\n'
ATTRS="${ATTRS}    guid: '${GUID:-}'"$'\n'
ATTRS="${ATTRS}    route_subdomain: '${ROUTE_SUBDOMAIN:-}'"$'\n'
ATTRS="${ATTRS}    environment: '${ENVIRONMENT:-Amazon Web Services}'"$'\n'
# Aliases - common alternate names content authors may use
ATTRS="${ATTRS}    bastion_ssh_user: '${SSH_USERNAME:-}'"$'\n'
ATTRS="${ATTRS}    bastion_ssh_password: '${SSH_PASSWORD:-}'"$'\n'
ATTRS="${ATTRS}    bastion_public_hostname: '${BASTION_FQDN:-}'"$'\n'
ATTRS="${ATTRS}    openshift_cluster_console_url: '${MASTER_URL:-}'"$'\n'
ATTRS="${ATTRS}    openshift_api_server_url: '${API_URL:-}'"$'\n'
ATTRS="${ATTRS}    openshift_cluster_admin_password: '${ADMIN_PASSWORD:-}'"$'\n'
ATTRS="${ATTRS}    openshift_cluster_admin_username: 'admin'"$'\n'
# Service URLs - derived from ROUTE_SUBDOMAIN
ATTRS="${ATTRS}    console_url: 'https://console-openshift-console.${ROUTE_SUBDOMAIN:-}'"$'\n'
ATTRS="${ATTRS}    rhacs_url: 'https://central-stackrox.${ROUTE_SUBDOMAIN:-}'"$'\n'
ATTRS="${ATTRS}    rhacs_admin_username: 'admin'"$'\n'
ATTRS="${ATTRS}    rhacs_admin_password: '${ADMIN_PASSWORD:-}'"$'\n'
ATTRS="${ATTRS}    acs_route: 'https://central-stackrox.${ROUTE_SUBDOMAIN:-}'"$'\n'
ATTRS="${ATTRS}    acs_portal_username: 'admin'"$'\n'
ATTRS="${ATTRS}    acs_portal_password: '${ADMIN_PASSWORD:-}'"$'\n'
ATTRS="${ATTRS}    argocd_url: 'https://openshift-gitops-server-openshift-gitops.${ROUTE_SUBDOMAIN:-}'"$'\n'
ATTRS="${ATTRS}    devhub_url: 'https://backstage-developer-hub-backstage.${ROUTE_SUBDOMAIN:-}'"$'\n'
ATTRS="${ATTRS}    ols_azure_url: '${OLS_AZURE_URL:-}'"$'\n'

echo "Attributes to inject:"
echo "$ATTRS"

# Check if asciidoc section already exists
if grep -q "^asciidoc:" "$SITE_FILE"; then
    echo "asciidoc section already exists, replacing attributes..."
    # Remove existing asciidoc section and add new one
    cp "$SITE_FILE" "${SITE_FILE}.bak"

    # Remove old asciidoc section (everything from "asciidoc:" to next top-level key or EOF)
    awk '
        /^asciidoc:/ { in_asciidoc=1; next }
        in_asciidoc && /^[a-z]/ { in_asciidoc=0 }
        !in_asciidoc { print }
    ' "${SITE_FILE}.bak" > "$SITE_FILE"
fi

# Append asciidoc section with attributes
echo "" >> "$SITE_FILE"
echo "asciidoc:" >> "$SITE_FILE"
echo "  attributes:" >> "$SITE_FILE"
echo -n "$ATTRS" >> "$SITE_FILE"

# Also inject key attributes into content/antora.yml for source block substitution
# (Antora source blocks with subs="+attributes" only read from antora.yml, not the site playbook)
ANTORA_YML="${REPO_DIR}/content/antora.yml"
if [ -f "$ANTORA_YML" ] && ! grep -q 'ols_azure_url' "$ANTORA_YML"; then
  echo "Injecting ols_azure_url into antora.yml..."
  echo "    ols_azure_url: '${OLS_AZURE_URL:-}'" >> "$ANTORA_YML"
fi

# 네임스페이스 속성은 반드시 antora.yml 에도 반영해야 합니다.
# 보안 트랙의 명령어 블록이 subs="+attributes" 를 쓰기 때문에, 여기에 없으면
# 참가자가 antora.yml 의 기본값을 그대로 보게 됩니다.
if [ -f "$ANTORA_YML" ]; then
  echo "Injecting workshop attributes into antora.yml (redpay_ns=${REDPAY_NS:-redpay})..."
  sed -i -E "s|^( +lab_user:).*|\1 '${LAB_USER_VALUE}'|" "$ANTORA_YML"
  sed -i -E "s|^( +lab_user_password:).*|\1 '${LAB_USER_PASSWORD:-${ADMIN_PASSWORD:-}}'|" "$ANTORA_YML"
  sed -i -E "s|^( +redpay_ns:).*|\1 '${REDPAY_NS:-redpay}'|" "$ANTORA_YML"
  sed -i -E "s|^( +spiffe_server_ns:).*|\1 '${SPIFFE_SERVER_NS:-postgresql-spiffe}'|" "$ANTORA_YML"
  sed -i -E "s|^( +spiffe_client_ns:).*|\1 '${SPIFFE_CLIENT_NS:-postgresql-spiffe-client}'|" "$ANTORA_YML"
  sed -i -E "s|^( +api_url:).*|\1 '${API_URL:-}'|" "$ANTORA_YML"
  grep -E "^ +(lab_user|lab_user_password|redpay_ns|spiffe_server_ns|spiffe_client_ns|api_url):" "$ANTORA_YML"
fi

echo "=== Antora injection complete ==="

# Copy the updated default-site.yml to site.yml (since Antora playbook might be configured to use site.yml)
if [ -f "$SITE_FILE" ]; then
    echo "Copying ${SITE_FILE} to ${REPO_DIR}/site.yml..."
    cp "$SITE_FILE" "${REPO_DIR}/site.yml"
fi

# ==============================================================================
# Generate ui-config.yml with conditional tabs based on enabled modules
# OCP Console and Terminal are always shown (base workloads)
# RHACS, ArgoCD, Developer Hub are conditional on their module flags
# ==============================================================================
echo "=== Generating ui-config.yml with conditional tabs ==="

UI_CONFIG="${REPO_DIR}/ui-config.yml"
DOMAIN="${ROUTE_SUBDOMAIN:-}"

cat > "$UI_CONFIG" <<UIEOF
---
type: showroom

default_width: 30
persist_url_state: true

antora:
  name: openshift-days-ops-track
  version: main

tabs:
  - name: OCP Console
    url: 'https://console-openshift-console.${DOMAIN}'

  - name: Terminal
    path: /wetty
    port: 443
UIEOF

# Add RHACS tab if security module is enabled
if [ "${MODULE_ENABLE_SECURITY:-true}" = "true" ]; then
cat >> "$UI_CONFIG" <<UIEOF

  - name: RHACS
    url: 'https://central-stackrox.${DOMAIN}'
UIEOF
fi

# Add ArgoCD tab if ACM or GitOps module is enabled
if [ "${MODULE_ENABLE_ACM:-true}" = "true" ] || [ "${MODULE_ENABLE_GITOPS:-true}" = "true" ]; then
cat >> "$UI_CONFIG" <<UIEOF

  - name: ArgoCD
    url: 'https://openshift-gitops-server-openshift-gitops.${DOMAIN}'
UIEOF
fi

# Add Developer Hub tab if devhub module is enabled
if [ "${MODULE_ENABLE_DEVHUB:-true}" = "true" ]; then
cat >> "$UI_CONFIG" <<UIEOF

  - name: Developer Hub
    url: 'https://backstage-developer-hub-backstage.${DOMAIN}'
UIEOF
fi

# Copy to served location
cp "$UI_CONFIG" /showroom/www/ui-config.yml 2>/dev/null || true

echo "Generated ui-config.yml:"
cat "$UI_CONFIG"
echo "=== All injection complete ==="
