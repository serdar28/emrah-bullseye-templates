# ------------------------------------------------------------------------------
# JITSI.SH
# ------------------------------------------------------------------------------
set -e
source $INSTALLER/000-source

# ------------------------------------------------------------------------------
# ENVIRONMENT
# ------------------------------------------------------------------------------
MACH="eb-jitsi"
cd $MACHINES/$MACH

ROOTFS="/var/lib/lxc/$MACH/rootfs"
DNS_RECORD=$(grep "address=/$MACH/" /etc/dnsmasq.d/eb-jitsi | head -n1)
IP=${DNS_RECORD##*/}
SSH_PORT="30$(printf %03d ${IP##*.})"
echo JITSI="$IP" >> $INSTALLER/000-source

JITSI_MEET_CONFIG="$ROOTFS/etc/jitsi/meet/$JITSI_FQDN-config.js"
JITSI_MEET_INTERFACE="$ROOTFS/usr/share/jitsi-meet/interface_config.js"

# ------------------------------------------------------------------------------
# NFTABLES RULES
# ------------------------------------------------------------------------------
# the public ssh
nft delete element eb-nat tcp2ip { $SSH_PORT } 2>/dev/null || true
nft add element eb-nat tcp2ip { $SSH_PORT : $IP }
nft delete element eb-nat tcp2port { $SSH_PORT } 2>/dev/null || true
nft add element eb-nat tcp2port { $SSH_PORT : 22 }
# http
nft delete element eb-nat tcp2ip { 80 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 80 : $IP }
nft delete element eb-nat tcp2port { 80 } 2>/dev/null || true
nft add element eb-nat tcp2port { 80 : 80 }
# https
nft delete element eb-nat tcp2ip { 443 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 443 : $IP }
nft delete element eb-nat tcp2port { 443 } 2>/dev/null || true
nft add element eb-nat tcp2port { 443 : 443 }
# tcp/5222
nft delete element eb-nat tcp2ip { 5222 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 5222 : $IP }
nft delete element eb-nat tcp2port { 5222 } 2>/dev/null || true
nft add element eb-nat tcp2port { 5222 : 5222 }
# udp/10000
nft delete element eb-nat udp2ip { 10000 } 2>/dev/null || true
nft add element eb-nat udp2ip { 10000 : $IP }
nft delete element eb-nat udp2port { 10000 } 2>/dev/null || true
nft add element eb-nat udp2port { 10000 : 10000 }

# ------------------------------------------------------------------------------
# INIT
# ------------------------------------------------------------------------------
[[ "$DONT_RUN_JITSI" = true ]] && exit

echo
echo "-------------------------- $MACH --------------------------"

# ------------------------------------------------------------------------------
# REINSTALL_IF_EXISTS
# ------------------------------------------------------------------------------
EXISTS=$(lxc-info -n $MACH | egrep '^State' || true)
if [[ -n "$EXISTS" ]] && [[ "$REINSTALL_JITSI_IF_EXISTS" != true ]]; then
    echo JITSI_SKIPPED=true >> $INSTALLER/000-source

    echo "Already installed. Skipped..."
    echo
    echo "Please set REINSTALL_JITSI_IF_EXISTS in $APP_CONFIG"
    echo "if you want to reinstall this container"
    exit
fi

# ------------------------------------------------------------------------------
# CONTAINER SETUP
# ------------------------------------------------------------------------------
# stop the template container if it's running
set +e
lxc-stop -n eb-bullseye
lxc-wait -n eb-bullseye -s STOPPED
set -e

# remove the old container if exists
set +e
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
lxc-destroy -n $MACH
rm -rf /var/lib/lxc/$MACH
sleep 1
set -e

# create the new one
lxc-copy -n eb-bullseye -N $MACH -p /var/lib/lxc/

# the shared directories
mkdir -p $SHARED/cache
mkdir -p $SHARED/recordings

# the container config
rm -rf $ROOTFS/var/cache/apt/archives
mkdir -p $ROOTFS/var/cache/apt/archives
rm -rf $ROOTFS/usr/local/eb/recordings
mkdir -p $ROOTFS/usr/local/eb/recordings

cat >> /var/lib/lxc/$MACH/config <<EOF
lxc.mount.entry = $SHARED/recordings usr/local/eb/recordings none bind 0 0

# Start options
lxc.start.auto = 1
lxc.start.order = 302
lxc.start.delay = 2
lxc.group = eb-group
lxc.group = onboot
EOF

# container network
cp $MACHINE_COMMON/etc/systemd/network/eth0.network $ROOTFS/etc/systemd/network/
sed -i "s/___IP___/$IP/" $ROOTFS/etc/systemd/network/eth0.network
sed -i "s/___GATEWAY___/$HOST/" $ROOTFS/etc/systemd/network/eth0.network

# start the container
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING

# wait for the network to be up
for i in $(seq 0 9); do
    lxc-attach -n $MACH -- ping -c1 host.loc && break || true
    sleep 1
done

# ------------------------------------------------------------------------------
# HOSTNAME
# ------------------------------------------------------------------------------
lxc-attach -n $MACH -- zsh <<EOS
set -e
echo $MACH > /etc/hostname
sed -i 's/\(127.0.1.1\s*\).*$/\1$JITSI_FQDN $MACH/' /etc/hosts
hostname $MACH
EOS

# ------------------------------------------------------------------------------
# PACKAGES
# ------------------------------------------------------------------------------
# fake install
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY -dy reinstall hostname
EOS

# update
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY update
apt-get $APT_PROXY -y dist-upgrade
EOS

# gnupg, ngrep, ncat, jq, ruby-hocon
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY -y install gnupg
apt-get $APT_PROXY -y install ngrep ncat jq
apt-get $APT_PROXY -y install ruby-hocon
EOS

# ssl packages
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY -y install ssl-cert certbot
EOS

# jitsi
cp etc/apt/sources.list.d/jitsi-stable.list $ROOTFS/etc/apt/sources.list.d/
lxc-attach -n $MACH -- zsh <<EOS
set -e
wget -T 30 -qO /tmp/jitsi.gpg.key https://download.jitsi.org/jitsi-key.gpg.key
cat /tmp/jitsi.gpg.key | gpg --dearmor >/usr/share/keyrings/jitsi.gpg
apt-get update
EOS

lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< \
    'jicofo jitsi-videobridge/jvb-hostname string $JITSI_FQDN'
debconf-set-selections <<< \
    'jitsi-meet-web-config jitsi-meet/cert-choice select Generate a new self-signed certificate'

apt-get $APT_PROXY -y install openjdk-11-jre-headless
apt-get $APT_PROXY -y --install-recommends install jitsi-meet
apt-mark hold 'jitsi-*' jicofo
EOS

# jitsi-meet-tokens related packages
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY -y install luarocks liblua5.2-dev
apt-get $APT_PROXY -y install gcc git
EOS

# ------------------------------------------------------------------------------
# JMS SSH KEY
# ------------------------------------------------------------------------------
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp $MACHINES/eb-jitsi-host/root/.ssh/jms-config /root/.ssh/

# create ssh key if not exists
if [[ ! -f /root/.ssh/jms ]] || [[ ! -f /root/.ssh/jms.pub ]]; then
    rm -f /root/.ssh/jms{,.pub}
    ssh-keygen -qP '' -t rsa -b 2048 -f /root/.ssh/jms
fi

# copy the public key to a downloadable place
cp /root/.ssh/jms.pub $ROOTFS/usr/share/jitsi-meet/static/

# ------------------------------------------------------------------------------
# SYSTEM CONFIGURATION
# ------------------------------------------------------------------------------
# certificates
cp /root/eb-ssl/eb-CA.pem $ROOTFS/usr/local/share/ca-certificates/jms-CA.crt
cp /root/eb-ssl/eb-CA.pem $ROOTFS/usr/share/jitsi-meet/static/jms-CA.crt
cp /root/eb-ssl/eb-jitsi.key $ROOTFS/etc/ssl/private/eb-cert.key
cp /root/eb-ssl/eb-jitsi.pem $ROOTFS/etc/ssl/certs/eb-cert.pem

lxc-attach -n $MACH -- zsh <<EOS
set -e
update-ca-certificates

chmod 640 /etc/ssl/private/eb-cert.key
chown root:ssl-cert /etc/ssl/private/eb-cert.key

rm /etc/jitsi/meet/$JITSI_FQDN.key
rm /etc/jitsi/meet/$JITSI_FQDN.crt
ln -s /etc/ssl/private/eb-cert.key /etc/jitsi/meet/$JITSI_FQDN.key
ln -s /etc/ssl/certs/eb-cert.pem /etc/jitsi/meet/$JITSI_FQDN.crt
EOS

# set-letsencrypt-cert
cp $MACHINES/common/usr/local/sbin/set-letsencrypt-cert $ROOTFS/usr/local/sbin/
chmod 744 $ROOTFS/usr/local/sbin/set-letsencrypt-cert

# certbot service
mkdir -p $ROOTFS/etc/systemd/system/certbot.service.d
cp $MACHINES/common/etc/systemd/system/certbot.service.d/override.conf \
    $ROOTFS/etc/systemd/system/certbot.service.d/
echo 'ExecStartPost=systemctl restart coturn.service' >> \
    $ROOTFS/etc/systemd/system/certbot.service.d/override.conf
lxc-attach -n $MACH -- systemctl daemon-reload

# ------------------------------------------------------------------------------
# COTURN
# ------------------------------------------------------------------------------
cp $ROOTFS/etc/turnserver.conf $ROOTFS/etc/turnserver.conf.org

cat >>$ROOTFS/etc/turnserver.conf <<EOF

# the following lines added by eb-jitsi
listening-ip=$IP
allowed-peer-ip=$IP
no-udp
EOF

lxc-attach -n $MACH -- zsh <<EOS
set -e
adduser turnserver ssl-cert
systemctl restart coturn.service
EOS

# ------------------------------------------------------------------------------
# PROSODY
# ------------------------------------------------------------------------------
cp $ROOTFS/etc/prosody/conf.avail/$JITSI_FQDN.cfg.lua \
    $ROOTFS/etc/prosody/conf.avail/$JITSI_FQDN.cfg.lua.org

mkdir -p $ROOTFS/etc/systemd/system/prosody.service.d
cp etc/systemd/system/prosody.service.d/override.conf \
    $ROOTFS/etc/systemd/system/prosody.service.d/

cp etc/prosody/conf.avail/network.cfg.lua $ROOTFS/etc/prosody/conf.avail/
ln -s ../conf.avail/network.cfg.lua $ROOTFS/etc/prosody/conf.d/

sed -i "/rate *=.*kb.s/  s/[0-9]*kb/1024kb/" \
    $ROOTFS/etc/prosody/prosody.cfg.lua
sed -i "s/^-- \(https_ports = { };\)/\1/" \
    $ROOTFS/etc/prosody/conf.avail/$JITSI_FQDN.cfg.lua
sed -i "/turns.*tcp/ s/host\s*=[^,]*/host = \"$TURN_FQDN\"/" \
    $ROOTFS/etc/prosody/conf.avail/$JITSI_FQDN.cfg.lua
sed -i "/turns.*tcp/ s/5349/443/" \
    $ROOTFS/etc/prosody/conf.avail/$JITSI_FQDN.cfg.lua

cp usr/share/jitsi-meet/prosody-plugins/*.lua \
    $ROOTFS/usr/share/jitsi-meet/prosody-plugins/

lxc-attach -n $MACH -- systemctl daemon-reload
lxc-attach -n $MACH -- systemctl restart prosody.service

# ------------------------------------------------------------------------------
# JICOFO
# ------------------------------------------------------------------------------
cp $ROOTFS/etc/jitsi/jicofo/config $ROOTFS/etc/jitsi/jicofo/config.org
cp $ROOTFS/etc/jitsi/jicofo/jicofo.conf $ROOTFS/etc/jitsi/jicofo/jicofo.conf.org

cat >>$ROOTFS/etc/jitsi/jicofo/config <<EOF

# set the maximum memory for the jicofo daemon
JICOFO_MAX_MEMORY=3072m
EOF

lxc-attach -n $MACH -- zsh <<EOS
set -e
hocon -f /etc/jitsi/jicofo/jicofo.conf \
    set jicofo.conference.enable-auto-owner true
EOS

lxc-attach -n $MACH -- systemctl restart jicofo.service

# ------------------------------------------------------------------------------
# NGINX
# ------------------------------------------------------------------------------
cp $ROOTFS/etc/nginx/nginx.conf $ROOTFS/etc/nginx/nginx.conf.org
cp $ROOTFS/etc/nginx/sites-available/$JITSI_FQDN.conf \
    $ROOTFS/etc/nginx/sites-available/$JITSI_FQDN.conf.org

mkdir -p $ROOTFS/etc/systemd/system/nginx.service.d
cp etc/systemd/system/nginx.service.d/override.conf \
    $ROOTFS/etc/systemd/system/nginx.service.d/

sed -i "/worker_connections/ s/\\S*;/8192;/" \
    $ROOTFS/etc/nginx/nginx.conf

mkdir -p $ROOTFS/usr/local/share/nginx/modules-available
cp usr/local/share/nginx/modules-available/jitsi-meet.conf \
    $ROOTFS/usr/local/share/nginx/modules-available/
sed -i "s/___LOCAL_IP___/$IP/" \
    $ROOTFS/usr/local/share/nginx/modules-available/jitsi-meet.conf
sed -i "s/___TURN_FQDN___/$TURN_FQDN/" \
    $ROOTFS/usr/local/share/nginx/modules-available/jitsi-meet.conf

cp etc/nginx/sites-available/jms.conf \
    $ROOTFS/etc/nginx/sites-available/$JITSI_FQDN.conf
sed -i "s/___JITSI_FQDN___/$JITSI_FQDN/" \
    $ROOTFS/etc/nginx/sites-available/$JITSI_FQDN.conf
sed -i "s/___TURN_FQDN___/$TURN_FQDN/" \
    $ROOTFS/etc/nginx/sites-available/$JITSI_FQDN.conf

lxc-attach -n $MACH -- zsh <<EOS
ln -s /usr/local/share/nginx/modules-available/jitsi-meet.conf \
    /etc/nginx/modules-enabled/99-jitsi-meet-custom.conf
rm /etc/nginx/sites-enabled/default
rm -rf /var/www/html
ln -s /usr/share/jitsi-meet /var/www/html
EOS

lxc-attach -n $MACH -- systemctl daemon-reload
lxc-attach -n $MACH -- systemctl stop nginx.service
lxc-attach -n $MACH -- systemctl start nginx.service

# ------------------------------------------------------------------------------
# JVB
# ------------------------------------------------------------------------------
cp $ROOTFS/etc/jitsi/videobridge/config $ROOTFS/etc/jitsi/videobridge/config.org
cp $ROOTFS/etc/jitsi/videobridge/jvb.conf \
    $ROOTFS/etc/jitsi/videobridge/jvb.conf.org
cp $ROOTFS/etc/jitsi/videobridge/sip-communicator.properties \
    $ROOTFS/etc/jitsi/videobridge/sip-communicator.properties.org

# meta
lxc-attach -n $MACH -- zsh <<EOS
set -e
mkdir -p /root/meta
VERSION=\$(apt-cache policy jitsi-videobridge2 | grep Installed | rev | \
    cut -d' ' -f1 | rev)
echo \$VERSION > /root/meta/jvb-version
EOS

# default memory limit
cat >>$ROOTFS/etc/jitsi/videobridge/config <<EOF

# set the maximum memory for the JVB daemon
VIDEOBRIDGE_MAX_MEMORY=3072m
EOF

# colibri
lxc-attach -n $MACH -- zsh <<EOS
set -e
hocon -f /etc/jitsi/videobridge/jvb.conf \
    set videobridge.apis.rest.enabled true
hocon -f /etc/jitsi/videobridge/jvb.conf \
    set videobridge.ice.udp.port 10000
EOS

# NAT harvester. these will be needed if this is an in-house server.
cat >>$ROOTFS/etc/jitsi/videobridge/sip-communicator.properties <<EOF
#org.ice4j.ice.harvest.NAT_HARVESTER_LOCAL_ADDRESS=$IP
#org.ice4j.ice.harvest.NAT_HARVESTER_PUBLIC_ADDRESS=$REMOTE_IP
EOF

if [[ "$EXTERNAL_IP" != "$REMOTE_IP" ]]; then
    cat >>$ROOTFS/etc/jitsi/videobridge/sip-communicator.properties <<EOF
#org.ice4j.ice.harvest.NAT_HARVESTER_PUBLIC_ADDRESS=$EXTERNAL_IP
EOF
fi

# restart
lxc-attach -n $MACH -- systemctl restart jitsi-videobridge2.service

# ------------------------------------------------------------------------------
# CONFIG.JS
# ------------------------------------------------------------------------------
cp $JITSI_MEET_CONFIG $JITSI_MEET_CONFIG.org

# ------------------------------------------------------------------------------
# INTERFACE_CONFIG.JS
# ------------------------------------------------------------------------------
cp $JITSI_MEET_INTERFACE $JITSI_MEET_INTERFACE.org

# ------------------------------------------------------------------------------
# TOOLS & SCRIPTS
# ------------------------------------------------------------------------------
# jicofo-log-analyzer
cp usr/local/bin/jicofo-log-analyzer $ROOTFS/usr/local/bin/
chmod 755 $ROOTFS/usr/local/bin/jicofo-log-analyzer

# ------------------------------------------------------------------------------
# CONTAINER SERVICES
# ------------------------------------------------------------------------------
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING

# wait for the network to be up
for i in $(seq 0 9); do
    lxc-attach -n $MACH -- ping -c1 host.loc && break || true
    sleep 1
done

# ------------------------------------------------------------------------------
# HOST CUSTOMIZATION FOR JITSI
# ------------------------------------------------------------------------------
# jitsi tools
cp $MACHINES/eb-jitsi-host/usr/local/sbin/add-jvb-node /usr/local/sbin/
cp $MACHINES/eb-jitsi-host/usr/local/sbin/set-letsencrypt-cert /usr/local/sbin/
chmod 744 /usr/local/sbin/add-jvb-node
chmod 744 /usr/local/sbin/set-letsencrypt-cert
