#
#
# Script de instalação do Ocs e Glpi no Rocky Linux
# Instalação baseada no Rocky Linux 9.6
# Instala e ativa tambem ssh caso não tenha
#
#
#!/bin/bash

# Verificar se é root
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Execute o script como root!"
    exit 1
fi

# Configurações iniciais
echo "🔧 Configurações iniciais do sistema..."
hostnamectl set-hostname glpi-ocs-server
echo "export LANG=pt_BR.UTF-8" >> /etc/profile
source /etc/profile
localectl set-locale LANG=pt_BR.UTF-8

# Instalar e configurar SSH Server
echo "🔐 Instalando e configurando SSH Server..."
dnf install -y openssh-server
systemctl enable sshd --now
firewall-cmd --add-service=ssh --permanent
firewall-cmd --reload

echo "✅ SSH configurado. Acessível via: ssh $(whoami)@$(hostname -I | awk '{print $1}')"

# Atualizar sistema
echo "🔄 Atualizando sistema..."
dnf update -y

# Instalar dependências
echo "📦 Instalando dependências..."
dnf install -y epel-release
dnf config-manager --set-enabled crb
dnf install -y wget tar httpd mod_ssl php php-{gd,json,intl,mbstring,pdo,pear,curl,xml,zip,ldap,simplexml,opcache,snmp,fileinfo,dom,posix,ctype,filter,gettext,iconv,pgsql} \
postgresql-server postgresql-contrib perl-XML-Simple perl-DBI perl-DBD-Pg perl-Crypt-PasswdMD5 perl-Net-IP perl-Proc-Daemon perl-Proc-PID-File \
perl-Apache-DBI perl-SOAP-Lite perl-XML-Entities make gcc glibc-devel policycoreutils-python-utils

# Configurar PostgreSQL
echo "🐘 Configurando PostgreSQL..."
/usr/bin/postgresql-setup --initdb
systemctl enable postgresql --now

# Configurar pg_hba.conf
PG_HBA="/var/lib/pgsql/data/pg_hba.conf"
if [ -f "$PG_HBA" ]; then
    sed -i 's/\(local\s*all\s*all\s*\)peer/\1md5/' "$PG_HBA"
    sed -i 's/\(host\s*all\s*all\s*127.0.0.1\/32\s*\)ident/\1md5/' "$PG_HBA"
    systemctl restart postgresql
else
    echo "❌ ERRO: Arquivo pg_hba.conf não encontrado em $PG_HBA"
    exit 1
fi

# Criar usuários e bancos de dados
read -p "🔑 Digite a senha para o usuário GLPI (glpi_user): " glpi_password
read -p "🔑 Digite a senha para o usuário OCS (ocs_user): " ocs_password

sudo -u postgres psql <<EOF
CREATE USER glpi_user WITH PASSWORD '$glpi_password';
CREATE USER ocs_user WITH PASSWORD '$ocs_password';
CREATE DATABASE glpidb TEMPLATE template0 ENCODING 'UTF8';
CREATE DATABASE ocsdb TEMPLATE template0 ENCODING 'UTF8';
ALTER DATABASE glpidb OWNER TO glpi_user;
ALTER DATABASE ocsdb OWNER TO ocs_user;
EOF

# Configurar Firewall
echo "🔥 Configurando Firewall..."
firewall-cmd --add-service={http,https} --permanent
firewall-cmd --reload

# Configurar SELinux
echo "🛡️ Configurando SELinux (modo permissivo)..."
setsebool -P httpd_can_network_connect_db 1
setsebool -P httpd_can_sendmail 1
semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/html/glpi(/.*)?"
restorecon -Rv /var/www/html/glpi
setenforce 0

# Instalar e configurar Apache
echo "🌐 Configurando Apache..."
systemctl enable httpd --now

# Instalar GLPI
echo "📥 Instalando GLPI..."
GLPI_VERSION="10.0.7"
wget -q https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz
if [ $? -ne 0 ]; then
    echo "❌ Falha ao baixar GLPI. Tentando URL alternativa..."
    wget -q https://github.com/glpi-project/glpi/releases/download/10.0.7/glpi-10.0.7.tgz
fi

