#!/bin/bash
# ==========================================================
# GS Linux - Automação de Servidor DNS (BIND) + Web (Apache)
# Sistema: AlmaLinux / Rocky Linux (usa dnf, named e httpd)
#
# VERSÃO COMPLETA: script principal + módulos extras (perguntam s/n)
#
# O que o script faz:
#   1. Pede confirmação para continuar
#   2. Pergunta o domínio, o IP do servidor e os registros DNS
#   3. Instala BIND e Apache
#   4. Cria a zona DNS e configura o named
#   5. Baixa um template HTML da Internet e publica no Apache
#   6. Libera o firewall, sobe os serviços e testa
#
# Como executar (como root):
#   chmod +x gs_dns_web.sh
#   ./gs_dns_web.sh
# ==========================================================

# ---------- CONFIGURAÇÃO (troque a URL pela do template usado em aula) ----------
URL_TEMPLATE="COLE_AQUI_A_URL_DO_ZIP_DO_TEMPLATE"
ARQ_REGISTROS="/tmp/registros_dns.txt"

# ---------- PASSO 0: verificar se é root ----------
if [ "$(id -u)" != "0" ]; then
    echo "[ERRO] Execute este script como root (use: sudo ./gs_dns_web.sh)"
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
read -p "Deseja continuar? (s/n): " RESP
if [ "$RESP" != "s" ]; then
    echo "[INFO] Execução cancelada pelo usuário."
    exit 0
fi


# ==========================================================
# MÓDULO 4 - IP fixo e hostname
# ==========================================================
echo ""
read -p "Executar MÓDULO 4 - IP fixo e hostname? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    # MÓDULO 4: IP FIXO + HOSTNAME (usa nmcli)

    echo "[INFO] Interfaces disponíveis:"
    ip -br address
    echo ""

    read -p "Nome da interface (ex: enp0s8): " INTERFACE
    read -p "IP fixo com máscara (ex: 192.168.56.11/24): " IP_FIXO
    read -p "Servidor DNS (ex: 192.168.56.11): " DNS_IP
    read -p "Gateway (Enter se não tiver): " GATEWAY
    read -p "Novo hostname (ex: ns1.thay.fiap.lab): " NOVO_HOST

    # Descobre o nome da conexão ligada à interface
    CONEXAO=$(nmcli -g GENERAL.CONNECTION device show $INTERFACE)
    if [ -z "$CONEXAO" ]; then
        echo "[AVISO] Interface sem conexão. Criando uma nova..."
        nmcli connection add type ethernet ifname $INTERFACE con-name $INTERFACE
        CONEXAO=$INTERFACE
    fi

    echo "[INFO] Configurando IP fixo em $CONEXAO..."
    nmcli connection modify "$CONEXAO" ipv4.method manual ipv4.addresses $IP_FIXO ipv4.dns $DNS_IP
    if [ -n "$GATEWAY" ]; then
        nmcli connection modify "$CONEXAO" ipv4.gateway $GATEWAY
    fi
    nmcli connection up "$CONEXAO"

    echo "[INFO] Configurando o hostname..."
    hostnamectl set-hostname $NOVO_HOST

    # Coloca o nome no /etc/hosts
    IP_SEM_MASCARA=$(echo $IP_FIXO | cut -d/ -f1)
    echo "$IP_SEM_MASCARA    $NOVO_HOST" >> /etc/hosts

    echo "[OK] Resultado:"
    ip -br address show $INTERFACE
    hostname
fi

# ---------- PASSO 2: coletar dados do usuário ----------
echo ""
echo "[INFO] PASSO 2: coletando informações..."
read -p "Nome do domínio (ex: thay.fiap.lab): " DOMINIO
read -p "IP deste servidor (ex: 192.168.56.11): " IP_SERVIDOR

# Limpa o arquivo temporário onde os registros serão guardados
> $ARQ_REGISTROS

