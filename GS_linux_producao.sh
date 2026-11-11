#!/bin/bash
# GS Linux - Parte obrigatoria: BIND (DNS) + Apache (HTTP)
# Compatibilidade: AlmaLinux / Rocky Linux
# Execute como root: sudo bash gs_linux_obrigatoria.sh

set -o pipefail

NAMED_CONF="/etc/named.conf"
DIR_ZONAS="/var/named"
DIR_SITE="/var/www/html"
ARQ_REGISTROS="/tmp/registros_dns_gs.txt"

erro() { echo "[ERRO] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }

perguntar_sn() {
  local resposta=""
  while [[ "$resposta" != "s" && "$resposta" != "n" ]]; do
    read -r -p "$1 (s/n): " resposta
    resposta=$(printf '%s' "$resposta" | tr '[:upper:]' '[:lower:]')
  done
  RESP="$resposta"
}

ler_dominio() {
  local valor=""
  while true; do
    read -r -p "$1" valor
    valor=$(printf '%s' "$valor" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    if [[ "$valor" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && [[ "$valor" != *..* ]]; then
      LIDO="$valor"; return
    fi
    echo "[AVISO] Domínio inválido. Exemplo: empresa.fiap.lab"
  done
}

ip_valido() {
  local ip="$1" parte
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a partes <<< "$ip"
  for parte in "${partes[@]}"; do
    (( 10#$parte <= 255 )) || return 1
  done
}

ler_ip() {
  local valor=""
  while true; do
    read -r -p "$1" valor
    if ip_valido "$valor"; then LIDO="$valor"; return; fi
    echo "[AVISO] IP inválido. Exemplo: 192.168.56.20"
  done
}


configurar_ip_fixo() {
  info "Interfaces de rede disponíveis:"
  ip -br link
  read -r -p "Nome da interface que receberá IP fixo (ex.: enp0s8): " INTERFACE
  ip link show "$INTERFACE" >/dev/null 2>&1 || erro "Interface $INTERFACE não encontrada."
  read -r -p "IP fixo com prefixo (ex.: 192.168.56.20/24): " IP_CIDR
  IP_BASE="${IP_CIDR%/*}"
  PREFIXO="${IP_CIDR#*/}"
  ip_valido "$IP_BASE" || erro "Endereço IPv4 inválido."
  [[ "$IP_CIDR" == */* && "$PREFIXO" =~ ^[0-9]{1,2}$ ]] && (( PREFIXO <= 32 )) || erro "Prefixo inválido. Use /24, por exemplo."
  read -r -p "Gateway (pressione Enter se não houver): " GATEWAY
  if [[ -n "$GATEWAY" ]]; then ip_valido "$GATEWAY" || erro "Gateway inválido."; fi
  command -v nmcli >/dev/null 2>&1 || erro "nmcli não encontrado. Instale/ative o NetworkManager antes de configurar IP fixo."
  systemctl is-active --quiet NetworkManager || systemctl enable --now NetworkManager || erro "Não foi possível iniciar NetworkManager."
  read -r -p "DNS para resolução externa (ex.: 8.8.8.8): " DNS_UPSTREAM
  ip_valido "$DNS_UPSTREAM" || erro "DNS informado inválido."

  CONEXAO=$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null | head -n1)
  if [[ -z "$CONEXAO" || "$CONEXAO" == "--" ]]; then
    CONEXAO="$INTERFACE"
    nmcli connection add type ethernet ifname "$INTERFACE" con-name "$CONEXAO" >/dev/null || erro "Não foi possível criar conexão NetworkManager."
  fi
  info "Aplicando IP fixo $IP_CIDR na conexão $CONEXAO..."
  nmcli connection modify "$CONEXAO" ipv4.method manual ipv4.addresses "$IP_CIDR" ipv4.dns "$DNS_UPSTREAM" || erro "Falha ao configurar IP fixo."
  if [[ -n "$GATEWAY" ]]; then
    nmcli connection modify "$CONEXAO" ipv4.gateway "$GATEWAY" || erro "Falha ao configurar gateway."
  fi
  nmcli connection up "$CONEXAO" || erro "Não foi possível ativar a conexão. Verifique a interface e a rede da VM."
  IP_SERVIDOR="$IP_BASE"
  ok "IP fixo aplicado. IP do servidor: $IP_SERVIDOR"
}

ler_host() {
  local valor=""
  while true; do
    read -r -p "$1" valor
    valor=$(printf '%s' "$valor" | tr '[:upper:]' '[:lower:]')
    if [[ "$valor" =~ ^(@|[a-z0-9]([a-z0-9.-]*[a-z0-9])?)$ ]] && [[ "$valor" != *..* ]]; then
      LIDO="$valor"; return
    fi
    echo "[AVISO] Nome inválido. Use @, letras, números, ponto ou hífen."
  done
}

[[ $(id -u) -eq 0 ]] || erro "Execute como root: sudo bash $0"
command -v dnf >/dev/null 2>&1 || erro "Este script requer AlmaLinux ou Rocky Linux (dnf)."

clear 2>/dev/null || true
echo "=================================================="
echo " INSTALADOR GS LINUX - DNS (BIND) + WEB (APACHE)"
echo "=================================================="
echo "Este script instala e configura somente os itens obrigatórios da GS."
perguntar_sn "Deseja continuar?"
[[ "$RESP" == "s" ]] || { info "Execução cancelada."; exit 0; }

info "Verificando conexão com a internet..."
ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 || echo "[AVISO] Não consegui testar acesso à internet por ping. O DNF/download ainda podem funcionar."

info "Configurando o endereço estático obrigatório do servidor..."
echo "[AVISO] A alteração da rede pode desconectar temporariamente a VM. Tenha acesso ao console da máquina."
configurar_ip_fixo
info "Coletando domínio que será usado no DNS..."
ler_dominio "Nome do domínio (ex.: empresa.fiap.lab): "
DOMINIO="$LIDO"

# O IP informado precisa estar configurado na VM para que os clientes alcancem o servidor.
if ! ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$IP_SERVIDOR"; then
  echo "[AVISO] O IP $IP_SERVIDOR não aparece configurado nesta VM."
  echo "        Configure-o na interface antes de esperar acesso de outros computadores."
fi

: > "$ARQ_REGISTROS"
echo
echo "Adicione os registros DNS solicitados. Digite FIM quando terminar."
echo "Tipos aceitos: A, AAAA, CNAME, MX, NS e TXT."
while true; do
  read -r -p "Tipo de registro (A/AAAA/CNAME/MX/NS/TXT ou FIM): " TIPO
  TIPO=$(printf '%s' "$TIPO" | tr '[:lower:]' '[:upper:]')
  [[ "$TIPO" == "FIM" ]] && break
  case "$TIPO" in
    A)
      ler_host "Nome do host (@ para domínio principal): "; HOST="$LIDO"
      ler_ip "Endereço IPv4: "; VALOR="$LIDO"
      echo "$HOST IN A $VALOR" >> "$ARQ_REGISTROS" ;;
    AAAA)
      ler_host "Nome do host: "; HOST="$LIDO"
      while true; do
        read -r -p "Endereço IPv6: " VALOR
        if [[ "$VALOR" =~ ^[0-9a-fA-F:]+$ && "$VALOR" == *:* ]]; then break; fi
        echo "[AVISO] IPv6 inválido."
      done
      echo "$HOST IN AAAA $VALOR" >> "$ARQ_REGISTROS" ;;
    CNAME)
      ler_host "Nome do apelido (ex.: blog): "; HOST="$LIDO"
      [[ "$HOST" != "@" ]] || { echo "[AVISO] CNAME não pode usar @ como nome."; continue; }
      ler_host "Nome de destino (ex.: www): "; VALOR="$LIDO"
      echo "$HOST IN CNAME $VALOR.$DOMINIO." >> "$ARQ_REGISTROS" ;;
    MX)
      read -r -p "Prioridade MX (ex.: 10): " PRIO
      [[ "$PRIO" =~ ^[0-9]+$ ]] || { echo "[AVISO] Prioridade inválida."; continue; }
      ler_host "Host do servidor de e-mail (ex.: mail): "; VALOR="$LIDO"
      echo "@ IN MX $PRIO $VALOR.$DOMINIO." >> "$ARQ_REGISTROS"
      echo "[AVISO] Crie também um registro A para $VALOR, se necessário." ;;
    NS)
      ler_host "Nome do servidor de nomes (ex.: ns2): "; VALOR="$LIDO"
      echo "@ IN NS $VALOR.$DOMINIO." >> "$ARQ_REGISTROS"
      echo "[AVISO] Crie também um registro A para $VALOR, se necessário." ;;
    TXT)
      ler_host "Nome do host (@ para domínio principal): "; HOST="$LIDO"
      read -r -p "Texto do registro: " VALOR
      VALOR=${VALOR//\"/}
      echo "$HOST IN TXT \"$VALOR\"" >> "$ARQ_REGISTROS" ;;
    *) echo "[AVISO] Tipo não reconhecido. Use A, AAAA, CNAME, MX, NS, TXT ou FIM." ;;
  esac
done

info "Instalando BIND, Apache e ferramentas necessárias..."
dnf install -y bind bind-utils httpd firewalld wget unzip curl || erro "Falha ao instalar pacotes. Verifique internet e repositórios."
ok "Pacotes instalados."

info "Configurando BIND..."
[[ -f "$NAMED_CONF" ]] || erro "Arquivo $NAMED_CONF não encontrado."
if [[ ! -f "$NAMED_CONF.gs-bkp" ]]; then cp -a "$NAMED_CONF" "$NAMED_CONF.gs-bkp"; fi
# Permite consultas DNS na rede do laboratório. Use somente em ambiente de aula/laboratório.
if grep -qE '^[[:space:]]*listen-on[[:space:]]+port[[:space:]]+53' "$NAMED_CONF"; then
  sed -i 's/^[[:space:]]*listen-on[[:space:]]\+port[[:space:]]\+53.*/        listen-on port 53 { any; };/' "$NAMED_CONF"
else
  sed -i '/options[[:space:]]*{/a\        listen-on port 53 { any; };' "$NAMED_CONF"
fi
if grep -qE '^[[:space:]]*allow-query' "$NAMED_CONF"; then
  sed -i 's/^[[:space:]]*allow-query.*/        allow-query { any; };/' "$NAMED_CONF"
else
  sed -i '/options[[:space:]]*{/a\        allow-query { any; };' "$NAMED_CONF"
fi
# Segurança básica: servidor autoritativo, sem recursão e sem transferência de zona.
# Remove diretivas antigas equivalentes para evitar duplicidade e aplica os valores exigidos.
if grep -qE '^[[:space:]]*recursion[[:space:]]' "$NAMED_CONF"; then
  sed -i 's/^[[:space:]]*recursion[[:space:]].*/        recursion no;/' "$NAMED_CONF"
else
  sed -i '/options[[:space:]]*{/a\        recursion no;' "$NAMED_CONF"
fi
if grep -qE '^[[:space:]]*allow-transfer[[:space:]]' "$NAMED_CONF"; then
  sed -i 's/^[[:space:]]*allow-transfer[[:space:]].*/        allow-transfer { none; };/' "$NAMED_CONF"
else
  sed -i '/options[[:space:]]*{/a\        allow-transfer { none; };' "$NAMED_CONF"
fi

if ! grep -Fq "zone \"$DOMINIO\"" "$NAMED_CONF"; then
  cat >> "$NAMED_CONF" <<ZONE

zone "$DOMINIO" IN {
    type master;
    file "$DOMINIO.zone";
    allow-transfer { none; };
};
ZONE
fi

ARQ_ZONA="$DIR_ZONAS/$DOMINIO.zone"
[[ ! -f "$ARQ_ZONA" ]] || cp -a "$ARQ_ZONA" "$ARQ_ZONA.gs-bkp.$(date +%Y%m%d%H%M%S)"
SERIAL="$(date +%Y%m%d)01"
cat > "$ARQ_ZONA" <<ZONEFILE
\$TTL 600
@ IN SOA ns1.$DOMINIO. admin.$DOMINIO. (
    $SERIAL ; Serial
    28800   ; Refresh
    14400   ; Retry
    86400   ; Expire
    600 )   ; Minimum TTL
@   IN NS ns1.$DOMINIO.
ns1 IN A  $IP_SERVIDOR
ZONEFILE
cat "$ARQ_REGISTROS" >> "$ARQ_ZONA"
chown root:named "$ARQ_ZONA"
chmod 640 "$ARQ_ZONA"
restorecon "$ARQ_ZONA" 2>/dev/null || true

named-checkconf "$NAMED_CONF" || erro "Configuração do BIND inválida. Confira $NAMED_CONF."
named-checkzone "$DOMINIO" "$ARQ_ZONA" || erro "Arquivo de zona inválido: $ARQ_ZONA."
ok "Configuração DNS validada."

info "Configurando o template do Apache..."
read -r -p "URL direta do arquivo ZIP do template HTML: " URL_TEMPLATE
[[ -n "$URL_TEMPLATE" ]] || erro "A URL do template é obrigatória para cumprir a atividade."
mkdir -p "$DIR_SITE"
if [[ -n "$URL_TEMPLATE" ]]; then
  TMP_ZIP="$(mktemp /tmp/template_gs_XXXXXX.zip)"
  TMP_DIR="$(mktemp -d /tmp/template_gs_XXXXXX)"
  if curl -fL --connect-timeout 15 --max-time 120 -o "$TMP_ZIP" "$URL_TEMPLATE" && unzip -tq "$TMP_ZIP" >/dev/null 2>&1; then
    unzip -q -o "$TMP_ZIP" -d "$TMP_DIR" || erro "Não foi possível extrair o template."
    INDEX=$(find "$TMP_DIR" -type f -name index.html -print -quit)
    [[ -n "$INDEX" ]] || erro "O ZIP não contém index.html."
    cp -a "$(dirname "$INDEX")"/. "$DIR_SITE"/
    ok "Template publicado em $DIR_SITE."
  else
    erro "Não foi possível baixar/validar o ZIP. Confira se a URL é direta e se há internet."
  fi
  rm -f "$TMP_ZIP"; rm -rf "$TMP_DIR"
else
  echo "[AVISO] URL não informada. Para cumprir o requisito do template, será necessário executar novamente com a URL correta."
  [[ -f "$DIR_SITE/index.html" ]] || echo "<h1>Servidor web $DOMINIO funcionando</h1>" > "$DIR_SITE/index.html"
fi
chmod -R a+rX "$DIR_SITE"
restorecon -R "$DIR_SITE" 2>/dev/null || true

info "Ocultando versão do Apache nos cabeçalhos HTTP..."
APACHE_SEGURANCA="/etc/httpd/conf.d/seguranca-gs.conf"
cat > "$APACHE_SEGURANCA" <<'APACHESEC'
ServerTokens Prod
ServerSignature Off
APACHESEC
httpd -t || erro "Configuração de segurança do Apache inválida."

info "Configurando firewall e iniciando serviços..."
systemctl enable --now firewalld || echo "[AVISO] Não foi possível iniciar firewalld."
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=dns
  firewall-cmd --permanent --add-service=http
  firewall-cmd --reload
fi
httpd -t || erro "Configuração do Apache inválida."
info "Habilitando inicialização automática dos serviços..."
systemctl enable named httpd || erro "Não foi possível habilitar named/httpd na inicialização."
systemctl restart named || { journalctl -u named -n 20 --no-pager; erro "BIND não iniciou."; }
systemctl restart httpd || { journalctl -u httpd -n 20 --no-pager; erro "Apache não iniciou."; }
systemctl is-active --quiet named || erro "BIND não está ativo."
systemctl is-active --quiet httpd || erro "Apache não está ativo."
ok "BIND e Apache ativos e habilitados para iniciar com o sistema."

echo
echo "=============== TESTES ==============="
echo "Consulta DNS do domínio:"
dig @127.0.0.1 "$DOMINIO" +short
echo "Consulta DNS do servidor de nomes:"
dig @127.0.0.1 "ns1.$DOMINIO" +short
CODIGO=$(curl -s -o /dev/null -w '%{http_code}' http://localhost)
echo "Resposta HTTP do Apache: $CODIGO"
[[ "$CODIGO" == "200" ]] || erro "O Apache não respondeu HTTP 200."
# Confirma que o cabeçalho Server não revela a versão detalhada do Apache.
SERVER_HEADER=$(curl -sI http://localhost | awk 'BEGIN{IGNORECASE=1} /^Server:/{print; exit}')
echo "Cabeçalho HTTP: ${SERVER_HEADER:-não identificado}"
echo "======================================="
ok "Todos os passos obrigatórios foram concluídos com sucesso."
echo "Domínio: $DOMINIO"
echo "IP fixo: $IP_SERVIDOR"
echo "Site: http://$IP_SERVIDOR"
echo "Teste DNS: dig @127.0.0.1 $DOMINIO"

echo
perguntar_sn "A instalação terminou com sucesso. Deseja reiniciar o servidor agora?"
if [[ "$RESP" == "s" ]]; then
  info "Reiniciando o servidor conforme solicitado..."
  systemctl reboot
else
  info "Reinicialização adiada pelo usuário."
fi
