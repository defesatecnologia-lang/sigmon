#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${APP_DIR}/docker-compose.prod.yml"
APP_TAG="${1:-latest}"
HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-600}"

fail() {
    echo "ERRO: $*" >&2
    exit 1
}

if [[ "$#" -gt 1 ]]; then
    fail "uso: $0 [latest|vMAJOR.MINOR.PATCH]"
fi

if [[ "$APP_TAG" != "latest" && ! "$APP_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "tag inválida: ${APP_TAG}. Use 'latest' ou uma versão como v1.2.3."
fi

[[ -f "$COMPOSE_FILE" ]] || fail "docker-compose.prod.yml não encontrado em ${APP_DIR}."
[[ -f "${APP_DIR}/.env" ]] || fail ".env não encontrado em ${APP_DIR}."
command -v docker >/dev/null 2>&1 || fail "docker não encontrado no PATH."
docker compose version >/dev/null 2>&1 || fail "plugin 'docker compose' não encontrado."
[[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || fail "DEPLOY_HEALTH_TIMEOUT deve ser um número de segundos."

export APP_TAG
cd "$APP_DIR"

echo "==> Baixando imagem SIGMON (${APP_TAG})"
docker compose -f "$COMPOSE_FILE" pull app

echo "==> Atualizando o container"
docker compose -f "$COMPOSE_FILE" up -d --no-build app

APP_ID="$(docker compose -f "$COMPOSE_FILE" ps -q app | tr -d '\r\n')"
[[ -n "$APP_ID" ]] || fail "container app não foi criado."

echo "==> Aguardando container healthy (máx. ${HEALTH_TIMEOUT}s)"
ELAPSED=0
STATUS="starting"
while [[ "$ELAPSED" -lt "$HEALTH_TIMEOUT" ]]; do
    STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$APP_ID" 2>/dev/null || echo starting)"
    if [[ "$STATUS" == "healthy" ]]; then
        break
    fi
    if [[ "$STATUS" == "unhealthy" || "$STATUS" == "no-healthcheck" ]]; then
        docker compose -f "$COMPOSE_FILE" logs --tail=100 app >&2
        fail "container app ficou ${STATUS}."
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

[[ "$STATUS" == "healthy" ]] || fail "app não ficou healthy em ${HEALTH_TIMEOUT}s."

echo "OK: SIGMON atualizado para ${APP_TAG} e healthy."
