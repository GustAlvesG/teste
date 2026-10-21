#!/usr/bin/env bash
#
# homolog.sh - monta e mantem a homologacao /homolog ao lado da producao
#              (espacos.clubedosfuncionarios.com.br, VM da DMZ)
#
# Uso (sempre com sudo, a partir da sua sessao de administrador):
#   sudo bash homolog.sh levantamento   # so leitura: confere a VM e grava um relatorio
#   sudo bash homolog.sh instalar       # usuario, pasta, .env, build e servico (nao toca no nginx)
#   sudo bash homolog.sh nginx          # senha de acesso + location /homolog + reload
#   sudo bash homolog.sh verificar      # testes de ponta a ponta (pode repetir quando quiser)
#   sudo bash homolog.sh deploy         # atualizacoes futuras da branch homolog
#   sudo bash homolog.sh rollback       # desfaz nginx + servico (mantem pasta e usuario)
#
# Garantias deste script:
#   - nao altera a pasta, o .env, o servico nem o "location /" da producao;
#   - nunca imprime valores do .env (so nomes de variaveis);
#   - a homologacao escuta so em 127.0.0.1 e entra pelo 443 que ja existe;
#   - toda edicao do nginx tem backup fora de /etc/nginx e e desfeita se o nginx -t falhar.
#
set -Eeuo pipefail

# ======================= AJUSTE SE O LEVANTAMENTO MOSTRAR OUTRO VALOR =======================
DOMINIO="espacos.clubedosfuncionarios.com.br"
PROD_SERVICO="nextjs-app"
PROD_DIR="/opt/nextjs-app"
PROD_PORTA="3000"

HML_SERVICO="espacos-homolog"
HML_USER="espacos-hml"              # usuario PROPRIO: a homologacao nao le o .env da producao
HML_DIR="/opt/espacos-homolog"
HML_PORTA="3001"
REPO_URL="https://github.com/Erick-Porto/clubeel.git"
BRANCH="homolog"

# Na homologacao ficam VAZIAS (funcao desligada) por padrao. Troque para 0 so com motivo.
DESLIGAR_PAGAMENTO=1                # eRede sem credenciais: nenhuma cobranca real sai da homologacao
DESLIGAR_WHATSAPP=1                 # o webhook do WhatsApp so aponta para a producao

# Limites da homologacao (para nunca derrubar a producao na mesma VM)
HML_MEMORIA_MAX="768M"              # servico em execucao
BUILD_MEMORIA_MAX="2G"              # npm ci / next build
BUILD_HEAP_MB="1536"                # heap do Node durante o build

HTPASSWD="/etc/nginx/.htpasswd-homolog"
SNIPPET="/etc/nginx/snippets/espacos-homolog.conf"
SNIPPET_PROXY="/etc/nginx/snippets/espacos-homolog-proxy.conf"
BACKUP_DIR="/root/backup-homolog"   # fora de /etc/nginx: backup ali seria carregado pelo nginx
CURL_EXTRA="${CURL_EXTRA:-}"        # uso interno de teste; deixe vazio
# ============================================================================================

UNIT="/etc/systemd/system/${HML_SERVICO}.service"
# Testes locais nunca passam por proxy HTTP, se a VM tiver um configurado.
export NO_PROXY="127.0.0.1,localhost,${DOMINIO}${NO_PROXY:+,$NO_PROXY}" no_proxy="127.0.0.1,localhost,${DOMINIO}${no_proxy:+,$no_proxy}"
MARCA_INCLUDE="# homologacao /homolog (homolog.sh)"
TS="$(date +%Y%m%d-%H%M%S)"

ok()     { printf '  [ok] %s\n' "$*"; }
info()   { printf '  [..] %s\n' "$*"; }
aviso()  { printf '  [!!] %s\n' "$*"; }
falha()  { printf '\n  [XX] %s\n\n' "$*" >&2; exit 1; }
secao()  { printf '\n=== %s ===\n' "$*"; }

exige_root() { [ "$(id -u)" -eq 0 ] || falha "Rode com sudo: sudo bash $0 $*"; }

confirmar() {
  local r
  read -rp "  >> $1 [s/N] " r || true
  [[ "$r" =~ ^[sS]$ ]]
}

curl_local() {
  # Fala com o nginx desta VM pelo nome do site, sem depender do NAT (sem hairpin).
  # shellcheck disable=SC2086
  curl -sS --noproxy "*" --max-time 20 --resolve "${DOMINIO}:443:127.0.0.1" $CURL_EXTRA "$@"
}

como_hml() {
  # Executa como o usuario da homologacao, a partir de uma pasta que ele consegue ler.
  ( cd "$HML_DIR" 2>/dev/null || cd /; sudo -u "$HML_USER" -H "$@" )
}

