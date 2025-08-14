#!/bin/bash

# Verifica se o script está sendo executado como root
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script deve ser executado como root ou com sudo." >&2
    exit 1
fi

# Atualiza o sistema
echo "Atualizando o sistema..."
dnf update -y

# Instala o servidor SSH (openssh-server)
echo "Instalando o servidor SSH..."
dnf install -y openssh-server

# Habilita e inicia o serviço SSH
echo "Configurando o serviço SSH..."
systemctl enable sshd
systemctl start sshd

# Configura o firewall para permitir SSH
echo "Configurando o firewall..."
if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload
    echo "Firewall configurado para permitir SSH."
else
    echo "Firewall-cmd não encontrado. Verifique se o firewalld está instalado."
fi

# Configurações opcionais de segurança para o SSH (descomente se desejar)
# echo "Configurando opções de segurança no SSH..."
# sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
# sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
# systemctl restart sshd

# Verifica o status do serviço SSH
echo "Verificando o status do serviço SSH..."
systemctl status sshd --no-pager

# Mostra o endereço IP para conexão
echo -e "\nConfiguração SSH concluída!"
ip a | grep -w inet | grep -v 127.0.0.1 | awk '{print "Conecte-se usando: ssh seu_usuario@"$2}' | cut -d'/' -f1
