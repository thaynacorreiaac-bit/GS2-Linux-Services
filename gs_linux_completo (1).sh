#!/bin/bash
# ==========================================================
# GS Linux - DNS (BIND) + Web (Apache) + módulos extras
# Sistema: AlmaLinux / Rocky Linux (usa dnf, named e httpd)
#
# FLUXO:
#   1. Confirmação do usuário
#   2. (opcional) Módulo 4 - IP fixo e hostname
#   3. Pergunta domínio, IP e registros DNS (com validação)
#   4. Instala BIND + Apache e configura a zona
#   5. Baixa o template HTML e publica no Apache
#   6. Firewall + serviços + testes
#   7. Módulos extras (cada um pergunta s/n)
#
# Como executar (como root):
#   chmod +x gs_linux_completo.sh
#   ./gs_linux_completo.sh
# ==========================================================

# ---------- CONFIGURAÇÃO (ajuste aqui) ----------
# URL do .zip do template (troque pela usada em aula)
URL_TEMPLATE="COLE_AQUI_A_URL_DO_ZIP_DO_TEMPLATE"

# "s" = pergunta antes de cada módulo extra | "n" = pula todos sem perguntar
PERGUNTAR_MODULOS="s"

# Caminhos usados pelo script
NAMED_CONF="/etc/named.conf"
DIR_ZONAS="/var/named"
DIR_SITE="/var/www/html"
DIR_WWW="/var/www"
HTTPD_CONF="/etc/httpd/conf/httpd.conf"
DIR_VHOST="/etc/httpd/conf.d"
DHCP_CONF="/etc/dhcp/dhcpd.conf"
SELINUX_CONF="/etc/selinux/config"
ARQ_REGISTROS="/tmp/registros_dns.txt"

# ---------- FUNÇÕES AUXILIARES ----------
# (funções simples que evitam repetir código)

# Pergunta s/n e repete até a resposta ser s ou n. Resultado em $RESP
confirmar() {
    RESP=""
    while [ "$RESP" != "s" ] && [ "$RESP" != "n" ]
    do
        read -p "$1 (s/n): " RESP
        RESP=$(echo "$RESP" | tr 'A-Z' 'a-z')
    done
}

# Pergunta se executa um módulo extra. Resultado em $EXEC
perguntar_modulo() {
    EXEC="n"
    if [ "$PERGUNTAR_MODULOS" = "s" ]; then
        echo ""
        confirmar "Executar $1?"
        EXEC=$RESP
    fi
}

