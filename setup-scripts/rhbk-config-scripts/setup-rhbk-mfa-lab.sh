#!/usr/bin/env bash
#
# 레드페이 보안 트랙 — 모듈 15 (Red Hat build of Keycloak / MFA) 사전 환경 구성
#
# 진행자(환경 제공자)용 스크립트입니다. 참가자는 이 스크립트를 실행하지 않습니다.
# 참가자는 실습에서 다음만 수행합니다:
#   1) Keycloak 콘솔 → Authentication → Required actions → Configure OTP 확인
#   2) OpenShift 콘솔 로그인 화면 → rhbk 선택 → 사용자 등록(Register)
#   3) QR 코드를 OTP 앱에 등록 → 토큰 입력 → 로그인
#
# 이 스크립트가 미리 준비하는 것:
#   - RHBK Operator 설치 (namespace: rhbk)
#   - Keycloak 인스턴스 + Route
#   - Realm "redpay" (셀프 등록 허용, TOTP 정책, brute-force 보호, 짧은 SSO 세션)
#   - OIDC client "openshift" + groups mapper
#   - openshift-config/rhbk-client-secret, OAuth 에 "rhbk" Identity Provider 추가
#     (기존 Identity Provider 는 그대로 유지합니다)
#
# 사용법:
#   ./setup-rhbk-mfa-lab.sh all       # 전체 구성 (기본값)
#   ./setup-rhbk-mfa-lab.sh operator  # Operator 설치만
#   ./setup-rhbk-mfa-lab.sh keycloak  # Keycloak 인스턴스 + Route
#   ./setup-rhbk-mfa-lab.sh realm     # Realm / client / OTP 설정
#   ./setup-rhbk-mfa-lab.sh oauth     # OpenShift OAuth 연동
#   ./setup-rhbk-mfa-lab.sh status    # 준비 상태 점검
#   ./setup-rhbk-mfa-lab.sh info      # 진행자/참가자 안내 정보 출력
#   ./setup-rhbk-mfa-lab.sh reset     # 참가자가 등록한 사용자 삭제 + OTP 기본 동작 Off 로 되돌리기
#   ./setup-rhbk-mfa-lab.sh cleanup   # OAuth 에서 rhbk 제거 + namespace 삭제
#
# 환경 변수:
#   RHBK_NS                     기본값 rhbk
#   RHBK_REALM                  기본값 redpay
#   RHBK_IDP_NAME               기본값 rhbk   (OpenShift 로그인 화면에 보이는 이름)
#   RHBK_CHANNEL                기본값 stable-v26
#   RHBK_OTP_DEFAULT_ACTION     기본값 false
#       false → 참가자가 실습에서 "Set as default action" 을 직접 켭니다 (가이드 기준).
#       true  → 진행자가 미리 켜 둡니다 (실습 시간을 줄이고 싶을 때).
#
# 실행 위치: bastion (cluster-admin 으로 oc login 된 상태)
# 필요 도구: oc, curl, python3
# 소요 시간: 약 4~6분 (Operator 설치 + OAuth pod 재시작 대기)

set -euo pipefail

RHBK_NS="${RHBK_NS:-rhbk}"
RHBK_REALM="${RHBK_REALM:-redpay}"
RHBK_IDP_NAME="${RHBK_IDP_NAME:-rhbk}"
RHBK_CHANNEL="${RHBK_CHANNEL:-stable-v26}"
RHBK_OTP_DEFAULT_ACTION="${RHBK_OTP_DEFAULT_ACTION:-false}"
CLIENT_ID="openshift"
CLIENT_SECRET_NAME="rhbk-client-secret"
CA_CONFIGMAP_NAME="rhbk-ca"

ACTION="${1:-all}"

log()  { echo "[rhbk-mfa] $*"; }
warn() { echo "[rhbk-mfa] WARNING: $*" >&2; }
err()  { echo "[rhbk-mfa] ERROR: $*" >&2; exit 1; }
hr()   { echo "--------------------------------------------------------------------"; }

