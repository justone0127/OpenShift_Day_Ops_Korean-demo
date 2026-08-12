#!/usr/bin/env bash
#
# 나루페이 보안 트랙(모듈 15/16/17) 사전 배포 스크립트
#
# 워크샵 참가자가 가이드에서 YAML 을 복사·붙여넣기 하지 않아도 되도록,
# 실습 대상 워크로드를 미리 배포해 둡니다.
#
#   ./setup-security-track.sh all       # 15/16/17 전부 준비 (기본값)
#   ./setup-security-track.sh acs       # 15번 모듈만
#   ./setup-security-track.sh vault     # 16번 모듈만
#   ./setup-security-track.sh ztwim     # 17번 모듈만
#   ./setup-security-track.sh status    # 현재 준비 상태 점검
#   ./setup-security-track.sh cleanup   # 전부 정리
#
# 실행 위치: bastion (cluster-admin 으로 oc login 된 상태)
# 소요 시간: all 기준 약 8~12분 (대부분 Vault/ZTWIM 설치 대기)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
SETUP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VAULT_SCRIPTS="${SETUP_ROOT}/vault-config-scripts"
ZTWIM_SCRIPTS="${SETUP_ROOT}/ztwim-config-scripts"

# 참가자가 15번 모듈의 "차단 시연" 단계에서 다시 apply 할 매니페스트 사본 위치
LAB_DIR="${LAB_DIR:-${HOME}/narupay-lab}"

NARUPAY_NS="narupay"
STACKROX_NS="${STACKROX_NS:-stackrox}"

ACTION="${1:-all}"

log()  { echo "[security-track] $*"; }
warn() { echo "[security-track] WARNING: $*" >&2; }
err()  { echo "[security-track] ERROR: $*" >&2; exit 1; }
hr()   { echo "--------------------------------------------------------------------"; }

require_oc() {
  command -v oc >/dev/null 2>&1 || err "oc 를 PATH 에서 찾을 수 없습니다"
  oc whoami >/dev/null 2>&1 || err "OpenShift 에 로그인되어 있지 않습니다 (oc login)"
}

# ─────────────────────────────────────────────────────────────────────
# 모듈 15 — RHACS
# ─────────────────────────────────────────────────────────────────────

check_acs_installed() {
  if ! oc get ns "${STACKROX_NS}" >/dev/null 2>&1; then
    warn "namespace ${STACKROX_NS} 가 없습니다. RHACS 가 설치되지 않은 것으로 보입니다."
    warn "15번 모듈은 RHACS Central/SecuredCluster 가 사전 설치되어 있어야 합니다."
    return 1
  fi
  return 0
}

enable_admission_enforcement() {
  # 15번 모듈의 "차단 시연" 단계는 admission controller 가 생성 요청을
  # 가로채야 동작합니다. 기본값이 꺼져 있는 환경을 대비해 켜 둡니다.
  local sc
  sc="$(oc get securedcluster -n "${STACKROX_NS}" -o name 2>/dev/null | head -1 || true)"
  if [[ -z "${sc}" ]]; then
    warn "SecuredCluster 리소스를 찾을 수 없습니다. admission controller 설정을 건너뜁니다."
    return 0
  fi

  log "Admission controller 설정 중 (${sc})..."
  oc patch "${sc}" -n "${STACKROX_NS}" --type=merge -p \
    '{"spec":{"admissionControl":{"listenOnCreates":true,"listenOnUpdates":true}}}' >/dev/null
  log "listenOnCreates / listenOnUpdates = true"
}

