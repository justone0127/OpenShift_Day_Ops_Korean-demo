#!/usr/bin/env bash
#
# 나루페이 보안 트랙(모듈 1/2/3) 사전 배포 스크립트
#
# 워크샵 참가자가 가이드에서 YAML 을 복사·붙여넣기 하지 않아도 되도록,
# 실습 대상 워크로드를 미리 배포해 둡니다.
#
#   ./setup-security-track.sh all       # 모듈 1/2/3 전부 준비 (기본값)
#   ./setup-security-track.sh acs       # 모듈 1 (RHACS) 만
#   ./setup-security-track.sh ztwim     # 모듈 2 (ZTWIM) 만
#   ./setup-security-track.sh vault     # 모듈 3 (Secrets Management) 만
#   ./setup-security-track.sh status      # 현재 준비 상태 점검
#   ./setup-security-track.sh cleanup     # 전부 정리 (SPIRE 플랫폼 포함, 재구성용)
#   ./setup-security-track.sh cleanup-lab # 실습 워크로드만 정리 (SPIRE 플랫폼 유지)
#
# all 은 Vault 설치·구성·시드까지 포함합니다. 실습 환경에 RHACS 와 ZTWIM 오퍼레이터는
# 사전 설치되어 있지만 Vault 는 없으므로, 이 스크립트가 Helm 으로 직접 설치합니다.
#
# 하나라도 실패하면 마지막 요약에 ✗ 로 표시되고 종료 코드 1 을 반환합니다.
#
# 실행 위치: bastion (cluster-admin 으로 oc login 된 상태)
# 소요 시간: all 기준 약 8~12분 (대부분 Vault/ZTWIM 설치 대기)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
SETUP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VAULT_SCRIPTS="${SETUP_ROOT}/vault-config-scripts"
ZTWIM_SCRIPTS="${SETUP_ROOT}/ztwim-config-scripts"

# 참가자가 모듈 1 의 "차단 시연" 단계에서 다시 apply 할 매니페스트 사본 위치
LAB_DIR="${LAB_DIR:-${HOME}/narupay-lab}"

NARUPAY_NS="narupay"
STACKROX_NS="${STACKROX_NS:-stackrox}"

ACTION="${1:-all}"

log()  { echo "[security-track] $*"; }
warn() { echo "[security-track] WARNING: $*" >&2; }
err()  { echo "[security-track] ERROR: $*" >&2; exit 1; }
hr()   { echo "--------------------------------------------------------------------"; }

# 모듈별 준비 결과. 하나라도 실패하면 요약에 ✗ 로 표시하고 종료 코드 1 을 반환합니다.
# (실패를 조용히 넘기면 워크샵 당일 해당 모듈에서 그대로 막히기 때문입니다.)
RESULTS=()
STEP_FAILED=0
mark_ok()   { RESULTS+=("OK|$1|$2"); }
mark_fail() { RESULTS+=("FAIL|$1|$2"); STEP_FAILED=1; }

require_oc() {
  command -v oc >/dev/null 2>&1 || err "oc 를 PATH 에서 찾을 수 없습니다"
  oc whoami >/dev/null 2>&1 || err "OpenShift 에 로그인되어 있지 않습니다 (oc login)"
}

# ─────────────────────────────────────────────────────────────────────
# 모듈 1 — RHACS
# ─────────────────────────────────────────────────────────────────────

check_acs_installed() {
  if ! oc get ns "${STACKROX_NS}" >/dev/null 2>&1; then
    warn "namespace ${STACKROX_NS} 가 없습니다. RHACS 가 설치되지 않은 것으로 보입니다."
    warn "모듈 1 은 RHACS Central/SecuredCluster 가 사전 설치되어 있어야 합니다."
    return 1
  fi
  return 0
}

enable_admission_enforcement() {
  # 모듈 1 의 "차단 시연" 단계는 admission controller 가 생성 요청을
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
  log "모듈 1 (RHACS) 준비 중..."
  if ! check_acs_installed; then
    mark_fail "모듈 1 — RHACS" "RHACS(stackrox)가 설치되어 있지 않습니다"
    return 1
  fi

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

  mark_ok "모듈 1 — RHACS" "payment-api / payment-api-secure 배포 완료"
  log "모듈 1 준비 완료."
  log "RHACS 가 위반 사항을 집계하는 데 30초~1분 정도 걸립니다."
}

