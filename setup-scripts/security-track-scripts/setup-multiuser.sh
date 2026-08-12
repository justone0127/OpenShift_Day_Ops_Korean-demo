#!/usr/bin/env bash
#
# 나루페이 보안 트랙 — 다중 사용자 배포 스크립트
#
# 참가자마다 계정(user1, user2, ...)이 하나씩 주어지는 환경을 위해,
# 사용자별로 격리된 실습 네임스페이스와 워크로드를 생성합니다.
#
#   ./setup-multiuser.sh deploy 30    # user1~user30 + admin 환경 생성
#   ./setup-multiuser.sh status 30    # 준비 상태 점검
#   ./setup-multiuser.sh cleanup 30      # 사용자 환경만 정리
#   ./setup-multiuser.sh cleanup-all 30  # 사용자 환경 + SPIRE/Vault 까지 정리
#
#   ./setup-multiuser.sh deploy 0                    # admin 것만 (확인용)
#   EXTRA_USERS="" ./setup-multiuser.sh deploy 30    # 참가자 것만
#   EXTRA_USERS="admin lab-user" ./setup-multiuser.sh deploy 30
#
# 사용자당 생성되는 것:
#   userN-narupay                    payment-api, payment-api-secure, legacy-secret-app
#   userN-postgresql-spiffe          PostgreSQL 서버 + ClusterSPIFFEID
#   userN-postgresql-spiffe-client   클라이언트 + ClusterSPIFFEID
#   RoleBinding                      userN 에게 위 세 네임스페이스 admin 권한
#   ConfigMap                        모듈 1 차단 시연용 매니페스트 사본
#   Vault                            secret/userN-narupay/payment-db
#
# 계정(user1~userN)은 실습 환경이 이미 생성해 제공한다고 가정합니다.
# 이 스크립트는 계정을 만들지 않고 권한만 부여합니다.
#
# EXTRA_USERS (기본값: admin) 는 번호 사용자 외에 추가로 환경을 만들 계정입니다.
# 진행자가 참가자와 동일한 환경에서 미리 확인하는 용도입니다.
#
# 공유 자원(사용자별로 나누지 않는 것):
#   - RHACS Central / 정책          정책 Enforce 는 클러스터 전역입니다
#   - SPIRE 플랫폼(SpireServer 등)   configure-ztwim-lab.sh 가 한 번만 구성
#   - Vault 인스턴스                 경로만 사용자별로 나눕니다
#
# 공유 자원 중 참가자가 조회해야 하는 것(RHACS 콘솔 주소, Vault UI 주소,
# admission controller 설정)은 최소 읽기 권한을 별도로 부여합니다.
#
# 실행 위치: bastion (cluster-admin 으로 oc login 된 상태)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
SETUP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VAULT_SCRIPTS="${SETUP_ROOT}/vault-config-scripts"
ZTWIM_SCRIPTS="${SETUP_ROOT}/ztwim-config-scripts"

USER_PREFIX="${USER_PREFIX:-user}"
USER_START="${USER_START:-1}"

# 번호 사용자(user1..userN) 외에 추가로 환경을 만들 계정.
# 진행자가 참가자와 동일한 환경에서 미리 확인할 수 있도록 기본으로 admin 을 포함합니다.
# 여러 명이면 공백으로 구분하고, 필요 없으면 EXTRA_USERS="" 로 비우십시오.
EXTRA_USERS="${EXTRA_USERS:-admin}"
STACKROX_NS="${STACKROX_NS:-stackrox}"
VAULT_NS="${VAULT_NS:-vault}"

ACTION="${1:-}"
COUNT="${2:-30}"

log()  { echo "[multiuser] $*"; }
warn() { echo "[multiuser] WARNING: $*" >&2; }
err()  { echo "[multiuser] ERROR: $*" >&2; exit 1; }
hr()   { echo "--------------------------------------------------------------------"; }

FAILED_USERS=()

# 단일 사용자(접두사 없음) 모드를 나타내는 사용자 이름입니다.
# setup-security-track.sh 가 이 값을 넘겨 narupay / postgresql-spiffe 처럼
# 접두사 없는 네임스페이스를 만듭니다.
NONE_USER='__none__'

# 사용자 이름 → 네임스페이스 접두사 ("user1-" 또는 "")
ns_prefix() {
  [[ "$1" == "${NONE_USER}" ]] && { echo ""; return 0; }
  echo "$1-"
}

