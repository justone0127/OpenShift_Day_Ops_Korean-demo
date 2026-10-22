#!/usr/bin/env bash
#
# RedPay 보안 트랙 — 모듈 1 (Red Hat build of Keycloak / MFA) 사전 환경 구성
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
# 실행 위치: cluster-admin 으로 oc login 된 곳이면 어디든 (bastion, Showroom 터미널 등)
# 필요 도구: oc (curl 은 있으면 인증서 확인에만 사용, 없어도 동작)
#   Keycloak 설정은 keycloak-0 pod 안의 관리 CLI(kcadm.sh)를 oc exec 로 호출하므로
#   python3, jq 등이 필요 없습니다.
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
  command -v oc >/dev/null 2>&1 || err "oc 를 PATH 에서 찾을 수 없습니다"
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
#
# keycloak-0 pod 안의 kcadm.sh 를 oc exec 로 호출합니다. JSON 을 직접 다루지 않으므로
# 실행하는 쪽에 python3 / jq 가 없어도 됩니다.
# ─────────────────────────────────────────────────────────────────────

KCADM_CONFIG="/tmp/kcadm-redpay.config"

# kcx <kcadm 인자...>  → keycloak-0 안에서 kcadm.sh 실행 (CR LF 정리)
kcx() {
  oc exec -n "${RHBK_NS}" keycloak-0 -- /opt/keycloak/bin/kcadm.sh "$@" --config "${KCADM_CONFIG}" \
    | tr -d '\r'
}

kc_login() {
  local user pass i
  user="$(oc get secret keycloak-initial-admin -n "${RHBK_NS}" -o jsonpath='{.data.username}' | base64 -d)"
  pass="$(oc get secret keycloak-initial-admin -n "${RHBK_NS}" -o jsonpath='{.data.password}' | base64 -d)"
  # Keycloak 이 막 뜬 직후에는 잠시 실패할 수 있으므로 재시도합니다.
  for i in $(seq 1 24); do
    if kcx config credentials --server http://localhost:8080 --realm master \
         --user "${user}" --password "${pass}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  err "Keycloak 관리자 로그인 실패 (oc exec keycloak-0 → kcadm.sh)"
}

realm_exists() {
  kcx get "realms/${RHBK_REALM}" --fields realm >/dev/null 2>&1
}

configure_realm() {
  hr
  log "Realm '${RHBK_REALM}' 구성..."
  kc_login

  # SSO 세션을 60초로 짧게 둔 이유:
  #   OpenShift 콘솔에서 로그아웃해도 Keycloak 세션은 남아 있습니다.
  #   세션이 짧아야 참가자가 다시 로그인할 때 OTP 입력 화면을 바로 확인할 수 있습니다.
  local settings=(
    -s displayName=RedPay -s enabled=true
    -s registrationAllowed=true -s registrationEmailAsUsername=false
    -s loginWithEmailAllowed=true -s duplicateEmailsAllowed=false
    -s resetPasswordAllowed=false -s verifyEmail=false -s rememberMe=false
    -s bruteForceProtected=true -s permanentLockout=false -s failureFactor=10
    -s otpPolicyType=totp -s otpPolicyAlgorithm=HmacSHA1 -s otpPolicyDigits=6
    -s otpPolicyPeriod=30 -s otpPolicyLookAheadWindow=1
    -s ssoSessionIdleTimeout=60 -s ssoSessionMaxLifespan=600
    -s accessCodeLifespanUserAction=900 -s accessCodeLifespanLogin=1800
  )

  if realm_exists; then
    log "  realm 이 이미 존재합니다 — 설정만 갱신합니다"
    kcx update "realms/${RHBK_REALM}" "${settings[@]}" >/dev/null
  else
    kcx create realms -s "realm=${RHBK_REALM}" "${settings[@]}" >/dev/null
    log "  realm 생성 완료"
  fi

  configure_otp_required_action
  configure_client
}