# ─────────────────────────────────────────────────────────────────────
# 모듈 3 — Secrets Management (Vault)
#
# 실습 환경에 Vault 는 포함되어 있지 않으므로 이 단계가 실제로 설치까지 합니다.
# 설치 형상과 트러블슈팅은 FACILITATOR-VAULT-SETUP.adoc 를 참고하십시오.
# ─────────────────────────────────────────────────────────────────────

vault_pod() {
  oc get pod -n vault -l app.kubernetes.io/name=vault,component=server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

vault_exec() {
  local pod="$1"; shift
  oc exec -n vault "${pod}" -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root "$@"
}

# Helm 설치 직후에는 pod 가 아직 Ready 가 아니므로, secret 을 쓰기 전에 기다립니다.
wait_for_vault_ready() {
  local tries="${VAULT_READY_TRIES:-60}" i pod ready
  log "Vault pod 기동 대기 중 (최대 $((tries * 5))초)..."
  for ((i = 0; i < tries; i++)); do
    pod="$(vault_pod)"
    if [[ -n "${pod}" ]]; then
      ready="$(oc get pod -n vault "${pod}" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
      if [[ "${ready}" == "true" ]]; then
        log "Vault pod Ready (${pod})"
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

# 시드가 실제로 읽히는지까지 확인합니다. dev mode 라 pod 가 재기동되면 사라지기 때문에
# "기록했다"가 아니라 "읽힌다"를 기준으로 성공을 판정합니다.
verify_vault_secret() {
  local pod
  pod="$(vault_pod)"
  [[ -n "${pod}" ]] || return 1
  vault_exec "${pod}" vault kv get -format=json secret/narupay/payment-db 2>/dev/null \
    | grep -q '"password"'
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
  log "모듈 3 (Secrets Management) 준비 중..."

  log "Kubernetes Secret 을 사용하는 기존 방식 애플리케이션을 배포합니다..."
  oc apply -f "${MANIFEST_DIR}/legacy-secret-app.yaml"
  oc rollout status deployment/legacy-secret-app -n "${NARUPAY_NS}" --timeout=120s || \
    warn "legacy-secret-app rollout 확인 실패"

  if [[ ! -x "${VAULT_SCRIPTS}/install-vault.sh" ]]; then
    mark_fail "모듈 3 — Secrets Management" \
      "install-vault.sh 를 찾을 수 없습니다 (${VAULT_SCRIPTS})"
    return 1
  fi

  log "HashiCorp Vault 설치 중 (dev mode, 수 분 소요)..."
  if ! "${VAULT_SCRIPTS}/install-vault.sh"; then
    mark_fail "모듈 3 — Secrets Management" \
      "Vault 설치 실패 — FACILITATOR-VAULT-SETUP.adoc 트러블슈팅 참고"
    return 1
  fi

  if ! wait_for_vault_ready; then
    mark_fail "모듈 3 — Secrets Management" \
      "Vault pod 가 Ready 되지 않았습니다 (oc get pods -n vault)"
    return 1
  fi

  if [[ -x "${VAULT_SCRIPTS}/configure-vault-lab.sh" ]]; then
    log "Vault policy / Kubernetes auth 구성 중..."
    "${VAULT_SCRIPTS}/configure-vault-lab.sh" || \
      warn "Vault 구성 일부 실패 — 개념 설명 진행에는 지장이 없습니다"
  fi

  seed_vault_story_secret

  if ! verify_vault_secret; then
    mark_fail "모듈 3 — Secrets Management" \
      "secret/narupay/payment-db 를 읽을 수 없습니다 (./verify-vault.sh --fix)"
    return 1
  fi
  log "secret/narupay/payment-db 읽기 확인 완료"

  mark_ok "모듈 3 — Secrets Management" "Vault + legacy-secret-app 준비 완료"
  log "모듈 3 준비 완료."
}

# ─────────────────────────────────────────────────────────────────────
# 모듈 2 — ZTWIM
# ─────────────────────────────────────────────────────────────────────

setup_ztwim() {
  hr
  log "모듈 2 (ZTWIM) 준비 중..."

  if [[ ! -x "${ZTWIM_SCRIPTS}/configure-ztwim-lab.sh" ]]; then
    mark_fail "모듈 2 — ZTWIM" \
      "configure-ztwim-lab.sh 를 찾을 수 없습니다 (${ZTWIM_SCRIPTS})"
    return 1
  fi

  log "SPIRE 플랫폼 구성 중 (수 분 소요)..."
  if ! "${ZTWIM_SCRIPTS}/configure-ztwim-lab.sh"; then
    mark_fail "모듈 2 — ZTWIM" "SPIRE 플랫폼 구성 실패"
    return 1
  fi

  log "PostgreSQL mTLS 실습 워크로드 배포 중..."
  if ! "${ZTWIM_SCRIPTS}/configure-ztwim-postgresql-lab.sh" deploy; then
    mark_fail "모듈 2 — ZTWIM" "PostgreSQL mTLS 워크로드 배포 실패"
    return 1
  fi

  mark_ok "모듈 2 — ZTWIM" "SPIRE + PostgreSQL mTLS 워크로드 준비 완료"
  log "모듈 2 준비 완료."
}

# ─────────────────────────────────────────────────────────────────────
# 상태 점검 / 정리
# ─────────────────────────────────────────────────────────────────────

status() {
  hr
  log "보안 트랙 준비 상태"
  hr

  echo "▸ 모듈 1 — RHACS"
  oc get pods -n "${STACKROX_NS}" --no-headers 2>/dev/null \
    | awk '{print "    stackrox: "$1" "$3}' | head -5 || echo "    (RHACS 미설치)"
  oc get deployment -n "${NARUPAY_NS}" -l workshop=narupay-security-track \
    -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas --no-headers 2>/dev/null \
    | sed 's/^/    /' || echo "    (나루페이 워크로드 없음)"
  [[ -f "${LAB_DIR}/payment-api-vulnerable.yaml" ]] \
    && echo "    참가자용 매니페스트: ${LAB_DIR} ✓" \
    || echo "    참가자용 매니페스트: 없음 ✗"

  echo
  echo "▸ 모듈 3 — Secrets Management"
  oc get pods -n vault --no-headers 2>/dev/null | sed 's/^/    /' || echo "    (Vault 미설치)"
  oc get route vault -n vault -o jsonpath='    Vault UI: https://{.spec.host}/{"\n"}' 2>/dev/null || true

  echo
  echo "▸ 모듈 2 — ZTWIM"
  oc get pods -n postgresql-spiffe --no-headers 2>/dev/null | sed 's/^/    /' || echo "    (미배포)"
  oc get pods -n postgresql-spiffe-client --no-headers 2>/dev/null | sed 's/^/    /' || true
  hr
}

# SPIRE CR 이 실제로 어느 namespace 에 있는지 찾습니다.
# 환경에 따라 openshift- 접두사 유무가 달라서 하드코딩하지 않습니다.
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

wait_ns_gone() {
  local ns="$1" timeout="${2:-180}" elapsed=0
  oc get ns "${ns}" >/dev/null 2>&1 || return 0
  log "namespace ${ns} 삭제 대기 중..."
  while oc get ns "${ns}" >/dev/null 2>&1; do
    if [[ "${elapsed}" -ge "${timeout}" ]]; then
      warn "namespace ${ns} 가 아직 Terminating 입니다. 다음 배포가 실패할 수 있습니다."
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 0
}

# SPIRE 플랫폼(CR + datastore)을 제거합니다. 오퍼레이터와 namespace 는 보존합니다 —
# 오퍼레이터는 실습 환경이 사전 설치해 제공하는 것이라 우리가 지울 대상이 아닙니다.
#
# datastore PVC 를 함께 지우는 이유: SPIRE 서버는 등록 엔트리와 CA 를 sqlite 에
# 보관하므로, PVC 를 남기면 "새로 구성"해도 이전 상태가 그대로 살아납니다.
cleanup_spire_platform() {
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

  log "ZTWIM 오퍼레이터와 namespace ${ns} 는 그대로 둡니다 (실습 환경 제공 요소)."
}

# 실습 워크로드만 제거합니다. SPIRE 플랫폼은 건드리지 않습니다.
cleanup_workloads() {
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
}

# 기본 cleanup — 지우고 처음부터 다시 구성하는 용도입니다.
# 다음 all 이 Terminating namespace 때문에 실패하지 않도록 삭제 완료까지 기다립니다.
cleanup() {
  hr
  log "보안 트랙 전체 정리 중..."

  cleanup_workloads
  cleanup_spire_platform

  wait_ns_gone "${NARUPAY_NS}" || true
  wait_ns_gone postgresql-spiffe || true
  wait_ns_gone postgresql-spiffe-client || true
  wait_ns_gone vault || true

  log "정리 완료. 이제 ./setup-security-track.sh all 로 새로 구성할 수 있습니다."
  log "RHACS 정책의 Enforcement 설정은 콘솔에서 수동으로 되돌려야 합니다"
  log "  (Policy Management → Latest tag → Response method → Inform only)"
}

# 실습 워크로드만 정리하고 SPIRE 플랫폼은 유지합니다.
# 같은 환경에서 워크로드만 다시 배포할 때 SPIRE 재구성 시간을 아낄 수 있습니다.
cleanup_lab_only() {
  hr
  log "실습 워크로드만 정리 중 (SPIRE 플랫폼 유지)..."
  cleanup_workloads
  log "정리 완료. SPIRE 플랫폼은 그대로 두었습니다."
}

print_summary() {
  local entry state name detail vault_route

  hr
  if [[ "${STEP_FAILED}" -eq 0 ]]; then
    log "보안 트랙 준비 완료"
  else
    log "보안 트랙 준비 — 일부 실패"
  fi
  hr
  echo
  echo "  준비 결과:"
  echo
  for entry in ${RESULTS[@]+"${RESULTS[@]}"}; do
    state="${entry%%|*}"
    name="${entry#*|}"; name="${name%%|*}"
    detail="${entry##*|}"
    if [[ "${state}" == "OK" ]]; then
      printf "    [✓] %-28s %s\n" "${name}" "${detail}"
    else
      printf "    [✗] %-28s %s\n" "${name}" "${detail}"
    fi
  done

  echo
  echo "  참가자에게 안내할 내용:"
  echo
  echo "  ▸ 모듈 1 (RHACS)"
  echo "      취약 버전:  deployment/payment-api        (namespace: ${NARUPAY_NS})"
  echo "      안전 버전:  deployment/payment-api-secure (namespace: ${NARUPAY_NS})"
  echo "      차단 시연용 매니페스트: ${LAB_DIR}/payment-api-vulnerable.yaml"
  oc get route central -n "${STACKROX_NS}" -o jsonpath='      RHACS 콘솔: https://{.spec.host}{"\n"}' 2>/dev/null || true
  echo
  echo "  ▸ 모듈 2 (ZTWIM)"
  echo "      서버: deployment/postgresql-spiffe        (namespace: postgresql-spiffe)"
  echo "      클라이언트: deployment/postgresql-spiffe-client (namespace: postgresql-spiffe-client)"
  echo
  echo "  ▸ 모듈 3 (Secrets Management)"
  echo "      기존 방식 앱: deployment/legacy-secret-app (namespace: ${NARUPAY_NS})"
  echo "      Secret:       payment-db-creds"
  vault_route="$(oc get route vault -n vault -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${vault_route}" ]]; then
    echo "      Vault UI: https://${vault_route}/  (Token: root)"
  else
    echo "      Vault UI: 없음 ✗  — Vault 가 준비되지 않았습니다"
  fi
  echo
  hr

  if [[ "${STEP_FAILED}" -ne 0 ]]; then
    echo
    warn "실패한 항목이 있습니다. 해당 모듈은 워크샵에서 그대로 막힙니다."
    warn "Vault 관련 문제는 ./verify-vault.sh 로 상세 점검할 수 있습니다."
    echo
    return 1
  fi
  return 0
}

main() {
  require_oc
  case "${ACTION}" in
    # 개별 실행도 요약을 출력해, 실패가 스크롤에 묻히지 않게 합니다.
    # set -e 아래에서 한 모듈이 실패해도 나머지를 계속 진행하도록 || true 를 씁니다.
    acs)     setup_acs   || true; print_summary ;;
    ztwim)   setup_ztwim || true; print_summary ;;
    vault)   setup_vault || true; print_summary ;;
    # 가이드 진행 순서(RHACS → ZTWIM → Secrets)와 동일하게 준비합니다.
    all)
      setup_acs   || true
      setup_ztwim || true
      setup_vault || true
      print_summary
      ;;
    status)      status ;;
    cleanup)     cleanup ;;
    cleanup-lab) cleanup_lab_only ;;
    *)
      echo "사용법: $0 [all|acs|ztwim|vault|status|cleanup|cleanup-lab]" >&2
      exit 1
      ;;
  esac
}

main "$@"