# Loop que pede os registros até o usuário digitar FIM
TIPO=""
while [ "$TIPO" != "FIM" ]
do
    echo ""
    read -p "Tipo de registro (A, CNAME, MX) ou FIM para terminar: " TIPO
    TIPO=$(echo "$TIPO" | tr 'a-z' 'A-Z')

    if [ "$TIPO" = "A" ]; then
        read -p "  Nome do host (ex: www): " HOST
        read -p "  Endereço IP (ex: 192.168.56.11): " VALOR
        echo "$HOST    IN    A    $VALOR" >> $ARQ_REGISTROS
        echo "[INFO] Registro A adicionado: $HOST -> $VALOR"
    elif [ "$TIPO" = "CNAME" ]; then
        read -p "  Nome do apelido (ex: site): " HOST
        read -p "  Aponta para qual host (ex: www): " VALOR
        echo "$HOST    IN    CNAME    $VALOR" >> $ARQ_REGISTROS
        echo "[INFO] Registro CNAME adicionado: $HOST -> $VALOR"
    elif [ "$TIPO" = "MX" ]; then
        read -p "  Prioridade (ex: 10): " PRIO
        read -p "  Host do servidor de e-mail (ex: mail): " VALOR
        echo "@    IN    MX    $PRIO    $VALOR" >> $ARQ_REGISTROS
        echo "[INFO] Registro MX adicionado: $VALOR (prioridade $PRIO)"
        echo "[AVISO] Lembre de criar também um registro A para o host $VALOR"
    elif [ "$TIPO" = "FIM" ]; then
        echo "[INFO] Registros coletados."
    else
        echo "[AVISO] Tipo inválido. Use A, CNAME, MX ou FIM."
    fi
done

# ---------- PASSO 3: instalar pacotes ----------
echo ""
echo "[INFO] PASSO 3: instalando BIND, Apache, wget e unzip..."
dnf install -y bind bind-utils httpd wget unzip
if [ $? -ne 0 ]; then
    echo "[ERRO] Falha na instalação dos pacotes. Verifique a internet."
    exit 1
fi
echo "[OK] Pacotes instalados."

# ---------- PASSO 4: configurar o BIND ----------
echo ""
echo "[INFO] PASSO 4: configurando o servidor DNS..."

# Backup do arquivo original (boa prática)
cp /etc/named.conf /etc/named.conf.bkp
echo "[INFO] Backup criado em /etc/named.conf.bkp"

# Faz o named escutar em todas as interfaces e aceitar consultas de qualquer rede
sed -i 's/listen-on port 53 .*/listen-on port 53 { any; };/' /etc/named.conf
sed -i 's/allow-query .*/allow-query { any; };/' /etc/named.conf

# Declara a zona no named.conf (só se ainda não existir)
grep -q "zone \"$DOMINIO\"" /etc/named.conf
if [ $? -ne 0 ]; then
    echo "zone \"$DOMINIO\" IN {" >> /etc/named.conf
    echo "    type master;" >> /etc/named.conf
    echo "    file \"$DOMINIO.zone\";" >> /etc/named.conf
    echo "};" >> /etc/named.conf
    echo "[INFO] Zona $DOMINIO declarada no named.conf"
else
    echo "[AVISO] A zona $DOMINIO já existe no named.conf, pulando."
fi

# Monta o arquivo de zona
ARQ_ZONA="/var/named/$DOMINIO.zone"
SERIAL="$(date +%Y%m%d)""01"

echo "\$TTL 600" > $ARQ_ZONA
echo "@    IN    SOA    ns1.$DOMINIO.    admin.$DOMINIO. (" >> $ARQ_ZONA
echo "        $SERIAL    ; Serial" >> $ARQ_ZONA
echo "        28800      ; Refresh" >> $ARQ_ZONA
echo "        14400      ; Retry" >> $ARQ_ZONA
echo "        86400      ; Expire" >> $ARQ_ZONA
echo "        600 )      ; Minimum TTL" >> $ARQ_ZONA
echo "" >> $ARQ_ZONA
echo "@      IN    NS    ns1.$DOMINIO." >> $ARQ_ZONA
echo "ns1    IN    A     $IP_SERVIDOR" >> $ARQ_ZONA

# Adiciona os registros que o usuário digitou
cat $ARQ_REGISTROS >> $ARQ_ZONA

# Permissões e contexto SELinux do arquivo de zona
chown root:named $ARQ_ZONA
chmod 640 $ARQ_ZONA
restorecon $ARQ_ZONA 2>/dev/null
echo "[INFO] Arquivo de zona criado em $ARQ_ZONA"

