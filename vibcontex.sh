#!/bin/bash

CEPH_MOUNT="/galaxy_base"
SSH_DIR="/home/docker/.ssh"
DOCKER_ID="1000"
GALAXY_ID="1001"

# Docker user and group
if ! groups "docker" >/dev/null 2>&1; then
    groupadd docker -g "$DOCKER_ID"
fi
if ! id "docker" >/dev/null 2>&1; then
    useradd docker -u "$DOCKER_ID" -g docker
fi
# Galaxy user and group
if ! groups "galaxy" >/dev/null 2>&1; then
    groupadd galaxy -g "$GALAXY_ID"
fi
if ! id "galaxy" >/dev/null 2>&1; then
    useradd galaxy -u "$GALAXY_ID" -G docker -g galaxy
fi

# Update the system and install Ceph repos
yum update -y
yum install https://download.ceph.com/rpm-jewel/el7/noarch/ceph-release-1-1.el7.noarch.rpm -y
yum install yum-utils ceph-common -y

# Set hostname
hostnamectl set-hostname --static $(/sbin/ip -4 -o addr show to 10.145.0.0/16 | /bin/sed "s#.*\(10\.[0-9]\+\.[0-9]\+\.[0-9]\+\)/[0-9].*#\1#" \
| /usr/bin/head -1 | xargs host | sed "s/.* //;s/\.$//")

# mount Ceph
if [ ! -d "$CEPH_MOUNT" ]; then
    mkdir "$CEPH_MOUNT"
fi
if ! grep -Fq "$CEPH_MOUNT" /etc/fstab; then
    echo "mds11.grimer.stor,mds12.grimer.stor,mds13.grimer.stor:/external/vib $CEPH_MOUNT ceph secretfile=/mnt/vib.secret,name=vib,noatime 0 0" >> /etc/fstab
fi
mount "$CEPH_MOUNT"

# Install and enable Docker service
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum makecache fast
yum install docker-ce -y

# Enable Docker service
systemctl start docker
systemctl enable docker

# Include SSH keys
if [ ! -d "$SSH_DIR" ]; then
    su - docker -c "cd /home/docker && tar xvzf /mnt/pub_keys.tar.gz"
fi

# Get OpenNebula VM context variables
source /tmp/one_env

# Setup the Docker Master or Worker
if [ "$ROLE_NAME" == "Master" ]; then
    docker swarm init --advertise-addr "$ETH0_IP"
    # Use local socket
    echo '{"debug":true,"hosts":["tcp://'`hostname -f`':2375","unix:///var/run/docker.sock"]}' > /etc/docker/daemon.json
    systemctl restart docker
    # Drain Master from workers list
    docker node update --availability drain `hostname -f`
fi
if [ "$ROLE_NAME" == "Worker" ]; then
    SWARM_TOKEN=$(su - docker -c "ssh -q -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking no' $MASTER_IP")
    docker swarm join --token "$SWARM_TOKEN" "$MASTER_IP":2377
fi

# Send READY message to ONE gate
curl -X "PUT" "$ONEGATE_ENDPOINT/vm" --header "X-ONEGATE-TOKEN: $(cat /mnt/token.txt)" --header "X-ONEGATE-VMID: $VMID" -d "READY = YES"

