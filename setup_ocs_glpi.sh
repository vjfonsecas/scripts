#!/bin/bash

# Verificar se é root
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Execute o script como root!"
    exit 1
fi

# Configurações iniciais
echo "🔧 Configurações iniciais do sistema..."
sudo hostnamectl set-hostname glpi-ocs-server
echo "export LANG=pt_BR.UTF-8" >> /etc/profile
localectl set-locale LANG=pt_BR.UTF-8

# Instalar e configurar SSH Server
echo "🔐 Instalando e configurando SSH Server..."
sudo dnf install -y openssh-server
sudo systemctl enable sshd --now
sudo firewall-cmd --add-service=ssh --permanent
sudo firewall-cmd --reload

echo "✅ SSH configurado. Acessível via: ssh $(whoami)@$(hostname -I | awk '{print $1}')"

# Atualizar sistema
echo "🔄 Atualizando sistema..."
sudo dnf update -y

# Instalar dependências
echo "📦 Instalando dependências..."
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled crb
sudo dnf install -y wget tar httpd mod_ssl php php-{gd,json,intl,mbstring,pdo,pear,curl,xml,zip,ldap,simplexml,opcache,snmp,fileinfo,dom,posix,ctype,filter,gettext,iconv,pgsql} \
postgresql-server postgresql-contrib perl-XML-Simple perl-DBI perl-DBD-Pg perl-Crypt-PasswdMD5 perl-Net-IP perl-Proc-Daemon perl-Proc-PID-File \
perl-Apache-DBI perl-SOAP-Lite perl-XML-Entities make gcc glibc-devel

# Configurar PostgreSQL
echo "🐘 Configurando PostgreSQL..."
sudo postgresql-setup --initdb
sudo systemctl enable postgresql --now

# Configurar pg_hba.conf
sudo sed -i 's/\(local\s*all\s*all\s*\)peer/\1md5/' /var/lib/pgsql/data/pg_hba.conf
sudo sed -i 's/\(host\s*all\s*all\s*127.0.0.1\/32\s*\)ident/\1md5/' /var/lib/pgsql/data/pg_hba.conf
sudo systemctl restart postgresql

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
sudo firewall-cmd --add-service={http,https} --permanent
sudo firewall-cmd --reload

# Configurar SELinux
echo "🛡️ Configurando SELinux (modo permissivo)..."
sudo setsebool -P httpd_can_network_connect_db 1
sudo setsebool -P httpd_can_sendmail 1
sudo semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/html/glpi(/.*)?"
sudo semanage fcontext -a -t httpd_sys_rw_content_t "/usr/share/ocsinventory-reports/(.*)?"
sudo setenforce 0  # Modo permissivo

# Instalar GLPI
echo "📥 Instalando GLPI..."
GLPI_VERSION="10.0.7"
wget https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz
tar -xzf glpi-${GLPI_VERSION}.tgz
sudo mv glpi /var/www/html/
sudo chown -R apache:apache /var/www/html/glpi

# Configurar Virtual Host
sudo tee /etc/httpd/conf.d/glpi.conf > /dev/null <<EOF
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

# Instalar OCS Inventory
echo "📊 Instalando OCS Inventory..."
OCS_VERSION="2.9.3"
wget https://github.com/OCSInventory-NG/OCSInventory-ocsreports/releases/download/${OCS_VERSION}/OCSNG_UNIX_SERVER-${OCS_VERSION}.tar.gz
tar -xzf OCSNG_UNIX_SERVER-${OCS_VERSION}.tar.gz
cd OCSNG_UNIX_SERVER-${OCS_VERSION}

# Instalação automatizada do OCS
sudo ./setup.sh <<EOF
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
sudo tee /etc/ocsinventory-server/ocsinventory-server.conf > /dev/null <<EOF
DB_TYPE=Pg
DB_NAME=ocsdb
DB_HOST=localhost
DB_PORT=5432
DB_USER=ocs_user
DB_PWD=$ocs_password
EOF

sudo systemctl restart httpd

# Configurar cron jobs
echo "⏰ Configurando tarefas agendadas..."
sudo tee /etc/cron.d/ocsinventory > /dev/null <<EOF
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
echo "2. Configure o plugin OCS no menu 'Plugins > OCS Inventory NG'"
echo "3. Recomenda-se reativar o SELinux gradualmente:"
echo "   sudo setenforce 1"
echo "   sudo ausearch -m avc --start recent | audit2allow -M mypol"
echo "   sudo semodule -i mypol.pp"
echo "4. Configure seu firewall para permitir acesso externo"
echo "================================================"
