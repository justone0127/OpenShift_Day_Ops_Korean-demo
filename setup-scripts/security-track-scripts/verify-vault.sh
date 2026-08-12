#!/usr/bin/env bash
#
# 모듈 3 (Secrets Management) Vault 사전 구성 확인 스크립트
#
# 실습 환경에는 RHACS 와 ZTWIM 오퍼레이터가 사전 설치되어 있지만
# Vault 는 포함되어 있지 않습니다. setup-multiuser.sh deploy 가 설치하며,
# 이 스크립트로 모듈 3 진행에 필요한 것이 모두 준비됐는지 점검합니다.
#
#   ./verify-vault.sh          # 점검만
#   ./verify-vault.sh --fix    # 문제가 있으면 재구성 시도
#
# 종료 코드: 0 = 모두 정상, 1 = 하나 이상 실패
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_NS="${VAULT_NAMESPACE:-vault}"
NARUPAY_NS="${NARUPAY_NS:-narupay}"
SECRET_PATH="${VAULT_SECRET_PATH:-secret/narupay/payment-db}"
FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

PASS=0
FAIL=0

ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "         $*"; }
head_() { echo; echo "── $* ────────────────────────────────────────────"; }

vault_pod() {
  oc get pod -n "${VAULT_NS}" -l app.kubernetes.io/name=vault,component=server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

vault_exec() {
  local pod="$1"; shift
  oc exec -n "${VAULT_NS}" "${pod}" -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root "$@" 2>/dev/null
}

echo "======================================================================"
echo " 모듈 3 (Secrets Management) Vault 사전 구성 점검"
echo "======================================================================"

# ── 0. 클러스터 접속 ────────────────────────────────────────────────
head_ "0. 클러스터 접속"
if ! command -v oc >/dev/null 2>&1; then
  bad "oc 를 PATH 에서 찾을 수 없습니다"
  echo; echo "결과: 실패 ${FAIL} / 통과 ${PASS}"; exit 1
fi
if oc whoami >/dev/null 2>&1; then
  ok "oc 로그인됨 ($(oc whoami))"
else
  bad "OpenShift 에 로그인되어 있지 않습니다 (oc login 필요)"
  echo; echo "결과: 실패 ${FAIL} / 통과 ${PASS}"; exit 1
fi

# ── 1. Vault 네임스페이스와 pod ──────────────────────────────────────
head_ "1. Vault 설치 상태"
if oc get ns "${VAULT_NS}" >/dev/null 2>&1; then
  ok "namespace ${VAULT_NS} 존재"
else
  bad "namespace ${VAULT_NS} 가 없습니다 — Vault 가 설치되지 않았습니다"
  info "해결: ./setup-multiuser.sh deploy"
fi

POD="$(vault_pod)"
if [[ -n "${POD}" ]]; then
  PHASE="$(oc get pod -n "${VAULT_NS}" "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null)"
  READY="$(oc get pod -n "${VAULT_NS}" "${POD}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)"
  if [[ "${PHASE}" == "Running" && "${READY}" == "true" ]]; then
    ok "Vault pod Running/Ready (${POD})"
  else
    bad "Vault pod 상태 이상 (${POD}: phase=${PHASE} ready=${READY})"
  fi
else
  bad "Vault server pod 를 찾을 수 없습니다"
  info "해결: ./setup-multiuser.sh deploy"
fi

# ── 2. Route (참가자가 UI 로 접속) ───────────────────────────────────
head_ "2. Vault UI Route"
VAULT_HOST="$(oc get route vault -n "${VAULT_NS}" -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -n "${VAULT_HOST}" ]]; then
  ok "Route 존재: https://${VAULT_HOST}/"
  CODE="$(curl -s -k -o /dev/null -w '%{http_code}' --max-time 10 "https://${VAULT_HOST}/ui/" 2>/dev/null)"
  if [[ "${CODE}" =~ ^(200|307|308)$ ]]; then
    ok "UI 응답 확인 (HTTP ${CODE})"
  else
    bad "UI 에 접속되지 않습니다 (HTTP ${CODE:-무응답})"
    info "라우터 전파에 1~2분 걸릴 수 있습니다. 잠시 후 다시 실행해 보십시오."
  fi
else
  bad "route/vault 가 없습니다 — 참가자가 Vault UI 실습을 할 수 없습니다"
fi

