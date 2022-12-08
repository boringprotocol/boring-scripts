#!/bin/bash -ex

if [ -f /boot/boring.env ]; then
	. /boot/boring.env
fi

LOCAL_GATEWAY=$(/sbin/ip route | /bin/awk '/default/ { print $3 }'| /bin/head -1)

RESET=false

if [ -f /boot/1boring.env ]; then
	# if files differ, run a reset
	set +e
	/usr/bin/diff /boot/boring.env /boot/1boring.env
	if [[ "$?" != "0" ]]; then
		/usr/bin/diff /boot/boring.env /boot/1boring.env |grep "SETUP_KEY"
		if [[ "$?" == "0" ]]; then
		# setup key was changed, hard reset
			systemctl stop netbird
			rm -rf /etc/netbird/config.json ||true
			rm -rf /etc/sysconfig/netbird ||true
			cp /boot/1boring.env /boot/2boring.env
cat <<EOZ > /etc/hosts
127.0.0.1	localhost ${BORING_NAME}
EOZ
			hostnamectl set-hostname $BORING_NAME
			RESET=true
			echo reseting
		else
			# setup key was unchanged, soft reset
			# todo, soft reset stuff goes here (SSID, name, network)
			RESET=false
			echo soft reset
		fi
	fi
	set -e
else
	# cause it's firstboot
	RESET=true
	FIRSTBOOT=true
cat <<EOZ > /etc/hosts
127.0.0.1	localhost ${BORING_NAME}
EOZ
	hostnamectl set-hostname $BORING_NAME
	echo firstbooting
fi

set +e

HOSTAPD_RESET=false
/usr/bin/diff /boot/boring.env /boot/1boring.env |grep "WIFI_PREFERENCE"
if [[ "$?" == "0" ]]; then
	HOSTAPD_RESET=true
fi
/usr/bin/diff /boot/boring.env /boot/1boring.env |grep "SSID"
if [[ "$?" == "0" ]]; then
	HOSTAPD_RESET=true
fi
/usr/bin/diff /boot/boring.env /boot/1boring.env |grep "COUNTRY_CODE"
if [[ "$?" == "0" ]]; then
	HOSTAPD_RESET=true
fi
/usr/bin/diff /boot/boring.env /boot/1boring.env |grep "WPA_PASSPHRASE"
if [[ "$?" == "0" ]]; then
	HOSTAPD_RESET=true
fi
/usr/bin/diff /boot/boring.env /boot/1boring.env |grep "CHANNEL"
if [[ "$?" == "0" ]]; then
	HOSTAPD_RESET=true
fi

set -e

if [[ "$HOSTAPD_RESET" == "true" || "$FIRSTBOOT" == "true" ]]; then
# wifi preference has changed, run hostapd config
		if [[ "$WIFI_PREFERENCE" == "2.4Ghz" ]]; then
			HW_MODE=g