require_tools() {
  local t
  for t in oc curl python3; do
    command -v "${t}" >/dev/null 2>&1 || err "${t} 를 PATH 에서 찾을 수 없습니다"
  done
  oc whoami >/dev/null 2>&1 || err "OpenShift 에 로그인되어 있지 않습니다 (oc login)"
  oc auth can-i patch oauths.config.openshift.io >/dev/null 2>&1 \
    || err "cluster-admin 권한이 필요합니다 (OAuth 리소스 수정 권한 없음)"
}

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local timeout="$1" desc="$2"; shift 2
  local elapsed=0
  until "$@" >/dev/null 2>&1; do
    sleep 5; elapsed=$((elapsed + 5))
    if (( elapsed >= timeout )); then
      err "${desc} 대기 시간 초과 (${timeout}s)"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────
# 1. Operator
# ─────────────────────────────────────────────────────────────────────

csv_succeeded() {
  oc get csv -n "${RHBK_NS}" --no-headers 2>/dev/null | grep rhbk-operator | grep -q Succeeded
}

install_operator() {
  hr
  log "RHBK Operator 설치 (namespace: ${RHBK_NS}, channel: ${RHBK_CHANNEL})..."

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${RHBK_NS}
  labels:
    workshop: redpay-security-track
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhbk
  namespace: ${RHBK_NS}
spec:
  targetNamespaces:
  - ${RHBK_NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: ${RHBK_NS}
spec:
  channel: ${RHBK_CHANNEL}
  installPlanApproval: Automatic
  name: rhbk-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  log "Operator CSV 가 Succeeded 가 될 때까지 대기 (최대 5분)..."
  wait_until 300 "RHBK Operator CSV" csv_succeeded
  log "Keycloak CRD 등록 대기..."
  wait_until 120 "Keycloak CRD" oc get crd keycloaks.k8s.keycloak.org
  log "RHBK Operator 준비 완료"
}

# ─────────────────────────────────────────────────────────────────────
# 2. Keycloak 인스턴스
# ─────────────────────────────────────────────────────────────────────

deploy_keycloak() {
  hr
  log "Keycloak 인스턴스 배포..."

  # 실습용이므로 내장 dev-file DB 를 사용합니다.
  # 운영 환경에서는 외부 PostgreSQL 을 사용하십시오.
  cat <<EOF | oc apply -f -
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: ${RHBK_NS}
spec:
  instances: 1
  db:
    vendor: dev-file
  http:
    httpEnabled: true
  hostname:
    strict: false
  proxy:
    headers: xforwarded
EOF

  log "Keycloak pod 생성 대기..."
  wait_until 240 "keycloak-0 pod 생성" oc get pod keycloak-0 -n "${RHBK_NS}"
  oc wait --for=condition=Ready pod/keycloak-0 -n "${RHBK_NS}" --timeout=300s >/dev/null

  if ! oc get route keycloak -n "${RHBK_NS}" >/dev/null 2>&1; then
    log "Route 생성..."
    oc create route edge keycloak --service=keycloak-service --port=8080 \
      --insecure-policy=Redirect -n "${RHBK_NS}" >/dev/null
  fi

  log "Keycloak 준비 완료: $(keycloak_url)"
}

keycloak_url() {
  echo "https://$(oc get route keycloak -n "${RHBK_NS}" -o jsonpath='{.spec.host}')"
}

# ─────────────────────────────────────────────────────────────────────
# 3. Realm / Client / OTP
# ─────────────────────────────────────────────────────────────────────

KC_URL=""
KC_TOKEN=""

kc_login() {
  KC_URL="$(keycloak_url)"
  local user pass
  user="$(oc get secret keycloak-initial-admin -n "${RHBK_NS}" -o jsonpath='{.data.username}' | base64 -d)"
  pass="$(oc get secret keycloak-initial-admin -n "${RHBK_NS}" -o jsonpath='{.data.password}' | base64 -d)"

  # Route 가 막 생성된 직후에는 잠시 503 이 날 수 있으므로 재시도합니다.
  local i
  for i in $(seq 1 24); do
    KC_TOKEN="$(curl -sk "${KC_URL}/realms/master/protocol/openid-connect/token" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=admin-cli" \
      --data-urlencode "username=${user}" \
      --data-urlencode "password=${pass}" \
      | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token",""))
except Exception: print("")' || true)"
    [[ -n "${KC_TOKEN}" ]] && return 0
    sleep 5
  done
  err "Keycloak admin token 을 얻지 못했습니다 (${KC_URL})"
}

# kc <METHOD> <path> [json-body]  → 응답 본문 출력, HTTP 오류 시 실패
kc() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sk -X "${method}" "${KC_URL}/admin${path}"
              -H "Authorization: Bearer ${KC_TOKEN}"
              -H "Content-Type: application/json"
              -w '\n%{http_code}')
  [[ -n "${body}" ]] && args+=(-d "${body}")
  local out code
  out="$(curl "${args[@]}")"
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [[ "${code}" -ge 400 ]]; then
    echo "${out}" >&2
    return 1
  fi
  printf '%s' "${out}"
}