configure_otp_required_action() {
  local da="false"
  [[ "$(echo "${RHBK_OTP_DEFAULT_ACTION}" | tr '[:upper:]' '[:lower:]')" == "true" ]] && da="true"
  log "Required action 'Configure OTP' 설정 (Enabled=On, Default action=${da})..."
  kcx update authentication/required-actions/CONFIGURE_TOTP -r "${RHBK_REALM}" \
    -s enabled=true -s "defaultAction=${da}" >/dev/null
}

client_uuid() {
  kcx get clients -r "${RHBK_REALM}" -q "clientId=${CLIENT_ID}" --fields id --format csv --noquotes \
    2>/dev/null | head -1
}

configure_client() {
  local domain callback uuid
  domain="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
  callback="https://oauth-openshift.${domain}/oauth2callback/${RHBK_IDP_NAME}"

  local client=(
    -s "clientId=${CLIENT_ID}" -s name=OpenShift -s enabled=true
    -s protocol=openid-connect -s publicClient=false
    -s clientAuthenticatorType=client-secret
    -s standardFlowEnabled=true -s directAccessGrantsEnabled=false
    -s "redirectUris=[\"${callback}\"]" -s 'webOrigins=["+"]'
  )

  uuid="$(client_uuid)"
  if [[ -z "${uuid}" ]]; then
    log "OIDC client '${CLIENT_ID}' 생성 (redirect: ${callback})..."
    kcx create clients -r "${RHBK_REALM}" "${client[@]}" >/dev/null
    uuid="$(client_uuid)"
    [[ -n "${uuid}" ]] || err "OIDC client 생성 후 ID 를 찾지 못했습니다"
  else
    log "OIDC client '${CLIENT_ID}' 가 이미 존재합니다 — redirect URI 갱신"
    kcx update "clients/${uuid}" -r "${RHBK_REALM}" "${client[@]}" >/dev/null
  fi

  if ! kcx get "clients/${uuid}/protocol-mappers/models" -r "${RHBK_REALM}" \
         --fields name --format csv --noquotes 2>/dev/null | grep -qx groups; then
    log "groups claim mapper 추가..."
    # config 값은 문자열이어야 하므로 '"..."' 로 감쌉니다.
    kcx create "clients/${uuid}/protocol-mappers/models" -r "${RHBK_REALM}" \
      -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"="false"' -s 'config."id.token.claim"="true"' \
      -s 'config."access.token.claim"="true"' -s 'config."claim.name"="groups"' \
      -s 'config."userinfo.token.claim"="true"' >/dev/null
  fi

  local secret
  secret="$(kcx get "clients/${uuid}/client-secret" -r "${RHBK_REALM}" --fields value --format csv --noquotes | head -1)"
  [[ -n "${secret}" ]] || err "client secret 을 가져오지 못했습니다"

  log "openshift-config/${CLIENT_SECRET_NAME} 갱신..."
  oc create secret generic "${CLIENT_SECRET_NAME}" -n openshift-config \
    --from-literal=clientSecret="${secret}" --dry-run=client -o yaml | oc apply -f - >/dev/null
  log "Realm 구성 완료"
}

# ─────────────────────────────────────────────────────────────────────
# 4. OpenShift OAuth 연동
# ─────────────────────────────────────────────────────────────────────

# OAuth identityProviders 목록에서 이름이 같은 항목의 인덱스(0부터). 없으면 빈 문자열.
idp_index() {
  local line
  line="$(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\n"}{end}' 2>/dev/null \
    | grep -nx "${RHBK_IDP_NAME}" | head -1 | cut -d: -f1)"
  [[ -n "${line}" ]] && echo $((line - 1))
  return 0
}

