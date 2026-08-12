#!/usr/bin/env bash
#
# 나루페이 보안 트랙 — 다중 사용자 배포 스크립트
#
# 참가자마다 계정(user1, user2, ...)이 하나씩 주어지는 환경을 위해,
# 사용자별로 격리된 실습 네임스페이스와 워크로드를 생성합니다.
#
#   ./setup-multiuser.sh deploy 30    # user1~user30 + admin 환경 생성
#   ./setup-multiuser.sh status 30    # 준비 상태 점검
#   ./setup-multiuser.sh cleanup 30   # 전부 정리
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
render_ztwim() {
  local file="$1" prefix="$2" base="$3"    # base: postgresql-spiffe | postgresql-spiffe-client
  local ns="${prefix}-${base}"
  awk -v ns="${ns}" -v base="${base}" -v prefix="${prefix}" '
    /^kind:/ { kind = $2 }
    # Namespace 오브젝트의 이름
    kind == "Namespace" && $0 == "  name: " base { print "  name: " ns; next }
    # ClusterSPIFFEID 는 클러스터 범위라 사용자별로 고유해야 함
    kind == "ClusterSPIFFEID" && $0 ~ /^  name: / { print "  name: " prefix "-" base; next }
    {
      # namespace 필드
      gsub("^  namespace: " base "$", "  namespace: " ns)
      # namespaceSelector 의 metadata.name 라벨
      gsub("kubernetes.io/metadata.name: " base "$", "kubernetes.io/metadata.name: " ns)
      # 서비스 FQDN (postgresql-spiffe.postgresql-spiffe.svc)
      gsub("postgresql-spiffe\\.postgresql-spiffe\\.svc", "postgresql-spiffe." prefix "-postgresql-spiffe.svc")
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

seed_vault_for_user() {
  local u="$1" pod
  pod="$(vault_pod)"
  [[ -n "${pod}" ]] || return 1
  oc exec -n "${VAULT_NS}" "${pod}" -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
    vault kv put "secret/${u}-narupay/payment-db" \
      username=narupay_app password='NaruPay2024!@#' >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────
# 사용자별 배포
# ─────────────────────────────────────────────────────────────────────

deploy_user() {
  local u="$1"
  local ns_pay="${u}-narupay"
  local ns_srv="${u}-postgresql-spiffe"
  local ns_cli="${u}-postgresql-spiffe-client"

  log "[${u}] 배포 중..."

  # 모듈 1 / 3 — 나루페이 워크로드
  render_narupay "${MANIFEST_DIR}/payment-api-vulnerable.yaml" "${ns_pay}" | oc apply -f - >/dev/null
  render_narupay "${MANIFEST_DIR}/payment-api-secure.yaml"     "${ns_pay}" | oc apply -f - >/dev/null
  render_narupay "${MANIFEST_DIR}/legacy-secret-app.yaml"      "${ns_pay}" | oc apply -f - >/dev/null

  # 모듈 1 의 차단 시연에서 참가자가 다시 apply 할 매니페스트.
  # 사용자마다 터미널이 다르므로 파일 대신 ConfigMap 으로 제공합니다.
  oc create configmap narupay-lab-manifests -n "${ns_pay}" \
    --from-file=payment-api-vulnerable.yaml=<(render_narupay "${MANIFEST_DIR}/payment-api-vulnerable.yaml" "${ns_pay}") \
    --from-file=payment-api-secure.yaml=<(render_narupay "${MANIFEST_DIR}/payment-api-secure.yaml" "${ns_pay}") \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

  # 모듈 2 — ZTWIM 실습 워크로드
  if [[ -f "${ZTWIM_SCRIPTS}/demo-postgresql-spiffe.yaml" ]]; then
    render_ztwim "${ZTWIM_SCRIPTS}/demo-postgresql-spiffe.yaml" "${u}" postgresql-spiffe \
      | oc apply -f - >/dev/null
    render_ztwim "${ZTWIM_SCRIPTS}/demo-postgresql-spiffe-client.yaml" "${u}" postgresql-spiffe-client \
      | oc apply -f - >/dev/null
  fi

  # 권한 — 계정은 환경이 이미 만들어 두었다고 가정하고 RoleBinding 만 부여
  local ns
  for ns in "${ns_pay}" "${ns_srv}" "${ns_cli}"; do
    oc get ns "${ns}" >/dev/null 2>&1 || continue
    oc adm policy add-role-to-user admin "${u}" -n "${ns}" >/dev/null 2>&1 || \
      warn "[${u}] ${ns} RoleBinding 실패"
  done

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

do_deploy() {
  hr
  log "환경 생성 — $(describe_target)"
  prepare_cluster

  hr
  each_user deploy_one

  hr
  if [[ ${#FAILED_USERS[@]} -eq 0 ]]; then
    log "완료 — $(describe_target) 전원 배포됨"
  else
    warn "실패한 사용자: ${FAILED_USERS[*]}"
  fi
  log "상태 점검: $0 status ${COUNT}"
  hr
  [[ ${#FAILED_USERS[@]} -eq 0 ]]
}

check_user() {
  local u="$1"
  local ns_pay="${u}-narupay"
  local pay sec leg srv cli vault_ok mark

  pay="$(oc get deploy payment-api -n "${ns_pay}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  sec="$(oc get deploy payment-api-secure -n "${ns_pay}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  leg="$(oc get deploy legacy-secret-app -n "${ns_pay}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  srv="$(oc get deploy postgresql-spiffe -n "${u}-postgresql-spiffe" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  cli="$(oc get deploy postgresql-spiffe-client -n "${u}-postgresql-spiffe-client" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"

  if oc exec -n "${VAULT_NS}" "$(vault_pod)" -- env \
       VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
       vault kv get "secret/${u}-narupay/payment-db" >/dev/null 2>&1; then
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

  printf "  [%s] %-10s narupay(%s/%s/%s)  spiffe(%s/%s)  vault(%s)\n" \
    "${mark}" "${u}" "${pay:-0}" "${sec:-0}" "${leg:-0}" "${srv:-0}" "${cli:-0}" "${vault_ok}"
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
  local u="$1"
  log "[${u}] 정리 중..."
  oc delete ns "${u}-narupay" "${u}-postgresql-spiffe" "${u}-postgresql-spiffe-client" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  # ClusterSPIFFEID 는 클러스터 범위라 네임스페이스와 함께 지워지지 않습니다
  oc delete clusterspiffeid "${u}-postgresql-spiffe" "${u}-postgresql-spiffe-client" \
    --ignore-not-found >/dev/null 2>&1 || true
  local pod
  pod="$(vault_pod)"
  [[ -n "${pod}" ]] && oc exec -n "${VAULT_NS}" "${pod}" -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
    vault kv metadata delete "secret/${u}-narupay/payment-db" >/dev/null 2>&1 || true
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

main() {
  [[ -n "${ACTION}" ]] || usage
  require_oc
  case "${ACTION}" in
    deploy)  do_deploy ;;
    status)  do_status ;;
    cleanup) do_cleanup ;;
    -h|--help|help) usage ;;
    *) err "알 수 없는 액션: ${ACTION}" ;;
  esac
}

main "$@"
