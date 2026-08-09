#!/usr/bin/env bash
# Deploy hidden_sync.py to the current kubectl context and point myhn.html at it.
# Idempotent: re-run after changing hidden_sync.py or k8s.yaml.
set -euo pipefail
cd "$(dirname "$0")"

HTML=myhn.html

# Reuse the secret path already in the html, otherwise generate one
SECRET_PATH=$(grep -oE "SYNC_ENDPOINT = 'https?://[^']*(/hn-[0-9a-f]+)'" "$HTML" | grep -oE '/hn-[0-9a-f]+' || true)
if [ -z "$SECRET_PATH" ]; then
    SECRET_PATH="/hn-$(openssl rand -hex 8)"
    echo "Generated new secret path: $SECRET_PATH"
fi

render() {
    sed -e "s|__SECRET_PATH__|$SECRET_PATH|" -e "s|__SYNC_HOST__|$1|" k8s.yaml
}

kubectl create configmap hidden-sync-script --from-file=hidden_sync.py --dry-run=client -o yaml | kubectl apply -f -

# The TLS cert hostname is derived from the LB IP (<ip>.sslip.io), which is
# only known once the Service exists: apply, wait for the IP, apply again.
EXTERNAL_IP=$(kubectl get svc hidden-sync -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [ -z "$EXTERNAL_IP" ]; then
    render "pending.sslip.io" | kubectl apply -f -
    echo "Waiting for LoadBalancer external IP..."
    for _ in $(seq 1 60); do
        EXTERNAL_IP=$(kubectl get svc hidden-sync -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        [ -n "$EXTERNAL_IP" ] && break
        sleep 5
    done
    if [ -z "$EXTERNAL_IP" ]; then
        echo "ERROR: no external IP after 5 minutes; check: kubectl get svc hidden-sync" >&2
        exit 1
    fi
fi

SYNC_HOST="$EXTERNAL_IP.sslip.io"
render "$SYNC_HOST" | kubectl apply -f -
kubectl rollout restart deployment/hidden-sync
kubectl rollout status deployment/hidden-sync --timeout=120s

ENDPOINT="https://$SYNC_HOST$SECRET_PATH"
CURRENT=$(grep -oE "SYNC_ENDPOINT = '[^']*'" "$HTML" | sed "s/SYNC_ENDPOINT = '\(.*\)'/\1/")
if [ "$CURRENT" != "$ENDPOINT" ]; then
    sed -i "s|SYNC_ENDPOINT = '[^']*'|SYNC_ENDPOINT = '$ENDPOINT'|" "$HTML"
    echo "Updated SYNC_ENDPOINT: '$CURRENT' -> '$ENDPOINT'"
else
    echo "SYNC_ENDPOINT unchanged: $ENDPOINT"
fi

echo "Smoke test (first run may take ~1 min while the TLS cert is issued):"
for i in $(seq 1 12); do
    if curl -sf --max-time 10 "$ENDPOINT"; then
        echo " <- GET OK"
        exit 0
    fi
    sleep 10
done
echo "ERROR: endpoint not answering; check: kubectl logs deployment/hidden-sync -c tls" >&2
exit 1