kc_status() {
  curl -sk -o /dev/null -w '%{http_code}' "${KC_URL}/admin$1" -H "Authorization: Bearer ${KC_TOKEN}"
}

configure_realm() {
  hr
  log "Realm '${RHBK_REALM}' 구성..."
  kc_login

  local realm_settings
  realm_settings="$(cat <<EOF
{
  "realm": "${RHBK_REALM}",
  "displayName": "RedPay",
  "enabled": true,
  "registrationAllowed": true,
  "registrationEmailAsUsername": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": false,
  "verifyEmail": false,
  "rememberMe": false,
  "bruteForceProtected": true,
  "permanentLockout": false,
  "failureFactor": 10,
  "otpPolicyType": "totp",
  "otpPolicyAlgorithm": "HmacSHA1",
  "otpPolicyDigits": 6,
  "otpPolicyPeriod": 30,
  "otpPolicyLookAheadWindow": 1,
  "ssoSessionIdleTimeout": 60,
  "ssoSessionMaxLifespan": 600,
  "accessCodeLifespanUserAction": 900,
  "accessCodeLifespanLogin": 1800
}
EOF
)"

  if [[ "$(kc_status "/realms/${RHBK_REALM}")" == "200" ]]; then
    log "  realm 이 이미 존재합니다 — 설정만 갱신합니다"
    kc PUT "/realms/${RHBK_REALM}" "${realm_settings}" >/dev/null
  else
    kc POST "/realms" "${realm_settings}" >/dev/null
    log "  realm 생성 완료"
  fi
  # SSO 세션을 60초로 짧게 둔 이유:
  #   OpenShift 콘솔에서 로그아웃해도 Keycloak 세션은 남아 있습니다.
  #   세션이 짧아야 참가자가 "다시 로그인 → OTP 입력" 을 바로 확인할 수 있습니다.

  configure_otp_required_action
  configure_client
}

configure_otp_required_action() {
  log "Required action 'Configure OTP' 설정 (Enabled=On, Default action=${RHBK_OTP_DEFAULT_ACTION})..."
  local ra
  ra="$(kc GET "/realms/${RHBK_REALM}/authentication/required-actions/CONFIGURE_TOTP")"
  ra="$(printf '%s' "${ra}" | DEFAULT_ACTION="${RHBK_OTP_DEFAULT_ACTION}" python3 -c '
import sys, json, os
ra = json.load(sys.stdin)
ra["enabled"] = True
ra["defaultAction"] = os.environ["DEFAULT_ACTION"].lower() == "true"
print(json.dumps(ra))')"
  kc PUT "/realms/${RHBK_REALM}/authentication/required-actions/CONFIGURE_TOTP" "${ra}" >/dev/null
}

