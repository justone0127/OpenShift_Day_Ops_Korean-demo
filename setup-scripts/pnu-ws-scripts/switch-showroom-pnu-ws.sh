#!/usr/bin/env bash
#
# Showroom 매뉴얼을 PNU 워크숍 버전(pnu-ws 브랜치)으로 전환 + 재초기화 — 진행자용
#
# pnu-ws 매뉴얼 구성:
#   설정 및 개요
#   01 설치 및 검증 / 02 애플리케이션 관리 / 03 Ingress / 04 네트워크 보안 /
#   05 디버깅 / 06 GitOps / 07 Observability / 08 Lightspeed /
#   09 보안 시나리오(RedPay) / 10 RHBK / 11 ZTWIM / 12 RHACS
#   Wrap Up
#
# 한 줄 실행 (bastion, cluster-admin 으로 oc login 된 상태):
#   bash <(curl -sL https://raw.githubusercontent.com/justone0127/OpenShift_Day_Ops_Korean-demo/pnu-ws/setup-scripts/pnu-ws-scripts/switch-showroom-pnu-ws.sh)
#
# 인자 (한 줄 실행 뒤에 그대로 붙이면 됩니다):
#   (없음)            showroom 네임스페이스 자동 탐색 후 전환
#   showroom-xxxx-1   네임스페이스 직접 지정
#   --dry-run         무엇을 바꿀지 보기만 함
#   --status          현재 설정과 상태만 확인
#
# 하는 일:
#   1. showroom Deployment 의 git-cloner / content 컨테이너가
#      이 저장소의 pnu-ws 브랜치를 보도록 GIT_REPO_URL / GIT_REPO_REF 를 바꿉니다.
#   2. workshop-vars ConfigMap 이 있으면 MODULE_ENABLE_* 값을 pnu-ws 구성
#      (01~06·Observability·Lightspeed + 보안 모듈 = true, 나머지 = false)으로 맞춥니다.
#      → 나중에 inject-env-vars.sh 가 다시 실행되어도 목차가 바뀌지 않습니다.
#   3. pod 를 다시 띄워 clone → Antora 빌드를 처음부터 다시 수행합니다.
#
# 이미 같은 저장소·브랜치를 보고 있으면 설정은 그대로 두고 pod 만 재시작합니다.
# (매뉴얼을 고쳐 푸시한 뒤 최신 커밋을 반영할 때도 다시 실행하면 됩니다.)
#
# 환경 변수:
#   SHOWROOM_REPO_URL  기본값 https://github.com/justone0127/OpenShift_Day_Ops_Korean-demo.git
#   SHOWROOM_REPO_REF  기본값 pnu-ws
#
set -euo pipefail

REPO_URL="${SHOWROOM_REPO_URL:-https://github.com/justone0127/OpenShift_Day_Ops_Korean-demo.git}"
REPO_REF="${SHOWROOM_REPO_REF:-pnu-ws}"
DEPLOY="showroom"

usage() {
  cat <<'USAGE'
사용법: switch-showroom-pnu-ws.sh [showroom-네임스페이스] [--dry-run|--status]

  Showroom 이 pnu-ws 브랜치(01~12 통합 매뉴얼)를 보도록 전환하고
  pod 를 재시작해 매뉴얼을 다시 빌드합니다.

  한 줄 실행:
    bash <(curl -sL https://raw.githubusercontent.com/justone0127/OpenShift_Day_Ops_Korean-demo/pnu-ws/setup-scripts/pnu-ws-scripts/switch-showroom-pnu-ws.sh)
USAGE
}

# pnu-ws 매뉴얼에서 노출할 모듈 (workshop-vars ConfigMap 에 반영)
MODULE_FLAGS=(
  MODULE_ENABLE_INSTALL=true
  MODULE_ENABLE_APPMGMT=true
  MODULE_ENABLE_INGRESS=true
  MODULE_ENABLE_NETSEC=true
  MODULE_ENABLE_DEBUGGING=true
  MODULE_ENABLE_GITOPS=true
  MODULE_ENABLE_LDAP=false
  MODULE_ENABLE_OIDC=false
  MODULE_ENABLE_OBSERVABILITY=true
  MODULE_ENABLE_PERFORMANCE=false
  MODULE_ENABLE_VIRT=false
  MODULE_ENABLE_DEVHUB=false
  MODULE_ENABLE_OLS=true
  MODULE_ENABLE_ACM=false
  MODULE_ENABLE_SECURITY=true
  MODULE_ENABLE_ZTWIM=true
)

MODE="apply"
NS=""
for arg in "$@"; do
  case "${arg}" in
    --dry-run) MODE="dry-run" ;;
    --status)  MODE="status" ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "알 수 없는 옵션: ${arg}" >&2; exit 1 ;;
    *)         NS="${arg}" ;;
  esac