# ── 3. Unseal 상태 (dev mode 는 자동) ────────────────────────────────
head_ "3. Vault 상태 (dev mode)"
if [[ -n "${POD}" ]]; then
  STATUS="$(vault_exec "${POD}" vault status -format=json)"
  if [[ -n "${STATUS}" ]]; then
    SEALED="$(echo "${STATUS}" | grep -o '"sealed"[[:space:]]*:[[:space:]]*[a-z]*' | grep -o '[a-z]*$')"
    if [[ "${SEALED}" == "false" ]]; then
      ok "Vault unsealed (dev mode)"
    else
      bad "Vault 가 sealed 상태입니다"
      info "dev mode 는 자동 unseal 됩니다. pod 를 재시작해 보십시오."
    fi
  else
    bad "vault status 조회 실패"
  fi
fi

# ── 4. 실습용 secret 시드 ────────────────────────────────────────────
head_ "4. 실습용 secret (${SECRET_PATH})"
if [[ -n "${POD}" ]]; then
  KV="$(vault_exec "${POD}" vault kv get -format=json "${SECRET_PATH}")"
  if [[ -n "${KV}" ]] && echo "${KV}" | grep -q '"password"'; then
    ok "${SECRET_PATH} 에 username/password 존재"
  else
    bad "${SECRET_PATH} 를 읽을 수 없습니다"
    info "Vault 는 dev mode 라 pod 재시작 시 데이터가 사라집니다."
    if [[ "${FIX}" -eq 1 ]]; then
      info "--fix: secret 을 다시 기록합니다..."
      if vault_exec "${POD}" vault kv put "${SECRET_PATH}" \
           username=narupay_app password='NaruPay2024!@#' >/dev/null; then
        ok "재시드 완료"
      else
        bad "재시드 실패"
      fi
    else
      info "해결: ./verify-vault.sh --fix  또는  ./setup-multiuser.sh deploy"
    fi
  fi
fi

# ── 5. Kubernetes auth (개념 설명 시 참조) ──────────────────────────
head_ "5. Kubernetes auth 구성"
if [[ -n "${POD}" ]]; then
  if vault_exec "${POD}" vault auth list -format=json | grep -q 'kubernetes/'; then
    ok "kubernetes auth method 활성화됨"
  else
    bad "kubernetes auth method 가 없습니다"
    info "모듈 3 은 개념 설명 중심이라 진행은 가능하지만, 구성 설명 시 화면이 비어 있습니다."
    info "해결: ${SCRIPT_DIR}/../vault-config-scripts/configure-vault-lab.sh"
  fi
fi

# ── 6. 비교 대상 애플리케이션 ────────────────────────────────────────
head_ "6. legacy-secret-app (Secret 주입 방식 비교 대상)"
if oc get deployment legacy-secret-app -n "${NARUPAY_NS}" >/dev/null 2>&1; then
  AVAIL="$(oc get deployment legacy-secret-app -n "${NARUPAY_NS}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  if [[ "${AVAIL:-0}" -ge 1 ]]; then
    ok "legacy-secret-app 실행 중 (${NARUPAY_NS})"
  else
    bad "legacy-secret-app 이 준비되지 않았습니다 (available=${AVAIL:-0})"
  fi
else
  bad "deployment/legacy-secret-app 이 없습니다 (${NARUPAY_NS})"
  info "해결: ./setup-multiuser.sh deploy"
fi

if oc get secret payment-db-creds -n "${NARUPAY_NS}" >/dev/null 2>&1; then
  ok "secret/payment-db-creds 존재 (첫 번째 실습에서 사용)"
else
  bad "secret/payment-db-creds 가 없습니다"
fi

# ── 결과 ─────────────────────────────────────────────────────────────
echo
echo "======================================================================"
if [[ "${FAIL}" -eq 0 ]]; then
  echo " 결과: 모두 통과 (${PASS}건). 모듈 3 진행 준비 완료."
  [[ -n "${VAULT_HOST}" ]] && echo " Vault UI: https://${VAULT_HOST}/  (Token 방식, 토큰: root)"
  echo "======================================================================"
  exit 0
else
  echo " 결과: ${FAIL}건 실패 / ${PASS}건 통과"
  echo " 위의 [FAIL] 항목과 해결 안내를 확인하십시오."
  echo "======================================================================"
  exit 1
fi