limitado() {
  # npm ci / build dentro de um cgroup proprio: se estourar memoria, morre so o build.
  local cpus quota
  cpus="$(nproc)"
  if [ "$cpus" -gt 1 ]; then quota="$(( (cpus - 1) * 100 ))%"; else quota="100%"; fi
  ( cd "$HML_DIR" && systemd-run --quiet --scope \
      -p MemoryMax="$BUILD_MEMORIA_MAX" -p CPUQuota="$quota" -- \
      sudo -u "$HML_USER" -H env NEXT_TELEMETRY_DISABLED=1 \
      NODE_OPTIONS="--max-old-space-size=${BUILD_HEAP_MB}" nice -n 10 "$@" )
}

nomes_env() {
  # Lista so os NOMES das variaveis de um .env (nunca os valores).
  grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$1" \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' | sort
}

valor_vazio() {
  # 0 se a variavel existe e esta vazia (ou nao existe); nao imprime nada.
  local v
  v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" | tail -1 | sed -E 's/^[^=]*=//; s/^["'\'']//; s/["'\'']$//' || true)"
  [ -z "$v" ]
}

set_env() {
  # set_env NOME  (o valor vem da variavel de shell VALOR). Substitui ou acrescenta,
  # remove duplicatas e mantem 600/dono. Nao ecoa o valor.
  local nome="$1" f="$HML_DIR/.env" tmp
  tmp="$(mktemp "$HML_DIR/.env.tmp.XXXXXX")"
  NOME="$nome" VALOR="${VALOR:-}" awk '
    BEGIN { n = ENVIRON["NOME"]; v = ENVIRON["VALOR"]; feito = 0 }
    $0 ~ ("^[[:space:]]*(export[[:space:]]+)?" n "=") { if (!feito) { print n "=" v; feito = 1 }; next }
    { print }
    END { if (!feito) print n "=" v }
  ' "$f" > "$tmp"
  chown "$HML_USER:$HML_USER" "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}

acha_site() {
  # Arquivo (real, sem symlink) com o server 443 do dominio.
  local f
  for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -f "$f" ] || continue
    if grep -qE "server_name[^;]*${DOMINIO//./\\.}" "$f" && grep -qE "listen[^;]*443" "$f"; then
      readlink -f "$f"
    fi
  done | sort -u
}

