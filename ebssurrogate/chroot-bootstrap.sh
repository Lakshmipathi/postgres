#!/usr/bin/env bash
#
# This script runs inside chrooted environment. It installs grub and its
# Configuration file.
#

set -o errexit
set -o pipefail
set -o xtrace

function update_install_packages {
	# Update APT with new sources
	cat /etc/apt/sources.list
	sleep 10
	apt-get update

	# Do not configure grub during package install
	echo 'grub-pc grub-pc/install_devices_empty select true' | debconf-set-selections
	echo 'grub-pc grub-pc/install_devices select' | debconf-set-selections

	export DEBIAN_FRONTEND=noninteractive

	# Install various packages needed for a booting system
	apt-get install -y \
		linux-aws \
		grub2 \
		e2fsprogs

	# Install standard packages
	apt-get install -y \
		sudo \
		cloud-init \
		acpid \
		ec2-hibinit-agent \
		ec2-instance-connect \
		hibagent \
		ncurses-term \
		ssh-import-id \

	# apt upgrade
	apt-get upgrade -y

	# Install OpenSSH
	sudo add-apt-repository universe
	apt-get update
	apt-get install -y --no-install-recommends \
		openssh-server \
		git \
		ufw \
		cron \
		logrotate \
		fail2ban \
		locales

cat << EOF > /etc/default/locale
LANG="C.UTF-8"
LC_CTYPE="C.UTF-8"
EOF
	localedef -i en_US -f UTF-8 en_US.UTF-8
	# Disable IPV6 for ufw
	sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw
}

function install_packages_for_build {
	apt-get install -y --no-install-recommends linux-libc-dev
	apt-get install -y --no-install-recommends acl
	apt-get install -y --no-install-recommends magic-wormhole sysstat
	apt-get install -y --no-install-recommends build-essential libreadline-dev zlib1g-dev flex bison libxml2-dev libxslt-dev libssl-dev libsystemd-dev libpq-dev libxml2-utils uuid-dev xsltproc ssl-cert
	apt-get install -y --no-install-recommends llvm-11-dev clang-11
	apt-get install -y --no-install-recommends gcc-10 g++-10
	apt-get install -y --no-install-recommends libgeos-dev libproj-dev libgdal-dev libjson-c-dev libboost-all-dev libcgal-dev libmpfr-dev libgmp-dev cmake
	apt-get install -y --no-install-recommends libkrb5-dev
	apt-get install -y --no-install-recommends maven default-jre default-jdk
	apt-get install -y --no-install-recommends curl gpp apt-transport-https cmake libc++-dev libc++abi-dev libc++1 libglib2.0-dev libtinfo5 libc++abi1 ninja-build python
	apt-get install -y --no-install-recommends liblzo2-dev
}

function install_configure_grub {
	mkdir -p /etc/default/grub.d

cat << EOF > /etc/default/grub.d/50-aws-settings.cfg
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_TIMEOUT=0
GRUB_CMDLINE_LINUX_DEFAULT=" root=/dev/nvme0n1p2 rootfstype=ext4 rw noatime,nodiratime,discard console=tty1 console=ttyS0 ip=dhcp tsc=reliable net.ifnames=0 quiet module_blacklist=psmouse,input_leds,autofs4 ipv6.disable=1 nvme_core.io_timeout=4294967295 systemd.hostname=ubuntu"
GRUB_TERMINAL=console
GRUB_DISABLE_LINUX_UUID=true
EOF
        grub-mkconfig -o /boot/grub/grub.cfg
	grub-install --target=i386-pc --directory=/usr/lib/grub/i386-pc --recheck --boot-directory=/boot /dev/xvdf

	# skip fsck for first boot
	touch /fastboot
}

function setup_hostname {
	# Don't request hostname during boot but set hosntame
	sed -i 's/gethostname()/ubuntu /g' /etc/dhcp/dhclient.conf
	sed -i 's/host-name,//g' /etc/dhcp/dhclient.conf
	echo "ubuntu" > /etc/hostname
	chmod 644 /etc/hostname

# Set options for the default interface
cat << EOF > /etc/netplan/eth0.yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
EOF
}

function create_admin_account {
	groupadd admin
}

#Set default target as multi-user
function set_default_target {
	rm -f /etc/systemd/system/default.target
	ln -s /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
}

# Clear apt caches
function cleanup_cache {
	apt-get clean
}

update_install_packages
install_packages_for_build
install_configure_grub
setup_hostname
create_admin_account
set_default_target
cleanup_cache
