#!/usr/bin/env bash
#
# PNU 워크숍(pnu-ws) — 실습 환경 + Showroom 매뉴얼을 한 번에 준비 (진행자용)
#
# 한 줄 실행 (bastion, cluster-admin 으로 oc login 된 상태):
#   bash <(curl -sL https://raw.githubusercontent.com/justone0127/OpenShift_Day_Ops_Korean-demo/pnu-ws/setup-scripts/pnu-ws-scripts/setup-pnu-ws.sh) [액션]
#
# 액션:
#   all          1부 준비(GitOps) → 2부 보안 트랙 배포 → Showroom 을 pnu-ws 로 전환 (기본값)
#   env          실습 환경만 준비 (1부 + 2부), Showroom 은 그대로
#   showroom     Showroom 매뉴얼만 pnu-ws 로 전환
#   status       1부 점검 + 2부 준비 상태 + Showroom 설정 확인
#   cleanup      참가자 실습 리소스 정리 (1부 네임스페이스 + 2부 사용자 환경)
#   cleanup-all  cleanup + 보안 트랙 공통 구성요소(SPIRE/Keycloak 등)까지 정리
#
# 2부 보안 트랙 스크립트는 같은 디렉터리의 파일들을 함께 쓰므로,
# curl 로 실행했을 때는 저장소를 아래 경로에 clone(또는 갱신)한 뒤 실행합니다:
#   ${WORKSHOP_DIR:-$HOME/OpenShift_Day_Ops_Korean-demo}  (브랜치 pnu-ws)
#
# 환경 변수:
#   WORKSHOP_REPO_URL  기본값 https://github.com/justone0127/OpenShift_Day_Ops_Korean-demo.git
#   WORKSHOP_REF       기본값 pnu-ws
#   WORKSHOP_DIR       기본값 $HOME/OpenShift_Day_Ops_Korean-demo
#   SHOWROOM_NS        Showroom 네임스페이스 (생략 시 자동 탐색)
#
set -euo pipefail

REPO_URL="${WORKSHOP_REPO_URL:-https://github.com/justone0127/OpenShift_Day_Ops_Korean-demo.git}"
REPO_REF="${WORKSHOP_REF:-pnu-ws}"
ACTION="${1:-all}"

log() { echo "[pnu-ws] $*"; }
err() { echo "[pnu-ws] ERROR: $*" >&2; exit 1; }
hr()  { echo "===================================================================="; }

usage() {
  cat <<'USAGE'
사용법: setup-pnu-ws.sh [all|env|showroom|status|cleanup|cleanup-all]

  all          1부 준비(GitOps) → 2부 보안 트랙 배포 → Showroom 을 pnu-ws 로 전환 (기본값)
  env          실습 환경만 준비 (1부 + 2부)
  showroom     Showroom 매뉴얼만 pnu-ws 로 전환
  status       1부 점검 + 2부 준비 상태 + Showroom 설정 확인
  cleanup      참가자 실습 리소스 정리 (1부 + 2부 사용자 환경)
  cleanup-all  cleanup + 보안 트랙 공통 구성요소까지 정리
USAGE
}

case "${ACTION}" in
  all|env|showroom|status|cleanup|cleanup-all) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; err "알 수 없는 액션: ${ACTION}" ;;
esac

command -v oc >/dev/null 2>&1 || err "oc 를 PATH 에서 찾을 수 없습니다"
oc whoami >/dev/null 2>&1 || err "OpenShift 에 로그인되어 있지 않습니다 (oc login)"

# ── 저장소 위치 결정 ──────────────────────────────────────────────────
# 저장소 안에서 실행했으면 그 저장소를, curl 로 실행했으면 clone 한 저장소를 씁니다.
ROOT=""
if [[ -f "${BASH_SOURCE[0]}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -d "${here}/../security-track-scripts" ]] && ROOT="$(cd "${here}/../.." && pwd)"
fi
if [[ -z "${ROOT}" ]]; then
  command -v git >/dev/null 2>&1 || err "git 이 필요합니다 (저장소 clone)"
  ROOT="${WORKSHOP_DIR:-$HOME/OpenShift_Day_Ops_Korean-demo}"
  if [[ -d "${ROOT}/.git" ]]; then
    log "저장소 갱신: ${ROOT} (${REPO_REF})"
    git -C "${ROOT}" fetch -q origin "${REPO_REF}"
    git -C "${ROOT}" checkout -q -B "${REPO_REF}" "origin/${REPO_REF}"
  else
    log "저장소 clone: ${REPO_URL} @ ${REPO_REF} → ${ROOT}"
    git clone -q --depth 1 -b "${REPO_REF}" "${REPO_URL}" "${ROOT}"
  fi
fi

CORE="${ROOT}/setup-scripts/pnu-ws-scripts/setup-core-ops.sh"
SWITCH="${ROOT}/setup-scripts/pnu-ws-scripts/switch-showroom-pnu-ws.sh"
SECURITY="${ROOT}/setup-scripts/security-track-scripts/setup-security-track.sh"
for f in "${CORE}" "${SWITCH}" "${SECURITY}"; do
  [[ -f "${f}" ]] || err "스크립트를 찾을 수 없습니다: ${f}"
done
chmod +x "${CORE}" "${SWITCH}" "${SECURITY}" "${ROOT}/setup-scripts/security-track-scripts/setup-multiuser.sh" 2>/dev/null || true

run_core()     { hr; log "1부 · OpenShift 운영 기본 (01~06): $1"; "${CORE}" "$1"; }
run_security() { hr; log "2부 · 보안 트랙 (RedPay): $1";        "${SECURITY}" "$1"; }
run_switch()   { hr; log "Showroom 매뉴얼 → ${REPO_REF}";        "${SWITCH}" ${SHOWROOM_NS:+"${SHOWROOM_NS}"} "$@"; }

case "${ACTION}" in
  all)
    run_core gitops
    run_security all
    run_switch
    run_core check || log "1부 점검에 FAIL 항목이 있습니다. 위 내용을 확인하십시오."
    ;;
  env)
    run_core gitops
    run_security all
    run_core check || log "1부 점검에 FAIL 항목이 있습니다. 위 내용을 확인하십시오."
    ;;
  showroom)    run_switch ;;
  status)
    run_core check || true
    run_security status || true
    run_switch --status || true
    ;;
  cleanup)     run_core cleanup; run_security cleanup ;;
  cleanup-all) run_core cleanup; run_security cleanup-all ;;
esac

hr
log "완료: ${ACTION}"
