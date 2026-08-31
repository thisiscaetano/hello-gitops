#!/usr/bin/env bash
# stress.sh — load test para hello-gitops usando wrk
# Uso: ./stress.sh <BASE_URL> [CONCURRENCY] [DURATION_SECONDS]
# Exemplo: ./stress.sh https://hello-gitops.example.com 50 120

BASE_URL="${1:?Informe a URL base, ex: https://hello-gitops.example.com}"
CONCURRENCY="${2:-50}"
DURATION="${3:-120}"

ROUTES=("/" "/health" "/secret-check" "/error")

if ! command -v wrk &>/dev/null; then
  echo "Instale o wrk: sudo pacman -S wrk"
  exit 1
fi

echo "==> Stress test: ${BASE_URL}"
echo "    Concorrência : ${CONCURRENCY} connections"
echo "    Duração      : ${DURATION}s por rota"
echo ""

for route in "${ROUTES[@]}"; do
  echo "--- ${route}"
  wrk -t4 -c"${CONCURRENCY}" -d"${DURATION}s" "${BASE_URL}${route}"
  echo ""
done

echo "==> Acompanhe o HPA com:"
echo "    kubectl get hpa hello-gitops-hpa -w"
