#!/usr/bin/env bash
#
# 레드페이 보안 트랙 — 단일 사용자 환경 배포
#
# 참가자가 한 명이거나, 참가자마다 클러스터를 하나씩 받는 구성에서 씁니다.
#
#   ./setup-security-track.sh all       # 환경 생성 (기본값)
#   ./setup-security-track.sh status    # 준비 상태 점검
#   ./setup-security-track.sh cleanup   # 사용자 환경만 정리
#   ./setup-security-track.sh cleanup-all  # SPIRE/Vault 까지 전부 정리
#
# 실제 동작은 setup-multiuser.sh 의 단일 사용자 모드입니다.
# 로직을 한 곳에 두어 두 경로가 어긋나지 않게 했습니다.
#
# 접두사 없는 네임스페이스를 만듭니다:
#   redpay / postgresql-spiffe / postgresql-spiffe-client
#
# 워크샵 매뉴얼(content/antora.yml 의 redpay_ns 등)도 같은 이름을 기본값으로
# 쓰므로 참가자가 따로 설정할 것은 없습니다.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MULTIUSER="${SCRIPT_DIR}/setup-multiuser.sh"

[[ -x "${MULTIUSER}" ]] || {
  echo "[security-track] ERROR: ${MULTIUSER} 를 찾을 수 없습니다" >&2
  exit 1
}

# 번호 사용자를 만들지 않고, 접두사 없는 단일 환경만 배포합니다.
export EXTRA_USERS="__none__"

ACTION="${1:-all}"

case "${ACTION}" in
  all)         exec "${MULTIUSER}" deploy 0 ;;
  status)      exec "${MULTIUSER}" status 0 ;;
  cleanup)     exec "${MULTIUSER}" cleanup 0 ;;
  cleanup-all) exec "${MULTIUSER}" cleanup-all 0 ;;
  -h|--help|help)
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
  *)
    echo "[security-track] ERROR: 알 수 없는 액션: ${ACTION}" >&2
    echo "사용법: $0 [all|status|cleanup|cleanup-all]" >&2
    exit 1
    ;;
esac