tar -xzf glpi-${GLPI_VERSION}.tgz
mv glpi /var/www/html/
chown -R apache:apache /var/www/html/glpi

# Configurar Virtual Host
tee /etc/httpd/conf.d/glpi.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName glpi.local
    DocumentRoot /var/www/html/glpi
    <Directory /var/www/html/glpi>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog /var/log/httpd/glpi_error.log
    CustomLog /var/log/httpd/glpi_access.log combined
</VirtualHost>
EOF

systemctl restart httpd

# Instalar OCS Inventory
echo "📊 Instalando OCS Inventory..."
OCS_VERSION="2.9.3"
wget -q https://github.com/OCSInventory-NG/OCSInventory-ocsreports/releases/download/${OCS_VERSION}/OCSNG_UNIX_SERVER-${OCS_VERSION}.tar.gz
if [ $? -ne 0 ]; then
    echo "❌ Falha ao baixar OCS. Tentando URL alternativa..."
    wget -q https://github.com/OCSInventory-NG/OCSInventory-ocsreports/releases/download/2.9.3/OCSNG_UNIX_SERVER-2.9.3.tar.gz
fi

tar -xzf OCSNG_UNIX_SERVER-${OCS_VERSION}.tar.gz
cd OCSNG_UNIX_SERVER-${OCS_VERSION}

# Instalação automatizada do OCS
./setup.sh <<EOF
1
/usr/local/ocs
y
y
y
y
y
y
y
EOF

# Configurar OCS para PostgreSQL
mkdir -p /etc/ocsinventory-server
tee /etc/ocsinventory-server/ocsinventory-server.conf > /dev/null <<EOF
DB_TYPE=Pg
DB_NAME=ocsdb
DB_HOST=localhost
DB_PORT=5432
DB_USER=ocs_user
DB_PWD=$ocs_password
EOF

# Configurar permissões OCS
chown -R apache:apache /usr/share/ocsinventory-reports/
semanage fcontext -a -t httpd_sys_rw_content_t "/usr/share/ocsinventory-reports/(.*)?"
restorecon -Rv /usr/share/ocsinventory-reports/

systemctl restart httpd

# Configurar cron jobs
echo "⏰ Configurando tarefas agendadas..."
tee /etc/cron.d/ocsinventory > /dev/null <<EOF
*/10 * * * * apache /usr/bin/php /usr/share/ocsinventory-reports/ocsreports/background_jobs/launcher.php
0 */4 * * * apache /usr/bin/php /usr/share/ocsinventory-reports/ocsreports/background_jobs/launcher.php --force
EOF

# Configurar comunicação OCS-GLPI
echo "🔄 Configurando integração OCS-GLPI..."
sudo -u apache php /var/www/html/glpi/bin/console glpi:plugin:install ocsinventoryng
sudo -u apache php /var/www/html/glpi/bin/console glpi:plugin:activate ocsinventoryng

# Finalização
echo "✅ Instalação concluída!"
echo "================================================"
echo "📌 Informações de acesso:"
echo "GLPI: http://$(hostname -I | awk '{print $1}')/glpi"
echo "OCS Reports: http://$(hostname -I | awk '{print $1}')/ocsreports"
echo "Usuário padrão GLPI: glpi/glpi"
echo "Usuário padrão OCS: admin/admin"
echo "================================================"
echo "⚠️ Importante:"
echo "1. Acesse o GLPI e complete o assistente de instalação"
echo "2. Configure o plugin OCS:"
echo "   - Acesse http://$(hostname -I | awk '{print $1}')/glpi"
echo "   - Vá em Plugins > OCS Inventory NG"
echo "   - Use as credenciais:"
echo "        Usuário: ocs_user"
echo "        Senha: $ocs_password"
echo "        Banco de dados: ocsdb"
echo "3. Para expor na internet:"
echo "   - Configure seu firewall/roteador para encaminhar as portas 80 e 443"
echo "   - Considere usar HTTPS com certificado válido"
echo "4. SELinux está em modo permissivo (setenforce 0)"
echo "   Para reativar gradualmente:"
echo "   sudo setenforce 1"
echo "   sudo ausearch -m avc --start recent | audit2allow -M mypol"
echo "   sudo semodule -i mypol.pp"
echo "================================================"