configure_client() {
  local domain callback
  domain="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
  callback="https://oauth-openshift.${domain}/oauth2callback/${RHBK_IDP_NAME}"

  local client_uuid
  client_uuid="$(kc GET "/realms/${RHBK_REALM}/clients?clientId=${CLIENT_ID}" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"

  local client_body
  client_body="$(cat <<EOF
{
  "clientId": "${CLIENT_ID}",
  "name": "OpenShift",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "redirectUris": ["${callback}"],
  "webOrigins": ["+"]
}
EOF
)"

  if [[ -z "${client_uuid}" ]]; then
    log "OIDC client '${CLIENT_ID}' 생성 (redirect: ${callback})..."
    kc POST "/realms/${RHBK_REALM}/clients" "${client_body}" >/dev/null
    client_uuid="$(kc GET "/realms/${RHBK_REALM}/clients?clientId=${CLIENT_ID}" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])')"
  else
    log "OIDC client '${CLIENT_ID}' 가 이미 존재합니다 — redirect URI 갱신"
    kc PUT "/realms/${RHBK_REALM}/clients/${client_uuid}" "${client_body}" >/dev/null
  fi

  local has_mapper
  has_mapper="$(kc GET "/realms/${RHBK_REALM}/clients/${client_uuid}/protocol-mappers/models" \
    | python3 -c 'import sys,json; print(any(m.get("name")=="groups" for m in json.load(sys.stdin)))')"
  if [[ "${has_mapper}" != "True" ]]; then
    log "groups claim mapper 추가..."
    kc POST "/realms/${RHBK_REALM}/clients/${client_uuid}/protocol-mappers/models" \
      '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"false","id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}}' >/dev/null
  fi

  local secret
  secret="$(kc GET "/realms/${RHBK_REALM}/clients/${client_uuid}/client-secret" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])')"

  log "openshift-config/${CLIENT_SECRET_NAME} 갱신..."
  oc create secret generic "${CLIENT_SECRET_NAME}" -n openshift-config \
    --from-literal=clientSecret="${secret}" --dry-run=client -o yaml | oc apply -f - >/dev/null
  log "Realm 구성 완료"
}

# ─────────────────────────────────────────────────────────────────────
# 4. OpenShift OAuth 연동
# ─────────────────────────────────────────────────────────────────────

configure_oauth() {
  hr
  log "OpenShift OAuth 에 '${RHBK_IDP_NAME}' Identity Provider 추가..."

  local host issuer
  host="$(oc get route keycloak -n "${RHBK_NS}" -o jsonpath='{.spec.host}')"
  issuer="https://${host}/realms/${RHBK_REALM}"

  # OAuth 서버가 Keycloak 인증서를 신뢰하지 못하는 환경(자체 서명 ingress 인증서)이면
  # ingress CA 를 ConfigMap 으로 넣어 줍니다.
  local ca_name=""
  if ! curl -s -o /dev/null --max-time 10 "${issuer}/.well-known/openid-configuration"; then
    log "  Keycloak 인증서가 공인 CA 가 아닙니다 — ingress CA 를 ${CA_CONFIGMAP_NAME} 로 등록"
    local ca_file
    ca_file="$(mktemp)"
    oc get configmap default-ingress-cert -n openshift-config-managed \
      -o jsonpath='{.data.ca-bundle\.crt}' > "${ca_file}"
    oc create configmap "${CA_CONFIGMAP_NAME}" -n openshift-config \
      --from-file=ca.crt="${ca_file}" --dry-run=client -o yaml | oc apply -f - >/dev/null
    rm -f "${ca_file}"
    ca_name="${CA_CONFIGMAP_NAME}"
  fi

  local gen
  gen="$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')"

  # 기존 Identity Provider 는 유지하고, 같은 이름의 항목만 교체합니다.
  local patch
  patch="$(oc get oauth cluster -o json | IDP="${RHBK_IDP_NAME}" ISSUER="${issuer}" \
    CLIENT_ID="${CLIENT_ID}" SECRET="${CLIENT_SECRET_NAME}" CA="${ca_name}" python3 -c '
import sys, json, os
oauth = json.load(sys.stdin)
idps = [i for i in (oauth.get("spec", {}).get("identityProviders") or []) if i.get("name") != os.environ["IDP"]]
openid = {
    "clientID": os.environ["CLIENT_ID"],
    "clientSecret": {"name": os.environ["SECRET"]},
    "issuer": os.environ["ISSUER"],
    "claims": {
        "preferredUsername": ["preferred_username"],
        "name": ["name"],
        "email": ["email"],
        "groups": ["groups"],
    },
    "extraScopes": ["email", "profile"],
}
if os.environ["CA"]:
    openid["ca"] = {"name": os.environ["CA"]}
idps.append({"name": os.environ["IDP"], "mappingMethod": "claim", "type": "OpenID", "openID": openid})
print(json.dumps({"spec": {"identityProviders": idps}}))')"

  oc patch oauth cluster --type=merge -p "${patch}" >/dev/null

  log "OAuth pod 재시작 대기 (1~3분)..."
  local elapsed=0
  until [[ "$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')" -gt "${gen}" ]]; do
    sleep 3; elapsed=$((elapsed + 3))
    if (( elapsed >= 90 )); then
      log "  (설정 변경이 없어 재시작이 필요 없거나, operator 반영이 느립니다)"
      break
    fi
  done
  oc rollout status deployment/oauth-openshift -n openshift-authentication --timeout=300s >/dev/null || \
    warn "oauth-openshift rollout 확인 실패 — oc get pods -n openshift-authentication 로 확인하십시오"
  log "OAuth 연동 완료 — OpenShift 로그인 화면에 '${RHBK_IDP_NAME}' 가 표시됩니다"
}

