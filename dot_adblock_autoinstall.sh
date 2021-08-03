#!/bin/sh

echo 'Creating startup script to mount /opt, /root and start Entware services'
cat << 'EOF' > /etc/init.d/rootopt
#!/bin/sh /etc/rc.common

START=97
STOP=00

start() {
        [ -d /etc/root ] && mount -o bind /etc/root /root
        [ -d /etc/opt ] && mount -o bind /etc/opt /opt
        [ -x /opt/etc/init.d/rc.unslung ] && /opt/etc/init.d/rc.unslung start
        return 0
}

stop() {
        [ -x /opt/etc/init.d/rc.unslung ] && /opt/etc/init.d/rc.unslung stop
        [ -d /etc/opt ] && umount /opt
        [ -d /etc/root ] && umount /root
        return 0
}
EOF
chmod +x /etc/init.d/rootopt

mkdir -p /etc/opt /etc/root || exit 1
/etc/init.d/rootopt enable
/etc/init.d/rootopt start

echo 'Install Entware'
wget http://bin.entware.net/aarch64-k3.10/installer/generic.sh -O- | sh -
#Add /opt/bin /opt/sbin to PATH
echo 'export PATH=$PATH:/opt/bin:/opt/sbin' >> /root/.profile

echo 'Install stubby'
/opt/bin/opkg update
/opt/bin/opkg install stubby

echo 'Configure and start stubby'
mv -f /opt/etc/stubby/stubby.yml /opt/etc/stubby/stubby.yml.bak
cat << 'EOF' > /opt/etc/stubby/stubby.yml
# Note: by default on OpenWRT stubby configuration is handled via
# the UCI system and the file /etc/config/stubby. If you want to
# use this file to configure stubby, then set "option manual '1'"
# in /etc/config/stubby.
resolution_type: GETDNS_RESOLUTION_STUB
round_robin_upstreams: 1
appdata_dir: "/var/lib/stubby"
# tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@65053
  - 0::1@65053
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
upstream_recursive_servers:
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 1.0.0.1
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"
  - address_data: 8.8.4.4
    tls_auth_name: "dns.google"
EOF
cat << 'EOF' > /etc/init.d/stubby
#!/bin/sh /etc/rc.common
# Stubby
 
START=98
STOP=00
 
start() {        
        /opt/sbin/stubby -g
	echo "Stubby started"
}                 
 
stop() {
	killall -SIGHUP stubby 
	echo "Stubby stoped"
}
EOF
chmod +x /etc/init.d/stubby
/etc/init.d/stubby enable
/etc/init.d/stubby start

echo 'Configure adblock service'
mkdir -p /opt/etc/adblock || exit 1
touch /opt/etc/adblock/black.list /opt/etc/adblock/white.list
cat << 'EOF' > /opt/etc/adblock/update.sh
#!/bin/sh

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 0.0.0.0 is defined as a non-routable meta-address used to designate an invalid, unknown, or non applicable target. Using 0.0.0.0 is empirically faster, possibly because there's no wait for a timeout resolution
ENDPOINT_IP4="0.0.0.0"
TMPDIR="/tmp/block.build.list"
STGDIR="/tmp/block.build.before"
TARGET="/tmp/block.hosts"
BLIST="/opt/etc/adblock/black.list"
WLIST="/opt/etc/adblock/white.list"

# Download and process the files needed to make the lists (enable/add more, if you want)

# luckypatcher hosts
curl -k -o- "https://drive.google.com/uc?export=download&confirm=no_antivirus&id=1lB5oFNhcojiSyjSnKfswtqHCgqOXLKTY" | awk -v r="$ENDPOINT_IP4" '{sub(/^127.0.0.1/, r)} $0 ~ "^"r' > "$TMPDIR"

# focus on ad related domains
curl -k -o- "https://pgl.yoyo.org/as/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext" | awk -v r="$ENDPOINT_IP4" '{sub(/^127.0.0.1/, r)} $0 ~ "^"r' >> "$TMPDIR"

# focus on mobile ads
curl -k -o- "https://adaway.org/hosts.txt" | awk -v r="$ENDPOINT_IP4" '{sub(/^127.0.0.1/, r)} $0 ~ "^"r' >> "$TMPDIR"

# broad blocklist
curl -k -o- "https://someonewhocares.org/hosts/hosts" | awk -v r="$ENDPOINT_IP4" '{sub(/^127.0.0.1/, r)} $0 ~ "^"r' >> "$TMPDIR"

# focus on malicious bitcoin mining sites
curl -k -o- "https://raw.githubusercontent.com/hoshsadiq/adblock-nocoin-list/master/hosts.txt" | awk -v r="$ENDPOINT_IP4" '{sub(/^0.0.0.0/, r)} $0 ~ "^"r' >> "$TMPDIR"

# focus on malvertising by disconnect.me
curl -k -o- "https://s3.amazonaws.com/lists.disconnect.me/simple_malvertising.txt" | grep -v -e ^# -e ^$ | awk -v r="$ENDPOINT_IP4 " '{sub(//, r)} $0 ~ "^"r' >> "$TMPDIR"

# focus on Windows installers ads sources
curl -k -o- "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts" | awk -v r="$ENDPOINT_IP4" '{sub(/^0.0.0.0/, r)} $0 ~ "^"r' >> "$TMPDIR"


# Add black list, if non-empty
if [ -s "$BLIST" ]
then
    awk -v r="$ENDPOINT_IP4" '/^[^#]/ { print r,$1 }' "$BLIST" >> "$TMPDIR"
fi


# Sort the download/black lists
awk '{sub(/\r$/,"");print $1,$2}' "$TMPDIR" | sort -u > "$STGDIR"


# Filter (if applicable)
if [ -s "$WLIST" ]
then
    # Filter the blacklist, suppressing whitelist matches
    # This is relatively slow
    egrep -v "^[[:space:]]*$" "$WLIST" | awk '/^[^#]/ {sub(/\r$/,"");print $1}' | grep -vf - "$STGDIR" > "$TARGET"
else
    cat "$STGDIR" > "$TARGET"
fi


# Delete files used to build list to free up the limited space
rm -f "$TMPDIR"
rm -f "$STGDIR"


killall -SIGHUP dnsmasq

EOF

chmod +x /opt/etc/adblock/update.sh

cat << 'EOF' > /etc/init.d/adblock
#!/bin/sh /etc/rc.common
# Adblock
 
START=99
STOP=00
 
start() {        
        echo "Downloading hosts"
        /opt/etc/adblock/update.sh
	echo "Adblock started"
}                 
 
stop() {
	echo "Removing block.hosts"          
        rm -f /tmp/block.hosts
	killall -SIGHUP dnsmasq 
	echo "Adblock stoped"
}

EOF
chmod +x /etc/init.d/adblock
/etc/init.d/adblock enable
/etc/init.d/adblock start

echo 'Add block hosts and stubby dns to dnsmasq'
echo 'addn-hosts=/tmp/block.hosts' > /etc/dnsmasq.d/adblock
cat << 'EOF' > /etc/dnsmasq.d/stubby
no-resolv
server=127.0.0.1#65053
EOF

/etc/init.d/dnsmasq restart
