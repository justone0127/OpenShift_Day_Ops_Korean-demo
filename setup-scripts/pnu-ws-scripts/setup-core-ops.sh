#!/usr/bin/env bash
#
# PNU 워크숍 모듈 01~06(OpenShift 운영 기본) — 환경 준비·점검·정리 (진행자용)
#
# 한 줄 실행 (bastion, cluster-admin 으로 oc login 된 상태):
#   bash <(curl -sL https://raw.githubusercontent.com/justone0127/OpenShift_Day_Ops_Korean-demo/pnu-ws/setup-scripts/pnu-ws-scripts/setup-core-ops.sh) [액션]
#
# 액션:
#   all       GitOps 설치(없을 때만) + 사전 점검            (기본값)
#   gitops    OpenShift GitOps Operator 설치 + ArgoCD 준비 대기 (모듈 06)
#   check     01~06 실습에 필요한 조건 점검 (변경 없음)
#   cleanup   참가자가 01~06 에서 만든 실습 리소스 정리
#             (네임스페이스, ArgoCD Application/AppProject, AdminNetworkPolicy)
#
# 모듈별로 필요한 것:
#   01 설치 및 검증      노드 Ready, ClusterOperator 정상, 기본 StorageClass(PVC 바인딩)
#   02 애플리케이션 관리 registry.access.redhat.com 이미지 pull
#   03 Ingress           default IngressController
#   04 네트워크 보안     OVN-Kubernetes, AdminNetworkPolicy CRD
#   05 디버깅            Showroom 터미널에서 raw.githubusercontent.com 접근 (curl)
#   06 GitOps            OpenShift GitOps (openshift-gitops 네임스페이스의 ArgoCD)
#
# 환경 변수:
#   GITOPS_CHANNEL   GitOps Operator 채널 (기본값 latest)
#   WAIT_TIMEOUT     설치 대기 시간(초)  (기본값 600)
#
set -euo pipefail

GITOPS_CHANNEL="${GITOPS_CHANNEL:-latest}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
ACTION="${1:-all}"

log()  { echo "[core-ops] $*"; }
warn() { echo "[core-ops] WARNING: $*" >&2; }
err()  { echo "[core-ops] ERROR: $*" >&2; exit 1; }
hr()   { echo "--------------------------------------------------------------------"; }

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
ng()   { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
wn()   { echo "  [WARN] $*"; WARN=$((WARN+1)); }

usage() {
  cat <<'USAGE'
사용법: setup-core-ops.sh [all|gitops|check|cleanup]

  all      GitOps 설치(없을 때만) + 사전 점검 (기본값)
  gitops   OpenShift GitOps Operator 설치 + ArgoCD 준비 대기
  check    01~06 실습 조건 점검 (변경 없음)
  cleanup  참가자가 01~06 에서 만든 실습 리소스 정리
USAGE
}

case "${ACTION}" in
  all|gitops|check|cleanup) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; err "알 수 없는 액션: ${ACTION}" ;;
esac

command -v oc >/dev/null 2>&1 || err "oc 를 PATH 에서 찾을 수 없습니다"
oc whoami >/dev/null 2>&1 || err "OpenShift 에 로그인되어 있지 않습니다 (oc login)"

# ── 모듈 06: OpenShift GitOps ─────────────────────────────────────────
gitops_ready() {
  oc get deploy openshift-gitops-server -n openshift-gitops \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^[1-9]'
}

install_gitops() {
  hr
  if gitops_ready; then
    log "OpenShift GitOps 가 이미 설치되어 있습니다 (openshift-gitops-server Available)."
    return 0
  fi

  if oc get subscription.operators.coreos.com -A --no-headers 2>/dev/null | grep -q 'openshift-gitops-operator'; then
    log "GitOps Operator Subscription 이 이미 있습니다. ArgoCD 준비를 기다립니다."
  else
    log "OpenShift GitOps Operator 설치 (channel=${GITOPS_CHANNEL})..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: ${GITOPS_CHANNEL}
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  fi

  log "기본 ArgoCD 인스턴스(openshift-gitops) 준비 대기 (최대 ${WAIT_TIMEOUT}초)..."
  local waited=0
  until gitops_ready; do
    if (( waited >= WAIT_TIMEOUT )); then
      oc get csv -n openshift-gitops-operator 2>/dev/null || true
      oc get pods -n openshift-gitops 2>/dev/null || true
      err "시간 내에 ArgoCD 가 준비되지 않았습니다"
    fi
    sleep 10; waited=$((waited+10))
    (( waited % 60 == 0 )) && log "  ...${waited}초 경과"
  done
  oc wait --for=condition=Available deploy --all -n openshift-gitops --timeout=300s >/dev/null 2>&1 || \
    warn "openshift-gitops 의 일부 Deployment 가 아직 Available 이 아닙니다"
  log "OpenShift GitOps 준비 완료."
}

