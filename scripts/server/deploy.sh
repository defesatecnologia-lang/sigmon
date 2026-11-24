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
#   4. importa config/DB/private/proprios-pml.sql em bancos ja existentes
#   5. valida webfonts e exibe a tag lida do arquivo VERSION
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

# Importa os dados proprietarios de Londrina de forma idempotente.
# O entrypoint do MySQL so roda /docker-entrypoint-initdb.d em banco novo;
# em banco existente a importacao precisa ser feita aqui.
import_private_seed() {
    local seed_file="config/DB/private/proprios-pml.sql"
    if [[ ! -f "$seed_file" ]]; then
        echo "    ${seed_file} ausente — pulando importacao."
        return 0
    fi

    local seed_hash
    seed_hash="$(sha256sum "$seed_file" | awk '{print $1}')"

    docker compose -f "$COMPOSE_FILE" exec -T db sh -c '
MYSQL_PWD="$MYSQL_PASSWORD" mysql -u "$MYSQL_USER" "$MYSQL_DATABASE" <<SQL
CREATE TABLE IF NOT EXISTS sigmon_seed_control (
  arquivo VARCHAR(191) NOT NULL PRIMARY KEY,
  sha256 CHAR(64) NOT NULL,
  aplicado_em DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL
' >/dev/null

    local applied
    applied="$(docker compose -f "$COMPOSE_FILE" exec -T -e SEED_HASH="$seed_hash" db sh -c '
MYSQL_PWD="$MYSQL_PASSWORD" mysql -N -B -u "$MYSQL_USER" "$MYSQL_DATABASE" <<SQL
SELECT COUNT(*) FROM sigmon_seed_control
 WHERE arquivo = "proprios-pml.sql" AND sha256 = "$SEED_HASH";
SQL
' | tr -d '\r')"

    if [[ "$applied" == "1" ]]; then
        echo "    proprios-pml.sql ja aplicado (hash ${seed_hash:0:12}...)."
        return 0
    fi

    echo "    importando proprios-pml.sql (hash ${seed_hash:0:12}...)"
    {
        echo 'START TRANSACTION;'
        cat "$seed_file"
        echo 'COMMIT;'
    } | docker compose -f "$COMPOSE_FILE" exec -T db sh -c '
MYSQL_PWD="$MYSQL_PASSWORD" mysql --default-character-set=utf8mb4 -u "$MYSQL_USER" "$MYSQL_DATABASE"
'

    docker compose -f "$COMPOSE_FILE" exec -T -e SEED_HASH="$seed_hash" db sh -c '
MYSQL_PWD="$MYSQL_PASSWORD" mysql -u "$MYSQL_USER" "$MYSQL_DATABASE" <<SQL
INSERT INTO sigmon_seed_control (arquivo, sha256)
VALUES ("proprios-pml.sql", "$SEED_HASH")
ON DUPLICATE KEY UPDATE sha256 = VALUES(sha256), aplicado_em = CURRENT_TIMESTAMP;
SQL
' >/dev/null
    echo "    OK — dados proprietarios importados."
}

command -v docker >/dev/null 2>&1 || fail "docker não encontrado no PATH."
docker compose version >/dev/null 2>&1 || fail "plugin 'docker compose' não encontrado."
[[ -f "$COMPOSE_FILE" ]] || fail "$COMPOSE_FILE não encontrado em $APP_DIR."
[[ -f .env ]] || fail ".env não encontrado em $APP_DIR (copie de .env.prod.example)."

echo "==> [1/5] Sincronizando com origin/${BRANCH}"
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

echo "==> [2/5] Build e subida dos containers"
docker compose -f "$COMPOSE_FILE" up -d --build

echo "==> [3/5] Aguardando app healthy (máx. ${HEALTH_TIMEOUT}s)"
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

echo "==> [4/5] Importando dados proprietários (proprios-pml.sql)"
import_private_seed

echo "==> [5/5] Validando assets e tag"
docker compose -f "$COMPOSE_FILE" exec -T app \
    test -f /var/www/html/public/assets/webfonts/fa-solid-900.woff2 \
    || fail "webfonts ausentes no container (imagem antiga?)."

HTTPS_PORT="$(sed -n 's/^APP_HTTPS_PORT=//p' .env | tail -n 1 | tr -d "\"' \r")"
HTTPS_PORT="${HTTPS_PORT:-443}"

for pattern in 'fontawesome-*.css' 'home-dashboard-*.css' 'main-*.css'; do
    ASSET_FILE="$(docker compose -f "$COMPOSE_FILE" exec -T app \
        sh -c "ls /var/www/html/public/assets/${pattern} 2>/dev/null | head -n 1" | tr -d '\r')"
    if [[ -z "$ASSET_FILE" ]]; then
        echo "AVISO: nenhum arquivo ${pattern} no container."
        continue
    fi
    ASSET_URL="/assets/$(basename "$ASSET_FILE")"
    ASSET_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' \
        "https://localhost:${HTTPS_PORT}${ASSET_URL}" || true)"
    echo "    ${ASSET_URL}: HTTP ${ASSET_CODE}"
    [[ "$ASSET_CODE" == "200" ]] || echo "AVISO: ${ASSET_URL} com HTTP ${ASSET_CODE}."

    # O PurgeCSS ja removeu os glyphs dos icones em producao porque o stage de
    # build do Docker nao copiava os diretorios PHP. Verificar o conteudo do CSS
    # evita que um deploy "200 OK" esconda icones ausentes novamente.
    if [[ "$pattern" == 'fontawesome-*.css' && "$ASSET_CODE" == "200" ]]; then
        if curl -k -s "https://localhost:${HTTPS_PORT}${ASSET_URL}" \
            | grep -q 'fa-user-shield'; then
            echo "    glyphs dos icones presentes no CSS."
        else
            fail "CSS do Font Awesome sem os glyphs (fa-user-shield ausente)."
        fi
    fi
done

HTTP_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' \
    "https://localhost:${HTTPS_PORT}/assets/webfonts/fa-solid-900.woff2" || true)"
echo "    /assets/webfonts/fa-solid-900.woff2: HTTP ${HTTP_CODE}"
[[ "$HTTP_CODE" == "200" ]] || echo "AVISO: webfonts com HTTP ${HTTP_CODE}; verifique o Nginx/apps."

echo "    VERSION (repo): $(cat VERSION 2>/dev/null || echo dev)"
echo "    APP_VERSION (container): $(docker compose -f "$COMPOSE_FILE" exec -T app printenv APP_VERSION 2>/dev/null || true)"

echo "OK: SIGMON atualizado e healthy."