# ─────────────────────────────────────────────────────────────────────
# 상태 / 안내 / 리셋 / 정리
# ─────────────────────────────────────────────────────────────────────

status() {
  hr
  log "RHBK MFA 실습 준비 상태"
  hr
  local ok=true

  if csv_succeeded; then echo "  ✓ RHBK Operator"; else echo "  ✗ RHBK Operator"; ok=false; fi

  if oc get pod keycloak-0 -n "${RHBK_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    echo "  ✓ Keycloak pod Ready"
  else
    echo "  ✗ Keycloak pod"; ok=false
  fi

  if oc get route keycloak -n "${RHBK_NS}" >/dev/null 2>&1; then
    echo "  ✓ Route: $(keycloak_url)"
    kc_login
    if [[ "$(kc_status "/realms/${RHBK_REALM}")" == "200" ]]; then
      local info
      info="$(kc GET "/realms/${RHBK_REALM}" | python3 -c '
import sys,json; r=json.load(sys.stdin)
print("registration=%s otp=%s/%sdigits/%ss" % (r.get("registrationAllowed"), r.get("otpPolicyType"), r.get("otpPolicyDigits"), r.get("otpPolicyPeriod")))')"
      echo "  ✓ Realm ${RHBK_REALM} (${info})"
      local ra
      ra="$(kc GET "/realms/${RHBK_REALM}/authentication/required-actions/CONFIGURE_TOTP" | python3 -c '
import sys,json; r=json.load(sys.stdin); print("Enabled=%s, Set as default action=%s" % (r["enabled"], r["defaultAction"]))')"
      echo "  ✓ Configure OTP: ${ra}"
      local users
      users="$(kc GET "/realms/${RHBK_REALM}/users/count")"
      echo "    등록된 사용자 수: ${users}"
    else
      echo "  ✗ Realm ${RHBK_REALM}"; ok=false
    fi
  else
    echo "  ✗ Route"; ok=false
  fi

  if oc get secret "${CLIENT_SECRET_NAME}" -n openshift-config >/dev/null 2>&1; then
    echo "  ✓ openshift-config/${CLIENT_SECRET_NAME}"
  else
    echo "  ✗ openshift-config/${CLIENT_SECRET_NAME}"; ok=false
  fi

  if oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | tr ' ' '\n' | grep -qx "${RHBK_IDP_NAME}"; then
    echo "  ✓ OAuth identity provider '${RHBK_IDP_NAME}'"
  else
    echo "  ✗ OAuth identity provider '${RHBK_IDP_NAME}'"; ok=false
  fi
  hr
  $ok && log "준비 완료" || log "일부 항목이 준비되지 않았습니다 — ./setup-rhbk-mfa-lab.sh all 을 다시 실행하십시오"
}

