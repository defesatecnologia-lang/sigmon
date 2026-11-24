# Deploy — GitHub Actions e servidor

## Fluxo

1. Depois que o CI da branch `main` termina com sucesso, o CD lê `VERSION`, cria a tag `vX.Y.Z`, publica o GitHub Release e envia as imagens versionada, `major.minor`, `latest` e SHA ao GHCR.
2. Se a tag/release da versão já existir, o workflow não a recria nem republica.
3. Para cada nova release, incremente `VERSION` (formato `vX.Y.Z`) antes de mesclar as mudanças em `main`.

> O CD publica a imagem, mas não conecta ao servidor. O deploy é executado localmente no servidor pelo script abaixo.

Se o job de publicação do GHCR falhar com `permission_denied` ou `write_package`,
configure o secret `GHCR_TOKEN` nas configurações do repositório. Use um Personal
Access Token classic com permissão `write:packages` de uma conta autorizada a
publicar pacotes na organização. O token é usado somente no login do GHCR; não o
adicione ao código nem o compartilhe nos logs.

## TLS por padrão (intranet)

O container `app` termina TLS no próprio Nginx:

| Host | Container | Finalidade                     |
|------|-----------|--------------------------------|
| `${APP_PORT:-80}`   | `8080` | Redirect 301 → HTTPS      |
| `${APP_HTTPS_PORT:-443}` | `8443` | HTTPS (TLS) com a aplicação |

- **Sem certificado montado** → o entrypoint gera certificado **self-signed** automaticamente (o browser mostra aviso; aceitável em intranet corporativa; o acesso funciona via `https://<servidor>/`).
- **Com CA interna** → copie `server.crt`/`server.key` da sua CA para o volume `nginx_certs` e reinicie:

```bash
docker cp server.crt sigmon-app-1:/etc/nginx/certs/server.crt
docker cp server.key sigmon-app-1:/etc/nginx/certs/server.key
docker compose -f docker-compose.prod.yml restart app
```

- Os clientes devem confiar na CA interna (ou aceitar o self-signed).
- Cookies de sessão são `Secure` (o Nginx detecta `$https` automaticamente).

## Portas customizadas (ex.: acesso em `https://ip:8000`)

Quando o servidor hospeda vários sistemas, ajuste apenas o `.env` — não é preciso editar o compose:

```env
APP_PORT=8001        # HTTP (apenas redirect) -> container 8080
APP_HTTPS_PORT=8000  # HTTPS (aplicação) -> container 8443
```

```bash
docker compose -f docker-compose.prod.yml up -d --build
curl -k https://localhost:8000/
```

O redirect `HTTP -> HTTPS` gerado pelo entrypoint usa `APP_HTTPS_PORT`, então
`http://ip:8001` vai para `https://ip:8000/` (e não para `https://ip/` na porta
443, onde pode estar outro sistema). Se `APP_HTTPS_PORT=443`, o redirect fica
sem porta, como no padrão.

> **MySQL:** use `mysql:8.4` (LTS). Não existe tag oficial `mysql:8.5`; a tag
> `mysql:lts` atualmente aponta para `9.7` (major diferente) e só deve ser
> adotada após migração e testes.

## Pré-requisitos no servidor (Ubuntu Server)

```bash
# Diretório da aplicação
sudo mkdir -p /opt/sigmon
sudo chown $USER:$USER /opt/sigmon

# Particao dedicada para dados do MySQL (RAID6 montada em /mnt/sstv-sigmon).
# O container do MySQL roda como uid/gid 999.
sudo mkdir -p /mnt/sstv-sigmon/mysql
sudo chown -R 999:999 /mnt/sstv-sigmon/mysql
sudo chmod 750 /mnt/sstv-sigmon/mysql

# Estrutura esperada em /opt/sigmon
/opt/sigmon/
├── docker-compose.prod.yml    # copiado do repositório
├── .env                       # criado manualmente (não versionado)
└── config/
    └── DB/
        └── cftv_gml.sql       # schema inicial (cópia do repo)
```

> **Dados do banco:** `docker-compose.prod.yml` monta `${DB_DATA_PATH:-/mnt/sstv-sigmon/mysql}` em `/var/lib/mysql` (não usa volume nomeado). Garanta que `/mnt/sstv-sigmon` esteja montado (ex.: entrada em `/etc/fstab`) antes de subir os containers. O `01-schema.sql` em `docker-entrypoint-initdb.d` só é executado quando o diretório de dados está vazio (primeira inicialização).

## Arquivo `.env`

Crie `/opt/sigmon/.env` (baseado em `.env.prod.example`, com senhas fortes e únicas):

```bash
DB_ROOT_PASSWORD=senha_root_forte
DB_PASS=senha_usuario_forte
DB_NAME=cftv_gml
DB_USER=cftv_user

# Caminho dos dados do MySQL no host (particao dedicada RAID6)
DB_DATA_PATH=/mnt/sstv-sigmon/mysql

# Acesso HTTPS/HTTP no host (defaults: 443 / 80)
APP_PORT=80
APP_HTTPS_PORT=443

# Sentry (opcional; em branco = desativado)
SENTRY_DSN=

# IPs de proxy confiáveis (vazio = nenhum)
PROXY_TRUSTED_IPS=
```

## Instalação inicial (primeira vez)