# ── 사전 점검 ─────────────────────────────────────────────────────────
check() {
  hr
  log "01~06 사전 점검"

  echo "01 설치 및 검증"
  local total ready
  total="$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  ready="$(oc get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/' | wc -l | tr -d ' ')"
  [[ "${total}" -gt 0 && "${total}" == "${ready}" ]] && ok "노드 ${ready}/${total} Ready" || ng "노드 Ready ${ready}/${total}"

  local degraded
  degraded="$(oc get co --no-headers 2>/dev/null | awk '$3!="True" || $5=="True" {print $1}' | xargs)"
  [[ -z "${degraded}" ]] && ok "ClusterOperator 전부 Available / Degraded 없음" || wn "확인 필요한 ClusterOperator: ${degraded}"

  local sc
  sc="$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null | xargs)"
  [[ -n "${sc}" ]] && ok "기본 StorageClass: ${sc}" || ng "기본 StorageClass 가 없습니다 (01 의 PVC 실습이 Pending 됩니다)"

  echo "03 Ingress"
  oc get ingresscontroller default -n openshift-ingress-operator >/dev/null 2>&1 \
    && ok "default IngressController 존재" || ng "default IngressController 가 없습니다"

  echo "04 네트워크 보안"
  local nettype
  nettype="$(oc get network.config cluster -o jsonpath='{.status.networkType}' 2>/dev/null)"
  [[ "${nettype}" == "OVNKubernetes" ]] && ok "networkType=OVNKubernetes" || ng "networkType=${nettype:-unknown} (OVN-Kubernetes 필요)"
  oc get crd adminnetworkpolicies.policy.networking.k8s.io >/dev/null 2>&1 \
    && ok "AdminNetworkPolicy CRD 존재" || wn "AdminNetworkPolicy CRD 가 없습니다 (ANP 실습 불가)"
  oc get crd egressfirewalls.k8s.ovn.org >/dev/null 2>&1 \
    && ok "EgressFirewall CRD 존재" || ng "EgressFirewall CRD 가 없습니다"

  echo "05 디버깅"
  if command -v curl >/dev/null 2>&1; then
    curl -sfL -o /dev/null --max-time 10 \
      https://raw.githubusercontent.com/rhpds/openshift-days-ops-showroom/main/support/05-debugging/deploy-broken-apps.sh \
      && ok "장애 앱 배포 스크립트 다운로드 가능 (raw.githubusercontent.com)" \
      || wn "raw.githubusercontent.com 에 접근할 수 없습니다 (05/04 의 curl 실습 불가)"
  else
    wn "curl 이 없어 외부 접근을 확인하지 못했습니다"
  fi

  echo "06 GitOps"
  if gitops_ready; then
    ok "openshift-gitops-server Available"
    local host
    host="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null)"
    [[ -n "${host}" ]] && ok "ArgoCD URL: https://${host}" || wn "ArgoCD Route 를 찾지 못했습니다"
    # 'Log in via OpenShift' 로 들어온 cluster-admin 이 workshop 프로젝트를 볼 수 있어야 합니다.
    local policy
    policy="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.rbac.policy}' 2>/dev/null)"
    if grep -q 'cluster-admins' <<<"${policy}"; then
      ok "ArgoCD RBAC: cluster-admins 그룹 → role:admin"
    else
      wn "ArgoCD RBAC 에 cluster-admins 매핑이 보이지 않습니다 (UI 에서 Application 이 안 보일 수 있음)"
    fi
    if ! oc get group cluster-admins -o jsonpath='{.users}' 2>/dev/null | grep -q '"admin"'; then
      wn "admin 사용자가 cluster-admins 그룹에 없습니다 — 필요 시: oc adm groups add-users cluster-admins admin"
    fi
  else
    ng "OpenShift GitOps 가 없습니다 → '$0 gitops' 로 설치하십시오"
  fi

  hr
  log "결과: OK ${PASS} / WARN ${WARN} / FAIL ${FAIL}"
  (( FAIL == 0 ))
}

# ── 정리 ─────────────────────────────────────────────────────────────
cleanup() {
  hr
  log "01~06 실습 리소스 정리"
  oc delete application.argoproj.io managed-project -n openshift-gitops --ignore-not-found 2>/dev/null || true
  oc delete appproject.argoproj.io workshop -n openshift-gitops --ignore-not-found 2>/dev/null || true
  oc delete adminnetworkpolicy cluster-deny-external-dns --ignore-not-found 2>/dev/null || true
  oc delete project \
    install-test storage-test app-management ingress-demo \
    netpol-frontend netpol-backend debug-lab gitops-managed-project \
    --ignore-not-found --wait=false
  log "네임스페이스 삭제를 요청했습니다 (백그라운드에서 정리됩니다)."
}

case "${ACTION}" in
  all)     install_gitops; check ;;
  gitops)  install_gitops ;;
  check)   check ;;
  cleanup) cleanup ;;
esac
