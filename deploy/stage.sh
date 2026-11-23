#!/bin/bash
set -uo pipefail
STEP="init"
: > /tmp/status
: > /tmp/reason
: > /tmp/alb_host
fail() { echo FAILED > /tmp/status; echo "$1" > /tmp/reason; echo "FAILED: $1"; exit 1; }
ok() { echo SUCCESS > /tmp/status; echo "${1:-done}" > /tmp/reason; echo "SUCCESS: ${1:-done}"; exit 0; }
trap 'if [ ! -s /tmp/status ]; then echo FAILED > /tmp/status; echo "Unexpected error during: $STEP" > /tmp/reason; fi' EXIT

STAGE="${STAGE:-}"
REQUEST_TYPE="${REQUEST_TYPE:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
REGION="${REGION:-}"
VPC_ID="${VPC_ID:-}"
LBC_ROLE_ARN="${LBC_ROLE_ARN:-}"
PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_IDS:-}"
ALB_SG_ID="${ALB_SG_ID:-}"
APP_ROLE_ARN="${APP_ROLE_ARN:-}"
DB_SECRET_ARN="${DB_SECRET_ARN:-}"
CERTIFICATE_ARN="${CERTIFICATE_ARN:-}"
REPLICAS="${REPLICAS:-}"
export STAGE REQUEST_TYPE CLUSTER_NAME REGION VPC_ID LBC_ROLE_ARN PUBLIC_SUBNET_IDS ALB_SG_ID APP_ROLE_ARN DB_SECRET_ARN CERTIFICATE_ARN REPLICAS
export AWS_DEFAULT_REGION="$REGION"
# Repository checkout made by CodeBuild (GitHub source).
REPO_DIR="${CODEBUILD_SRC_DIR:-$(pwd)}"

IS_DELETE=0
[ "$REQUEST_TYPE" = "Delete" ] && IS_DELETE=1

STEP="validate inputs"
case "$STAGE" in
  addons) NEEDED="CLUSTER_NAME REGION REQUEST_TYPE" ; [ $IS_DELETE = 1 ] || NEEDED="$NEEDED VPC_ID LBC_ROLE_ARN" ;;
  app)    NEEDED="CLUSTER_NAME REGION REQUEST_TYPE" ; [ $IS_DELETE = 1 ] || NEEDED="$NEEDED VPC_ID PUBLIC_SUBNET_IDS ALB_SG_ID APP_ROLE_ARN DB_SECRET_ARN REPLICAS" ;;
  *)      fail "Deployer: unknown stage '$STAGE'" ;;
esac
for v in $NEEDED; do
  [ -n "${!v:-}" ] || fail "Deployer: required parameter $v is missing for stage $STAGE"
done

# Unreachable cluster: success on delete (a rolled-back create must be deletable).
skip_or_fail() { # message
  if [ $IS_DELETE = 1 ]; then ok "$1; nothing to clean up"; fi
  fail "$1"
}

STEP="EKS cluster lookup"
if ! CLUSTER_VERSION=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query cluster.version --output text 2>/tmp/err); then
  skip_or_fail "EKS cluster $CLUSTER_NAME not available: $(head -c 300 /tmp/err)"
fi

ARCH=$(uname -m)
case "$ARCH" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac

install_tools() {
  STEP="install helm $HELM_VERSION"
  local f="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  curl -fsSL "https://get.helm.sh/$f" -o "/tmp/$f" || return 1
  curl -fsSL "https://get.helm.sh/$f.sha256sum" -o "/tmp/$f.sha256sum" || return 1
  (cd /tmp && sha256sum -c "$f.sha256sum") || return 1
  tar -xzf "/tmp/$f" -C /tmp "linux-${ARCH}/helm" || return 1
  install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm || return 1
  # kubectl: latest patch of the cluster's minor version (within the supported skew), checksum verified.
  STEP="install kubectl for Kubernetes $CLUSTER_VERSION"
  local kv
  kv=$(curl -fsSL "https://dl.k8s.io/release/stable-${CLUSTER_VERSION}.txt") || kv=$(curl -fsSL https://dl.k8s.io/release/stable.txt) || return 1
  curl -fsSL "https://dl.k8s.io/release/${kv}/bin/linux/${ARCH}/kubectl" -o /tmp/kubectl || return 1
  curl -fsSL "https://dl.k8s.io/release/${kv}/bin/linux/${ARCH}/kubectl.sha256" -o /tmp/kubectl.sha256 || return 1
  echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c - || return 1
  install -m 0755 /tmp/kubectl /usr/local/bin/kubectl || return 1
}
if ! install_tools; then
  skip_or_fail "Deployer tooling: failed during '$STEP'"
fi

STEP="aws eks update-kubeconfig"
if ! aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>/tmp/err; then
  skip_or_fail "EKS cluster $CLUSTER_NAME: update-kubeconfig failed: $(head -c 300 /tmp/err)"
fi
if [ $IS_DELETE = 1 ]; then
  STEP="cluster API check"
  kubectl get namespace kube-system --request-timeout=30s >/dev/null 2>/tmp/err || ok "EKS cluster API not reachable ($(head -c 200 /tmp/err))"
fi

ADDONS="vpc-cni coredns kube-proxy aws-ebs-csi-driver"
sel_for() {
  case "$1" in
    vpc-cni) echo "k8s-app=aws-node" ;;
    coredns) echo "k8s-app=kube-dns" ;;
    kube-proxy) echo "k8s-app=kube-proxy" ;;
    aws-ebs-csi-driver) echo "app.kubernetes.io/name=aws-ebs-csi-driver" ;;
    lbc) echo "app.kubernetes.io/name=aws-load-balancer-controller" ;;
  esac
}
now() { date +%s; }

