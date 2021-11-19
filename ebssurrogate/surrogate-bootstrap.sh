#!/usr/bin/env bash
#
# This script creates filesystem and setups up chrooted
# enviroment for further processing. It also runs
# ansible playbook and finally does system cleanup.
#

set -o errexit
set -o pipefail
set -o xtrace

function waitfor_boot_finished {
	export DEBIAN_FRONTEND=noninteractive

	echo "args: ${ARGS}"
	# Wait for cloudinit on the surrogate to complete before making progress
	while [[ ! -f /var/lib/cloud/instance/boot-finished ]]; do
	    echo 'Waiting for cloud-init...'
	    sleep 1
	done
}

function install_packages {
	# Setup Ansible on host VM
	apt-get update && sudo apt-get install software-properties-common -y
	add-apt-repository --yes --update ppa:ansible/ansible && sudo apt-get install ansible -y
	ansible-galaxy collection install community.general

	# Update apt and install required packages
	apt-get update
	apt-get install -y \
		gdisk \
		e2fsprogs \
		debootstrap \
		nvme-cli \
		docker.io 

}

function device_partition_mappings {
	# NVMe EBS launch device mappings (symlinks): /dev/nvme*n* to /dev/xvd*
	declare -A blkdev_mappings
	for blkdev in $(nvme list | awk '/^\/dev/ { print $1 }'); do  # /dev/nvme*n*
	    # Mapping info from disk headers
	    header=$(nvme id-ctrl --raw-binary "${blkdev}" | cut -c3073-3104 | tr -s ' ' | sed 's/ $//g' | sed 's!/dev/!!')
	    mapping="/dev/${header%%[0-9]}"  # normalize sda1 => sda

	    # Create /dev/xvd* device symlink
	    if [[ ! -z "$mapping" ]] && [[ -b "${blkdev}" ]] && [[ ! -L "${mapping}" ]]; then
		ln -s "$blkdev" "$mapping"

		blkdev_mappings["$blkdev"]="$mapping"
	    fi
	done

	# Partition the new root EBS volume
	sgdisk -Zg -n1:0:4095 -t1:EF02 -c1:GRUB -n2:0:0 -t2:8300 -c2:EXT4 /dev/xvdf

	# NVMe EBS launch device partition mappings (symlinks): /dev/nvme*n*p* to /dev/xvd*[0-9]+
	declare -A partdev_mappings
	for blkdev in "${!blkdev_mappings[@]}"; do  # /dev/nvme*n*
	    mapping="${blkdev_mappings[$blkdev]}"

	    # Create /dev/xvd*[0-9]+ partition device symlink
	    for partdev in "${blkdev}"p*; do
		partnum=${partdev##*p}
		if [[ ! -L "${mapping}${partnum}" ]]; then
		    ln -s "${blkdev}p${partnum}" "${mapping}${partnum}"

		    partdev_mappings["${blkdev}p${partnum}"]="${mapping}${partnum}"
		fi
	    done
	done
}


function format_and_mount_rootfs {
	#Download and install latest e2fsprogs for fast_commit feature
	if [ "${USE_FAST_COMMIT}" = "yes" ]; then
		apt-get install gcc make bison -y
		wget https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git/snapshot/e2fsprogs-1.46.4.tar.gz
		tar -xvf e2fsprogs-1.46.4.tar.gz && cd e2fsprogs-1.46.4 && ./configure && make -j2 && make install
		# Format the drive as 
		mkfs.ext4 -O fast_commit /dev/xvdf2
	else
		mkfs.ext4 /dev/xvdf2
	fi
	mount -o noatime,nodiratime /dev/xvdf2 /mnt
	mkfs.ext4 -O ^has_journal /dev/xvdc

}

function pull_docker {
	docker run -itd --name ccachedata "${DOCKER_IMAGE}:${DOCKER_IMAGE_TAG}" sh
	docker exec -itd ccachedata mkdir -p /build/ccache
}


function setup_chroot_environment {
	# Bootstrap Ubuntu into /mnt
	debootstrap --arch amd64 --variant=minbase focal /mnt

	# Update ec2-region
	REGION=$(curl --silent http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -E 's|[a-z]+$||g')
	sed -i "s/REGION/${REGION}/g" /tmp/sources.list
	cp /tmp/sources.list /mnt/etc/apt/sources.list

	# Create mount points and mount the filesystem
	mkdir -p /mnt/{dev,proc,sys}
	mount --rbind /dev /mnt/dev
	mount --rbind /proc /mnt/proc
	mount --rbind /sys /mnt/sys

        # Create build mount point and mount 
	mkdir -p /mnt/tmp
	mount /dev/xvdc /mnt/tmp
	chmod 777 /mnt/tmp

	# Copy the bootstrap script into place and execute inside chroot
	cp /tmp/chroot-bootstrap.sh /mnt/tmp/chroot-bootstrap.sh
	chroot /mnt /tmp/chroot-bootstrap.sh
	rm -f /mnt/tmp/chroot-bootstrap.sh

	# Copy the nvme identification script into /sbin inside the chroot
	mkdir -p /mnt/sbin
	cp /tmp/ebsnvme-id /mnt/sbin/ebsnvme-id
	chmod +x /mnt/sbin/ebsnvme-id

	# Copy the udev rules for identifying nvme devices into the chroot
	mkdir -p /mnt/etc/udev/rules.d
	cp /tmp/70-ec2-nvme-devices.rules \
		/mnt/etc/udev/rules.d/70-ec2-nvme-devices.rules

	#Copy custom cloud-init
	rm -f /mnt/etc/cloud/cloud.cfg
	cp /tmp/cloud.cfg /mnt/etc/cloud/cloud.cfg

	sleep 10
}

function download_ccache {
	docker cp ccachedata:/build/ccache/. /mnt/tmp/ccache
}

function execute_playbook {
	# Run Ansible playbook
	#export ANSIBLE_LOG_PATH=/tmp/ansible.log && export ANSIBLE_DEBUG=True && export ANSIBLE_REMOTE_TEMP=/mnt/tmp 
	export ANSIBLE_LOG_PATH=/tmp/ansible.log && export ANSIBLE_REMOTE_TEMP=/mnt/tmp 
	ansible-playbook -c chroot -i '/mnt,' /tmp/ansible-playbook/ansible/playbook.yml --extra-vars " $ARGS"
}

function update_systemd_services {
	# Disable vector service and set timer unit.
	cp -v /tmp/vector.timer /mnt/etc/systemd/system/vector.timer
	rm -f /mnt/etc/systemd/system/multi-user.target.wants/vector.service
	ln -s /mnt/etc/systemd/system/vector.timer /mnt/etc/systemd/system/multi-user.target.wants/vector.timer

	# Uncomment below to Disable postgresql service during first boot.
	# rm -f /mnt/etc/systemd/system/multi-user.target.wants/postgresql.service
}


function clean_system {
	# Copy cleanup scripts
	cp -v /tmp/ansible-playbook/scripts/90-cleanup.sh /mnt/tmp
	chmod +x /mnt/tmp/90-cleanup.sh
	chroot /mnt /tmp/90-cleanup.sh

	# Cleanup logs
	rm -rf /mnt/var/log/*
	# https://github.com/fail2ban/fail2ban/issues/1593
	touch /mnt/var/log/auth.log

	touch /mnt/var/log/pgbouncer.log
	chroot /mnt /usr/bin/chown postgres:postgres /var/log/pgbouncer.log

	# Setup postgresql logs
	mkdir -p /mnt/var/log/postgresql
	chroot /mnt /usr/bin/chown postgres:postgres /var/log/postgresql

	# unwanted files
	rm -rf /mnt/var/lib/apt/lists/*
	rm -rf /mnt/root/.cache
	rm -rf /mnt/root/.vpython*
	rm -rf /mnt/root/go

}

function upload_ccache {
	docker cp /mnt/tmp/ccache/. ccachedata:/build/ccache
	docker stop ccachedata
	docker commit ccachedata "${DOCKER_IMAGE}:${DOCKER_IMAGE_TAG}"
	echo ${DOCKER_PASSWD} | docker login --username ${DOCKER_USER} --password-stdin 
	docker push  "${DOCKER_IMAGE}:${DOCKER_IMAGE_TAG}"
}

# Unmount bind mounts
function umount_reset_mappings {
	umount -l /mnt/dev
	umount -l /mnt/proc
	umount -l /mnt/sys
	umount -l /mnt/tmp

	umount /mnt

	# Reset device mappings
	for dev_link in "${blkdev_mappings[@]}" "${partdev_mappings[@]}"; do
	    if [[ -L "$dev_link" ]]; then
		rm -f "$dev_link"
	    fi
	done
}

waitfor_boot_finished
install_packages
device_partition_mappings
format_and_mount_rootfs
pull_docker
setup_chroot_environment
download_ccache
execute_playbook
update_systemd_services
upload_ccache
clean_system
umount_reset_mappings
