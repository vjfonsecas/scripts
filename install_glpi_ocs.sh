#!/bin/bash

# Função para verificar e instalar dependências
install_dependencies() {
    echo "➤ Atualizando o sistema e instalando dependências..."
    sudo dnf update -y
    sudo dnf install -y wget tar httpd php php-{gd,json,intl,mbstring,pdo,pear,curl,xml,zip,ldap,simplexml,opcache,snmp,fileinfo,dom,posix,ctype,filter,gettext,iconv,pgsql} postgresql-server postgresql-contrib
}

# Função para configurar o PostgreSQL
setup_postgresql() {
    echo "➤ Configurando PostgreSQL..."
    sudo postgresql-setup --initdb
    sudo systemctl enable postgresql --now

    # Solicitar senhas para os usuários GLPI e OCS
    read -p "🔑 Digite a senha para o usuário GLPI (glpi_user): " glpi_password
    read -p "🔑 Digite a senha para o usuário OCS (ocs_user): " ocs_password

    # Comandos SQL para criar bancos e usuários
    sudo -u postgres psql <<EOF
CREATE USER glpi_user WITH PASSWORD '$glpi_password';
CREATE USER ocs_user WITH PASSWORD '$ocs_password';
CREATE DATABASE glpi_db WITH OWNER glpi_user;
CREATE DATABASE ocs_db WITH OWNER ocs_user;
EOF

    # Configurar acesso remoto (opcional)
    sudo sed -i 's/local   all             all                                     peer/local   all             all                                     md5/g' /var/lib/pgsql/data/pg_hba.conf
    sudo systemctl restart postgresql
}

# Função para instalar o GLPI
install_glpi() {
    echo "➤ Baixando e instalando GLPI..."
    GLPI_VERSION="10.0.7"
    wget -q https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz
    tar -xzf glpi-${GLPI_VERSION}.tgz
    sudo mv glpi /var/www/html/
    sudo chown -R apache:apache /var/www/html/glpi

    # Configurar Virtual Host do GLPI
    sudo cat > /etc/httpd/conf.d/glpi.conf <<EOF
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot /var/www/html/glpi
    <Directory /var/www/html/glpi>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

    sudo systemctl restart httpd
}

# Função para instalar o OCS Inventory
install_ocs() {
    echo "➤ Baixando e instalando OCS Inventory..."
    OCS_VERSION="2.9.3"
    wget -q https://github.com/OCSInventory-NG/OCSInventory-ocsreports/releases/download/${OCS_VERSION}/OCSNG_UNIX_SERVER-${OCS_VERSION}.tar.gz
    tar -xzf OCSNG_UNIX_SERVER-${OCS_VERSION}.tar.gz
    cd OCSNG_UNIX_SERVER-${OCS_VERSION}
    sudo ./setup.sh

    # Configurar comunicação com GLPI (via plugin)
    echo "✅ OCS Inventory instalado. Configure o plugin no GLPI após a instalação."
}

# Função para ajustar firewall e SELinux
setup_security() {
    echo "➤ Configurando firewall e SELinux..."
    sudo firewall-cmd --add-service={http,https} --permanent
    sudo firewall-cmd --reload

    # Ajustes SELinux (se habilitado)
    sudo setsebool -P httpd_can_network_connect_db 1
    sudo chcon -R -t httpd_sys_rw_content_t /var/www/html/glpi
}

# Função principal
main() {
    echo "🚀 Iniciando instalação automatizada do GLPI + OCS Inventory + PostgreSQL..."
    install_dependencies
    setup_postgresql
    install_glpi
    install_ocs
    setup_security

    echo "✔️ Instalação concluída!"
    echo "➜ Acesse o GLPI em: http://$(hostname -I | awk '{print $1}')/glpi"
    echo "➜ Configure o plugin OCS no GLPI em: Plugins > OCS Inventory"
}

# Executar script
main