insere_include() {
  # Imprime o arquivo $1 com o include inserido antes do primeiro "location" do server 443
  # do dominio. Sai com 3 se nao encontrar exatamente um bloco assim.
  awk -v dom="$DOMINIO" -v inc="    include ${SNIPPET};  ${MARCA_INCLUDE}" '
    function abre(s,  t) { t = s; return gsub(/[{]/, "", t) }
    function fecha(s, t) { t = s; return gsub(/[}]/, "", t) }
    BEGIN { gsub(/\./, "\\.", dom); prof = 0; alvos = 0 }
    {
      linha[NR] = $0
      s = $0; sub(/#.*/, "", s)
      if (prof == 0 && s ~ /^[[:space:]]*server[[:space:]]*[{]/) { dentro = 1; tem443 = 0; temdom = 0; primloc = 0; ini = NR }
      if (dentro && prof == 1) {
        if (s ~ /^[[:space:]]*listen[[:space:]][^;]*443/) tem443 = 1
        if (s ~ ("^[[:space:]]*server_name[[:space:]][^;]*" dom "([[:space:];]|$)")) temdom = 1
        if (!primloc && s ~ /^[[:space:]]*location[[:space:]]/) primloc = NR
      }
      prof += abre(s) - fecha(s)
      if (dentro && prof == 0) {
        # bloco "server { ... }" inteiro numa linha so: nao sei inserir com seguranca
        if (NR == ini && s ~ /listen[[:space:]][^;]*443/ && s ~ ("server_name[[:space:]][^;]*" dom "([[:space:];]|$)")) invalido = 1
        if (tem443 && temdom) { alvos++; alvo = (primloc ? primloc : NR) }
        dentro = 0
      }
    }
    END {
      if (invalido || alvos != 1) exit 3
      for (i = 1; i <= NR; i++) { if (i == alvo) print inc; print linha[i] }
    }' "$1"
}

espera_porta() {
  local porta="$1"
  for _ in $(seq 1 40); do
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${porta}$" && return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------------------------------
cmd_levantamento() {
  exige_root levantamento
  set +e
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local rel="$BACKUP_DIR/levantamento-$TS.txt"
  {
    secao "Maquina"
    hostname; date; uptime -p

    secao "Recursos"
    printf 'CPUs: %s\n' "$(nproc)"
    free -h
    df -h /opt | tail -1
    local livre_mb
    livre_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
    if [ "$livre_mb" -ge 1800 ]; then ok "MemAvailable ${livre_mb} MB"
    else aviso "MemAvailable ${livre_mb} MB - o build do Next pede ~1,5 GB. Aumente a RAM da VM ou faca o build fora do horario."; fi

    secao "Servicos que parecem ser o site"
    systemctl list-units --type=service --all --no-pager --no-legend | grep -iE 'next|espacos|clube|node' || echo "(nenhum)"

    secao "Servico da producao: $PROD_SERVICO"
    if systemctl cat "$PROD_SERVICO" >/dev/null 2>&1; then
      systemctl show "$PROD_SERVICO" -p ActiveState -p User -p WorkingDirectory --no-pager
      printf 'ExecStart=%s\n' "$(systemctl show "$PROD_SERVICO" -p ExecStart --value | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p')"
      echo "--- unit (Environment com valor mascarado) ---"
      systemctl cat "$PROD_SERVICO" --no-pager \
        | sed -E '/^Environment=(NODE_ENV|PORT|NEXT_TELEMETRY_DISABLED)=/! s/^(Environment=[A-Za-z_][A-Za-z0-9_]*=).*/\1***/'
    else
      aviso "Servico '$PROD_SERVICO' nao existe. Ache o nome acima e ajuste PROD_SERVICO no topo do script."
    fi

    secao "Portas"
    ss -ltnp | grep -E ":(${PROD_PORTA}|${HML_PORTA})\b" || true
    if ss -ltn | awk '{print $4}' | grep -qE "[:.]${HML_PORTA}$"; then
      aviso "Porta ${HML_PORTA} OCUPADA - escolha outra e ajuste HML_PORTA."
    else ok "Porta ${HML_PORTA} livre"; fi
    if ss -ltn | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*|\[::\]):${PROD_PORTA}$"; then
      aviso "Producao escuta em todas as interfaces (${PROD_PORTA}). O ufw protege; fica como melhoria futura (-H 127.0.0.1)."
    fi

    secao "Pasta e .env da producao (so nomes)"
    ls -ld "$PROD_DIR" 2>/dev/null || aviso "$PROD_DIR nao existe - ajuste PROD_DIR"
    if [ -f "$PROD_DIR/.env" ]; then
      nomes_env "$PROD_DIR/.env"
      if valor_vazio "$PROD_DIR/.env" NEXT_PUBLIC_BASE_PATH; then ok "Producao sem NEXT_PUBLIC_BASE_PATH (raiz) - correto"
      else aviso "Producao TEM NEXT_PUBLIC_BASE_PATH preenchido - pare e revise."; fi
    else aviso "$PROD_DIR/.env nao encontrado"; fi
    [ -e "$HML_DIR" ] && aviso "$HML_DIR ja existe" || ok "$HML_DIR ainda nao existe"
    id "$HML_USER" >/dev/null 2>&1 && aviso "Usuario $HML_USER ja existe" || ok "Usuario $HML_USER ainda nao existe"

    secao "Node / npm / git / openssl"
    command -v node && node -v; npm -v; git --version; openssl version

    secao "nginx"
    nginx -v 2>&1
    local sites n
    sites="$(acha_site)"; n="$(printf '%s' "$sites" | grep -c . || true)"
    if [ "$n" -eq 1 ]; then
      ok "Server 443 do site em: $sites"
      echo "--- diretivas do server/location / (sem segredos) ---"
      grep -nE 'listen|server_name|location|proxy_|limit_req|add_header|include|modsecurity|auth_basic' "$sites"
      if insere_include "$sites" >/dev/null; then ok "Ponto de insercao do include encontrado"
      else aviso "Nao achei um unico server 443 para inserir o include - me mande este relatorio."; fi
    else
      aviso "Encontrados $n arquivos com o server 443 do dominio: ${sites:-nenhum}"
    fi
    grep -qs "$SNIPPET" $sites && aviso "Include da homologacao JA esta no nginx"
    echo "--- add_header herdados (a location da homologacao precisa repetir) ---"
    nginx -T 2>/dev/null | grep -nE '^[[:space:]]*add_header' || echo "(nenhum)"
    echo "--- location por regex (podem capturar /homolog sem o ^~) ---"
    nginx -T 2>/dev/null | grep -nE 'location[[:space:]]+~' || echo "(nenhuma)"
    nginx -T 2>/dev/null | grep -qE 'limit_req_zone[^;]*zone=appzone' && ok "Zona de rate limit 'appzone' existe" || info "Sem zona 'appzone'"
    awk '/^[[:space:]]*user[[:space:]]/ {print "Usuario do nginx: " $2}' /etc/nginx/nginx.conf

    secao "AppArmor / SELinux"
    if command -v aa-status >/dev/null; then aa-status 2>/dev/null | grep -iE 'nginx|node' || ok "Sem perfil AppArmor para nginx/node"; fi
    command -v getenforce >/dev/null && getenforce || ok "SELinux ausente (Ubuntu)"

    secao "Saida para GitHub e npm (necessaria para clone e build)"
    printf 'github.com: HTTP %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://github.com)"
    npm ping 2>&1 | tail -1

    secao "Linha de base da producao (via nginx local)"
    curl_local -o /dev/null -D - "https://${DOMINIO}/" | tr -d '\r' \
      | sed -E 's/^([Ss]et-[Cc]ookie: [^=]+=)[^;]*/\1***/' | tee "$BACKUP_DIR/baseline-prod-headers.txt"
  } 2>&1 | tee "$rel"
  printf '\nRelatorio salvo em %s\n' "$rel"
}

# ------------------------------------------------------------------------------------------
cmd_instalar() {
  exige_root instalar
  local node_bin cod_prod_antes livre_mb

  secao "Pre-condicoes"
  systemctl is-active --quiet "$PROD_SERVICO" || falha "Producao '$PROD_SERVICO' nao esta ativa. Nada foi feito."
  ok "Producao ativa"
  [ -f "$PROD_DIR/.env" ] || falha "$PROD_DIR/.env nao existe"
  [ ! -e "$HML_DIR" ] || falha "$HML_DIR ja existe. Para recomecar: sudo bash $0 rollback e apague a pasta."
  ! systemctl cat "$HML_SERVICO" >/dev/null 2>&1 || falha "Servico $HML_SERVICO ja existe."
  ! ss -ltn | awk '{print $4}' | grep -qE "[:.]${HML_PORTA}$" || falha "Porta ${HML_PORTA} ocupada."
  node_bin="$(command -v node)" || falha "node nao encontrado"
  command -v git >/dev/null || falha "git nao encontrado"
  livre_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
  [ "$livre_mb" -ge 1800 ] || { aviso "Memoria livre ${livre_mb} MB (o build pede ~1,5 GB)."; confirmar "Continuar mesmo assim?" || falha "Cancelado."; }
  cod_prod_antes="$(curl -s --noproxy "*" -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PROD_PORTA}/")"
  ok "Producao responde ${cod_prod_antes} em 127.0.0.1:${PROD_PORTA}"

  cat <<EOF

  Vai criar:
    usuario   ${HML_USER} (sem shell)
    pasta     ${HML_DIR}  (branch ${BRANCH})
    servico   ${HML_SERVICO} em 127.0.0.1:${HML_PORTA}
    pagamento na homologacao: $([ "$DESLIGAR_PAGAMENTO" = 1 ] && echo DESLIGADO || echo LIGADO - cobrancas REAIS)
    WhatsApp na homologacao:  $([ "$DESLIGAR_WHATSAPP" = 1 ] && echo DESLIGADO || echo LIGADO)
  Nao mexe em: ${PROD_DIR}, ${PROD_SERVICO}, nginx.
EOF
  confirmar "Prosseguir?" || falha "Cancelado."

  secao "1/5 Usuario e pasta"
  if ! id "$HML_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/${HML_USER}" --shell /usr/sbin/nologin "$HML_USER"
  fi
  chmod 750 "/var/lib/${HML_USER}"
  install -d -o "$HML_USER" -g "$HML_USER" -m 750 "$HML_DIR"
  ok "Usuario ${HML_USER} e pasta ${HML_DIR}"

  secao "2/5 Clone da branch ${BRANCH} (repositorio publico, sem credencial)"
  como_hml git clone --quiet --branch "$BRANCH" --single-branch "$REPO_URL" "$HML_DIR"
  ok "Commit: $(como_hml git -C "$HML_DIR" log -1 --format='%h %ad %s' --date=short)"

  secao "3/5 .env da homologacao (valores nunca sao exibidos)"
  install -o "$HML_USER" -g "$HML_USER" -m 600 "$PROD_DIR/.env" "$HML_DIR/.env"
  VALOR="/homolog"                                      set_env NEXT_PUBLIC_BASE_PATH
  VALOR="https://${DOMINIO}/homolog/api/auth"           set_env NEXTAUTH_URL
  VALOR="https://${DOMINIO}/homolog"                    set_env NEXT_PUBLIC_APP_URL
  VALOR="$(openssl rand -base64 32)"                    set_env NEXTAUTH_SECRET
  if [ "$DESLIGAR_PAGAMENTO" = 1 ]; then
    VALOR="" set_env INTERNAL_EREDE_CLIENT_ID
    VALOR="" set_env INTERNAL_EREDE_SECRET_ID
    ok "eRede desligada (CLIENT_ID e SECRET_ID vazios)"
  fi
  if [ "$DESLIGAR_WHATSAPP" = 1 ]; then
    VALOR="" set_env WHATSAPP_WEBHOOK_VERIFY_TOKEN
    VALOR="" set_env WHATSAPP_WEBHOOK_SIGNING_SECRET
    ok "Webhook do WhatsApp desligado (responde 503)"
  fi
  local token_lara=""
  read -rsp "  >> Token da Lara EXCLUSIVO da homologacao (Enter = manter o da producao): " token_lara || true
  echo
  if [ -n "$token_lara" ]; then VALOR="$token_lara" set_env INTERNAL_LARA_API_TOKEN; ok "Token Lara proprio aplicado"
  else aviso "Usando o mesmo token Lara da producao"; fi
  unset token_lara

  [ "$(grep -E '^NEXTAUTH_SECRET=' "$PROD_DIR/.env" | sha256sum)" != "$(grep -E '^NEXTAUTH_SECRET=' "$HML_DIR/.env" | sha256sum)" ] \
    || falha "NEXTAUTH_SECRET da homologacao igual ao da producao"
  grep -qE '^NEXT_PUBLIC_BASE_PATH=/homolog\s*$' "$HML_DIR/.env" || falha "NEXT_PUBLIC_BASE_PATH nao ficou /homolog"
  ok "NEXTAUTH_SECRET diferente da producao; basePath /homolog"
  echo "  Variaveis no .env da homologacao:"; nomes_env "$HML_DIR/.env" | sed 's/^/    /'

  secao "4/5 Dependencias e build (cgroup limitado, nice 10)"
  limitado npm ci --include=dev --no-audit --no-fund
  limitado npm run build
  [ -f "$HML_DIR/.next/BUILD_ID" ] || falha "Build nao gerou .next/BUILD_ID"
  grep -qE '"basePath": ?"/homolog"' "$HML_DIR/.next/routes-manifest.json" || falha "Build sem basePath /homolog"
  chmod -R o-rwx "$HML_DIR"
  ok "Build pronto com basePath /homolog"

  secao "5/5 Servico ${HML_SERVICO}"
  cat > "$UNIT" <<EOF
# Gerado por homolog.sh em ${TS}. Homologacao /homolog (branch ${BRANCH}).
[Unit]
Description=Espacos - homologacao (/homolog)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HML_USER}
Group=${HML_USER}
WorkingDirectory=${HML_DIR}
Environment=NODE_ENV=production
Environment=NEXT_TELEMETRY_DISABLED=1
# node direto (nao "npm start"): nao depende do bit +x de node_modules/.bin
ExecStart=${node_bin} ${HML_DIR}/node_modules/next/dist/bin/next start -H 127.0.0.1 -p ${HML_PORTA}
Restart=on-failure
RestartSec=5

# A homologacao nao pode tirar recurso da producao
MemoryMax=${HML_MEMORIA_MAX}
CPUQuota=100%
Nice=5
TasksMax=256

# Isolamento (MemoryDenyWriteExecute fica de fora: incompativel com o JIT do Node)
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${HML_DIR}
InaccessiblePaths=-${PROD_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
  systemctl daemon-reload
  if ! systemctl enable --now "$HML_SERVICO" >/dev/null 2>&1 || ! espera_porta "$HML_PORTA"; then
    journalctl -u "$HML_SERVICO" -n 40 --no-pager
    falha "Servico nao subiu (log acima). Producao nao foi tocada."
  fi
  local endereco
  endereco="$(ss -ltn | awk '{print $4}' | grep -E "[:.]${HML_PORTA}$" | sort -u | tr '\n' ' ')"
  [[ "$endereco" =~ ^(127\.0\.0\.1:${HML_PORTA}[[:space:]]*)+$ ]] || falha "Escutando em '${endereco}' - deveria ser so 127.0.0.1"
  ok "Escutando so em 127.0.0.1:${HML_PORTA}"

  local c1 c2
  c1="$(curl -s --noproxy "*" -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:${HML_PORTA}/homolog/login")"
  c2="$(curl -s --noproxy "*" -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 "http://127.0.0.1:${HML_PORTA}/homolog")"
  [ "$c1" = "200" ] && ok "/homolog/login -> 200" || aviso "/homolog/login -> ${c1} (esperado 200)"
  [[ "$c2" == 307* ]] && ok "/homolog -> ${c2}" || aviso "/homolog -> ${c2} (esperado 307 para /homolog/login)"

  systemctl is-active --quiet "$PROD_SERVICO" || falha "ATENCAO: producao nao esta ativa!"
  [ "$(curl -s --noproxy "*" -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PROD_PORTA}/")" = "$cod_prod_antes" ] \
    && ok "Producao inalterada (${cod_prod_antes})" || aviso "Producao respondeu diferente de antes - confira"
  info "Exposicao do servico: $(systemd-analyze security "$HML_SERVICO" --no-pager 2>/dev/null | tail -1)"

  printf '\nPronto. Ainda NAO esta acessivel pela internet. Proximo passo: sudo bash %s nginx\n' "$0"
}