done

log()  { echo "[showroom] $*"; }
warn() { echo "[showroom] WARNING: $*" >&2; }
err()  { echo "[showroom] ERROR: $*" >&2; exit 1; }
hr()   { echo "--------------------------------------------------------------------"; }

command -v oc >/dev/null 2>&1 || err "oc 를 PATH 에서 찾을 수 없습니다"
oc whoami >/dev/null 2>&1 || err "OpenShift 에 로그인되어 있지 않습니다 (oc login)"

# ── 네임스페이스 탐색 ────────────────────────────────────────────────
if [[ -z "${NS}" ]]; then
  found="$(oc get deploy -A --field-selector metadata.name="${DEPLOY}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | grep '^showroom' || true)"
  count="$(printf '%s' "${found}" | grep -c . || true)"
  case "${count}" in
    0) err "showroom Deployment 를 찾지 못했습니다. 네임스페이스를 인자로 지정하십시오." ;;
    1) NS="${found}" ;;
    *) err "showroom 네임스페이스가 여러 개입니다 ($(echo ${found})). 하나를 인자로 지정하십시오." ;;
  esac
fi
oc get deploy "${DEPLOY}" -n "${NS}" >/dev/null 2>&1 || err "${NS} 에 ${DEPLOY} Deployment 가 없습니다"

current_env() {   # <initContainers|containers> <container> <ENV>
  oc get deploy "${DEPLOY}" -n "${NS}" \
    -o jsonpath="{.spec.template.spec.$1[?(@.name==\"$2\")].env[?(@.name==\"$3\")].value}"
}

show_status() {
  hr
  log "네임스페이스: ${NS}"
  echo "  git-cloner : $(current_env initContainers git-cloner GIT_REPO_URL)  @ $(current_env initContainers git-cloner GIT_REPO_REF)"
  echo "  content    : $(current_env containers content GIT_REPO_URL)  @ $(current_env containers content GIT_REPO_REF)"
  oc get pods -n "${NS}" --no-headers 2>/dev/null | grep "^${DEPLOY}-" | sed 's/^/  pod: /' || true
  oc get route -n "${NS}" -o jsonpath='{range .items[*]}  URL: https://{.spec.host}{"\n"}{end}' 2>/dev/null || true
  if oc get configmap workshop-vars -n "${NS}" >/dev/null 2>&1; then
    echo "  workshop-vars (MODULE_ENABLE_*):"
    oc get configmap workshop-vars -n "${NS}" -o go-template='{{range $k,$v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' \
      | grep '^MODULE_ENABLE_' | sed 's/^/    /' || true
  fi
  hr
}

if [[ "${MODE}" == "status" ]]; then
  show_status
  exit 0
fi

# ── 브랜치 존재 확인 (clone 실패로 pod 가 멈추는 것을 미리 막음) ─────────
if command -v git >/dev/null 2>&1; then
  log "원격 저장소에서 브랜치 확인: ${REPO_URL} @ ${REPO_REF}"
  if ! git ls-remote --exit-code --heads "${REPO_URL}" "${REPO_REF}" >/dev/null 2>&1; then
    err "저장소에 '${REPO_REF}' 브랜치가 없거나 저장소에 접근할 수 없습니다: ${REPO_URL}"
  fi
else
  warn "git 이 없어 브랜치 존재 여부를 미리 확인하지 못했습니다"