# ------------------------------------------------------------------ addons
if [ "$STAGE" = "addons" ]; then
  if [ $IS_DELETE = 1 ]; then
    STEP="helm uninstall aws-load-balancer-controller"
    helm uninstall aws-load-balancer-controller -n kube-system --timeout 5m || echo "helm uninstall failed or release absent; continuing"
    ok "AWS Load Balancer Controller uninstalled (best effort)"
  fi

  STEP="AWS Load Balancer Controller"
  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>/tmp/err || fail "AWS Load Balancer Controller: helm repo add failed: $(head -c 300 /tmp/err)"
  helm repo update >/dev/null 2>&1
  if ! helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
      --version "$LBC_CHART_VERSION" -n kube-system \
      --set "clusterName=${CLUSTER_NAME}" \
      --set serviceAccount.create=true \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${LBC_ROLE_ARN}" \
      --set "vpcId=${VPC_ID}" \
      --set "region=${REGION}" \
      --wait --timeout 15m 2>/tmp/err; then
    fail "AWS Load Balancer Controller: helm install failed or was not ready within 15 minutes: $(tail -c 400 /tmp/err)"
  fi

  DEADLINE=$(( $(now) + 900 ))
  for a in $ADDONS; do
    STEP="EKS add-on $a status"
    while true; do
      S=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$a" --region "$REGION" --query addon.status --output text 2>/tmp/err) || S="ERROR: $(head -c 200 /tmp/err)"
      [ "$S" = "ACTIVE" ] && break
      case "$S" in CREATE_FAILED|UPDATE_FAILED) fail "EKS add-on $a: status $S" ;; esac
      [ "$(now)" -ge "$DEADLINE" ] && fail "EKS add-on $a: not ACTIVE within 15 minutes (status: $S)"
      sleep 15
    done
    echo "add-on $a is ACTIVE"
  done

  for c in vpc-cni coredns kube-proxy aws-ebs-csi-driver lbc; do
    STEP="pods of $c"
    SEL=$(sel_for "$c")
    NAME="$c"
    [ "$c" = "lbc" ] && NAME="AWS Load Balancer Controller"
    LEFT=$(( DEADLINE - $(now) ))
    [ "$LEFT" -lt 60 ] && LEFT=60
    kubectl wait --for=condition=Ready pod -l "$SEL" -n kube-system --timeout="${LEFT}s" 2>/tmp/err || fail "$NAME: pods ($SEL) not Ready in kube-system: $(tail -c 300 /tmp/err)"
    BAD=$(kubectl get pods -n kube-system -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}' | grep -v '=Running$' || true)
    [ -z "$BAD" ] || fail "$NAME: pods not Running: $(echo "$BAD" | head -c 300)"
  done
  ok "Add-ons and AWS Load Balancer Controller are healthy"
fi