# Valida as configurações antes de subir o serviço
named-checkconf
if [ $? -ne 0 ]; then
    echo "[ERRO] Erro no named.conf. Corrija e execute novamente."
    exit 1
fi
named-checkzone $DOMINIO $ARQ_ZONA
if [ $? -ne 0 ]; then
    echo "[ERRO] Erro no arquivo de zona. Corrija e execute novamente."
    exit 1
fi
echo "[OK] Configuração do DNS validada."

# ---------- PASSO 5: publicar o site ----------
echo ""
echo "[INFO] PASSO 5: baixando e publicando o template HTML..."

# Limpa a pasta do site e baixa o template
rm -rf /var/www/html/*
rm -rf /tmp/template
mkdir /tmp/template

wget -q -O /tmp/template.zip "$URL_TEMPLATE"
if [ $? -eq 0 ]; then
    unzip -q -o /tmp/template.zip -d /tmp/template
    # Descobre a pasta onde está o index.html dentro do template
    PASTA=$(dirname $(find /tmp/template -name index.html | head -n 1))
    cp -r $PASTA/* /var/www/html/
    echo "[OK] Template copiado para /var/www/html"
else
    echo "[AVISO] Não consegui baixar o template. Verifique a URL."
fi

# Se mesmo assim não existir index.html, cria uma página simples
if [ ! -f /var/www/html/index.html ]; then
    echo "[AVISO] Criando página padrão simples."
    echo "<h1>Site $DOMINIO funcionando!</h1>" > /var/www/html/index.html
fi

restorecon -R /var/www/html 2>/dev/null

# ---------- PASSO 6: firewall e serviços ----------
echo ""
echo "[INFO] PASSO 6: liberando firewall e iniciando serviços..."
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=http
firewall-cmd --reload

systemctl enable --now named
systemctl enable --now httpd
systemctl restart named
systemctl restart httpd
echo "[OK] Serviços named e httpd ativos."


# ##########################################################
# MÓDULOS EXTRAS (cada um pergunta se deve ser executado)
# ##########################################################

# ==========================================================
# MÓDULO 1 - Zona reversa (PTR)
# ==========================================================
echo ""
read -p "Executar MÓDULO 1 - Zona reversa (PTR)? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    # MÓDULO 1: ZONA REVERSA (PTR)
    # Usa as variáveis DOMINIO e IP_SERVIDOR do script principal.
    # Se rodar sozinho, ele pergunta.

    if [ -z "$DOMINIO" ]; then
        read -p "Nome do domínio: " DOMINIO
    fi
    if [ -z "$IP_SERVIDOR" ]; then
        read -p "IP do servidor: " IP_SERVIDOR
    fi

    echo "[INFO] Criando a zona reversa..."

    # Pega os 3 primeiros números do IP (ex: 192.168.56)
    REDE=$(echo $IP_SERVIDOR | cut -d. -f1-3)

    # Inverte a rede: 192.168.56 vira 56.168.192
    REVERSA=$(echo $REDE | awk -F. '{print $3"."$2"."$1}')
    ARQ_REV="/var/named/$REVERSA.zone"
    SERIAL="$(date +%Y%m%d)""01"

    # Declara a zona no named.conf
    grep -q "zone \"$REVERSA.in-addr.arpa\"" /etc/named.conf
    if [ $? -ne 0 ]; then
        echo "zone \"$REVERSA.in-addr.arpa\" IN {" >> /etc/named.conf
        echo "    type master;" >> /etc/named.conf
        echo "    file \"$REVERSA.zone\";" >> /etc/named.conf
        echo "};" >> /etc/named.conf
        echo "[INFO] Zona reversa declarada no named.conf"
    fi

    # Cabeçalho do arquivo da zona reversa
    echo "\$TTL 600" > $ARQ_REV
    echo "@    IN    SOA    ns1.$DOMINIO.    admin.$DOMINIO. (" >> $ARQ_REV
    echo "        $SERIAL    ; Serial" >> $ARQ_REV
    echo "        28800      ; Refresh" >> $ARQ_REV
    echo "        14400      ; Retry" >> $ARQ_REV
    echo "        86400      ; Expire" >> $ARQ_REV
    echo "        600 )      ; Minimum TTL" >> $ARQ_REV
    echo "" >> $ARQ_REV
    echo "@    IN    NS    ns1.$DOMINIO." >> $ARQ_REV

    # Loop para criar os registros PTR
    RESP="s"
    while [ "$RESP" = "s" ]
    do
        read -p "Último número do IP (ex: 11): " FINAL
        read -p "Nome do host (ex: www): " HOST_PTR
        echo "$FINAL    IN    PTR    $HOST_PTR.$DOMINIO." >> $ARQ_REV
        echo "[INFO] PTR adicionado: $REDE.$FINAL -> $HOST_PTR.$DOMINIO"
        read -p "Adicionar outro PTR? (s/n): " RESP
    done

    # Permissões e validação
    chown root:named $ARQ_REV
    chmod 640 $ARQ_REV
    restorecon $ARQ_REV 2>/dev/null

    named-checkconf
    named-checkzone $REVERSA.in-addr.arpa $ARQ_REV
    if [ $? -ne 0 ]; then
        echo "[ERRO] Problema na zona reversa."
        exit 1
    fi

    systemctl restart named
    echo "[OK] Zona reversa criada. Teste:"
    dig @127.0.0.1 -x $IP_SERVIDOR +short
fi

# ==========================================================
# MÓDULO 2A - DNS secundário (parte no PRIMÁRIO)
# ==========================================================
echo ""
read -p "Executar MÓDULO 2A - DNS secundário (parte no PRIMÁRIO)? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    # MÓDULO 2A: DNS SECUNDÁRIO - parte feita NO SERVIDOR PRIMÁRIO
    # Libera a transferência de zona e cria o NS/A do ns2.

    if [ -z "$DOMINIO" ]; then
        read -p "Nome do domínio: " DOMINIO
    fi

    read -p "IP do servidor SECUNDÁRIO: " IP_SEC
    ARQ_ZONA="/var/named/$DOMINIO.zone"

    echo "[INFO] Liberando transferência de zona para $IP_SEC..."

    # Insere as linhas logo abaixo de 'file "dominio.zone";' no named.conf
    sed -i "/file \"$DOMINIO.zone\";/a allow-transfer { $IP_SEC; };" /etc/named.conf
    sed -i "/file \"$DOMINIO.zone\";/a also-notify { $IP_SEC; };" /etc/named.conf

    # Registros do segundo servidor de nomes
    echo "@      IN    NS    ns2.$DOMINIO." >> $ARQ_ZONA
    echo "ns2    IN    A     $IP_SEC" >> $ARQ_ZONA

    # Aumenta o serial (obrigatório, senão o secundário não atualiza)
    NOVO_SERIAL="$(date +%Y%m%d)""02"
    sed -i "s/[0-9][0-9]*  *; Serial/$NOVO_SERIAL    ; Serial/" $ARQ_ZONA

    named-checkconf
    named-checkzone $DOMINIO $ARQ_ZONA
    if [ $? -ne 0 ]; then
        echo "[ERRO] Problema na zona. Corrija antes de continuar."
        exit 1
    fi

    systemctl restart named
    echo "[OK] Primário pronto. Agora rode o módulo 2B no secundário."
fi

# ==========================================================
# MÓDULO 3 - Virtual host no Apache
# ==========================================================
echo ""
read -p "Executar MÓDULO 3 - Virtual host no Apache? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    # MÓDULO 3: VIRTUAL HOST NO APACHE (novo site) + registro no DNS

    if [ -z "$DOMINIO" ]; then
        read -p "Nome do domínio: " DOMINIO
    fi
    if [ -z "$IP_SERVIDOR" ]; then
        read -p "IP do servidor: " IP_SERVIDOR
    fi

    read -p "Nome do novo site (ex: blog): " NOME_SITE
    SITE="$NOME_SITE.$DOMINIO"
    PASTA="/var/www/$SITE"

    echo "[INFO] Criando o site $SITE..."

    # Pasta e página do novo site
    mkdir -p $PASTA
    echo "<h1>Bem-vindo ao $SITE</h1>" > $PASTA/index.html
    restorecon -R $PASTA

    # Quando existe VirtualHost, o primeiro vira o padrão.
    # Por isso criamos antes o vhost do site principal (arquivo 00-...)
    if [ ! -f /etc/httpd/conf.d/00-principal.conf ]; then
        echo "<VirtualHost *:80>" > /etc/httpd/conf.d/00-principal.conf
        echo "    ServerName www.$DOMINIO" >> /etc/httpd/conf.d/00-principal.conf
        echo "    ServerAlias $DOMINIO" >> /etc/httpd/conf.d/00-principal.conf
        echo "    DocumentRoot /var/www/html" >> /etc/httpd/conf.d/00-principal.conf
        echo "</VirtualHost>" >> /etc/httpd/conf.d/00-principal.conf
        echo "[INFO] Vhost do site principal criado."
    fi

    # VirtualHost do novo site
    CONF="/etc/httpd/conf.d/$SITE.conf"
    echo "<VirtualHost *:80>" > $CONF
    echo "    ServerName $SITE" >> $CONF
    echo "    DocumentRoot $PASTA" >> $CONF
    echo "    <Directory $PASTA>" >> $CONF
    echo "        Require all granted" >> $CONF
    echo "    </Directory>" >> $CONF
    echo "</VirtualHost>" >> $CONF

    # Testa a configuração do Apache
    httpd -t
    if [ $? -ne 0 ]; then
        echo "[ERRO] Erro na configuração do Apache."
        exit 1
    fi
    systemctl restart httpd

    # Cria o registro A do novo site no DNS
    ARQ_ZONA="/var/named/$DOMINIO.zone"
    if [ -f $ARQ_ZONA ]; then
        echo "$NOME_SITE    IN    A    $IP_SERVIDOR" >> $ARQ_ZONA
        NOVO_SERIAL="$(date +%Y%m%d)""03"
        sed -i "s/[0-9][0-9]*  *; Serial/$NOVO_SERIAL    ; Serial/" $ARQ_ZONA
        named-checkzone $DOMINIO $ARQ_ZONA
        systemctl restart named
        echo "[INFO] Registro A de $SITE criado no DNS."
    fi

    echo "[OK] Teste: curl -H 'Host: $SITE' http://localhost"
fi

# ==========================================================
# MÓDULO 5 - Firewall, SELinux e porta do Apache
# ==========================================================
echo ""
read -p "Executar MÓDULO 5 - Firewall, SELinux e porta do Apache? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    # MÓDULO 5: FIREWALL, SELINUX E PORTA DO APACHE

    echo "[INFO] Status atual:"
    echo "SELinux: $(getenforce)"
    firewall-cmd --list-all

    # --- Liberar serviços no firewall ---
    SERVICO=""
    while [ "$SERVICO" != "fim" ]
    do
        read -p "Serviço a liberar (dns, http, https, dhcp, ssh) ou fim: " SERVICO
        if [ "$SERVICO" != "fim" ]; then
            firewall-cmd --permanent --add-service=$SERVICO
            echo "[INFO] Serviço $SERVICO liberado."
        fi
    done
    firewall-cmd --reload

    # --- Trocar a porta do Apache (opcional) ---
    read -p "Nova porta para o Apache (Enter para pular): " PORTA_HTTP
    if [ -n "$PORTA_HTTP" ]; then
        echo "[INFO] Mudando o Apache para a porta $PORTA_HTTP..."
        dnf install -y policycoreutils-python-utils
        sed -i "s/^Listen .*/Listen $PORTA_HTTP/" /etc/httpd/conf/httpd.conf
        semanage port -a -t http_port_t -p tcp $PORTA_HTTP
        firewall-cmd --permanent --add-port=$PORTA_HTTP/tcp
        firewall-cmd --reload
        httpd -t
        systemctl restart httpd
    fi

    # --- Corrigir contextos do SELinux ---
    echo "[INFO] Restaurando contextos do SELinux..."
    restorecon -R /var/named /var/www /etc/dhcp 2>/dev/null

    # --- Mudar o modo do SELinux (opcional) ---
    read -p "Modo do SELinux (enforcing/permissive ou Enter para manter): " MODO
    if [ "$MODO" = "permissive" ]; then
        setenforce 0
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
        echo "[AVISO] SELinux em modo permissive."
    elif [ "$MODO" = "enforcing" ]; then
        setenforce 1
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
        echo "[INFO] SELinux em modo enforcing."
    fi

    echo "[OK] Firewall e SELinux configurados."
    firewall-cmd --list-all
