#!/usr/bin/env bash
# Deploy exclusivo do SIGMON em servidor Ubuntu.
#
# Uso:
#   ./scripts/server/deploy.sh              # sincroniza com origin/main
#   ./scripts/server/deploy.sh fix/dev-development
#
# Fluxo:
#   1. git fetch + git reset --hard origin/<branch>
#   2. docker compose -f docker-compose.prod.yml up -d --build
#   3. aguarda o container app ficar healthy
#   4. valida webfonts e exibe a tag lida do arquivo VERSION
#
# Preserva: .env, volumes do MySQL/uploads e certificados.
# Descarta apenas alterações versionadas no checkout (comportamento do reset).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="docker-compose.prod.yml"
BRANCH="${1:-main}"
HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-600}"

cd "$APP_DIR"

fail() {
    echo "ERRO: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker não encontrado no PATH."
docker compose version >/dev/null 2>&1 || fail "plugin 'docker compose' não encontrado."
[[ -f "$COMPOSE_FILE" ]] || fail "$COMPOSE_FILE não encontrado em $APP_DIR."
[[ -f .env ]] || fail ".env não encontrado em $APP_DIR (copie de .env.prod.example)."

echo "==> [1/4] Sincronizando com origin/${BRANCH}"
BEFORE="$(git rev-parse --short HEAD)"
git fetch origin --prune
git reset --hard "origin/${BRANCH}"
AFTER="$(git rev-parse --short HEAD)"
echo "    ${BEFORE} -> ${AFTER}"

if grep -Eq '^(APP_VERSION|APP_TAG)=.+' .env; then
    echo "AVISO: APP_VERSION/APP_TAG preenchidos no .env."
    echo "       A tag do rodapé NÃO virá do arquivo VERSION."
    echo "       Deixe ambos vazios para tag automática."
fi

echo "==> [2/4] Build e subida dos containers"
docker compose -f "$COMPOSE_FILE" up -d --build

echo "==> [3/4] Aguardando app healthy (máx. ${HEALTH_TIMEOUT}s)"
APP_ID="$(docker compose -f "$COMPOSE_FILE" ps -q app | tr '\n' ' ' | awk '{print $1}')"
[[ -n "$APP_ID" ]] || fail "container app não foi criado."

ELAPSED=0
STATUS="starting"
while [[ "$ELAPSED" -lt "$HEALTH_TIMEOUT" ]]; do
    STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$APP_ID" 2>/dev/null || echo starting)"
    if [[ "$STATUS" == "healthy" ]]; then
        break
    fi
    if [[ "$STATUS" == "unhealthy" ]]; then
        docker compose -f "$COMPOSE_FILE" logs --tail=100 app >&2
        fail "app ficou unhealthy."
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
[[ "$STATUS" == "healthy" ]] || fail "app não ficou healthy em ${HEALTH_TIMEOUT}s."

echo "==> [4/4] Validando assets e tag"
docker compose -f "$COMPOSE_FILE" exec -T app \
    test -f /var/www/html/public/assets/webfonts/fa-solid-900.woff2 \
    || fail "webfonts ausentes no container (imagem antiga?)."

HTTPS_PORT="$(sed -n 's/^APP_HTTPS_PORT=//p' .env | tail -n 1 | tr -d "\"' \r")"
HTTPS_PORT="${HTTPS_PORT:-443}"
HTTP_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' \
    "https://localhost:${HTTPS_PORT}/assets/webfonts/fa-solid-900.woff2" || true)"
echo "    webfonts HTTP ${HTTP_CODE} (esperado 200)"
[[ "$HTTP_CODE" == "200" ]] || echo "AVISO: webfonts com HTTP ${HTTP_CODE}; verifique o Nginx/apps."

echo "    VERSION (repo): $(cat VERSION 2>/dev/null || echo dev)"
echo "    APP_VERSION (container): $(docker compose -f "$COMPOSE_FILE" exec -T app printenv APP_VERSION 2>/dev/null || true)"

echo "OK: SIGMON atualizado e healthy."