# Retorna 0 se o texto for um IP válido (ex: 192.168.56.11)
ip_valido() {
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [ $? -ne 0 ]; then
        return 1
    fi
    for PARTE in $(echo "$1" | tr '.' ' ')
    do
        if [ "$PARTE" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

# Pergunta um texto e repete até não ser vazio. Resultado em $LIDO
ler_texto() {
    LIDO=""
    while [ -z "$LIDO" ]
    do
        read -p "$1" LIDO
    done
}

# Pergunta um IP e repete até ser válido. Resultado em $LIDO
ler_ip() {
    LIDO=""
    while [ -z "$LIDO" ]
    do
        read -p "$1" LIDO
        ip_valido "$LIDO"
        if [ $? -ne 0 ]; then
            echo "[AVISO] IP inválido. Use o formato 192.168.56.11"
            LIDO=""
        fi
    done
}

# Pergunta um número inteiro e repete até ser válido. Resultado em $LIDO
ler_numero() {
    LIDO=""
    while [ -z "$LIDO" ]
    do
        read -p "$1" LIDO
        echo "$LIDO" | grep -Eq '^[0-9]+$'
        if [ $? -ne 0 ]; then
            echo "[AVISO] Digite apenas números."
            LIDO=""
        fi
    done
}

# Pergunta um nome de host (letras, números, ponto, hífen, @). Resultado em $LIDO
ler_host() {
    LIDO=""
    while [ -z "$LIDO" ]
    do
        read -p "$1" LIDO
        LIDO=$(echo "$LIDO" | tr 'A-Z' 'a-z')
        echo "$LIDO" | grep -Eq '^[a-z0-9@._-]+$'
        if [ $? -ne 0 ]; then
            echo "[AVISO] Nome inválido. Use letras, números, ponto e hífen."
            LIDO=""
        fi
    done
}

# Pergunta um nome curto (sem ponto). Resultado em $LIDO
ler_rotulo() {
    LIDO=""
    while [ -z "$LIDO" ]
    do
        read -p "$1" LIDO
        LIDO=$(echo "$LIDO" | tr 'A-Z' 'a-z')
        echo "$LIDO" | grep -Eq '^[a-z0-9-]+$'
        if [ $? -ne 0 ]; then
            echo "[AVISO] Nome inválido. Use só letras, números e hífen."
            LIDO=""
        fi
    done
}

# Pergunta o domínio (ex: thay.fiap.lab). Resultado em $LIDO
ler_dominio() {
    LIDO=""
    while [ -z "$LIDO" ]
    do
        read -p "$1" LIDO
        LIDO=$(echo "$LIDO" | tr 'A-Z' 'a-z' | sed 's/\.$//')
        echo "$LIDO" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'
        if [ $? -ne 0 ]; then
            echo "[AVISO] Domínio inválido. Exemplo: thay.fiap.lab"
            LIDO=""
        fi
    done
}

# Aumenta o serial de um arquivo de zona (senão o BIND não atualiza)
proximo_serial() {
    ATUAL=$(grep "; Serial" "$1" | awk '{print $1}')
    if [ -z "$ATUAL" ]; then
        echo "[AVISO] Não achei o serial em $1"
        return 1
    fi
    HOJE="$(date +%Y%m%d)""01"
    if [ "$HOJE" -gt "$ATUAL" ]; then
        NOVO=$HOJE
    else
        NOVO=$((ATUAL + 1))
    fi
    sed -i "s/[0-9][0-9]*  *; Serial/$NOVO    ; Serial/" "$1"
    echo "[INFO] Serial atualizado para $NOVO"
}

# Mostra por que o serviço falhou
mostrar_erro_servico() {
    echo "[ERRO] O serviço $1 não subiu. Últimas mensagens:"
    journalctl -xeu "$1" --no-pager 2>/dev/null | tail -n 15
}

# ---------- PASSO 0: verificações iniciais ----------
if [ "$(id -u)" != "0" ]; then
    echo "[ERRO] Execute este script como root (use: sudo ./gs_linux_completo.sh)"
    exit 1
fi

command -v dnf > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[ERRO] O comando dnf não foi encontrado. Use AlmaLinux ou Rocky Linux."
    exit 1
fi

# ---------- PASSO 1: confirmação do usuário ----------
clear
echo "=============================================="
echo "   INSTALADOR AUTOMÁTICO - DNS (BIND) + WEB   "
echo "=============================================="
echo "[AVISO] Este script vai instalar o BIND e o Apache,"
echo "        criar uma zona DNS e publicar um site."
echo ""
confirmar "Deseja continuar?"
if [ "$RESP" != "s" ]; then
    echo "[INFO] Execução cancelada pelo usuário."
    exit 0
fi

echo "[INFO] Verificando conexão com a internet..."
ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[AVISO] Sem internet. A instalação e o download do template podem falhar."
else
    echo "[OK] Internet disponível."
fi

# ==========================================================
# MÓDULO 4 - IP fixo e hostname (opcional, fica antes do resto)
# ==========================================================
perguntar_modulo "MÓDULO 4 - IP fixo e hostname"
if [ "$EXEC" = "s" ]; then
    echo "[INFO] Interfaces disponíveis:"
    ip -br address
    echo ""

    # Interface: repete até digitar uma que exista
    INTERFACE=""
    while [ -z "$INTERFACE" ]
    do
        read -p "Nome da interface (ex: enp0s8): " INTERFACE
        ip link show "$INTERFACE" > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "[AVISO] Interface não encontrada."
            INTERFACE=""
        fi
    done

    # IP com máscara (ex: 192.168.56.11/24)
    IP_FIXO=""
    while [ -z "$IP_FIXO" ]
    do
        read -p "IP fixo com máscara (ex: 192.168.56.11/24): " IP_FIXO
        IP_PARTE=$(echo "$IP_FIXO" | cut -d/ -f1)
        MASC_PARTE=$(echo "$IP_FIXO" | cut -s -d/ -f2)
        VALIDO="s"
        ip_valido "$IP_PARTE"
        if [ $? -ne 0 ]; then
            VALIDO="n"
        fi
        echo "$MASC_PARTE" | grep -Eq '^[0-9]{1,2}$'
        if [ $? -ne 0 ]; then
            VALIDO="n"
        elif [ "$MASC_PARTE" -gt 32 ]; then
            VALIDO="n"
        fi
        if [ "$VALIDO" = "n" ]; then
            echo "[AVISO] Use o formato IP/máscara, ex: 192.168.56.11/24"
            IP_FIXO=""
        fi
    done

    ler_ip "Servidor DNS (ex: 192.168.56.11): "
    DNS_IP=$LIDO

    read -p "Gateway (Enter se não tiver): " GATEWAY
    if [ -n "$GATEWAY" ]; then
        ip_valido "$GATEWAY"
        if [ $? -ne 0 ]; then
            echo "[AVISO] Gateway inválido, será ignorado."
            GATEWAY=""
        fi
    fi

    ler_texto "Novo hostname (ex: ns1.thay.fiap.lab): "
    NOVO_HOST=$(echo "$LIDO" | tr 'A-Z' 'a-z')

    systemctl is-active --quiet NetworkManager
    if [ $? -ne 0 ]; then
        echo "[INFO] Iniciando o NetworkManager..."
        systemctl enable --now NetworkManager
    fi

    # Descobre o nome da conexão ligada à interface
    CONEXAO=$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null)
    if [ -z "$CONEXAO" ] || [ "$CONEXAO" = "--" ]; then
        echo "[AVISO] Interface sem conexão. Criando uma nova..."
        nmcli connection add type ethernet ifname "$INTERFACE" con-name "$INTERFACE"
        CONEXAO=$INTERFACE
    fi

    echo "[INFO] Configurando IP fixo na conexão $CONEXAO..."
    nmcli connection modify "$CONEXAO" ipv4.method manual ipv4.addresses "$IP_FIXO" ipv4.dns "$DNS_IP"
    if [ -n "$GATEWAY" ]; then
        nmcli connection modify "$CONEXAO" ipv4.gateway "$GATEWAY"
    fi
    nmcli connection up "$CONEXAO"
    if [ $? -ne 0 ]; then
        echo "[ERRO] Não foi possível ativar a conexão. Confira com: nmcli connection show"
        exit 1
    fi

    echo "[INFO] Configurando o hostname..."
    hostnamectl set-hostname "$NOVO_HOST"
    IP_SEM_MASCARA=$(echo "$IP_FIXO" | cut -d/ -f1)
    grep -q "$NOVO_HOST" /etc/hosts
    if [ $? -ne 0 ]; then
        echo "$IP_SEM_MASCARA    $NOVO_HOST" >> /etc/hosts
    fi

    echo "[OK] Resultado:"
    ip -br address show "$INTERFACE"
    hostname
fi

# ---------- PASSO 2: coletar dados do usuário ----------
echo ""
echo "[INFO] PASSO 2: coletando informações..."
ler_dominio "Nome do domínio (ex: thay.fiap.lab): "
DOMINIO=$LIDO
ler_ip "IP deste servidor (ex: 192.168.56.11): "
IP_SERVIDOR=$LIDO

# Avisa se o IP não está configurado nesta máquina
ip -4 address | grep -qw "$IP_SERVIDOR"
if [ $? -ne 0 ]; then
    echo "[AVISO] O IP $IP_SERVIDOR não está configurado nesta máquina."
    echo "        Confira com: ip -br address (ou use o módulo 4)."
fi

# Limpa o arquivo temporário onde os registros ficam guardados
> "$ARQ_REGISTROS"

# Loop que pede os registros até o usuário digitar FIM
TIPO=""
while [ "$TIPO" != "FIM" ]
do
    echo ""
    read -p "Tipo de registro (A, AAAA, CNAME, MX, NS, TXT) ou FIM para terminar: " TIPO
    TIPO=$(echo "$TIPO" | tr 'a-z' 'A-Z')

    if [ "$TIPO" = "A" ]; then
        ler_host "  Nome do host (ex: www, ou @ para o domínio): "
        HOST=$LIDO
        ler_ip "  Endereço IP (ex: 192.168.56.11): "
        grep -q "^$HOST[[:space:]]*IN[[:space:]]*CNAME" "$ARQ_REGISTROS"
        if [ $? -eq 0 ]; then
            echo "[AVISO] $HOST já é um CNAME. Registro ignorado."
        else
            echo "$HOST    IN    A    $LIDO" >> "$ARQ_REGISTROS"
            echo "[INFO] Registro A adicionado: $HOST -> $LIDO"
        fi

    elif [ "$TIPO" = "AAAA" ]; then
        ler_host "  Nome do host (ex: www): "
        HOST=$LIDO
        VALOR=""
        while [ -z "$VALOR" ]
        do
            read -p "  Endereço IPv6 (ex: 2001:db8::1): " VALOR
            echo "$VALOR" | grep -Eq '^[0-9a-fA-F:]+$'
            if [ $? -ne 0 ]; then
                echo "[AVISO] IPv6 inválido."
                VALOR=""
            fi
        done
        echo "$HOST    IN    AAAA    $VALOR" >> "$ARQ_REGISTROS"
        echo "[INFO] Registro AAAA adicionado: $HOST -> $VALOR"

    elif [ "$TIPO" = "CNAME" ]; then
        ler_host "  Nome do apelido (ex: site): "
        HOST=$LIDO
        ler_host "  Aponta para qual host (ex: www): "
        VALOR=$LIDO
        grep -q "^$HOST[[:space:]]" "$ARQ_REGISTROS"
        if [ $? -eq 0 ] || [ "$HOST" = "ns1" ] || [ "$HOST" = "@" ]; then
            echo "[AVISO] $HOST já existe (CNAME não pode coexistir com outro registro). Ignorado."
        else
            echo "$HOST    IN    CNAME    $VALOR" >> "$ARQ_REGISTROS"
            echo "[INFO] Registro CNAME adicionado: $HOST -> $VALOR"
        fi

    elif [ "$TIPO" = "MX" ]; then
        ler_numero "  Prioridade (ex: 10): "
        PRIO=$LIDO
        ler_host "  Host do servidor de e-mail (ex: mail): "
        echo "@    IN    MX    $PRIO    $LIDO" >> "$ARQ_REGISTROS"
        echo "[INFO] Registro MX adicionado: $LIDO (prioridade $PRIO)"
        echo "[AVISO] Lembre de criar também um registro A para o host $LIDO"

    elif [ "$TIPO" = "NS" ]; then
        ler_host "  Nome do servidor de nomes (ex: ns2): "
        echo "@    IN    NS    $LIDO" >> "$ARQ_REGISTROS"
        echo "[INFO] Registro NS adicionado: $LIDO"
        echo "[AVISO] Lembre de criar também um registro A para o host $LIDO"

    elif [ "$TIPO" = "TXT" ]; then
        ler_host "  Nome do host (ex: @): "
        HOST=$LIDO
        ler_texto "  Texto do registro: "
        VALOR=$(echo "$LIDO" | tr -d '"')
        echo "$HOST    IN    TXT    \"$VALOR\"" >> "$ARQ_REGISTROS"
        echo "[INFO] Registro TXT adicionado em $HOST"

    elif [ "$TIPO" = "FIM" ]; then
        echo "[INFO] Registros coletados."
    else
        echo "[AVISO] Tipo inválido. Use A, AAAA, CNAME, MX, NS, TXT ou FIM."
    fi
done

# Avisa se faltou o registro do www (o site abre por ele)
grep -q "^www[[:space:]]" "$ARQ_REGISTROS"
if [ $? -ne 0 ]; then
    echo "[AVISO] Você não criou o registro 'www'. O site não vai abrir por www.$DOMINIO"
fi

# ---------- PASSO 3: instalar pacotes ----------
echo ""
echo "[INFO] PASSO 3: instalando BIND, Apache, firewalld, wget e unzip..."
dnf install -y bind bind-utils httpd firewalld wget unzip curl
if [ $? -ne 0 ]; then
    echo "[ERRO] Falha na instalação dos pacotes. Verifique a internet e o repositório."
    exit 1
fi
echo "[OK] Pacotes instalados."

# ---------- PASSO 4: configurar o BIND ----------
echo ""
echo "[INFO] PASSO 4: configurando o servidor DNS..."

# Backup do arquivo original (só na primeira vez, para não sobrescrever o original)
if [ ! -f "$NAMED_CONF.bkp" ]; then
    cp "$NAMED_CONF" "$NAMED_CONF.bkp"
    echo "[INFO] Backup criado em $NAMED_CONF.bkp"
fi

# Escuta em todas as interfaces e aceita consultas de qualquer rede
sed -i 's/^\([[:space:]]*\)listen-on port 53 .*/\1listen-on port 53 { any; };/' "$NAMED_CONF"
sed -i 's/^\([[:space:]]*\)allow-query[[:space:]].*/\1allow-query { any; };/' "$NAMED_CONF"
grep -q "listen-on port 53 { any; };" "$NAMED_CONF"
if [ $? -ne 0 ]; then
    echo "[AVISO] Não consegui ajustar o listen-on no named.conf. Confira o arquivo."
fi
grep -q "allow-query { any; };" "$NAMED_CONF"
if [ $? -ne 0 ]; then
    echo "[AVISO] Não consegui ajustar o allow-query no named.conf. Confira o arquivo."
fi

# Declara a zona no named.conf (só se ainda não existir)
grep -q "zone \"$DOMINIO\"" "$NAMED_CONF"
if [ $? -ne 0 ]; then
    echo "zone \"$DOMINIO\" IN {" >> "$NAMED_CONF"
    echo "    type master;" >> "$NAMED_CONF"
    echo "    file \"$DOMINIO.zone\";" >> "$NAMED_CONF"
    echo "};" >> "$NAMED_CONF"
    echo "[INFO] Zona $DOMINIO declarada no named.conf"
else
    echo "[AVISO] A zona $DOMINIO já existe no named.conf, pulando."
fi

# Monta o arquivo de zona
ARQ_ZONA="$DIR_ZONAS/$DOMINIO.zone"
SERIAL="$(date +%Y%m%d)""01"

echo "\$TTL 600" > "$ARQ_ZONA"
echo "@    IN    SOA    ns1.$DOMINIO.    admin.$DOMINIO. (" >> "$ARQ_ZONA"
echo "        $SERIAL    ; Serial" >> "$ARQ_ZONA"
echo "        28800      ; Refresh" >> "$ARQ_ZONA"
echo "        14400      ; Retry" >> "$ARQ_ZONA"
echo "        86400      ; Expire" >> "$ARQ_ZONA"
echo "        600 )      ; Minimum TTL" >> "$ARQ_ZONA"
echo "" >> "$ARQ_ZONA"
echo "@      IN    NS    ns1.$DOMINIO." >> "$ARQ_ZONA"
echo "ns1    IN    A     $IP_SERVIDOR" >> "$ARQ_ZONA"

# Adiciona os registros que o usuário digitou
cat "$ARQ_REGISTROS" >> "$ARQ_ZONA"

# Permissões e contexto SELinux do arquivo de zona
chown root:named "$ARQ_ZONA"
chmod 640 "$ARQ_ZONA"
restorecon "$ARQ_ZONA" 2>/dev/null
echo "[INFO] Arquivo de zona criado em $ARQ_ZONA"

# Valida as configurações antes de subir o serviço
named-checkconf "$NAMED_CONF"
if [ $? -ne 0 ]; then
    echo "[ERRO] Erro no named.conf. Corrija e execute novamente."
    exit 1
fi
named-checkzone "$DOMINIO" "$ARQ_ZONA"
if [ $? -ne 0 ]; then
    echo "[ERRO] Erro no arquivo de zona $ARQ_ZONA. Corrija e execute novamente."
    exit 1
fi
echo "[OK] Configuração do DNS validada."

# ---------- PASSO 5: publicar o site ----------
echo ""
echo "[INFO] PASSO 5: baixando e publicando o template HTML..."

# Evita o aviso "Could not reliably determine the server's fully qualified domain name"
grep -q "^ServerName" "$HTTPD_CONF"
if [ $? -ne 0 ]; then
    echo "ServerName $DOMINIO" >> "$HTTPD_CONF"
fi

# Limpa a pasta do site e a pasta temporária
if [ -n "$DIR_SITE" ] && [ -d "$DIR_SITE" ]; then
    rm -rf "$DIR_SITE"/*
fi
rm -rf /tmp/template /tmp/template.zip
mkdir /tmp/template

echo "$URL_TEMPLATE" | grep -q "COLE_AQUI"
if [ $? -eq 0 ]; then
    echo "[AVISO] A URL_TEMPLATE não foi configurada no começo do script."
else
    wget -q --tries=2 --timeout=20 -O /tmp/template.zip "$URL_TEMPLATE"
    if [ $? -ne 0 ]; then
        echo "[AVISO] Não consegui baixar o template. Verifique a URL e a internet."
    else
        unzip -tq /tmp/template.zip > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "[AVISO] O arquivo baixado não é um .zip válido."
        else
            unzip -q -o /tmp/template.zip -d /tmp/template
            # Acha o index.html menos profundo dentro do template
            INDEX=$(find /tmp/template -name index.html | awk '{print length($0) " " $0}' | sort -n | head -n 1 | cut -d' ' -f2-)
            if [ -z "$INDEX" ]; then
                echo "[AVISO] O template não tem index.html."
            else
                PASTA=$(dirname "$INDEX")
                cp -r "$PASTA"/. "$DIR_SITE"/
                echo "[OK] Template copiado para $DIR_SITE"
            fi
        fi
    fi
fi

# Se mesmo assim não existir index.html, cria uma página simples
if [ ! -f "$DIR_SITE/index.html" ]; then
    echo "[AVISO] Criando página padrão simples."
    echo "<h1>Site $DOMINIO funcionando!</h1>" > "$DIR_SITE/index.html"
fi

# Garante que o Apache consegue ler os arquivos (permissão e SELinux)
chmod -R a+rX "$DIR_SITE"
restorecon -R "$DIR_SITE" 2>/dev/null

# ---------- PASSO 6: firewall e serviços ----------
echo ""
echo "[INFO] PASSO 6: liberando firewall e iniciando serviços..."
systemctl enable --now firewalld
systemctl is-active --quiet firewalld
if [ $? -eq 0 ]; then
    firewall-cmd --permanent --add-service=dns
    firewall-cmd --permanent --add-service=http
    firewall-cmd --reload
    echo "[OK] Firewall liberado para dns e http."
else
    echo "[AVISO] O firewalld não iniciou. Libere as portas 53 e 80 manualmente."
fi

httpd -t
if [ $? -ne 0 ]; then
    echo "[ERRO] Erro na configuração do Apache (veja a mensagem acima)."
    exit 1
fi

systemctl enable named httpd
systemctl restart named
systemctl is-active --quiet named
if [ $? -ne 0 ]; then
    mostrar_erro_servico named
    exit 1
fi
systemctl restart httpd
systemctl is-active --quiet httpd
if [ $? -ne 0 ]; then
    mostrar_erro_servico httpd
    exit 1
fi
echo "[OK] Serviços named e httpd ativos."

# ---------- TESTES DO FLUXO PRINCIPAL ----------
echo ""
echo "[INFO] Testando DNS e site..."
echo "--- Consulta DNS (ns1.$DOMINIO) ---"
dig @127.0.0.1 ns1.$DOMINIO +short
CODIGO=$(curl -s -o /dev/null -w "%{http_code}" http://localhost)
if [ "$CODIGO" = "200" ]; then
    echo "[OK] Servidor web respondeu 200 (OK)."
else
    echo "[AVISO] Servidor web respondeu código $CODIGO."
fi

# ##########################################################
# MÓDULOS EXTRAS (cada um pergunta se deve ser executado)
# ##########################################################

# ==========================================================
# MÓDULO 1 - Zona reversa (PTR)
# ==========================================================
perguntar_modulo "MÓDULO 1 - Zona reversa (PTR)"
if [ "$EXEC" = "s" ]; then
    echo "[INFO] Criando a zona reversa (rede /24)..."

    # Pega os 3 primeiros números do IP (ex: 192.168.56)
    REDE=$(echo "$IP_SERVIDOR" | cut -d. -f1-3)
    # Inverte a rede: 192.168.56 vira 56.168.192
    REVERSA=$(echo "$REDE" | awk -F. '{print $3"."$2"."$1}')
    ARQ_REV="$DIR_ZONAS/$REVERSA.zone"
    SERIAL="$(date +%Y%m%d)""01"

    # Declara a zona reversa no named.conf (só se não existir)
    grep -q "zone \"$REVERSA.in-addr.arpa\"" "$NAMED_CONF"
    if [ $? -ne 0 ]; then
        echo "zone \"$REVERSA.in-addr.arpa\" IN {" >> "$NAMED_CONF"
        echo "    type master;" >> "$NAMED_CONF"
        echo "    file \"$REVERSA.zone\";" >> "$NAMED_CONF"
        echo "};" >> "$NAMED_CONF"
        echo "[INFO] Zona reversa declarada no named.conf"
    fi

    # Cabeçalho do arquivo da zona reversa
    echo "\$TTL 600" > "$ARQ_REV"
    echo "@    IN    SOA    ns1.$DOMINIO.    admin.$DOMINIO. (" >> "$ARQ_REV"
    echo "        $SERIAL    ; Serial" >> "$ARQ_REV"
    echo "        28800      ; Refresh" >> "$ARQ_REV"
    echo "        14400      ; Retry" >> "$ARQ_REV"
    echo "        86400      ; Expire" >> "$ARQ_REV"
    echo "        600 )      ; Minimum TTL" >> "$ARQ_REV"
    echo "" >> "$ARQ_REV"
    echo "@    IN    NS    ns1.$DOMINIO." >> "$ARQ_REV"

    # Loop para criar os registros PTR (não aceita valor vazio)
    RESP="s"
    while [ "$RESP" = "s" ]
    do
        FINAL=""
        while [ -z "$FINAL" ]
        do
            ler_numero "Último número do IP (ex: 11): "
            if [ "$LIDO" -gt 255 ]; then
                echo "[AVISO] O número deve ser de 0 a 255."
            else
                FINAL=$LIDO
            fi
        done
        ler_rotulo "Nome do host (ex: www): "
        HOST_PTR=$LIDO

        grep -q "^$FINAL[[:space:]]" "$ARQ_REV"
        if [ $? -eq 0 ]; then
            echo "[AVISO] Já existe PTR para o final $FINAL. Ignorado."
        else
            echo "$FINAL    IN    PTR    $HOST_PTR.$DOMINIO." >> "$ARQ_REV"
            echo "[INFO] PTR adicionado: $REDE.$FINAL -> $HOST_PTR.$DOMINIO"
        fi
        confirmar "Adicionar outro PTR?"
    done

    # Permissões e validação
    chown root:named "$ARQ_REV"
    chmod 640 "$ARQ_REV"
    restorecon "$ARQ_REV" 2>/dev/null

    named-checkconf "$NAMED_CONF"
    if [ $? -ne 0 ]; then
        echo "[ERRO] Erro no named.conf."
        exit 1
    fi
    named-checkzone "$REVERSA.in-addr.arpa" "$ARQ_REV"
    if [ $? -ne 0 ]; then
        echo "[ERRO] Problema na zona reversa $ARQ_REV."
        exit 1
    fi

    systemctl restart named
    systemctl is-active --quiet named
    if [ $? -ne 0 ]; then
        mostrar_erro_servico named
        exit 1
    fi
    echo "[OK] Zona reversa criada. Teste:"
    dig @127.0.0.1 -x "$IP_SERVIDOR" +short
fi

# ==========================================================
# MÓDULO 2A - DNS secundário (parte feita NO PRIMÁRIO)
# (a parte do servidor secundário está no arquivo gs_secundario.sh)
# ==========================================================
perguntar_modulo "MÓDULO 2A - DNS secundário (parte no PRIMÁRIO)"
if [ "$EXEC" = "s" ]; then
    ARQ_ZONA="$DIR_ZONAS/$DOMINIO.zone"

    grep -q "zone \"$DOMINIO\"" "$NAMED_CONF"
    if [ $? -ne 0 ] || [ ! -f "$ARQ_ZONA" ]; then
        echo "[ERRO] A zona $DOMINIO não existe neste servidor."
        exit 1
    fi

    ler_ip "IP do servidor SECUNDÁRIO: "
    IP_SEC=$LIDO
    echo "[INFO] Liberando transferência de zona para $IP_SEC..."

    # Insere as linhas logo abaixo de 'file "dominio.zone";' (sem duplicar)
    grep -q "allow-transfer { $IP_SEC; };" "$NAMED_CONF"
    if [ $? -ne 0 ]; then
        sed -i "/file \"$DOMINIO.zone\";/a allow-transfer { $IP_SEC; };" "$NAMED_CONF"
        sed -i "/file \"$DOMINIO.zone\";/a also-notify { $IP_SEC; };" "$NAMED_CONF"
    else
        echo "[AVISO] allow-transfer já configurado para $IP_SEC."
    fi

    # Registros do segundo servidor de nomes (sem duplicar)
    grep -q "^ns2[[:space:]]" "$ARQ_ZONA"
    if [ $? -ne 0 ]; then
        echo "@      IN    NS    ns2.$DOMINIO." >> "$ARQ_ZONA"
        echo "ns2    IN    A     $IP_SEC" >> "$ARQ_ZONA"
    else
        echo "[AVISO] O registro ns2 já existe na zona."
    fi

    proximo_serial "$ARQ_ZONA"

    named-checkconf "$NAMED_CONF"
    if [ $? -ne 0 ]; then
        echo "[ERRO] Erro no named.conf."
        exit 1
    fi
    named-checkzone "$DOMINIO" "$ARQ_ZONA"
    if [ $? -ne 0 ]; then
        echo "[ERRO] Problema na zona. Corrija antes de continuar."
        exit 1
    fi

    systemctl restart named
    systemctl is-active --quiet named
    if [ $? -ne 0 ]; then
        mostrar_erro_servico named
        exit 1
    fi
    echo "[OK] Primário pronto. Agora rode o gs_secundario.sh na VM secundária."
fi

# ==========================================================
# MÓDULO 3 - Virtual host no Apache
# ==========================================================
perguntar_modulo "MÓDULO 3 - Virtual host no Apache"
if [ "$EXEC" = "s" ]; then
    ler_rotulo "Nome do novo site (ex: blog): "
    NOME_SITE=$LIDO
    SITE="$NOME_SITE.$DOMINIO"
    PASTA="$DIR_WWW/$SITE"

    echo "[INFO] Criando o site $SITE..."

    # Pasta e página do novo site
    mkdir -p "$PASTA"
    if [ ! -f "$PASTA/index.html" ]; then
        echo "<h1>Bem-vindo ao $SITE</h1>" > "$PASTA/index.html"
    fi
    chmod -R a+rX "$PASTA"
    restorecon -R "$PASTA" 2>/dev/null

    # Quando existe VirtualHost, o primeiro vira o padrão.
    # Por isso criamos antes o vhost do site principal (arquivo 00-...)
    PRINCIPAL="$DIR_VHOST/00-principal.conf"
    if [ ! -f "$PRINCIPAL" ]; then
        echo "<VirtualHost *:80>" > "$PRINCIPAL"
        echo "    ServerName www.$DOMINIO" >> "$PRINCIPAL"
        echo "    ServerAlias $DOMINIO" >> "$PRINCIPAL"
        echo "    DocumentRoot $DIR_SITE" >> "$PRINCIPAL"
        echo "</VirtualHost>" >> "$PRINCIPAL"
        echo "[INFO] Vhost do site principal criado."
    fi

    # VirtualHost do novo site
    CONF="$DIR_VHOST/$SITE.conf"
    echo "<VirtualHost *:80>" > "$CONF"
    echo "    ServerName $SITE" >> "$CONF"
    echo "    DocumentRoot $PASTA" >> "$CONF"
    echo "    <Directory $PASTA>" >> "$CONF"
    echo "        Require all granted" >> "$CONF"
    echo "    </Directory>" >> "$CONF"
    echo "</VirtualHost>" >> "$CONF"

    # Testa a configuração do Apache (se falhar, remove o vhost novo)
    httpd -t
    if [ $? -ne 0 ]; then
        echo "[ERRO] Erro na configuração do Apache. Removendo $CONF"
        rm -f "$CONF"
        exit 1
    fi
    systemctl restart httpd

    # Cria o registro A do novo site no DNS (sem duplicar)
    ARQ_ZONA="$DIR_ZONAS/$DOMINIO.zone"
    if [ -f "$ARQ_ZONA" ]; then
        grep -q "^$NOME_SITE[[:space:]]" "$ARQ_ZONA"
        if [ $? -ne 0 ]; then
            echo "$NOME_SITE    IN    A    $IP_SERVIDOR" >> "$ARQ_ZONA"
            proximo_serial "$ARQ_ZONA"
            named-checkzone "$DOMINIO" "$ARQ_ZONA"
            if [ $? -ne 0 ]; then
                echo "[ERRO] Problema na zona após adicionar $NOME_SITE."
                exit 1
            fi
            systemctl restart named
            echo "[INFO] Registro A de $SITE criado no DNS."
        else
            echo "[AVISO] Já existe o registro $NOME_SITE na zona."
        fi
    fi

    echo "[OK] Teste:"
    curl -s -H "Host: $SITE" http://localhost
fi

# ==========================================================
# MÓDULO 5 - Firewall, SELinux e porta do Apache
# ==========================================================
perguntar_modulo "MÓDULO 5 - Firewall, SELinux e porta do Apache"
if [ "$EXEC" = "s" ]; then
    echo "[INFO] Status atual:"
    echo "SELinux: $(getenforce)"

    # Garante que o firewalld está rodando
    systemctl enable --now firewalld
    firewall-cmd --list-all

    # --- Liberar serviços no firewall ---
    SERVICO=""
    while [ "$SERVICO" != "fim" ]
    do
        read -p "Serviço a liberar (dns, http, https, dhcp, ssh) ou fim: " SERVICO
        SERVICO=$(echo "$SERVICO" | tr 'A-Z' 'a-z')
        if [ "$SERVICO" != "fim" ] && [ -n "$SERVICO" ]; then
            firewall-cmd --get-services | tr ' ' '\n' | grep -qx "$SERVICO"
            if [ $? -eq 0 ]; then
                firewall-cmd --permanent --add-service="$SERVICO"
                echo "[INFO] Serviço $SERVICO liberado."
            else
                echo "[AVISO] Serviço $SERVICO não existe no firewalld."
            fi
        fi
    done
    firewall-cmd --reload

    # --- Trocar a porta do Apache (opcional) ---
    read -p "Nova porta para o Apache (Enter para pular): " PORTA_HTTP
    if [ -n "$PORTA_HTTP" ]; then
        echo "$PORTA_HTTP" | grep -Eq '^[0-9]+$'
        if [ $? -ne 0 ] || [ "$PORTA_HTTP" -gt 65535 ]; then
            echo "[AVISO] Porta inválida. Pulando."
        else
            echo "[INFO] Mudando o Apache para a porta $PORTA_HTTP..."
            dnf install -y policycoreutils-python-utils
            sed -i "s/^Listen .*/Listen $PORTA_HTTP/" "$HTTPD_CONF"

            # Só cadastra no SELinux se a porta ainda não estiver liberada para o http
            semanage port -l | grep -w "^http_port_t" | grep -qw "$PORTA_HTTP"
            if [ $? -ne 0 ]; then
                semanage port -a -t http_port_t -p tcp "$PORTA_HTTP"
            fi

            firewall-cmd --permanent --add-port="$PORTA_HTTP"/tcp
            firewall-cmd --reload
            httpd -t
            if [ $? -ne 0 ]; then
                echo "[ERRO] Erro na configuração do Apache."
                exit 1
            fi
            systemctl restart httpd
            echo "[OK] Apache escutando na porta $PORTA_HTTP"
        fi
    fi

    # --- Corrigir contextos do SELinux ---
    echo "[INFO] Restaurando contextos do SELinux..."
    restorecon -R /var/named /var/www /etc/dhcp 2>/dev/null

    # --- Mudar o modo do SELinux (opcional) ---
    read -p "Modo do SELinux (enforcing/permissive ou Enter para manter): " MODO
    if [ "$MODO" = "permissive" ]; then
        setenforce 0
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$SELINUX_CONF"
        echo "[AVISO] SELinux em modo permissive."
    elif [ "$MODO" = "enforcing" ]; then
        setenforce 1
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' "$SELINUX_CONF"
        echo "[INFO] SELinux em modo enforcing."
    fi

    echo "[OK] Firewall e SELinux configurados."
    firewall-cmd --list-all
fi

# ==========================================================
# MÓDULO 6 - Servidor DHCP
# ==========================================================
perguntar_modulo "MÓDULO 6 - Servidor DHCP"
if [ "$EXEC" = "s" ]; then
    echo "[AVISO] O servidor precisa de IP fixo dentro da rede do escopo (módulo 4)."
    echo "[AVISO] No VirtualBox, desative o DHCP da rede Host-Only (Ferramentas > Rede)"
    echo "        para ele não responder no lugar do seu servidor."

    ler_ip "Rede (ex: 192.168.56.0): "
    REDE_DHCP=$LIDO
    ler_ip "Máscara (ex: 255.255.255.0): "
    MASCARA=$LIDO
    ler_ip "IP inicial da faixa (ex: 192.168.56.100): "
    INICIO=$LIDO
    ler_ip "IP final da faixa (ex: 192.168.56.150): "
    FIM=$LIDO
    ler_ip "Gateway (ex: 192.168.56.1): "
    GATEWAY_DHCP=$LIDO
    ler_ip "Servidor DNS (ex: $IP_SERVIDOR): "
    DNS_DHCP=$LIDO

    # Avisa se nenhuma interface está na rede do escopo (vale para máscara /24)
    if [ "$MASCARA" = "255.255.255.0" ]; then
        PREFIXO=$(echo "$REDE_DHCP" | cut -d. -f1-3)
        ip -4 address | grep -q "inet $PREFIXO\."
        if [ $? -ne 0 ]; then
            echo "[AVISO] Nenhuma interface desta máquina está na rede $REDE_DHCP."
            echo "        O dhcpd não vai subir. Use o módulo 4 para colocar um IP fixo."
        fi
    fi

    echo "[INFO] Instalando o servidor DHCP..."
    dnf install -y dhcp-server
    if [ $? -ne 0 ]; then
        echo "[ERRO] Falha na instalação do dhcp-server."
        exit 1
    fi

    # Backup (só na primeira vez) e criação do dhcpd.conf
    if [ ! -f "$DHCP_CONF.bkp" ]; then
        cp "$DHCP_CONF" "$DHCP_CONF.bkp" 2>/dev/null
    fi

    echo "default-lease-time 600;" > "$DHCP_CONF"
    echo "max-lease-time 7200;" >> "$DHCP_CONF"
    echo "authoritative;" >> "$DHCP_CONF"
    echo "" >> "$DHCP_CONF"
    echo "subnet $REDE_DHCP netmask $MASCARA {" >> "$DHCP_CONF"
    echo "    range $INICIO $FIM;" >> "$DHCP_CONF"
    echo "    option routers $GATEWAY_DHCP;" >> "$DHCP_CONF"
    echo "    option domain-name-servers $DNS_DHCP;" >> "$DHCP_CONF"
    echo "    option domain-name \"$DOMINIO\";" >> "$DHCP_CONF"
    echo "}" >> "$DHCP_CONF"

    # Reserva de IP por MAC (opcional)
    confirmar "Criar reserva de IP por MAC?"
    if [ "$RESP" = "s" ]; then
        ler_rotulo "Nome da máquina (ex: cliente1): "
        NOME_RES=$LIDO
        MAC=""
        while [ -z "$MAC" ]
        do
            read -p "MAC (ex: 08:00:27:aa:bb:cc): " MAC
            echo "$MAC" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
            if [ $? -ne 0 ]; then
                echo "[AVISO] MAC inválido."
                MAC=""
            fi
        done
        ler_ip "IP reservado (ex: 192.168.56.120): "
        echo "" >> "$DHCP_CONF"
        echo "host $NOME_RES {" >> "$DHCP_CONF"
        echo "    hardware ethernet $MAC;" >> "$DHCP_CONF"
        echo "    fixed-address $LIDO;" >> "$DHCP_CONF"
        echo "}" >> "$DHCP_CONF"
        echo "[INFO] Reserva criada: $MAC -> $LIDO"
    fi

    # Valida a configuração
    dhcpd -t -cf "$DHCP_CONF"
    if [ $? -ne 0 ]; then
        echo "[ERRO] Erro no dhcpd.conf."
        exit 1
    fi

    systemctl enable --now firewalld
    firewall-cmd --permanent --add-service=dhcp
    firewall-cmd --reload

    systemctl enable dhcpd
    systemctl restart dhcpd
    systemctl is-active --quiet dhcpd
    if [ $? -ne 0 ]; then
        mostrar_erro_servico dhcpd
        exit 1
    fi
    echo "[OK] DHCP ativo. No cliente, teste: nmcli device reapply <interface>"
fi

# ==========================================================
# MÓDULO 7A - Criar usuários
# ==========================================================
perguntar_modulo "MÓDULO 7A - Criar usuários"
if [ "$EXEC" = "s" ]; then
    RESP="s"
    while [ "$RESP" = "s" ]
    do
        # Nome de usuário válido: minúsculas, números, _ e -
        USUARIO=""
        while [ -z "$USUARIO" ]
        do
            read -p "Nome do usuário: " USUARIO
            echo "$USUARIO" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'
            if [ $? -ne 0 ]; then
                echo "[AVISO] Nome inválido. Use minúsculas, números, _ e -"
                USUARIO=""
            fi
        done

        SENHA=""
        while [ -z "$SENHA" ]
        do
            read -s -p "Senha: " SENHA
            echo ""
            if [ -z "$SENHA" ]; then
                echo "[AVISO] A senha não pode ser vazia."
            fi
        done

        read -p "Grupo (Enter para nenhum): " GRUPO

        id "$USUARIO" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "[AVISO] O usuário $USUARIO já existe."
        else
            useradd -m "$USUARIO"
            echo "$USUARIO:$SENHA" | chpasswd
            echo "[OK] Usuário $USUARIO criado."

            # Cria o grupo se não existir e adiciona o usuário
            if [ -n "$GRUPO" ]; then
                echo "$GRUPO" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'
                if [ $? -ne 0 ]; then
                    echo "[AVISO] Nome de grupo inválido. Grupo ignorado."
                else
                    getent group "$GRUPO" > /dev/null
                    if [ $? -ne 0 ]; then
                        groupadd "$GRUPO"
                        echo "[INFO] Grupo $GRUPO criado."
                    fi
                    usermod -aG "$GRUPO" "$USUARIO"
                    echo "[INFO] $USUARIO adicionado ao grupo $GRUPO."
                fi
            fi

            confirmar "Forçar troca de senha no primeiro login?"
            if [ "$RESP" = "s" ]; then
                chage -d 0 "$USUARIO"
            fi
        fi

        confirmar "Criar outro usuário?"
    done
    echo "[OK] Fim da criação de usuários."
fi

# ==========================================================
# MÓDULO 7B - Excluir, bloquear ou dar sudo a um usuário
# ==========================================================
perguntar_modulo "MÓDULO 7B - Excluir, bloquear ou dar sudo a um usuário"
if [ "$EXEC" = "s" ]; then
    read -p "Nome do usuário: " USUARIO
    if [ "$USUARIO" = "root" ] || [ -z "$USUARIO" ]; then
        echo "[ERRO] Usuário inválido (não mexa no root)."
        exit 1
    fi
    id "$USUARIO" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "[ERRO] O usuário $USUARIO não existe."
        exit 1
    fi

    echo "1 - Excluir (apaga a pasta home também)"
    echo "2 - Bloquear"
    echo "3 - Desbloquear"
    echo "4 - Dar permissão de administrador (sudo)"
    read -p "Escolha uma opção: " OPCAO

    if [ "$OPCAO" = "1" ]; then
        confirmar "Tem certeza que quer EXCLUIR $USUARIO?"
        if [ "$RESP" = "s" ]; then
            userdel -r "$USUARIO"
            echo "[OK] Usuário $USUARIO excluído."
        else
            echo "[INFO] Cancelado."
        fi
    elif [ "$OPCAO" = "2" ]; then
        usermod -L "$USUARIO"
        echo "[OK] Usuário $USUARIO bloqueado."
    elif [ "$OPCAO" = "3" ]; then
        usermod -U "$USUARIO"
        echo "[OK] Usuário $USUARIO desbloqueado."
    elif [ "$OPCAO" = "4" ]; then
        usermod -aG wheel "$USUARIO"
        echo "[OK] $USUARIO agora está no grupo wheel (sudo)."
    else
        echo "[AVISO] Opção inválida."
    fi
fi

# ---------- FIM ----------
echo ""
echo "=============================================="
echo "[CONCLUÍDO] Domínio: $DOMINIO"
echo "            Site:    http://$IP_SERVIDOR"
echo "=============================================="
