#!/usr/bin/env bash
#
# producao.sh - atualiza a PRODUCAO (espacos.clubedosfuncionarios.com.br, VM da DMZ)
#
# Uso (sempre com sudo):
#   sudo bash producao.sh status                 # versao no ar, versao guardada, o que tem de novo
#   sudo bash producao.sh deploy                 # atualiza para origin/master
#   sudo REF=<commit> bash producao.sh deploy    # atualiza para um commit especifico
#   sudo bash producao.sh rollback               # volta para a versao anterior (troca as pastas)
#
# Como o deploy funciona:
#   1. copia a pasta da producao (sem node_modules e .next) para /opt/nextjs-app.novo
#   2. atualiza o git, roda npm ci e build LA DENTRO; a producao segue no ar, intacta
#   3. sobe a versao nova num servico temporario em 127.0.0.1:3002 e testa
#   4. so entao para a producao, troca as pastas e sobe de novo (poucos segundos fora)
#   5. se a versao nova nao responder, volta a anterior sozinho
#   A versao que saiu do ar fica em /opt/nextjs-app.anterior (uma so) para o rollback.
#
# Garantias: nunca imprime valores do .env; nao mexe no nginx, na homologacao nem no
# servico systemd da producao; nao usa o deploy.sh do repositorio (ele ainda chama o pm2).
#
set -Eeuo pipefail

# ============================== AJUSTE SE NECESSARIO ==============================
DOMINIO="espacos.clubedosfuncionarios.com.br"
SERVICO="nextjs-app"
APP_USER="nextapp"
APP_DIR="/opt/nextjs-app"
PORTA="3000"
BRANCH="master"

NOVO="${APP_DIR}.novo"
ANTERIOR="${APP_DIR}.anterior"
PORTA_TESTE="3002"
UNIT_TESTE="espacos-prod-teste"

BUILD_MEMORIA_MAX="2G"              # npm ci / next build (a producao continua rodando ao lado)
BUILD_HEAP_MB="1536"
DISCO_MIN_MB="3000"                 # cada versao ocupa ~800 MB (node_modules + .next)
CURL_EXTRA="${CURL_EXTRA:-}"        # uso interno de teste; deixe vazio
# ==================================================================================

export NO_PROXY="127.0.0.1,localhost,${DOMINIO}${NO_PROXY:+,$NO_PROXY}" no_proxy="127.0.0.1,localhost,${DOMINIO}${no_proxy:+,$no_proxy}"
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

trava() {
  # Um deploy/rollback de cada vez.
  exec 9>/run/lock/espacos-producao.lock
  flock -n 9 || falha "Ja tem um deploy/rollback da producao rodando."
}

como_app() {
  # como_app <pasta> <comando...>: roda como o dono da aplicacao, de dentro da pasta.
  local dir="$1"; shift
  ( cd "$dir" && sudo -u "$APP_USER" -H "$@" )
}

limitado() {
  # limitado <pasta> <comando...>: npm/build num cgroup proprio (se estourar, morre so o build).
  local dir="$1" cpus quota; shift
  cpus="$(nproc)"
  if [ "$cpus" -gt 1 ]; then quota="$(( (cpus - 1) * 100 ))%"; else quota="100%"; fi
  ( cd "$dir" && systemd-run --quiet --scope \
      -p MemoryMax="$BUILD_MEMORIA_MAX" -p CPUQuota="$quota" -- \
      sudo -u "$APP_USER" -H env NEXT_TELEMETRY_DISABLED=1 \
      NODE_OPTIONS="--max-old-space-size=${BUILD_HEAP_MB}" nice -n 10 "$@" )
}

escutando() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"; }

espera_porta() {
  local porta="$1"
  for _ in $(seq 1 60); do escutando "$porta" && return 0; sleep 1; done
  return 1
}

codigo() {
  # codigo <url>: status HTTP direto no Node, sem nginx.
  curl -s --noproxy "*" -o /dev/null -w '%{http_code}' --max-time 20 "$1" || true
}

codigo_publico() {
  # Pelo nginx desta VM, com o nome do site (sem depender do NAT).
  # shellcheck disable=SC2086
  curl -sS --noproxy "*" -o /dev/null -w '%{http_code}' --max-time 20 \
    --resolve "${DOMINIO}:443:127.0.0.1" $CURL_EXTRA "https://${DOMINIO}$1" 2>/dev/null || true
}