# 로그에 표시할 이름
display_user() {
  [[ "$1" == "${NONE_USER}" ]] && { echo "단일 사용자"; return 0; }
  echo "$1"
}

usage() {
  sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

require_oc() {
  command -v oc >/dev/null 2>&1 || err "oc 를 PATH 에서 찾을 수 없습니다"
  oc whoami >/dev/null 2>&1 || err "OpenShift 에 로그인되어 있지 않습니다 (oc login)"
}

# ─────────────────────────────────────────────────────────────────────
# 매니페스트 렌더링
#
# 네임스페이스만 사용자별로 바꾸고, 그 안의 리소스 이름(Service, Deployment,
# ServiceAccount, label)은 그대로 둡니다. 이름까지 바꾸면 가이드의 명령과
# 매니페스트가 어긋나기 때문입니다.
#
# 예외는 ClusterSPIFFEID 로, 클러스터 범위 리소스라 이름이 겹치면 안 됩니다.
# ─────────────────────────────────────────────────────────────────────

# narupay 매니페스트: Namespace 이름과 namespace 필드만 치환
render_narupay() {
  local file="$1" ns="$2"
  awk -v ns="${ns}" '
    /^kind:/ { kind = $2 }
    kind == "Namespace" && /^  name: narupay$/ { print "  name: " ns; next }
    /^  namespace: narupay$/                   { print "  namespace: " ns; next }
    { print }
  ' "${file}"
}

# ZTWIM 매니페스트: Namespace 이름, namespace 필드, namespaceSelector,
# ClusterSPIFFEID 이름, 서비스 FQDN 을 치환
# pfx 가 빈 문자열이면 모든 치환이 원본과 같아져 매니페스트가 그대로 적용됩니다.
render_ztwim() {
  local file="$1" pfx="$2" base="$3"    # base: postgresql-spiffe | postgresql-spiffe-client
  local ns="${pfx}${base}"
  awk -v ns="${ns}" -v base="${base}" -v pfx="${pfx}" '
    /^kind:/ { kind = $2 }
    # Namespace 오브젝트의 이름
    kind == "Namespace" && $0 == "  name: " base { print "  name: " ns; next }
    # ClusterSPIFFEID 는 클러스터 범위라 사용자별로 고유해야 함
    kind == "ClusterSPIFFEID" && $0 ~ /^  name: / { print "  name: " ns; next }
    {
      gsub("^  namespace: " base "$", "  namespace: " ns)
      gsub("kubernetes.io/metadata.name: " base "$", "kubernetes.io/metadata.name: " ns)
      gsub("postgresql-spiffe\\.postgresql-spiffe\\.svc", "postgresql-spiffe." pfx "postgresql-spiffe.svc")
      print
    }
  ' "${file}"
}

# ─────────────────────────────────────────────────────────────────────
# 클러스터 공통 준비 (사용자 수와 무관하게 한 번)
# ─────────────────────────────────────────────────────────────────────

prepare_cluster() {
  hr
  log "클러스터 공통 준비..."

  # RHACS admission controller — 모듈 1 의 차단 시연에 필요
  local sc
  sc="$(oc get securedcluster -n "${STACKROX_NS}" -o name 2>/dev/null | head -1 || true)"
  if [[ -n "${sc}" ]]; then
    oc patch "${sc}" -n "${STACKROX_NS}" --type=merge -p \
      '{"spec":{"admissionControl":{"listenOnCreates":true,"listenOnUpdates":true}}}' >/dev/null
    log "RHACS admission controller 활성화됨"
  else
    warn "SecuredCluster 를 찾을 수 없습니다. 모듈 1 의 차단 시연이 동작하지 않습니다."
  fi

  # SPIRE 플랫폼 — 사용자별이 아니라 클러스터에 하나
  if oc get spireserver -A >/dev/null 2>&1 && \
     [[ -n "$(oc get spireserver -A -o name 2>/dev/null)" ]]; then
    log "SPIRE 플랫폼 이미 구성됨"
  elif [[ -x "${ZTWIM_SCRIPTS}/configure-ztwim-lab.sh" ]]; then
    log "SPIRE 플랫폼 구성 중 (수 분 소요)..."
    "${ZTWIM_SCRIPTS}/configure-ztwim-lab.sh" || warn "SPIRE 플랫폼 구성 실패"
  else
    warn "configure-ztwim-lab.sh 를 찾을 수 없습니다. 모듈 2 가 동작하지 않습니다."
  fi

  # Vault — 인스턴스는 하나, 경로만 사용자별로 나눔
  if oc get pod -n "${VAULT_NS}" -l app.kubernetes.io/name=vault,component=server \
       -o name >/dev/null 2>&1 && [[ -n "$(vault_pod)" ]]; then
    log "Vault 이미 설치됨"
  elif [[ -x "${VAULT_SCRIPTS}/install-vault.sh" ]]; then
    log "Vault 설치 중 (수 분 소요)..."
    "${VAULT_SCRIPTS}/install-vault.sh" || warn "Vault 설치 실패"
    # pod 가 Ready 되기 전에 secret 을 쓰면 실패합니다.
    wait_for_vault_ready || warn "Vault pod 가 Ready 되지 않았습니다"
    [[ -x "${VAULT_SCRIPTS}/configure-vault-lab.sh" ]] && \
      "${VAULT_SCRIPTS}/configure-vault-lab.sh" || true
  else
    warn "install-vault.sh 를 찾을 수 없습니다. 모듈 3 의 Vault 실습이 동작하지 않습니다."
  fi

  grant_shared_read
}

# 참가자는 자기 네임스페이스 세 개만 admin 권한을 갖습니다. 그런데 가이드에는
# 공유 자원을 조회하는 명령이 세 개 있습니다:
#
#   oc get route central -n stackrox            (모듈 1 — RHACS 콘솔 주소)
#   oc get securedcluster -n stackrox           (모듈 1 — admission controller 확인)
#   oc get route vault -n vault                 (모듈 3 — Vault UI 주소)
#
# 이 세 개만 읽을 수 있는 최소 권한을 부여합니다.
# system:authenticated 그룹에 묶어, 사용자 수와 무관하게 한 번만 만들면 됩니다.
grant_shared_read() {
  if oc get ns "${VAULT_NS}" >/dev/null 2>&1; then
    oc apply -f - >/dev/null <<EOF || warn "vault 읽기 권한 부여 실패"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: narupay-lab-reader
  namespace: ${VAULT_NS}
rules:
  - apiGroups: ["route.openshift.io"]
    resources: ["routes"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: narupay-lab-reader
  namespace: ${VAULT_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: narupay-lab-reader
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:authenticated
EOF
    log "vault 네임스페이스 route 읽기 권한 부여됨"
  fi

  if oc get ns "${STACKROX_NS}" >/dev/null 2>&1; then
    oc apply -f - >/dev/null <<EOF || warn "stackrox 읽기 권한 부여 실패"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: narupay-lab-reader
  namespace: ${STACKROX_NS}
rules:
  - apiGroups: ["route.openshift.io"]
    resources: ["routes"]
    verbs: ["get", "list"]
  - apiGroups: ["platform.stackrox.io"]
    resources: ["securedclusters"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: narupay-lab-reader
  namespace: ${STACKROX_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: narupay-lab-reader
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:authenticated
EOF
    log "stackrox 네임스페이스 route/securedcluster 읽기 권한 부여됨"
  fi
}

vault_pod() {
  oc get pod -n "${VAULT_NS}" -l app.kubernetes.io/name=vault,component=server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# Helm 설치 직후에는 pod 가 아직 Ready 가 아니므로, secret 을 쓰기 전에 기다립니다.
wait_for_vault_ready() {
  local tries="${VAULT_READY_TRIES:-60}" i pod ready
  log "Vault pod 기동 대기 중 (최대 $((tries * 5))초)..."
  for ((i = 0; i < tries; i++)); do
    pod="$(vault_pod)"
    if [[ -n "${pod}" ]]; then
      ready="$(oc get pod -n "${VAULT_NS}" "${pod}" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
      [[ "${ready}" == "true" ]] && { log "Vault pod Ready (${pod})"; return 0; }
    fi
    sleep 5
  done
  return 1
}

seed_vault_for_user() {
  local u="$1" pod pfx
  pfx="$(ns_prefix "${u}")"
  pod="$(vault_pod)"
  [[ -n "${pod}" ]] || return 1
  oc exec -n "${VAULT_NS}" "${pod}" -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
    vault kv put "secret/${pfx}narupay/payment-db" \
      username=narupay_app password='NaruPay2024!@#' >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────
# 사용자별 배포
# ─────────────────────────────────────────────────────────────────────

deploy_user() {
  local u="$1" pfx
  pfx="$(ns_prefix "${u}")"
  local ns_pay="${pfx}narupay"
  local ns_srv="${pfx}postgresql-spiffe"
  local ns_cli="${pfx}postgresql-spiffe-client"

  log "[$(display_user "${u}")] 배포 중..."

  # 모듈 1 / 3 — 나루페이 워크로드
  # 매니페스트에 Namespace 가 함께 들어 있지만, 뒤따르는 리소스가
  # "namespace not found" 로 실패하지 않도록 먼저 만들어 둡니다.
  oc create namespace "${ns_pay}" >/dev/null 2>&1 || true
  local m
  for m in payment-api-vulnerable payment-api-secure legacy-secret-app narupay-vault-app; do
    if ! render_narupay "${MANIFEST_DIR}/${m}.yaml" "${ns_pay}" | oc apply -f - >/dev/null; then
      warn "[$(display_user "${u}")] ${m} 배포 실패"
    fi
  done

  # 모듈 1 의 차단 시연에서 참가자가 다시 apply 할 매니페스트.
  # 사용자마다 터미널이 다르므로 파일 대신 ConfigMap 으로 제공합니다.
  oc create configmap narupay-lab-manifests -n "${ns_pay}" \
    --from-file=payment-api-vulnerable.yaml=<(render_narupay "${MANIFEST_DIR}/payment-api-vulnerable.yaml" "${ns_pay}") \
    --from-file=payment-api-secure.yaml=<(render_narupay "${MANIFEST_DIR}/payment-api-secure.yaml" "${ns_pay}") \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

  # 모듈 2 — ZTWIM 실습 워크로드
  #
  # 접두사가 없는 단일 환경에서는 원래 스크립트를 그대로 씁니다.
  # 그쪽에 네임스페이스 생성 후 대기와 검증 로직이 들어 있어 더 안전합니다.
  if [[ -z "${pfx}" ]]; then
    if [[ -x "${ZTWIM_SCRIPTS}/configure-ztwim-postgresql-lab.sh" ]]; then
      log "[$(display_user "${u}")] ZTWIM 실습 워크로드 배포..."
      "${ZTWIM_SCRIPTS}/configure-ztwim-postgresql-lab.sh" deploy || \
        warn "[$(display_user "${u}")] ZTWIM 워크로드 배포 실패"
    else
      warn "configure-ztwim-postgresql-lab.sh 를 찾을 수 없습니다"
    fi
  elif [[ -f "${ZTWIM_SCRIPTS}/demo-postgresql-spiffe.yaml" ]]; then
    # 사용자별 접두사가 붙는 경우에는 매니페스트를 렌더링해 적용합니다.
    # 네임스페이스가 같은 스트림에서 만들어지므로, 먼저 만들고 잠깐 기다린 뒤
    # 나머지를 적용해야 "namespace not found" 를 피할 수 있습니다.
    local base
    for base in postgresql-spiffe postgresql-spiffe-client; do
      oc create namespace "${pfx}${base}" >/dev/null 2>&1 || true
    done
    for base in postgresql-spiffe postgresql-spiffe-client; do
      local src="${ZTWIM_SCRIPTS}/demo-${base}.yaml"
      [[ -f "${src}" ]] || continue
      if ! render_ztwim "${src}" "${pfx}" "${base}" | oc apply -f - >/dev/null; then
        warn "[${u}] ${pfx}${base} 워크로드 배포 실패"
      fi
    done
  fi

  # 권한 — 계정은 환경이 이미 만들어 두었다고 가정하고 RoleBinding 만 부여.
  # 단일 사용자 모드에서는 이미 cluster-admin 이므로 건너뜁니다.
  if [[ "${u}" != "${NONE_USER}" ]]; then
    local ns
    for ns in "${ns_pay}" "${ns_srv}" "${ns_cli}"; do
      oc get ns "${ns}" >/dev/null 2>&1 || continue
      oc adm policy add-role-to-user admin "${u}" -n "${ns}" >/dev/null 2>&1 || \
        warn "[${u}] ${ns} RoleBinding 실패"
    done
  fi

  # 모듈 3 — Vault 경로 시드
  seed_vault_for_user "${u}" || warn "[${u}] Vault 시드 실패"
}

# ─────────────────────────────────────────────────────────────────────
# 액션
# ─────────────────────────────────────────────────────────────────────

# 번호 사용자 + EXTRA_USERS 를 한 줄씩 출력합니다.
all_users() {
  local i u
  for ((i = USER_START; i < USER_START + COUNT; i++)); do
    echo "${USER_PREFIX}${i}"
  done
  for u in ${EXTRA_USERS}; do
    [[ -n "${u}" ]] && echo "${u}"
  done
}

# 프로세스 치환을 써서 루프가 서브셸에서 돌지 않게 합니다
# (FAILED_USERS 누적이 유지되어야 합니다).
each_user() {
  local u
  while read -r u; do
    [[ -n "${u}" ]] || continue
    "$@" "${u}"
  done < <(all_users)
}

describe_target() {
  local desc=""
  if [[ "${COUNT}" -gt 0 ]]; then
    desc="${USER_PREFIX}${USER_START} ~ ${USER_PREFIX}$((USER_START + COUNT - 1)) (${COUNT}명)"
  fi
  if [[ -n "${EXTRA_USERS// /}" ]]; then
    [[ -n "${desc}" ]] && desc="${desc} + "
    desc="${desc}추가 계정: ${EXTRA_USERS}"
  fi
  echo "${desc}"
}

deploy_one() {
  local u="$1"
  if ! deploy_user "${u}"; then
    FAILED_USERS+=("${u}")
    warn "[${u}] 배포 실패"
  fi
}

# 모든 대상이 Ready 될 때까지 기다립니다. 출력은 마지막에 한 번만 보여 줍니다.
wait_all_ready() {
  local tries="${READY_TRIES:-36}" i
  log "워크로드가 Ready 될 때까지 대기 중 (최대 $((tries * 10))초)..."
  for ((i = 0; i < tries; i++)); do
    FAILED_USERS=()
    each_user check_user >/dev/null 2>&1
    [[ ${#FAILED_USERS[@]} -eq 0 ]] && return 0
    sleep 10
  done
  return 1
}

do_deploy() {
  hr
  log "환경 생성 — $(describe_target)"
  prepare_cluster

  hr
  each_user deploy_one

  hr
  if [[ ${#FAILED_USERS[@]} -ne 0 ]]; then
    warn "배포 중 실패: ${FAILED_USERS[*]}"
  fi

  # 배포 요청만으로 끝내지 않고, 실제로 Ready 될 때까지 기다린 뒤 결과를 보여 줍니다.
  wait_all_ready
  hr
  log "최종 준비 상태"
  hr
  FAILED_USERS=()
  each_user check_user
  hr
  if [[ ${#FAILED_USERS[@]} -eq 0 ]]; then
    log "모듈 1/2/3 준비 완료. 워크샵을 진행할 수 있습니다."
    hr
    return 0
  fi
  warn "미완료: ${FAILED_USERS[*]}"
  warn "잠시 후 '$0 status ${COUNT}' 로 다시 확인하십시오."
  warn "Vault 관련 문제는 ./verify-vault.sh 로 상세 점검할 수 있습니다."
  hr
  return 1
}

check_user() {
  local u="$1" pfx
  pfx="$(ns_prefix "${u}")"
  local ns_pay="${pfx}narupay"
  local pay sec leg srv cli vault_ok mark

  pay="$(oc get deploy payment-api -n "${ns_pay}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  sec="$(oc get deploy payment-api-secure -n "${ns_pay}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  leg="$(oc get deploy legacy-secret-app -n "${ns_pay}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  srv="$(oc get deploy postgresql-spiffe -n "${pfx}postgresql-spiffe" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  cli="$(oc get deploy postgresql-spiffe-client -n "${pfx}postgresql-spiffe-client" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"

  if oc exec -n "${VAULT_NS}" "$(vault_pod)" -- env \
       VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
       vault kv get "secret/${pfx}narupay/payment-db" >/dev/null 2>&1; then
    vault_ok="✓"
  else
    vault_ok="✗"
  fi

  if [[ "${pay:-0}" -ge 1 && "${sec:-0}" -ge 1 && "${leg:-0}" -ge 1 && \
        "${srv:-0}" -ge 1 && "${cli:-0}" -ge 1 && "${vault_ok}" == "✓" ]]; then
    mark="✓"
  else
    mark="✗"
    FAILED_USERS+=("${u}")
  fi

  printf "  [%s] %-14s narupay(%s/%s/%s)  spiffe(%s/%s)  vault(%s)\n" \
    "${mark}" "$(display_user "${u}")" "${pay:-0}" "${sec:-0}" "${leg:-0}" "${srv:-0}" "${cli:-0}" "${vault_ok}"
}

do_status() {
  hr
  log "사용자별 준비 상태 — $(describe_target)"
  hr
  each_user check_user
  hr
  if [[ ${#FAILED_USERS[@]} -eq 0 ]]; then
    log "전원 준비 완료"
  else
    warn "미완료: ${FAILED_USERS[*]}"
    return 1
  fi
}

cleanup_user() {
  local u="$1" pfx
  pfx="$(ns_prefix "${u}")"
  log "[$(display_user "${u}")] 정리 중..."
  oc delete ns "${pfx}narupay" "${pfx}postgresql-spiffe" "${pfx}postgresql-spiffe-client" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  # ClusterSPIFFEID 는 클러스터 범위라 네임스페이스와 함께 지워지지 않습니다
  oc delete clusterspiffeid "${pfx}postgresql-spiffe" "${pfx}postgresql-spiffe-client" \
    --ignore-not-found >/dev/null 2>&1 || true
  local pod
  pod="$(vault_pod)"
  [[ -n "${pod}" ]] && oc exec -n "${VAULT_NS}" "${pod}" -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
    vault kv metadata delete "secret/${pfx}narupay/payment-db" >/dev/null 2>&1 || true
}

# SPIRE 플랫폼과 Vault 를 제거합니다. ZTWIM 오퍼레이터와 그 namespace 는 보존합니다 —
# 실습 환경이 사전 설치해 제공하는 요소라 우리가 지울 대상이 아닙니다.
#
# SPIRE datastore PVC 를 함께 지우는 이유: 등록 엔트리와 CA 가 sqlite 에 남아 있으면
# "새로 구성"해도 이전 상태가 그대로 살아납니다.
ztwim_namespace() {
  local ns cand
  ns="$(oc get spireserver --all-namespaces \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  if [[ -n "${ns}" ]]; then echo "${ns}"; return 0; fi
  for cand in openshift-zero-trust-workload-identity-manager \
              zero-trust-workload-identity-manager; do
    if oc get ns "${cand}" >/dev/null 2>&1; then echo "${cand}"; return 0; fi
  done
  echo "openshift-zero-trust-workload-identity-manager"
}

cleanup_platform() {
  local ns pvc
  ns="$(ztwim_namespace)"

  log "SPIRE 커스텀 리소스 제거 (namespace: ${ns})..."
  oc delete spireoidcdiscoveryprovider,spireserver,spireagent,spiffecsidriver,zerotrustworkloadidentitymanager \
    cluster -n "${ns}" --ignore-not-found --timeout=180s 2>/dev/null || true

  log "SPIRE 서버 datastore PVC 제거..."
  for pvc in $(oc get pvc -n "${ns}" -o name 2>/dev/null | grep -i spire || true); do
    oc delete "${pvc}" -n "${ns}" --ignore-not-found --timeout=120s 2>/dev/null || true
  done
  oc delete configmap spire-bundle -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true

  if [[ -x "${VAULT_SCRIPTS}/cleanup-vault-lab.sh" ]]; then
    log "Vault 제거..."
    "${VAULT_SCRIPTS}/cleanup-vault-lab.sh" || warn "Vault 제거 실패"
  fi

  log "ZTWIM 오퍼레이터와 namespace ${ns} 는 그대로 둡니다 (실습 환경 제공 요소)."
}

do_cleanup() {
  hr
  log "환경 정리 — $(describe_target)"
  hr
  each_user cleanup_user
  hr
  log "정리 요청 완료. 네임스페이스 삭제는 백그라운드로 진행됩니다."
  log "확인: oc get ns | grep -E '${USER_PREFIX}[0-9]+-'"
  hr
}

# 사용자 환경 + 공유 플랫폼(SPIRE, Vault)까지 전부 정리합니다.
# 클러스터를 처음부터 다시 구성할 때 씁니다.
do_cleanup_all() {
  hr
  log "전체 정리 — $(describe_target) + 공유 플랫폼"
  hr
  each_user cleanup_user
  cleanup_platform
  hr
  log "정리 완료. 이제 $0 deploy <인원수> 로 새로 구성할 수 있습니다."
  log "RHACS 정책의 Enforcement 설정은 콘솔에서 수동으로 되돌려야 합니다"
  log "  (Policy Management → Latest tag → Edit policy → Policy behavior → Actions → Enforcement → Inform)"
  hr
}

main() {
  [[ -n "${ACTION}" ]] || usage
  require_oc
  case "${ACTION}" in
    deploy)  do_deploy ;;
    status)  do_status ;;
    cleanup)     do_cleanup ;;
    cleanup-all) do_cleanup_all ;;
    -h|--help|help) usage ;;
    *) err "알 수 없는 액션: ${ACTION}" ;;
  esac
}

main "$@"