cat <<EOI > /etc/hostapd/hostapd.conf
country_code=${COUNTRY_CODE}
interface=wlan0
ssid=${SSID}
hw_mode=${HW_MODE}
channel=${CHANNEL}
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${WPA_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOI
		systemctl restart hostapd
		fi

		if [[ "$WIFI_PREFERENCE" == "5Ghz" ]]; then
			HW_MODE=a
			CHANNEL=33
cat <<EOJ > /etc/hostapd/hostapd.conf
country_code=${COUNTRY_CODE}
interface=wlan0
ssid=${SSID}
hw_mode=${HW_MODE}
channel=${CHANNEL}
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${WPA_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
ieee80211d=1
ieee80211n=1
ieee80211ac=1
wmm_enabled=1
EOJ
		systemctl restart hostapd
		fi
fi

cp /boot/boring.env /boot/1boring.env

# update-sidecar-connect-pi
# update journald-remote
# update telegraf.conf
if [[ "$UPDATE" == "true" ]]; then
	apt-get install -y systemd-journal-remote ||true
	cp /boringup/systemd-journal-gatewayd.service /lib/systemd/system/systemd-journal-gatewayd.service ||true
	systemctl enable systemd-journal-gatewayd ||true
    systemctl start systemd-journal-gatewayd ||true
	mkdir -p /usr/local/boring ||true
	cp /boringup/ip-is-in /usr/local/bin/ip-is-in

	systemctl stop dnsmasq ||true
	systemctl stop dhcpcd ||true

	USE_THIS_IP=$(/usr/local/bin/ip-is-in)
	read A B C D <<<"${USE_THIS_IP//./ }"
cat <<EOKI > /etc/dhcpcd.conf
interface wlan0
	static ip_address=${USE_THIS_IP}/24
	nohook wpa_supplicant
EOKI

	# dnsmasq host patch
	cat <<EOZ > /etc/dnsmasq.conf
interface=wlan0
dhcp-range=${A}.${B}.${C}.2,${A}.${B}.${C}.100,255.255.255.0,24h
domain=network
address=/boring.network/${USE_THIS_IP}
addn-hosts=/etc/dnsmasq.hosts
no-resolv
server=1.1.1.1
server=1.0.0.1
server=8.8.4.4
server=8.8.8.8
EOZ

	cat <<EOY > /etc/dnsmasq.hosts
${USE_THIS_IP} unconfigured.insecure.boring.surf.
EOY

	systemctl start dhcpcd ||true
	systemctl start dnsmasq ||true

	# cp telegraf.conf
	cp /boringup/telegraf.conf /etc/telegraf/telegraf.conf

	if [[ "$UPDATE_UI" == "true" ]]; then
		cd /usr/local/boring
		rm -rf connect-pi.tgz ||true
		wget https://s3.us-east-2.amazonaws.com/boringfiles.dank.earth/connect-pi.tgz
		tar -xzvf connect-pi.tgz
		cd connect-pi
		npm install -y
		npm run build
		#service file
		cp connect-pi.service /lib/systemd/system/connect-pi.service
		systemctl daemon-reload
		systemctl restart connect-pi
		# install nginx configure SSL for default insecure site ops
		export DEBIAN_FRONTEND=true
		apt install -y nginx
		cp connect-pi.nginx.conf /etc/nginx/sites-enabled/default
		systemctl enable nginx
		mkdir -p /usr/local/boring/certs
		cp fullchain.pem /usr/local/boring/certs/fullchain.pem
		cp privkey.pem /usr/local/boring/certs/privkey.pem
		systemctl restart nginx
	fi
fi

if [[ "$KIND" == "consumer" ]]; then
	echo "setting up consumer.."
	if [[ "$RESET" == "true" ]]; then
		systemctl stop netbird ||true

		mkdir -p /etc/sysconfig ||true

cat <<EOF > /etc/sysconfig/netbird
PROVIDER_PUBKEY=${PROVIDER_PUBKEY}
EOF

		systemctl start netbird
		sleep 2

		netbird up --setup-key $SETUP_KEY --management-url https://boring.dank.earth:33073
		sleep 5

	fi

	systemctl start netbird ||true
	sleep 20

	sysctl net.ipv4.ip_forward=1
	ip route del default
	ip route add default dev wt0
	for i in ${PUBLIC_PEER_IP_LIST//,/ }
	do
	ip route add $i/32 via $LOCAL_GATEWAY dev eth0
	done
	iptables -t nat -A POSTROUTING -o wt0 -j MASQUERADE
	# masquerade also for any direct traffic to falcon
	iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
	sleep 1

elif [[ "$KIND" == "provider" ]]; then
	echo "setting up provider.."

	if [[ "$RESET" == "true" ]]; then
		systemctl start netbird
		sleep 2

		netbird up --setup-key $SETUP_KEY --management-url https://boring.dank.earth:33073
		sleep 5

		mypubkey=`/usr/bin/wg show all dump |/usr/bin/head -n1 |/usr/bin/cut -f3`

		systemctl stop netbird
		mkdir -p /etc/sysconfig ||true
cat <<EOD > /etc/sysconfig/netbird
PROVIDER_PUBKEY=${mypubkey}
EOD
	fi

	systemctl start netbird || true
	sleep 20 

	sysctl net.ipv4.ip_forward=1
	iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
	iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	iptables -A FORWARD -i wt0 -o eth0 -j ACCEPT
else

	echo "error: invalid \$KIND specified: $KIND"
	exit 1
fi

# telegraf
	# do telegraf setup
	# gather our pubkey
	mypubkey=`/usr/bin/wg show all dump |/usr/bin/head -n1 |/usr/bin/cut -f3`
	# telegraf needs perms
	setcap CAP_NET_ADMIN+epi /usr/bin/telegraf
	systemctl stop telegraf ||true
	# setup telegraf id
cat <<EOT > /etc/default/telegraf
INFLUX_TOKEN=QqNqJPMtU3vQk5s-NOOtLU9kQbXZ106181ux7AR6wGOnA7pPVIWtWhvLXT3ai06L_FMcUj2fM1bfsHG_fUFIpw==
BORING_ID=${BORING_ID}
BORING_NAME=${BORING_NAME}
MYPUBKEY=${mypubkey}
EOT
	systemctl start telegraf ||true