# ------------------------------------------------------------------------------------------
cmd_nginx() {
  exige_root nginx
  systemctl is-active --quiet "$HML_SERVICO" || falha "Rode antes: sudo bash $0 instalar"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

  local site n
  site="$(acha_site)"; n="$(printf '%s' "$site" | grep -c . || true)"
  [ "$n" -eq 1 ] || falha "Esperava 1 arquivo com o server 443 de ${DOMINIO}, achei ${n}: ${site:-nenhum}"
  grep -q "$SNIPPET" "$site" && falha "O include ja esta em $site. Use: sudo bash $0 verificar"
  ok "Site: $site"

  local nginx_user limit_line=""
  nginx_user="$(awk '/^[[:space:]]*user[[:space:]]/ {gsub(";","",$2); print $2; exit}' /etc/nginx/nginx.conf)"
  nginx_user="${nginx_user:-www-data}"
  nginx -T 2>/dev/null | grep -qE 'limit_req_zone[^;]*zone=appzone' && limit_line="    limit_req zone=appzone burst=20 nodelay;"

  [ -f "$BACKUP_DIR/baseline-prod-headers.txt" ] || \
    curl_local -o /dev/null -D - "https://${DOMINIO}/" | tr -d '\r' \
      | sed -E 's/^([Ss]et-[Cc]ookie: [^=]+=)[^;]*/\1***/' > "$BACKUP_DIR/baseline-prod-headers.txt"

  secao "1/4 Senha de acesso a homologacao"
  if [ -s "$HTPASSWD" ]; then
    ok "Ja existe $HTPASSWD (mantido)"
  else
    local u hash
    read -rp "  >> Usuario de acesso [homolog]: " u || true
    u="${u:-homolog}"
    echo "  Digite a senha duas vezes (nao aparece na tela):"
    hash="$(openssl passwd -apr1)" || falha "Senha nao confirmada"
    printf '%s:%s\n' "$u" "$hash" > "$HTPASSWD"
    chown "root:${nginx_user}" "$HTPASSWD"; chmod 640 "$HTPASSWD"
    ok "Usuario '$u' criado em $HTPASSWD"
  fi

  secao "2/4 Snippets"
  cat > "$SNIPPET_PROXY" <<EOF
# Gerado por homolog.sh em ${TS} - proxy da homologacao (/homolog -> 127.0.0.1:${HML_PORTA})
auth_basic "Homologacao - acesso restrito";
auth_basic_user_file ${HTPASSWD};
${limit_line}
proxy_pass http://127.0.0.1:${HML_PORTA};
proxy_http_version 1.1;
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection "upgrade";
# a senha do auth_basic nao chega na aplicacao
proxy_set_header Authorization "";
# O Next escuta em 127.0.0.1 (-H) e por isso o middleware de login responde com Location
# absoluto "http(s)://localhost:${HML_PORTA}/...". Reescreve para o dominio publico.
proxy_redirect http://localhost:${HML_PORTA}/  https://\$host/;
proxy_redirect https://localhost:${HML_PORTA}/ https://\$host/;
proxy_redirect http://127.0.0.1:${HML_PORTA}/  https://\$host/;
proxy_redirect https://127.0.0.1:${HML_PORTA}/ https://\$host/;
# add_header numa location ANULA os herdados do http/server: por isso repetimos todos aqui
add_header X-Robots-Tag "noindex, nofollow" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
  cat > "$SNIPPET" <<EOF
# Gerado por homolog.sh em ${TS} - incluido no server 443 de ${DOMINIO}
# "= /homolog" e "^~ /homolog/" em vez de "^~ /homolog": nao captura /homologxyz
location = /homolog {
    include ${SNIPPET_PROXY};
}
location ^~ /homolog/ {
    include ${SNIPPET_PROXY};
}
# o app usa imagens sem otimizacao; o endpoint de otimizacao fica fechado
location ^~ /homolog/_next/image {
    return 404;
}
EOF
  chmod 644 "$SNIPPET" "$SNIPPET_PROXY"
  ok "$SNIPPET e $SNIPPET_PROXY"

  secao "3/4 Include no server 443 (com backup)"
  local bkp novo
  bkp="$BACKUP_DIR/$(basename "$site").${TS}"
  cp -p "$site" "$bkp"
  novo="$(mktemp)"
  if ! insere_include "$site" > "$novo"; then
    rm -f "$novo" "$SNIPPET" "$SNIPPET_PROXY"
    falha "Nao achei um unico server 443 de ${DOMINIO} em $site. Nada alterado."
  fi
  diff -u "$bkp" "$novo" || true
  confirmar "Aplicar esta alteracao no nginx?" || { rm -f "$novo" "$SNIPPET" "$SNIPPET_PROXY"; falha "Cancelado. Nada alterado."; }
  cat "$novo" > "$site"; rm -f "$novo"

  if ! nginx -t 2>&1; then
    cat "$bkp" > "$site"; rm -f "$SNIPPET" "$SNIPPET_PROXY"
    nginx -t >/dev/null 2>&1 && ok "Backup restaurado, nginx valido" || aviso "Verifique o nginx manualmente!"
    falha "nginx -t falhou. Alteracao desfeita. Backup em $bkp"
  fi
  systemctl reload nginx
  sleep 3   # o reload e assincrono: espera os workers novos assumirem
  ok "nginx recarregado (sem derrubar conexoes). Backup: $bkp"

  secao "4/4 Verificacao"
  cmd_verificar
}