fi

hr
log "네임스페이스 : ${NS}"
log "현재 설정    : $(current_env initContainers git-cloner GIT_REPO_URL) @ $(current_env initContainers git-cloner GIT_REPO_REF)"
log "변경할 설정  : ${REPO_URL} @ ${REPO_REF}"
hr

# git-cloner 는 initContainer 라서 'oc set env' 로는 바꿀 수 없습니다.
# 컨테이너·env 를 이름으로 병합하는 strategic merge patch 를 씁니다
# (다른 컨테이너와 다른 환경변수는 그대로 유지됩니다).
PATCH="$(cat <<JSON
{"spec":{"template":{"spec":{
  "initContainers":[{"name":"git-cloner","env":[
    {"name":"GIT_REPO_URL","value":"${REPO_URL}"},
    {"name":"GIT_REPO_REF","value":"${REPO_REF}"}]}],
  "containers":[{"name":"content","env":[
    {"name":"GIT_REPO_URL","value":"${REPO_URL}"},
    {"name":"GIT_REPO_REF","value":"${REPO_REF}"}]}]
}}}}
JSON
)"

if [[ "${MODE}" == "dry-run" ]]; then
  oc patch deploy "${DEPLOY}" -n "${NS}" --dry-run=server -p "${PATCH}" >/dev/null
  log "dry-run 성공 — 실제로 적용하려면 --dry-run 없이 다시 실행하십시오."
  exit 0
fi

# ── workshop-vars ConfigMap 의 모듈 플래그를 pnu-ws 구성으로 맞춤 ─────────
if oc get configmap workshop-vars -n "${NS}" >/dev/null 2>&1; then
  cm_data=""
  for kv in "${MODULE_FLAGS[@]}"; do
    cm_data="${cm_data:+${cm_data},}\"${kv%%=*}\":\"${kv#*=}\""
  done
  oc patch configmap workshop-vars -n "${NS}" --type=merge -p "{\"data\":{${cm_data}}}" >/dev/null
  log "workshop-vars ConfigMap 의 MODULE_ENABLE_* 를 pnu-ws 구성으로 맞췄습니다 (01~12)."
else
  log "workshop-vars ConfigMap 이 없습니다 — 저장소의 default-site.yml 모듈 설정을 그대로 씁니다."
fi

before="$(oc get deploy "${DEPLOY}" -n "${NS}" -o jsonpath='{.metadata.generation}')"
oc patch deploy "${DEPLOY}" -n "${NS}" -p "${PATCH}" >/dev/null
after="$(oc get deploy "${DEPLOY}" -n "${NS}" -o jsonpath='{.metadata.generation}')"

if [[ "${before}" == "${after}" ]]; then
  log "이미 같은 저장소·브랜치입니다. 최신 커밋을 반영하도록 pod 를 재시작합니다."
  oc rollout restart deploy/"${DEPLOY}" -n "${NS}" >/dev/null
else
  log "저장소·브랜치를 변경했습니다. pod 가 새로 시작되며 clone → 빌드를 다시 수행합니다."
fi

log "재초기화 대기 중 (clone + Antora 빌드, 보통 1~3분)..."
if ! oc rollout status deploy/"${DEPLOY}" -n "${NS}" --timeout=420s; then
  warn "rollout 이 완료되지 않았습니다. 초기화 컨테이너 로그:"
  pod="$(oc get pods -n "${NS}" --sort-by=.metadata.creationTimestamp -o name | grep "/${DEPLOY}-" | tail -1)"
  echo "── git-cloner ──";     oc logs "${pod}" -n "${NS}" -c git-cloner --tail=15 2>&1 || true
  echo "── antora-builder ──"; oc logs "${pod}" -n "${NS}" -c antora-builder --tail=15 2>&1 | grep -v "missing attribute" || true
  err "Showroom 재초기화 실패"
fi

show_status
log "완료. 브라우저에서 Showroom 을 새로고침하십시오."
log "왼쪽 목차: 설정 및 개요 → 01~12 → Wrap Up"