fi

# ==========================================================
# MÓDULO 6 - Servidor DHCP
# ==========================================================
echo ""
read -p "Executar MÓDULO 6 - Servidor DHCP? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    # MÓDULO 6: SERVIDOR DHCP
    # O servidor precisa ter IP fixo na mesma rede do escopo (módulo 4).

    if [ -z "$DOMINIO" ]; then
        read -p "Nome do domínio (ex: thay.fiap.lab): " DOMINIO
    fi

    read -p "Rede (ex: 192.168.56.0): " REDE
    read -p "Máscara (ex: 255.255.255.0): " MASCARA
    read -p "IP inicial da faixa (ex: 192.168.56.100): " INICIO
    read -p "IP final da faixa (ex: 192.168.56.150): " FIM
    read -p "Gateway (ex: 192.168.56.1): " GATEWAY
    read -p "Servidor DNS (ex: 192.168.56.11): " DNS_IP

    echo "[INFO] Instalando o servidor DHCP..."
    dnf install -y dhcp-server
    if [ $? -ne 0 ]; then
        echo "[ERRO] Falha na instalação."
        exit 1
    fi

    # Backup e criação do dhcpd.conf
    CONF="/etc/dhcp/dhcpd.conf"
    cp $CONF $CONF.bkp 2>/dev/null

    echo "default-lease-time 600;" > $CONF
    echo "max-lease-time 7200;" >> $CONF
    echo "authoritative;" >> $CONF
    echo "" >> $CONF
    echo "subnet $REDE netmask $MASCARA {" >> $CONF
    echo "    range $INICIO $FIM;" >> $CONF
    echo "    option routers $GATEWAY;" >> $CONF
    echo "    option domain-name-servers $DNS_IP;" >> $CONF
    echo "    option domain-name \"$DOMINIO\";" >> $CONF
    echo "}" >> $CONF

    # Reserva de IP por MAC (opcional)
    read -p "Criar reserva de IP por MAC? (s/n): " RESERVA
    if [ "$RESERVA" = "s" ]; then
        read -p "Nome da máquina (ex: cliente1): " NOME_RES
        read -p "MAC (ex: 08:00:27:aa:bb:cc): " MAC
        read -p "IP reservado (ex: 192.168.56.120): " IP_RES
        echo "" >> $CONF
        echo "host $NOME_RES {" >> $CONF
        echo "    hardware ethernet $MAC;" >> $CONF
        echo "    fixed-address $IP_RES;" >> $CONF
        echo "}" >> $CONF
        echo "[INFO] Reserva criada: $MAC -> $IP_RES"
    fi

    # Valida a configuração
    dhcpd -t -cf $CONF
    if [ $? -ne 0 ]; then
        echo "[ERRO] Erro no dhcpd.conf."
        exit 1
    fi

    firewall-cmd --permanent --add-service=dhcp
    firewall-cmd --reload

    systemctl enable --now dhcpd
    systemctl restart dhcpd
    systemctl status dhcpd --no-pager | head -n 5

    echo "[OK] DHCP ativo. No cliente, teste: nmcli device reapply <interface>"