# ------------------------------------------------------------------------------------------
cmd_verificar() {
  exige_root verificar
  set +e
  local base="https://${DOMINIO}" netrc u p h c
  local cabec_seg="x-frame-options x-content-type-options referrer-policy strict-transport-security"

  secao "Producao (deve estar igual a antes)"
  systemctl is-active --quiet "$PROD_SERVICO" && ok "$PROD_SERVICO ativo" || aviso "$PROD_SERVICO NAO esta ativo"
  h="$(curl_local -o /dev/null -D - "$base/" | tr -d '\r')"
  printf '%s\n' "$h" | head -1
  if [ -f "$BACKUP_DIR/baseline-prod-headers.txt" ]; then
    if [ "$(head -1 "$BACKUP_DIR/baseline-prod-headers.txt" | awk '{print $2}')" = "$(printf '%s\n' "$h" | head -1 | awk '{print $2}')" ]; then
      ok "Status igual a linha de base"; else aviso "Status diferente da linha de base"; fi
  fi

  secao "Homologacao sem senha (deve ser 401)"
  c="$(curl_local -o /dev/null -w '%{http_code}' "$base/homolog/login")"
  [ "$c" = "401" ] && ok "/homolog/login -> 401" || aviso "/homolog/login -> $c (esperado 401)"
  c="$(curl_local -o /dev/null -w '%{http_code}' "$base/homologxyz")"
  info "/homologxyz -> $c (vai para a producao, nao para a homologacao)"

  secao "Homologacao com senha"
  read -rp "  >> Usuario de acesso [homolog]: " u || true; u="${u:-homolog}"
  read -rsp "  >> Senha: " p || true; echo
  netrc="$(mktemp)"; chmod 600 "$netrc"
  printf 'machine %s login %s password %s\n' "$DOMINIO" "$u" "$p" > "$netrc"; unset p

  h="$(curl_local --netrc-file "$netrc" -o /dev/null -D - "$base/homolog/login" | tr -d '\r')"
  c="$(printf '%s\n' "$h" | head -1 | awk '{print $2}')"
  [ "$c" = "200" ] && ok "/homolog/login -> 200" || aviso "/homolog/login -> $c (esperado 200; 401 = senha errada)"
  printf '%s\n' "$h" | grep -qi '^x-robots-tag: noindex' && ok "X-Robots-Tag noindex" || aviso "Sem X-Robots-Tag"
  for c in $cabec_seg; do
    printf '%s\n' "$h" | grep -qi "^${c}:" && ok "Cabecalho $c presente" || aviso "Cabecalho $c AUSENTE na homologacao"
  done
  curl_local --netrc-file "$netrc" "$base/homolog/login" | grep -q "Homologa" \
    && ok "Faixa 'Homologacao' no HTML" || aviso "Faixa 'Homologacao' nao encontrada no HTML"

  h="$(curl_local --netrc-file "$netrc" -o /dev/null -D - "$base/homolog" | tr -d '\r')"
  printf '%s\n' "$h" | grep -iE '^(HTTP|location)' | sed 's/^/    /'
  if printf '%s\n' "$h" | grep -qiE "^location: *https?://(localhost|127\.0\.0\.1)|^location:.*:${HML_PORTA}/"; then
    aviso "Redirect aponta para localhost/porta ${HML_PORTA}: falta o proxy_redirect em $SNIPPET_PROXY"
  else
    ok "Redirect de /homolog fica no dominio publico"
  fi

  echo "  Cookies de /homolog/api/auth/csrf (valores ocultos):"
  curl_local --netrc-file "$netrc" -o /dev/null -D - "$base/homolog/api/auth/csrf" | tr -d '\r' \
    | grep -i '^set-cookie:' | sed -E 's/^([Ss]et-[Cc]ookie: [^=]+=)[^;]*/\1***/' | sed 's/^/    /'

  c="$(curl_local --netrc-file "$netrc" -o /dev/null -w '%{http_code}' "$base/homolog/_next/image?url=%2Ffavicon.ico&w=64&q=75")"
  [ "$c" = "404" ] && ok "/homolog/_next/image bloqueado (404)" || aviso "/homolog/_next/image -> $c (esperado 404)"
  rm -f "$netrc"

  secao "Servico e logs"
  systemctl is-active --quiet "$HML_SERVICO" && ok "$HML_SERVICO ativo" || aviso "$HML_SERVICO NAO esta ativo"
  ss -ltn | awk '{print $4}' | grep -E "[:.]${HML_PORTA}$" | sed 's/^/    escutando: /'
  journalctl -u "$HML_SERVICO" -n 15 --no-pager -p warning 2>/dev/null | sed 's/^/    /'
  echo "  Ultimas linhas do error.log do nginx:"; tail -5 /var/log/nginx/error.log 2>/dev/null | sed 's/^/    /'
}

