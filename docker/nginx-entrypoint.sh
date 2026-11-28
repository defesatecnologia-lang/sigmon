#!/bin/sh
# ============================================
# Entrypoint do container app (Nginx + PHP-FPM).
# Roda como www-data (uid 33) — nao escala privilegio.
#
# Modos:
#   - SIGMON_HTTP_ONLY=1: HTTP na 8080 servindo a aplicacao (sem TLS).
#   - SIGMON_HTTP_ONLY=0: HTTPS na 8443 + redirect 301 de 8080 -> HTTPS.
#
# Em modo TLS, garante certificados em /etc/nginx/certs/:
#   - usa o montado/CA interna se existir (server.crt/server.key);
#   - caso contrario gera um self-signed (fallback para intranet).
# ============================================
set -e

CONF_DIR="${CONF_DIR:-/run/nginx_conf}"
CERT_DIR="/etc/nginx/certs"
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"
LOCATIONS_CONF="/etc/nginx/locations.conf"
HTTP_ONLY="${SIGMON_HTTP_ONLY:-1}"

# Normaliza o valor: remove CR (arquivos .env editados no Windows) e espacos.
# Sem isso, "1\r" ou " 1 " nao casariam com o case abaixo.
HTTP_ONLY=$(printf '%s' "$HTTP_ONLY" | tr -d '\r' | tr -d '[:space:]')
echo "[entrypoint] SIGMON_HTTP_ONLY='$HTTP_ONLY'"

mkdir -p "$CONF_DIR" "$CERT_DIR"

case "$HTTP_ONLY" in
    1|true|TRUE|yes|YES|on|ON)
        cat > "$CONF_DIR/server.conf" <<EOF
server {
    listen 8080 default_server;
    server_name _;

    include $LOCATIONS_CONF;
}
EOF
        echo "[entrypoint] Modo HTTP_ONLY ativo — servindo aplicacao em 8080 (sem redirect TLS)."
        ;;
    *)
        if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
            echo "[entrypoint] Nenhum certificado em $CERT_DIR — gerando self-signed (substitua por CA interna se necessario)."
            openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
                -keyout "$KEY_FILE" -out "$CERT_FILE" \
                -subj "/C=BR/O=Sistema Cameras e Alarmes/CN=sigmon" \
                >/dev/null 2>&1
            chmod 600 "$KEY_FILE"
            chmod 644 "$CERT_FILE"
        fi

        # O nginx monta $https automaticamente ("on" em conexoes TLS);
        # portanto cookie Secure + HSTS da aplicacao funcionam no HTTPS.
        #
        # O redirect HTTP -> HTTPS precisa preservar a porta publica do HTTPS no host.
        # Sem isso, um acesso em http://ip:8001 cairia em https://ip/ (443), onde pode
        # estar outro sistema. APP_HTTPS_PORT e injetado pelo docker-compose.prod.yml.
        PUBLIC_HTTPS_PORT="${APP_HTTPS_PORT:-443}"
        case "$PUBLIC_HTTPS_PORT" in
            ''|443) HTTPS_AUTHORITY="\$host" ;;
            *[!0-9]*)
                echo "[entrypoint] APP_HTTPS_PORT invalido: $PUBLIC_HTTPS_PORT" >&2
                exit 1
                ;;
            *) HTTPS_AUTHORITY="\$host:${PUBLIC_HTTPS_PORT}" ;;
        esac

        cat > "$CONF_DIR/server.conf" <<EOF
server {
    listen 8080 default_server;
    server_name _;
    return 301 https://${HTTPS_AUTHORITY}\$request_uri;
}

server {
    listen 8443 ssl default_server;
    server_name _;

    # HTTP/2 desligado explicitamente (superficie dos CVEs 2026 de HTTP/2).
    http2 off;

    ssl_certificate     $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_prefer_server_ciphers off;

    include $LOCATIONS_CONF;
}
EOF
        ;;
esac

echo "[entrypoint] Config de servidor gerada em $CONF_DIR/server.conf"

nginx -g 'daemon off;' &
exec php-fpm --nodaemonize