fi

# ==========================================================
# MÓDULO 7A - Criar usuários
# ==========================================================
echo ""
read -p "Executar MÓDULO 7A - Criar usuários? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    # MÓDULO 7A: CRIAR USUÁRIOS (com grupo e senha)

    RESP="s"
    while [ "$RESP" = "s" ]
    do
        read -p "Nome do usuário: " USUARIO
        read -s -p "Senha: " SENHA
        echo ""
        read -p "Grupo (Enter para nenhum): " GRUPO

        id $USUARIO > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "[AVISO] O usuário $USUARIO já existe."
        else
            useradd -m $USUARIO
            echo "$USUARIO:$SENHA" | chpasswd
            echo "[OK] Usuário $USUARIO criado."

            # Cria o grupo se não existir e adiciona o usuário
            if [ -n "$GRUPO" ]; then
                getent group $GRUPO > /dev/null
                if [ $? -ne 0 ]; then
                    groupadd $GRUPO
                    echo "[INFO] Grupo $GRUPO criado."
                fi
                usermod -aG $GRUPO $USUARIO
                echo "[INFO] $USUARIO adicionado ao grupo $GRUPO."
            fi

            read -p "Forçar troca de senha no primeiro login? (s/n): " TROCA
            if [ "$TROCA" = "s" ]; then
                chage -d 0 $USUARIO
            fi
        fi

        read -p "Criar outro usuário? (s/n): " RESP
    done
    echo "[OK] Fim da criação de usuários."