# ------------------------------------------------------------------------------------------
cmd_deploy() {
  exige_root deploy
  systemctl cat "$HML_SERVICO" >/dev/null 2>&1 || falha "Servico $HML_SERVICO nao existe"
  grep -qE '^NEXT_PUBLIC_BASE_PATH=/homolog\s*$' "$HML_DIR/.env" || falha "$HML_DIR/.env sem NEXT_PUBLIC_BASE_PATH=/homolog"
  local ref="${REF:-origin/${BRANCH}}" antes depois
  antes="$(como_hml git -C "$HML_DIR" rev-parse --short HEAD)"

  secao "Atualizando ${HML_DIR} para ${ref}"
  como_hml git -C "$HML_DIR" fetch --quiet --prune origin "$BRANCH"
  como_hml git -C "$HML_DIR" reset --quiet --hard "$ref"
  como_hml git -C "$HML_DIR" clean -df --quiet
  depois="$(como_hml git -C "$HML_DIR" rev-parse --short HEAD)"
  ok "${antes} -> ${depois}: $(como_hml git -C "$HML_DIR" log -1 --format='%s')"

  secao "Dependencias e build"
  if ! limitado npm ci --include=dev --no-audit --no-fund || ! limitado npm run build; then
    falha "Build falhou. A homologacao pode ficar instavel ate um build bom. Para voltar: sudo REF=${antes} bash $0 deploy"
  fi
  grep -qE '"basePath": ?"/homolog"' "$HML_DIR/.next/routes-manifest.json" || falha "Build sem basePath /homolog"
  chmod -R o-rwx "$HML_DIR"; chmod 600 "$HML_DIR/.env"

  secao "Reiniciando ${HML_SERVICO}"
  systemctl restart "$HML_SERVICO"
  espera_porta "$HML_PORTA" || { journalctl -u "$HML_SERVICO" -n 40 --no-pager; falha "Nao subiu"; }
  local c
  c="$(curl -s --noproxy "*" -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:${HML_PORTA}/homolog/login")"
  [ "$c" = "200" ] && ok "/homolog/login -> 200" || aviso "/homolog/login -> $c"
  systemctl is-active --quiet "$PROD_SERVICO" && ok "Producao segue ativa" || aviso "Producao NAO esta ativa"
  info "Para voltar a versao anterior: sudo REF=${antes} bash $0 deploy"
}