configure_oauth() {
  hr
  log "OpenShift OAuth 에 '${RHBK_IDP_NAME}' Identity Provider 추가..."

  local host issuer
  host="$(oc get route keycloak -n "${RHBK_NS}" -o jsonpath='{.spec.host}')"
  issuer="https://${host}/realms/${RHBK_REALM}"

  # OAuth 서버가 Keycloak 인증서를 신뢰하지 못하는 환경(자체 서명 ingress 인증서)이면
  # ingress CA 를 ConfigMap 으로 넣어 줍니다. curl 이 없으면 확인을 건너뜁니다.
  local ca_json=""
  if command -v curl >/dev/null 2>&1; then
    if ! curl -s -o /dev/null --max-time 10 "${issuer}/.well-known/openid-configuration"; then
      log "  Keycloak 인증서가 공인 CA 가 아닙니다 — ingress CA 를 ${CA_CONFIGMAP_NAME} 로 등록"
      oc get configmap default-ingress-cert -n openshift-config-managed \
        -o jsonpath='{.data.ca-bundle\.crt}' \
        | oc create configmap "${CA_CONFIGMAP_NAME}" -n openshift-config --from-file=ca.crt=/dev/stdin \
            --dry-run=client -o yaml | oc apply -f - >/dev/null
      ca_json=",\"ca\":{\"name\":\"${CA_CONFIGMAP_NAME}\"}"
    fi
  else
    warn "curl 이 없어 Keycloak 인증서 확인을 건너뜁니다 (공인 인증서인 RHDP 환경이면 문제없습니다)"
  fi

  local idp
  idp="{\"name\":\"${RHBK_IDP_NAME}\",\"mappingMethod\":\"claim\",\"type\":\"OpenID\",\"openID\":{\"clientID\":\"${CLIENT_ID}\",\"clientSecret\":{\"name\":\"${CLIENT_SECRET_NAME}\"},\"issuer\":\"${issuer}\",\"claims\":{\"preferredUsername\":[\"preferred_username\"],\"name\":[\"name\"],\"email\":[\"email\"],\"groups\":[\"groups\"]},\"extraScopes\":[\"email\",\"profile\"]${ca_json}}}"

  local gen idx count patch
  gen="$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')"

  # 기존 Identity Provider 는 유지하고, 같은 이름의 항목만 교체합니다 (JSON patch).
  idx="$(idp_index)"
  count="$(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
  if [[ -n "${idx}" ]]; then
    patch="[{\"op\":\"remove\",\"path\":\"/spec/identityProviders/${idx}\"},{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${idp}}]"
  elif [[ "${count}" -gt 0 ]]; then
    patch="[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${idp}}]"
  else
    patch="[{\"op\":\"add\",\"path\":\"/spec/identityProviders\",\"value\":[${idp}]}]"
  fi
  oc patch oauth cluster --type=json -p "${patch}" >/dev/null

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
  wait_oauth_settled
  log "OAuth 연동 완료 — OpenShift 로그인 화면에 '${RHBK_IDP_NAME}' 가 표시됩니다"
}

# OAuth pod 일부만 새 설정으로 바뀐 상태에서 로그인하면, 요청이 옛 설정의 pod 로 가는 순간
# "Authentication error ... Try again" 이 납니다. rollout status 만으로는 operator 가
# 이어서 한 번 더 롤아웃하는 경우를 놓칠 수 있으므로, 다음이 모두 만족될 때까지 기다립니다.
#   - authentication ClusterOperator: Available=True, Progressing=False
#   - oauth-openshift pod 가 모두 Running/Ready 이고, 전부 같은 ReplicaSet(새 설정)에 속함
oauth_settled() {
  local avail prog total ready rs
  avail="$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
  prog="$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)"
  [[ "${avail}" == "True" && "${prog}" == "False" ]] || return 1
  total="$(oc get pods -n openshift-authentication -l app=oauth-openshift --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  ready="$(oc get pods -n openshift-authentication -l app=oauth-openshift --no-headers 2>/dev/null | grep -c '1/1 *Running' || true)"
  rs="$(oc get pods -n openshift-authentication -l app=oauth-openshift \
        -o jsonpath='{range .items[*]}{.metadata.labels.pod-template-hash}{"\n"}{end}' 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -eq "${total}" && "${rs}" -eq 1 ]]
}

