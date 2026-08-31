#!/usr/bin/env bash
# stress-curl.sh — load test para hello-gitops usando curl + xargs
# Uso: ./stress-curl.sh <BASE_URL> [TOTAL_REQUESTS] [CONCURRENCY]
# Exemplo: ./stress-curl.sh https://hello-gitops.example.com 500 20

BASE_URL="${1:?Informe a URL base, ex: https://hello-gitops.example.com}"
TOTAL="${2:-500}"
CONCURRENCY="${3:-20}"

ROUTES=("/" "/health" "/secret-check" "/error")

echo "==> Stress test: ${BASE_URL}"
echo "    Total de reqs : ${TOTAL} por rota"
echo "    Concorrência  : ${CONCURRENCY} paralelo"
echo ""

do_request() {
  curl -s -o /dev/null -w "%{http_code}\n" "$1"
}
export -f do_request

for route in "${ROUTES[@]}"; do
  url="${BASE_URL}${route}"
  echo "--- ${route}"
  printf '%s\n' $(seq 1 $TOTAL | xargs -I{} echo "$url") \
    | xargs -P "${CONCURRENCY}" -I{} bash -c 'do_request "$@"' _ {} \
    | sort | uniq -c | awk '{print "    HTTP "$2": "$1" reqs"}'
  echo ""
done

echo "==> Acompanhe o HPA com:"
echo "    kubectl get hpa hello-gitops-hpa -w"