# ------------------------------------------------------------------------------------------
cmd_rollback() {
  exige_root rollback
  confirmar "Remover a homologacao do nginx e parar/remover o servico ${HML_SERVICO}?" || falha "Cancelado."
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

  local site
  site="$(acha_site)"
  if [ -n "$site" ] && [ "$(printf '%s' "$site" | grep -c .)" -eq 1 ] && grep -q "$SNIPPET" "$site"; then
    local bkp
    bkp="$BACKUP_DIR/$(basename "$site").rollback.${TS}"
    cp -p "$site" "$bkp"
    grep -vF "$SNIPPET" "$bkp" > "$site.tmp.$$" && cat "$site.tmp.$$" > "$site" && rm -f "$site.tmp.$$"
    if nginx -t 2>&1; then
      systemctl reload nginx; sleep 3; ok "Include removido e nginx recarregado (backup: $bkp)"
      rm -f "$SNIPPET" "$SNIPPET_PROXY"
    else
      cat "$bkp" > "$site"; falha "nginx -t falhou apos remover o include; arquivo restaurado."
    fi
  else
    info "Include da homologacao nao encontrado no nginx (nada a remover)"
  fi

  if systemctl cat "$HML_SERVICO" >/dev/null 2>&1; then
    systemctl disable --now "$HML_SERVICO" >/dev/null 2>&1 || true
    rm -f "$UNIT"; systemctl daemon-reload; systemctl reset-failed "$HML_SERVICO" 2>/dev/null || true
    ok "Servico ${HML_SERVICO} removido"
  fi
  systemctl is-active --quiet "$PROD_SERVICO" && ok "Producao ativa" || aviso "Producao NAO esta ativa"

  cat <<EOF

  Mantidos (nao interferem na producao): ${HML_DIR}, usuario ${HML_USER}, ${HTPASSWD}.
  Para apagar de vez:
    sudo rm -rf ${HML_DIR}
    sudo userdel -r ${HML_USER}
    sudo rm -f ${HTPASSWD}
EOF
}

# ------------------------------------------------------------------------------------------
case "${1:-}" in
  levantamento) cmd_levantamento ;;
  instalar)     cmd_instalar ;;
  nginx)        cmd_nginx ;;
  verificar)    cmd_verificar ;;
  deploy)       cmd_deploy ;;
  rollback)     cmd_rollback ;;
  *) sed -n '3,12p' "$0"; exit 1 ;;
esac