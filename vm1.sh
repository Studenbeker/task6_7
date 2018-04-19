#!/bin/bash

IF_CFG='/etc/network/interfaces'
RE_CFG='/etc/resolv.conf'
source $(dirname $0)/vm1.config

        #EXTERNAL

if [ "$EXT_IP" = "DHCP" ]; then
echo "auto  $EXTERNAL_IF
iface $EXTERNAL_IF inet dhcp
" > $IF_CFG
route del default
dhclient $EXTERNAL_IF
else
echo "auto  $EXTERNAL_IF
iface $EXTERNAL_IF inet static
address $EXT_IP
gateway $EXT_GW
dns-nameservers 8.8.8.8
" > $IF_CFG
ifconfig $EXTERNAL_IF $EXT_IP
route del default
route add default gw $EXT_GW
echo "nameserver 8.8.8.8" > $RE_CFG;
fi

        #INTERNAL

echo "auto  $INTERNAL_IF
iface $INTERNAL_IF inet static
address $INT_IP
" >> $IF_CFG
ifconfig $INTERNAL_IF $INT_IP

        # VLAN

echo "auto  $INTERNAL_IF.$VLAN
iface $INTERNAL_IF.$VLAN inet static
address $VLAN_IP
vlan-raw-device $INTERNAL_IF
" >> $IF_CFG
modprobe 8021q
vconfig add $INTERNAL_IF $VLAN
ifconfig $INTERNAL_IF.$VLAN $VLAN_IP

        #HOSTS

IP=$(ifconfig $EXTERNAL_IF | grep 'inet addr' | cut -d: -f2 | awk '{print $1}')
HOSTNAME='vm1'
hostname $HOSTNAME
echo $IP $HOSTNAME >> /etc/hosts
       
       #IPTABLES

echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -A INPUT -i lo -j ACCEPT
iptables -A FORWARD -i $EXTERNAL_IF -o $INTERNAL_IF -j ACCEPT
iptables -t nat -A POSTROUTING -o $EXTERNAL_IF -j MASQUERADE
iptables -A FORWARD -i $EXTERNAL_IF -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i $EXTERNAL_IF -o $INTERNAL_IF -j REJECT

        #NGINX

NGINX=$(dpkg -l nginx | grep ii |wc -l)
if [ $NGINX = 0 ]
then
apt update && apt install nginx -y
fi

        #CERTS

dir="/etc/ssl/certs"
if [ ! -d "${dir}" ];
then
mkdir "${dir}"
fi

echo "
[ req ]
default_bits            = 4096 
default_keyfile         = privkey.pem
distinguished_name      = req_distinguished_name
req_extensions          = v3_req
 
[ req_distinguished_name ]
countryName                 = Country Name (2 letter code)
countryName_default         = UA
stateOrProvinceName         = State or Province Name (full name)
stateOrProvinceName_default = Some-State 
localityName                = Locality Name (eg, city)
localityName_default        = Kharkov
organizationName            = Organization Name (eg, company)
organizationName_default    = Example UA
commonName                  = Common Name (eg, YOUR name)
commonName_default          = stud.kharkov.com.ua
commonName_max              = 64

[ v3_req ]
basicConstraints            = CA:FALSE
keyUsage                    = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName              = @alt_names
 
[alt_names]
IP.1   = $IP
DNS.1   = $HOSTNAME" > /usr/lib/ssl/openssl_ex.cnf

openssl genrsa -out /etc/ssl/certs/root-ca.key 4096
openssl req -x509 -new -key /etc/ssl/certs/root-ca.key -days 365 -out /etc/ssl/certs/root-ca.crt -subj "/C=UA/L=Kharkov/O=KURS/OU=DEV/CN=stud.kharkov.com.ua"
openssl genrsa -out /etc/ssl/certs/web.key 4096
openssl req -new -key /etc/ssl/certs/web.key -out /etc/ssl/certs/web.csr -config /usr/lib/ssl/openssl_ex.cnf -subj "/C=UA/L=Kharkov/O=KURS/OU=DEV/CN=$HOSTNAME"
openssl x509 -req -in /etc/ssl/certs/web.csr -CA /etc/ssl/certs/root-ca.crt  -CAkey /etc/ssl/certs/root-ca.key -CAcreateserial -out /etc/ssl/certs/web.crt -days 365 -extensions v3_req -extfile /usr/lib/ssl/openssl_ex.cnf
cat /etc/ssl/certs/root-ca.crt >> /etc/ssl/certs/web.crt

rm -r /etc/nginx/sites-enabled/*
cp /etc/nginx/sites-available/default  /etc/nginx/sites-available/$HOSTNAME
echo "
upstream $HOSTNAME {
server $IP:80;
}
server {
listen  $IP:$NGINX_PORT ssl $HOSTNAME_server;
server_name $HOSTNAME
ssl on;
ssl_certificate /etc/ssl/certs/web.crt;
ssl_certificate_key /etc/ssl/certs/web.key;
 location / {
            proxy_pass http://$HOSTNAME;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
} " > /etc/nginx/sites-available/$HOSTNAME
ln -s /etc/nginx/sites-available/$HOSTNAME /etc/nginx/sites-enabled/$HOSTNAME

systemctl restart nginx

exit $?