versao() {
  # versao <pasta>: "commit data assunto | Next x.y.z | build dd/mm hh:mm"
  local d="$1" c n b
  c="$(como_app "$d" git log -1 --format='%h %ad %s' --date=short 2>/dev/null || echo '?')"
  n="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$d/node_modules/next/package.json" 2>/dev/null | head -1)"
  b="$(date -r "$d/.next/BUILD_ID" '+%d/%m %H:%M' 2>/dev/null || echo 'sem build')"
  printf '%s | Next %s | build %s' "$c" "${n:-?}" "$b"
}

rearma_auditd() {
  # A regra "-w /opt/nextjs-app ..." do auditd fica presa a pasta ANTIGA depois do mv.
  # Tira e poe de novo SO essa(s) regra(s), para vigiar a pasta que esta no ar agora.
  command -v auditctl >/dev/null 2>&1 || return 0
  local regras linha n=0
  regras="$(grep -hE -- "^-w ${APP_DIR}/?( |$)" /etc/audit/rules.d/*.rules 2>/dev/null || true)"
  [ -n "$regras" ] || return 0
  if auditctl -s 2>/dev/null | grep -q 'enabled 2'; then
    aviso "auditd travado (-e 2): a vigilancia de $APP_DIR so volta no proximo reboot"
    return 0
  fi
  while IFS= read -r linha; do
    # shellcheck disable=SC2086
    auditctl ${linha/#-w /-W } >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    auditctl $linha >/dev/null 2>&1 && n=$((n + 1))
  done <<< "$regras"
  if [ "$n" -gt 0 ]; then ok "auditd vigiando a pasta que esta no ar (${n} regra(s) religada(s))"
  else aviso "Nao consegui religar a regra do auditd; confira: sudo auditctl -l | grep $APP_DIR"; fi
}

confere_no_ar() {
  # 0 se a producao respondeu /login 200 direto no Node.
  espera_porta "$PORTA" || return 1
  local c
  for _ in 1 2 3 4 5; do
    c="$(codigo "http://127.0.0.1:${PORTA}/login")"
    [ "$c" = "200" ] && return 0
    sleep 2
  done
  return 1
}

relatorio_publico() {
  local c
  c="$(codigo_publico /login)"
  if [ "$c" = "200" ]; then ok "https://${DOMINIO}/login -> 200 (pelo nginx)"
  else aviso "https://${DOMINIO}/login pelo nginx -> ${c:-sem resposta} (direto no Node esta OK; confira o nginx)"; fi
}

# ----------------------------------------------------------------------------------
cmd_status() {
  exige_root status
  set +e
  secao "No ar (${APP_DIR})"
  systemctl is-active --quiet "$SERVICO" && ok "$SERVICO ativo" || aviso "$SERVICO NAO esta ativo"
  info "$(versao "$APP_DIR")"

  secao "Guardada para rollback (${ANTERIOR})"
  if [ -d "$ANTERIOR/.next" ]; then info "$(versao "$ANTERIOR")"; else info "nenhuma"; fi
  [ -e "$NOVO" ] && aviso "Existe ${NOVO} (deploy interrompido ou nao trocado)"
  for d in "${APP_DIR}".falhou.*; do
    [ -d "$d" ] && aviso "Versao que falhou no deploy: $d (apague quando nao precisar: sudo rm -rf $d)"
  done

  secao "Novidades em origin/${BRANCH}"
  como_app "$APP_DIR" git fetch --quiet --prune origin || aviso "git fetch falhou (sem internet/GitHub?): lista abaixo pode estar desatualizada"
  local n
  n="$(como_app "$APP_DIR" git rev-list --count "HEAD..origin/${BRANCH}" 2>/dev/null)"
  if [ "${n:-0}" -gt 0 ]; then
    info "${n} commit(s) a frente do que esta no ar:"
    como_app "$APP_DIR" git log --oneline --no-decorate "HEAD..origin/${BRANCH}" | head -20 | sed 's/^/    /'
  else ok "Nada novo: o ar ja esta em origin/${BRANCH}"; fi
  como_app "$APP_DIR" git status --porcelain --untracked-files=no | sed 's/^/    alterado na VM: /'

  secao "Disco"
  df -h "$(dirname "$APP_DIR")" | sed 's/^/    /'
}

# ----------------------------------------------------------------------------------
cmd_deploy() {
  exige_root deploy
  trava
  systemctl cat "$SERVICO" >/dev/null 2>&1 || falha "Servico $SERVICO nao existe"
  [ -d "$APP_DIR/.git" ] || falha "$APP_DIR nao e um clone git"
  [ -f "$APP_DIR/.env" ] || falha "$APP_DIR/.env nao existe"
  escutando "$PORTA_TESTE" && falha "A porta de teste ${PORTA_TESTE} esta ocupada. Ajuste PORTA_TESTE no script."
  local livre
  livre="$(df -Pm "$(dirname "$APP_DIR")" | awk 'NR==2 {print $4}')"
  [ "$livre" -ge "$DISCO_MIN_MB" ] || falha "So ${livre} MB livres (minimo ${DISCO_MIN_MB}). Libere espaco antes."
  if [ -e "$NOVO" ]; then
    confirmar "Ja existe ${NOVO} (deploy anterior interrompido). Apagar e recomecar?" || falha "Cancelado."
    rm -rf "$NOVO"
  fi

  secao "1/6 O que vai entrar"
  local ref="${REF:-origin/${BRANCH}}" atual alvo mudancas
  como_app "$APP_DIR" git fetch --quiet --prune origin || falha "git fetch falhou (sem acesso ao GitHub?). Nada alterado."
  alvo="$(como_app "$APP_DIR" git rev-parse --verify --quiet "${ref}^{commit}")" || falha "Nao achei '${ref}' no repositorio"
  atual="$(como_app "$APP_DIR" git rev-parse HEAD)"
  info "No ar: $(versao "$APP_DIR")"
  info "Alvo:  ${ref} = $(como_app "$APP_DIR" git log -1 --format='%h %ad %s' --date=short "$alvo")"
  if [ "$alvo" = "$atual" ]; then
    info "A producao ja esta nesse commit."
    confirmar "Refazer o build mesmo assim?" || exit 0
  elif como_app "$APP_DIR" git merge-base --is-ancestor "$atual" "$alvo"; then
    echo "  Commits que entram:"
    como_app "$APP_DIR" git log --oneline --no-decorate "${atual}..${alvo}" | head -30 | sed 's/^/    /'
  else
    aviso "O alvo NAO e continuacao do que esta no ar (versao mais antiga ou outro ramo)."
  fi
  if ! como_app "$APP_DIR" git diff --quiet "$atual" "$alvo" -- package.json package-lock.json; then
    info "Dependencias mudam (package.json/package-lock.json)"
  fi
  mudancas="$(como_app "$APP_DIR" git status --porcelain --untracked-files=no)"
  if [ -n "$mudancas" ]; then
    aviso "Arquivos alterados direto na VM. Eles NAO vao para a versao nova:"
    printf '%s\n' "$mudancas" | sed 's/^/    /'
    info "(continuam na pasta antiga, que vira ${ANTERIOR})"
  fi
  confirmar "Preparar esta versao? (a producao continua no ar)" || falha "Cancelado. Nada alterado."

  secao "2/6 Copia de trabalho em ${NOVO}"
  install -d -o "$APP_USER" -g "$APP_USER" -m 750 "$NOVO"
  tar -C "$APP_DIR" --exclude=./node_modules --exclude=./.next -cpf - . | tar -C "$NOVO" -xpf -
  como_app "$NOVO" git reset --quiet --hard "$alvo"
  como_app "$NOVO" git clean -df --quiet
  cmp -s "$APP_DIR/.env" "$NOVO/.env" || falha "O .env nao foi copiado igual. Nada alterado na producao."
  ok "Codigo em $(como_app "$NOVO" git log -1 --format='%h') com o .env atual da producao"

  secao "3/6 npm ci + build (cgroup limitado; a producao segue no ar)"
  limitado "$NOVO" npm ci --include=dev --no-audit --no-fund \
    || falha "npm ci falhou. Producao intacta. ${NOVO} fica para analise (o proximo deploy apaga)."
  limitado "$NOVO" npm run build \
    || falha "Build falhou. Producao intacta. ${NOVO} fica para analise (o proximo deploy apaga)."
  [ -s "$NOVO/.next/BUILD_ID" ] || falha "Build sem .next/BUILD_ID. Producao intacta."
  grep -qE '"basePath": ?""' "$NOVO/.next/routes-manifest.json" \
    || falha "O build saiu com basePath (a producao e na raiz). Confira NEXT_PUBLIC_BASE_PATH no .env da producao."
  chmod -R o-rwx "$NOVO"
  ok "Build pronto: $(versao "$NOVO")"

  secao "4/6 Teste da versao nova em 127.0.0.1:${PORTA_TESTE} (antes de mexer na producao)"
  local node c
  node="$(command -v node)"
  systemctl stop "$UNIT_TESTE" >/dev/null 2>&1 || true
  systemd-run --quiet --collect --unit="$UNIT_TESTE" \
    -p User="$APP_USER" -p Group="$APP_USER" -p WorkingDirectory="$NOVO" -p MemoryMax=1G \
    -E NODE_ENV=production -E NEXT_TELEMETRY_DISABLED=1 \
    "$node" "$NOVO/node_modules/next/dist/bin/next" start -H 127.0.0.1 -p "$PORTA_TESTE"
  if ! espera_porta "$PORTA_TESTE"; then
    journalctl -u "$UNIT_TESTE" -n 30 --no-pager 2>/dev/null | sed 's/^/    /'
    systemctl stop "$UNIT_TESTE" >/dev/null 2>&1 || true
    falha "A versao nova nao subiu no teste. Producao intacta."
  fi
  c="$(codigo "http://127.0.0.1:${PORTA_TESTE}/login")"
  systemctl stop "$UNIT_TESTE" >/dev/null 2>&1 || true
  [ "$c" = "200" ] || falha "A versao nova respondeu ${c} em /login no teste. Producao intacta."
  ok "Versao nova respondeu /login 200 no teste"

  secao "5/6 Troca (producao fora do ar por alguns segundos)"
  if ! confirmar "Trocar a producao agora?"; then
    info "Nada trocado. A versao pronta ficou em ${NOVO}; o proximo deploy pergunta se apaga."
    exit 0
  fi
  [ -e "$ANTERIOR" ] && rm -rf "$ANTERIOR"     # antes de parar: a janela fora do ar fica so na troca
  systemctl stop "$SERVICO"
  mv "$APP_DIR" "$ANTERIOR"
  mv "$NOVO" "$APP_DIR"
  systemctl start "$SERVICO"
  if ! confere_no_ar; then
    aviso "A producao nova nao respondeu. Voltando a anterior..."
    journalctl -u "$SERVICO" -n 30 --no-pager 2>/dev/null | sed 's/^/    /'
    systemctl stop "$SERVICO" || true
    mv "$APP_DIR" "${APP_DIR}.falhou.${TS}"
    mv "$ANTERIOR" "$APP_DIR"
    systemctl start "$SERVICO"
    rearma_auditd
    if confere_no_ar; then
      falha "Deploy desfeito: producao de volta na versao anterior. A versao com problema ficou em ${APP_DIR}.falhou.${TS}"
    fi
    falha "ATENCAO: a producao nao respondeu nem depois de voltar. Veja: journalctl -u ${SERVICO} -n 50"
  fi
  ok "Producao no ar com a versao nova"
  rearma_auditd

  secao "6/6 Resultado"
  info "No ar:     $(versao "$APP_DIR")"
  info "Guardada:  $(versao "$ANTERIOR")"
  relatorio_publico
  systemctl is-active --quiet espacos-homolog 2>/dev/null && ok "Homologacao segue ativa (nao foi tocada)"
  info "Para voltar: sudo bash $0 rollback"
}

# ----------------------------------------------------------------------------------
cmd_rollback() {
  exige_root rollback
  trava
  [ -d "$ANTERIOR/.next" ] || falha "Nao ha versao guardada em ${ANTERIOR}"
  info "No ar:    $(versao "$APP_DIR")"
  info "Voltar a: $(versao "$ANTERIOR")"
  confirmar "Voltar para a versao guardada? (poucos segundos fora do ar)" || falha "Cancelado. Nada alterado."

  # O .env e configuracao, nao codigo: o rollback mantem o .env que esta no ar hoje.
  if ! cmp -s "$APP_DIR/.env" "$ANTERIOR/.env"; then
    cp -p "$APP_DIR/.env" "$ANTERIOR/.env"
    info "O .env atual foi levado para a versao guardada (o rollback e so de codigo)"
  fi

  local troca="${APP_DIR}.troca.$$"
  systemctl stop "$SERVICO"
  mv "$APP_DIR" "$troca"
  mv "$ANTERIOR" "$APP_DIR"
  mv "$troca" "$ANTERIOR"
  systemctl start "$SERVICO"
  rearma_auditd
  confere_no_ar || falha "A producao nao respondeu depois do rollback. Veja: journalctl -u ${SERVICO} -n 50 (rodar rollback de novo destroca as pastas)"
  ok "Rollback feito"
  info "No ar:     $(versao "$APP_DIR")"
  info "Guardada:  $(versao "$ANTERIOR")  (rodar rollback de novo volta para ela)"
  relatorio_publico
}

# ----------------------------------------------------------------------------------
case "${1:-}" in
  status)   cmd_status ;;
  deploy)   cmd_deploy ;;
  rollback) cmd_rollback ;;
  *) sed -n '3,9p' "$0"; exit 1 ;;
esac