info() {
  hr
  log "진행자 안내 정보"
  hr
  echo "  Keycloak 콘솔 : $(keycloak_url)/admin/master/console/#/${RHBK_REALM}"
  echo "  admin 계정    : $(oc get secret keycloak-initial-admin -n "${RHBK_NS}" -o jsonpath='{.data.username}' | base64 -d)"
  echo "  admin 비밀번호: $(oc get secret keycloak-initial-admin -n "${RHBK_NS}" -o jsonpath='{.data.password}' | base64 -d)"
  echo "  Realm         : ${RHBK_REALM}"
  echo "  OpenShift 로그인 화면의 IdP 이름: ${RHBK_IDP_NAME}"
  echo
  echo "  참가자는 가이드의 명령으로 위 정보를 직접 조회할 수 있습니다."
  echo "  참가자 OTP 앱: Google Authenticator / Microsoft Authenticator / FreeOTP / Red Hat 2FA 등 TOTP 앱"
  hr
}

reset_lab() {
  hr
  log "실습 리셋 — realm '${RHBK_REALM}' 의 사용자 전체 삭제 + Configure OTP 기본 동작 복원"
  kc_login
  local ids id
  ids="$(kc GET "/realms/${RHBK_REALM}/users?max=1000&briefRepresentation=true" \
    | python3 -c 'import sys,json; print("\n".join(u["id"] for u in json.load(sys.stdin)))')"
  for id in ${ids}; do
    kc DELETE "/realms/${RHBK_REALM}/users/${id}" >/dev/null
  done
  configure_otp_required_action

  # Keycloak 에서 지운 사용자에 대응하는 OpenShift User/Identity 도 정리합니다.
  local name
  for name in $(oc get identity -o jsonpath="{range .items[?(@.providerName==\"${RHBK_IDP_NAME}\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null); do
    local user
    user="$(oc get identity "${name}" -o jsonpath='{.user.name}' 2>/dev/null || true)"
    oc delete identity "${name}" --ignore-not-found >/dev/null
    [[ -n "${user}" ]] && oc delete user "${user}" --ignore-not-found >/dev/null
  done
  log "리셋 완료"
}

cleanup() {
  hr
  log "RHBK MFA 실습 환경 정리..."
  local patch
  patch="$(oc get oauth cluster -o json | IDP="${RHBK_IDP_NAME}" python3 -c '
import sys, json, os
oauth = json.load(sys.stdin)
idps = [i for i in (oauth.get("spec", {}).get("identityProviders") or []) if i.get("name") != os.environ["IDP"]]
print(json.dumps({"spec": {"identityProviders": idps}}))')"
  oc patch oauth cluster --type=merge -p "${patch}" >/dev/null
  log "  OAuth 에서 '${RHBK_IDP_NAME}' 제거"

  local name
  for name in $(oc get identity -o jsonpath="{range .items[?(@.providerName==\"${RHBK_IDP_NAME}\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null); do
    local user
    user="$(oc get identity "${name}" -o jsonpath='{.user.name}' 2>/dev/null || true)"
    oc delete identity "${name}" --ignore-not-found >/dev/null
    [[ -n "${user}" ]] && oc delete user "${user}" --ignore-not-found >/dev/null
  done

  oc delete secret "${CLIENT_SECRET_NAME}" -n openshift-config --ignore-not-found >/dev/null
  oc delete configmap "${CA_CONFIGMAP_NAME}" -n openshift-config --ignore-not-found >/dev/null
  oc delete namespace "${RHBK_NS}" --ignore-not-found --wait=false >/dev/null
  log "정리 완료"
}

main() {
  require_tools
  case "${ACTION}" in
    all)      install_operator; deploy_keycloak; configure_realm; configure_oauth; status; info ;;
    operator) install_operator ;;
    keycloak) deploy_keycloak ;;
    realm)    configure_realm ;;
    oauth)    configure_oauth ;;
    status)   status ;;
    info)     info ;;
    reset)    reset_lab ;;
    cleanup)  cleanup ;;
    *)
      echo "사용법: $0 [all|operator|keycloak|realm|oauth|status|info|reset|cleanup]" >&2
      exit 1
      ;;
  esac
}

main "$@"