wait_oauth_settled() {
  log "OAuth pod 가 모두 새 설정으로 안정될 때까지 대기 (최대 6분)..."
  local elapsed=0 stable=0
  # 순간적으로 조건을 만족했다가 다시 롤아웃되는 경우를 걸러 내기 위해 30초 연속 안정을 확인합니다.
  while (( stable < 30 )); do
    if oauth_settled; then stable=$((stable + 5)); else stable=0; fi
    sleep 5; elapsed=$((elapsed + 5))
    if (( elapsed >= 360 )); then
      warn "OAuth 가 아직 안정되지 않았습니다 — oc get co authentication; oc get pods -n openshift-authentication 로 확인하십시오"
      return 0
    fi
  done
  log "  OAuth 안정됨 ($(oc get pods -n openshift-authentication -l app=oauth-openshift --no-headers | wc -l | tr -d ' ')개 pod, 모두 새 설정)"
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
    if oc get route keycloak -n "${RHBK_NS}" >/dev/null 2>&1; then
      echo "  ✓ Route: $(keycloak_url)"
    else
      echo "  ✗ Route"; ok=false
    fi
    kc_login
    if realm_exists; then
      local info ra users
      info="$(kcx get "realms/${RHBK_REALM}" --fields registrationAllowed,otpPolicyType,otpPolicyDigits,otpPolicyPeriod \
                --format csv --noquotes 2>/dev/null | head -1)"
      echo "  ✓ Realm ${RHBK_REALM} (registration,otp,digits,period = ${info})"
      ra="$(kcx get authentication/required-actions/CONFIGURE_TOTP -r "${RHBK_REALM}" \
              --fields enabled,defaultAction --format csv --noquotes 2>/dev/null | head -1)"
      echo "  ✓ Configure OTP: Enabled=${ra%%,*}, Set as default action=${ra##*,}"
      users="$(kcx get users/count -r "${RHBK_REALM}" 2>/dev/null | head -1)"
      echo "    등록된 사용자 수: ${users}"
    else
      echo "  ✗ Realm ${RHBK_REALM}"; ok=false
    fi
  else
    echo "  ✗ Keycloak pod"; ok=false
  fi

  if oc get secret "${CLIENT_SECRET_NAME}" -n openshift-config >/dev/null 2>&1; then
    echo "  ✓ openshift-config/${CLIENT_SECRET_NAME}"
  else
    echo "  ✗ openshift-config/${CLIENT_SECRET_NAME}"; ok=false
  fi

  if [[ -n "$(idp_index)" ]]; then
    echo "  ✓ OAuth identity provider '${RHBK_IDP_NAME}'"
    if oauth_settled; then
      echo "  ✓ OAuth pod 모두 새 설정으로 안정됨"
    else
      echo "  ✗ OAuth pod 가 아직 롤아웃 중 — 잠시 후 다시 확인하십시오 (이 상태에서 로그인하면 'Try again' 오류가 날 수 있음)"; ok=false
    fi
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
  echo "  참가자 OTP 앱: Google Authenticator / Microsoft Authenticator / FreeOTP 등 TOTP 앱"
  hr
}

delete_rhbk_identities() {
  # Keycloak 에서 지운 사용자에 대응하는 OpenShift User/Identity 도 정리합니다.
  local name user
  for name in $(oc get identity -o jsonpath="{range .items[?(@.providerName==\"${RHBK_IDP_NAME}\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null); do
    user="$(oc get identity "${name}" -o jsonpath='{.user.name}' 2>/dev/null || true)"
    oc delete identity "${name}" --ignore-not-found >/dev/null
    [[ -n "${user}" ]] && oc delete user "${user}" --ignore-not-found >/dev/null
  done
  return 0
}

reset_lab() {
  hr
  log "실습 리셋 — realm '${RHBK_REALM}' 의 사용자 전체 삭제 + Configure OTP 기본 동작 복원"
  kc_login
  local id
  for id in $(kcx get users -r "${RHBK_REALM}" --limit 1000 --fields id --format csv --noquotes); do
    kcx delete "users/${id}" -r "${RHBK_REALM}" >/dev/null
  done
  configure_otp_required_action
  delete_rhbk_identities
  log "리셋 완료"
}

cleanup() {
  hr
  log "RHBK MFA 실습 환경 정리..."
  local idx
  idx="$(idp_index)"
  if [[ -n "${idx}" ]]; then
    oc patch oauth cluster --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/identityProviders/${idx}\"}]" >/dev/null
    log "  OAuth 에서 '${RHBK_IDP_NAME}' 제거"
  fi

  delete_rhbk_identities

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
