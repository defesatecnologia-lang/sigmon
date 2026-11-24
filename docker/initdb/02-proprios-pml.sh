# Hook de inicializacao do MySQL (primeira subida, diretorio de dados vazio).
# E carregado via `source` pelo docker-entrypoint.sh — NAO marcar como executavel.
# Em bancos ja existentes o entrypoint nao roda; o import e feito pelo
# scripts/server/deploy.sh usando a mesma tabela sigmon_seed_control.
SEED_FILE=/sigmon-private/proprios-pml.sql

if [ -f "$SEED_FILE" ]; then
    SEED_HASH="$(sha256sum "$SEED_FILE" | awk '{print $1}')"

    docker_process_sql <<SQL
CREATE TABLE IF NOT EXISTS sigmon_seed_control (
  arquivo VARCHAR(191) NOT NULL PRIMARY KEY,
  sha256 CHAR(64) NOT NULL,
  aplicado_em DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL

    SEED_APPLIED="$(docker_process_sql -N -B <<SQL | tr -d '\r'
SELECT COUNT(*) FROM sigmon_seed_control
 WHERE arquivo = "proprios-pml.sql" AND sha256 = "$SEED_HASH";
SQL
)"

    if [ "$SEED_APPLIED" != "1" ]; then
        echo "SIGMON: importando dados proprietarios (proprios-pml.sql)..."
        docker_process_sql < "$SEED_FILE"
        docker_process_sql <<SQL
INSERT INTO sigmon_seed_control (arquivo, sha256)
VALUES ("proprios-pml.sql", "$SEED_HASH")
ON DUPLICATE KEY UPDATE sha256 = VALUES(sha256), aplicado_em = CURRENT_TIMESTAMP;
SQL
    else
        echo "SIGMON: proprios-pml.sql ja aplicado (hash $SEED_HASH)."
    fi
else
    echo "SIGMON: $SEED_FILE ausente — nada a importar."
fi