setup_acs() {
  hr
  log "모듈 15 (RHACS) 준비 중..."
  check_acs_installed || true

  log "나루페이 결제 API 를 취약 버전 / 안전 버전으로 각각 배포합니다..."
  # 순서 중요: 차단 정책을 켜기 전에 취약 버전이 이미 떠 있어야
  # 참가자가 "이미 뚫려 있는 상태"를 관찰할 수 있습니다.
  oc apply -f "${MANIFEST_DIR}/payment-api-vulnerable.yaml"
  oc apply -f "${MANIFEST_DIR}/payment-api-secure.yaml"

  log "참가자용 매니페스트 사본을 ${LAB_DIR} 에 배치합니다..."
  mkdir -p "${LAB_DIR}"
  cp "${MANIFEST_DIR}/payment-api-vulnerable.yaml" "${LAB_DIR}/"
  cp "${MANIFEST_DIR}/payment-api-secure.yaml" "${LAB_DIR}/"

  enable_admission_enforcement

  log "pod 기동 대기 중..."
  oc rollout status deployment/payment-api -n "${NARUPAY_NS}" --timeout=180s || \
    warn "payment-api rollout 확인 실패 — oc get pods -n ${NARUPAY_NS} 로 확인하십시오"
  oc rollout status deployment/payment-api-secure -n "${NARUPAY_NS}" --timeout=180s || \
    warn "payment-api-secure rollout 확인 실패 — oc get pods -n ${NARUPAY_NS} 로 확인하십시오"

  log "모듈 15 준비 완료."
  log "RHACS 가 위반 사항을 집계하는 데 30초~1분 정도 걸립니다."
}

# ─────────────────────────────────────────────────────────────────────
# 모듈 16 — Secrets Management
# ─────────────────────────────────────────────────────────────────────