# --------------------------------------------------------------------- app
if [ "$STAGE" = "app" ] && [ $IS_DELETE = 0 ]; then
  STEP="preflight AWS Load Balancer Controller"
  kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>/tmp/err || fail "AWS Load Balancer Controller: deployment not found in kube-system"
  kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s >/dev/null 2>&1 || fail "AWS Load Balancer Controller: deployment not ready"
  for a in $ADDONS; do
    STEP="preflight add-on $a"
    S=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$a" --region "$REGION" --query addon.status --output text 2>/dev/null) || fail "EKS add-on $a: not installed"
    [ "$S" = "ACTIVE" ] || fail "EKS add-on $a: status is $S, expected ACTIVE"
  done

  STEP="render manifests"
  command -v envsubst >/dev/null 2>&1 || apt-get install -y gettext-base >/dev/null 2>&1
  # Ingress variant: HTTPS adds the certificate and redirect annotations.
  # envsubst has no conditionals, so they are built here as YAML lines.
  LISTEN_PORTS='[{"HTTP":80}]'
  INGRESS_TLS_ANNOTATIONS=""
  if [ -n "$CERTIFICATE_ARN" ]; then
    LISTEN_PORTS='[{"HTTP":80},{"HTTPS":443}]'
    INGRESS_TLS_ANNOTATIONS="    alb.ingress.kubernetes.io/certificate-arn: \"${CERTIFICATE_ARN}\"
    alb.ingress.kubernetes.io/ssl-redirect: \"443\""
  fi
  export LISTEN_PORTS INGRESS_TLS_ANNOTATIONS
  # Explicit variable list: any other $word in the template is left untouched.
  envsubst '${CLUSTER_NAME} ${REGION} ${VPC_ID} ${PUBLIC_SUBNET_IDS} ${ALB_SG_ID} ${APP_ROLE_ARN} ${DB_SECRET_ARN} ${CERTIFICATE_ARN} ${REPLICAS} ${LISTEN_PORTS} ${INGRESS_TLS_ANNOTATIONS}' < "$REPO_DIR/k8s/webapp.yaml.tpl" > /tmp/manifests.yaml || fail "Kubernetes manifests: rendering failed"

  STEP="apply namespace and app code"
  kubectl create namespace webapp --dry-run=client -o yaml | kubectl apply -f - 2>/tmp/err || fail "Namespace webapp: create failed: $(tail -c 300 /tmp/err)"
  # The app code comes straight from app/app.py in the repository.
  kubectl create configmap webapp-code -n webapp --from-file=app.py="$REPO_DIR/app/app.py" --dry-run=client -o yaml | kubectl apply -f - 2>/tmp/err || fail "ConfigMap webapp-code: apply failed: $(tail -c 300 /tmp/err)"

  STEP="apply manifests"
  kubectl apply -f /tmp/manifests.yaml 2>/tmp/err || fail "Kubernetes manifests: kubectl apply failed: $(tail -c 400 /tmp/err)"
  # Restart so pods pick up a changed app.py on stack updates (ConfigMap
  # changes alone do not restart pods).
  kubectl rollout restart deployment/webapp -n webapp >/dev/null 2>&1 || true

  if kubectl get ingress webapp -n webapp >/dev/null 2>&1; then
    STEP="wait for Ingress hostname"
    DEADLINE=$(( $(now) + 900 ))
    while true; do
      H=$(kubectl get ingress webapp -n webapp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
      [ -n "$H" ] && break
      [ "$(now)" -ge "$DEADLINE" ] && fail "Ingress webapp: no ALB hostname after 15 minutes"
      sleep 15
    done
    echo "$H" > /tmp/alb_host
  fi
  ok "Application manifests applied"
fi

if [ "$STAGE" = "app" ] && [ $IS_DELETE = 1 ]; then
  STEP="delete Ingress"
  kubectl delete ingress -n webapp --all --ignore-not-found --wait=true --timeout=5m || echo "ingress delete did not finish cleanly; checking ALB state"

  if [ -n "$ALB_SG_ID" ]; then
    STEP="wait for ALB removal"
    DEADLINE=$(( $(now) + 900 ))
    while true; do
      LBS=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?SecurityGroups!=null && contains(SecurityGroups, '${ALB_SG_ID}')].LoadBalancerArn" --output text 2>/tmp/err) || { echo "describe-load-balancers failed: $(head -c 200 /tmp/err)"; LBS="?"; }
      [ -z "$LBS" ] && break
      [ "$(now)" -ge "$DEADLINE" ] && fail "Application Load Balancer: still present 15 minutes after Ingress deletion ($LBS)"
      sleep 15
    done

    STEP="wait for ALB network interfaces"
    DEADLINE=$(( $(now) + 900 ))
    while true; do
      ENIS=$(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=group-id,Values=${ALB_SG_ID}" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/tmp/err) || { echo "describe-network-interfaces failed: $(head -c 200 /tmp/err)"; ENIS="?"; }
      [ -z "$ENIS" ] && break
      [ "$(now)" -ge "$DEADLINE" ] && fail "ALB security group $ALB_SG_ID: network interfaces still present after 15 minutes ($ENIS)"
      sleep 15
    done
  fi

  STEP="delete namespace webapp"
  kubectl delete namespace webapp --ignore-not-found --wait=true --timeout=10m 2>/tmp/err || fail "Namespace webapp: deletion did not complete: $(tail -c 300 /tmp/err)"
  ok "Ingress, ALB, network interfaces and namespace removed"
fi
fail "Deployer: nothing to do for stage $STAGE and request $REQUEST_TYPE"
