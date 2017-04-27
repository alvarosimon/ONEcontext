#!/bin/bash

CEPH_MOUNT="/cephfs"
SSH_DIR="/home/docker/.ssh"

# Update the system and install Ceph repos
yum update -y
yum install https://download.ceph.com/rpm-jewel/el7/noarch/ceph-release-1-1.el7.noarch.rpm -y
yum install yum-utils ceph-common -y

# Install and enable Docker service
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum makecache fast
yum install docker-ce -y
useradd docker -g docker
systemctl start docker
systemctl enable docker

# Include SSH keys
if [ ! -d "$SSH_DIR" ]; then
    su - docker -c "cd /home/docker && tar xvzf /mnt/pub_keys.tar.gz"
fi

# Get OpenNebula VM context variables
source /tmp/one_env

# Set hostname
hostnamectl set-hostname --static $(/sbin/ip -4 -o addr show to 10.145.0.0/16 | \
/bin/sed "s#.\(10\.[0-9]\+\.[0-9]\+\.[0-9]\+\)/[0-9].#\1#" | \
/usr/bin/head -1 | xargs host | sed "s/.* //;s/\.$//")

# mount Ceph
if [ ! -d "$CEPH_MOUNT" ]; then
    mkdir "$CEPH_MOUNT"
fi
mount -t ceph mds11.grimer.stor,mds12.grimer.stor,mds13.grimer.stor:/external/vib -o secretfile=/mnt/vib.secret,name=vib,noatime $CEPH_MOUNT

# Setup the Docker Master or Worker
if [ "$ROLE_NAME" == "Master" ]; then
    docker swarm init --advertise-addr "$ETH0_IP"
fi
if [ "$ROLE_NAME" == "Worker" ]; then
    SWARM_TOKEN=$(su - docker -c "ssh -q -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking no' $MASTER_IP")
    docker swarm join --token "$SWARM_TOKEN" "$MASTER_IP":2377
fi

# Send READY message to ONE gate
curl -X "PUT" "$ONEGATE_ENDPOINT/vm" --header "X-ONEGATE-TOKEN: $(cat /mnt/token.txt)" --header "X-ONEGATE-VMID: $VMID" -d "READY = YES"