fi

# ==========================================================
# MÓDULO 7B - Excluir, bloquear ou dar sudo a um usuário
# ==========================================================
echo ""
read -p "Executar MÓDULO 7B - Excluir, bloquear ou dar sudo a um usuário? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    # MÓDULO 7B: OUTRAS AÇÕES COM USUÁRIO (excluir, bloquear, sudo)

    read -p "Nome do usuário: " USUARIO
    id $USUARIO > /dev/null 2>&1
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
        userdel -r $USUARIO
        echo "[OK] Usuário $USUARIO excluído."
    elif [ "$OPCAO" = "2" ]; then
        usermod -L $USUARIO
        echo "[OK] Usuário $USUARIO bloqueado."
    elif [ "$OPCAO" = "3" ]; then
        usermod -U $USUARIO
        echo "[OK] Usuário $USUARIO desbloqueado."
    elif [ "$OPCAO" = "4" ]; then
        usermod -aG wheel $USUARIO
        echo "[OK] $USUARIO agora está no grupo wheel (sudo)."
    else
        echo "[AVISO] Opção inválida."
    fi
fi

# ==========================================================
# MÓDULO 2B - DNS secundário (SÓ na VM SECUNDÁRIA)
# ==========================================================
echo ""
read -p "Executar MÓDULO 2B - DNS secundário (SÓ na VM SECUNDÁRIA)? (s/n): " EXEC
if [ "$EXEC" = "s" ]; then
    echo "[AVISO] Este módulo é para a VM secundária. Não rode no primário."
    # MÓDULO 2B: DNS SECUNDÁRIO - script rodado NA VM SECUNDÁRIA

    if [ "$(id -u)" != "0" ]; then
        echo "[ERRO] Execute como root."
        exit 1
    fi

    read -p "Nome do domínio (ex: thay.fiap.lab): " DOMINIO
    read -p "IP do servidor PRIMÁRIO: " IP_PRIMARIO

    echo "[INFO] Instalando o BIND..."
    dnf install -y bind bind-utils

    cp /etc/named.conf /etc/named.conf.bkp
    sed -i 's/listen-on port 53 .*/listen-on port 53 { any; };/' /etc/named.conf
    sed -i 's/allow-query .*/allow-query { any; };/' /etc/named.conf

    # Zona do tipo slave: copia a zona do primário
    echo "zone \"$DOMINIO\" IN {" >> /etc/named.conf
    echo "    type slave;" >> /etc/named.conf
    echo "    masters { $IP_PRIMARIO; };" >> /etc/named.conf
    echo "    file \"slaves/$DOMINIO.zone\";" >> /etc/named.conf
    echo "};" >> /etc/named.conf

    named-checkconf
    if [ $? -ne 0 ]; then
        echo "[ERRO] Erro no named.conf."
        exit 1
    fi

    firewall-cmd --permanent --add-service=dns
    firewall-cmd --reload

    systemctl enable --now named
    systemctl restart named

    echo "[INFO] Aguardando a transferência da zona..."
    sleep 3
    ls -l /var/named/slaves/
    dig @127.0.0.1 ns1.$DOMINIO +short
    echo "[OK] Secundário configurado."
fi

# ---------- PASSO 7: testes ----------
echo ""
echo "[INFO] PASSO 7: testando..."
echo "--- Consulta DNS (ns1.$DOMINIO) ---"
dig @127.0.0.1 ns1.$DOMINIO +short
echo "--- Resposta do servidor web ---"
curl -I http://localhost 2>/dev/null | head -n 1

echo ""
echo "=============================================="
echo "[CONCLUÍDO] Domínio: $DOMINIO"
echo "            Site:    http://$IP_SERVIDOR"
echo "=============================================="