vault_pod() {
  oc get pod -n vault -l app.kubernetes.io/name=vault,component=server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

seed_vault_story_secret() {
  local pod
  pod="$(vault_pod)"
  [[ -n "${pod}" ]] || { warn "Vault pod 를 찾을 수 없어 시연용 secret 을 건너뜁니다"; return 0; }

  log "Vault 에 나루페이 시연용 secret 을 기록합니다..."
  oc exec -n vault "${pod}" -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
    vault kv put secret/narupay/payment-db \
      username=narupay_app \
      password='NaruPay2024!@#' >/dev/null
  log "Vault 경로: secret/narupay/payment-db"
}

setup_vault() {
  hr
  log "모듈 16 (Secrets Management) 준비 중..."

  log "Kubernetes Secret 을 사용하는 기존 방식 애플리케이션을 배포합니다..."
  oc apply -f "${MANIFEST_DIR}/legacy-secret-app.yaml"

  if [[ -x "${VAULT_SCRIPTS}/install-vault.sh" ]]; then
    log "HashiCorp Vault 설치 중 (dev mode, 수 분 소요)..."
    "${VAULT_SCRIPTS}/install-vault.sh"
  else
    warn "${VAULT_SCRIPTS}/install-vault.sh 를 찾을 수 없습니다. Vault 설치를 건너뜁니다."
    return 0
  fi

  if [[ -x "${VAULT_SCRIPTS}/configure-vault-lab.sh" ]]; then
    log "Vault policy / Kubernetes auth 구성 중..."
    "${VAULT_SCRIPTS}/configure-vault-lab.sh"
  fi

  seed_vault_story_secret

  oc rollout status deployment/legacy-secret-app -n "${NARUPAY_NS}" --timeout=120s || \
    warn "legacy-secret-app rollout 확인 실패"

  log "모듈 16 준비 완료."
}

# ─────────────────────────────────────────────────────────────────────
# 모듈 17 — ZTWIM
# ─────────────────────────────────────────────────────────────────────

setup_ztwim() {
  hr
  log "모듈 17 (ZTWIM) 준비 중..."

  [[ -x "${ZTWIM_SCRIPTS}/configure-ztwim-lab.sh" ]] || {
    warn "${ZTWIM_SCRIPTS}/configure-ztwim-lab.sh 를 찾을 수 없습니다. 건너뜁니다."
    return 0
  }

  log "SPIRE 플랫폼 구성 중 (수 분 소요)..."
  "${ZTWIM_SCRIPTS}/configure-ztwim-lab.sh"

  log "PostgreSQL mTLS 실습 워크로드 배포 중..."
  "${ZTWIM_SCRIPTS}/configure-ztwim-postgresql-lab.sh" deploy

  log "모듈 17 준비 완료."
}

# ─────────────────────────────────────────────────────────────────────
# 상태 점검 / 정리
# ─────────────────────────────────────────────────────────────────────

status() {
  hr
  log "보안 트랙 준비 상태"
  hr

  echo "▸ 모듈 15 — RHACS"
  oc get pods -n "${STACKROX_NS}" --no-headers 2>/dev/null \
    | awk '{print "    stackrox: "$1" "$3}' | head -5 || echo "    (RHACS 미설치)"
  oc get deployment -n "${NARUPAY_NS}" -l workshop=narupay-security-track \
    -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas --no-headers 2>/dev/null \
    | sed 's/^/    /' || echo "    (나루페이 워크로드 없음)"
  [[ -f "${LAB_DIR}/payment-api-vulnerable.yaml" ]] \
    && echo "    참가자용 매니페스트: ${LAB_DIR} ✓" \
    || echo "    참가자용 매니페스트: 없음 ✗"

  echo
  echo "▸ 모듈 16 — Secrets Management"
  oc get pods -n vault --no-headers 2>/dev/null | sed 's/^/    /' || echo "    (Vault 미설치)"
  oc get route vault -n vault -o jsonpath='    Vault UI: https://{.spec.host}/{"\n"}' 2>/dev/null || true

  echo
  echo "▸ 모듈 17 — ZTWIM"
  oc get pods -n postgresql-spiffe --no-headers 2>/dev/null | sed 's/^/    /' || echo "    (미배포)"
  oc get pods -n postgresql-spiffe-client --no-headers 2>/dev/null | sed 's/^/    /' || true
  hr
}

cleanup() {
  hr
  log "보안 트랙 정리 중..."

  log "나루페이 워크로드 제거..."
  oc delete namespace "${NARUPAY_NS}" --ignore-not-found --wait=false

  if [[ -x "${ZTWIM_SCRIPTS}/configure-ztwim-postgresql-lab.sh" ]]; then
    log "ZTWIM 실습 워크로드 제거..."
    "${ZTWIM_SCRIPTS}/configure-ztwim-postgresql-lab.sh" cleanup || true
  fi

  if [[ -x "${VAULT_SCRIPTS}/cleanup-vault-lab.sh" ]]; then
    log "Vault 실습 환경 제거..."
    "${VAULT_SCRIPTS}/cleanup-vault-lab.sh" || true
  fi

  rm -rf "${LAB_DIR}"

  log "정리 완료."
  log "RHACS 정책의 Enforcement 설정은 콘솔에서 수동으로 되돌려야 합니다"
  log "  (Policy Management → Latest tag → Response method → Inform only)"
}

print_summary() {
  hr
  log "보안 트랙 준비 완료"
  hr
  echo
  echo "  참가자에게 안내할 내용:"
  echo
  echo "  ▸ 모듈 15 (RHACS)"
  echo "      취약 버전:  deployment/payment-api        (namespace: ${NARUPAY_NS})"
  echo "      안전 버전:  deployment/payment-api-secure (namespace: ${NARUPAY_NS})"
  echo "      차단 시연용 매니페스트: ${LAB_DIR}/payment-api-vulnerable.yaml"
  oc get route central -n "${STACKROX_NS}" -o jsonpath='      RHACS 콘솔: https://{.spec.host}{"\n"}' 2>/dev/null || true
  echo
  echo "  ▸ 모듈 16 (Secrets Management)"
  echo "      기존 방식 앱: deployment/legacy-secret-app (namespace: ${NARUPAY_NS})"
  echo "      Secret:       payment-db-creds"
  oc get route vault -n vault -o jsonpath='      Vault UI: https://{.spec.host}/  (Token: root){"\n"}' 2>/dev/null || true
  echo
  echo "  ▸ 모듈 17 (ZTWIM)"
  echo "      서버: deployment/postgresql-spiffe        (namespace: postgresql-spiffe)"
  echo "      클라이언트: deployment/postgresql-spiffe-client (namespace: postgresql-spiffe-client)"
  echo
  hr
}

main() {
  require_oc
  case "${ACTION}" in
    acs)     setup_acs ;;
    vault)   setup_vault ;;
    ztwim)   setup_ztwim ;;
    all)     setup_acs; setup_vault; setup_ztwim; print_summary ;;
    status)  status ;;
    cleanup) cleanup ;;
    *)
      echo "사용법: $0 [all|acs|vault|ztwim|status|cleanup]" >&2
      exit 1
      ;;
  esac
}

main "$@"