```bash
cd /opt/sigmon

# Instalar Docker se não tiver
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Baixar docker-compose.prod.yml e .env de exemplo do repositório
curl -O https://raw.githubusercontent.com/defesatecnologia-lang/sigmon/main/docker-compose.prod.yml
curl -o .env.prod.example https://raw.githubusercontent.com/defesatecnologia-lang/sigmon/main/.env.prod.example
mkdir -p scripts/server
curl -o scripts/server/deploy.sh https://raw.githubusercontent.com/defesatecnologia-lang/sigmon/main/scripts/server/deploy.sh
chmod +x scripts/server/deploy.sh
cp .env.prod.example .env
# editar .env com senhas e DB_DATA_PATH

# Schema inicial (usado pelo MySQL apenas na primeira inicialização do diretório de dados)
mkdir -p config/DB
curl -o config/DB/cftv_gml.sql https://raw.githubusercontent.com/defesatecnologia-lang/sigmon/main/config/DB/cftv_gml.sql

# Subir (imagem do GHCR + schema init no MySQL se DB_DATA_PATH estiver vazio)
docker compose -f docker-compose.prod.yml up -d
```

Acesse `https://<servidor>/` (aceite o certificado na primeira vez).

> **Erro `ERROR 1418 (HY000)` ao importar `cftv_gml.sql`:** a função
> `proximo_codigo_equipamento()` é `NOT DETERMINISTIC` / `MODIFIES SQL DATA`.
> Com binary log ativado (padrão no MySQL 8.4), o servidor recusa criá-la a
> menos que `log_bin_trust_function_creators=1`. O `docker-compose.prod.yml`
> já passa essa flag. Se você importar o SQL com um script próprio ou outro
> servidor MySQL, adicione a opção ao servidor (ou `SET GLOBAL
> log_bin_trust_function_creators = 1;` como root antes da importação) e
> reimporte o schema **do zero** — a importação interrompida deixa triggers,
> procedures e eventos faltando.

## Testar manualmente

```bash
docker compose -f docker-compose.prod.yml ps   # db + app healthy
curl -k https://localhost/                     # 200 (front controller)
curl -I http://localhost/                      # 301 -> https
```

### `sigmon-db-1` unhealthy na primeira subida

Se o `db` fica `unhealthy` e o `app` não inicia (`condition: service_healthy`),
colete antes de mudar qualquer coisa:

```bash
docker compose -f docker-compose.prod.yml logs --tail=200 db
docker inspect --format '{{json .State.Health}}' sigmon-db-1 | jq -r '.Log[-1].Output'
ls -ld "${DB_DATA_PATH:-/mnt/sstv-sigmon/mysql}"
df -h "${DB_DATA_PATH:-/mnt/sstv-sigmon/mysql}"
```

Causas comuns:

- **inicialização lenta em RAID6**: `initialize` + import do schema levou ~5 min e o healthcheck antigo (180s) marcava o `db` como `unhealthy` antes do MySQL abrir a porta 3306. O compose agora usa `start_period: 360s` — basta atualizar o compose e subir de novo;
- diretório de dados sem `chown -R 999:999` (uid do MySQL no container) ou sem espaço;
- `.env` editado **depois** da primeira inicialização — `MYSQL_USER`/`MYSQL_PASSWORD` só são criados quando o diretório está vazio;
- import do `cftv_gml.sql` falhou (veja `ERROR 1418` acima): o healthcheck espera `SELECT 1 FROM usuarios`, então o banco nunca fica healthy se a tabela não existe.

> Os `[ERROR] Event Scheduler ... Query execution was interrupted` no log durante
> o `Stopping temporary server` são esperados: os eventos do schema estavam
> ativos enquanto o entrypoint encerrava o servidor temporário. Não indicam
> falha na importação.

Se for instalação nova e o diretório não contém dados a preservar:

```bash
docker compose -f docker-compose.prod.yml down
sudo rm -rf /mnt/sstv-sigmon/mysql/*
sudo chown -R 999:999 /mnt/sstv-sigmon/mysql
sudo chmod 750 /mnt/sstv-sigmon/mysql
docker compose -f docker-compose.prod.yml up -d --build
```

> ⛔ O `rm -rf` acima apaga todo o banco. Em servidor com dados, faça backup
> (`scripts/backup.sh`) e corrija apenas permissões/credenciais.

### Ícones do menu/grid não aparecem

O CSS do Font Awesome referencia `assets/webfonts/fa-solid-900.woff2`. As
webfonts são geradas pelo `npm run build` em `public/assets/webfonts/` e são
**gitignored** — por isso precisam ser copiadas do stage de build para a imagem
final (já feito no `Dockerfile.nginx`).

Para conferir no servidor:

```bash
docker compose -f docker-compose.prod.yml exec app ls -la /var/www/html/public/assets/webfonts
curl -k -o /dev/null -w '%{http_code}\n' https://localhost:8000/assets/webfonts/fa-solid-900.woff2
# esperado: 200
```

Se der `404`, a imagem em execução é antiga: rode `up -d --build` novamente.

### Tag automática (rodapé)

A versão exibida no rodapé vem da variável `APP_RELEASE_TAG` embutida na imagem pelo CD. O arquivo `VERSION` é a fonte da versão e a tag correspondente é criada automaticamente quando `main` é atualizada.

Para atualizações pelo servidor, configure `.env` assim:

```env
APP_TAG=latest
APP_VERSION=
```

Depois disso, execute o script no servidor para atualizar o sistema.

## Atualização pelo script (servidor)

Com o repositório disponível em `/opt/sigmon`, execute:

```bash
cd /opt/sigmon
./scripts/server/deploy.sh
```

O script baixa a imagem `latest`, recria o container da aplicação e espera ficar saudável. Para usar uma versão fixa:

```bash
./scripts/server/deploy.sh v1.2.3
```

O usuário que executa o script precisa ter acesso ao Docker. Se a imagem do GHCR for privada, faça `docker login ghcr.io` antes.
