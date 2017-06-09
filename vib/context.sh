#!/bin/bash

# VIB ONE context script for docker swarm setup
# Not licensed
# authors: alvaro.simongarcia@ugent.be, stijn.deweirdt@ugent.be

ONEDIR=/var/tmp/vibcontext
mkdir -p $ONEDIR
chmod 700 $ONEDIR
# AII style logging
exec >>$ONEDIR/log 2>&1

set -x

DOCKER_SSH_DIR="/home/docker/.ssh"
DOCKER_ID="1000"

GALAXY_ID="1001"

CEPH_MOUNT="/galaxy_base"
CEPH_NAME="vib"

IP_RANGE="10.145.0.0/16"

REMOTE_API_PORT=4000
DOCKER_PORT=2375

OKFN=$ONEDIR/ok
# 0=reboot
NOW=0

# buggy one-context 5.0.3?
FORCE_NO_CONTEXT_DEP=1

SWARM=legacy

function latest_kernel () {
    local path
    yum -y install http://elrepo.org/linux/kernel/el7/x86_64/RPMS/elrepo-release-7.0-2.el7.elrepo.noarch.rpm
    yum -y --enablerepo=elrepo-kernel install kernel-ml grubby
    # get latest vmlinuz image
    path=$(ls -lrt /boot/vmlinuz-*|tail -1)
    grubby --set-default=$path
    grubby --default-kernel
}

function add_docker_user () {
    # Docker user and group
    # can be executed multiple times
    if ! groups "docker" >/dev/null 2>&1; then
        groupadd docker -g "$DOCKER_ID"
    fi
    if ! id "docker" >/dev/null 2>&1; then
        useradd docker -u "$DOCKER_ID" -g docker
    fi
    # Include SSH keys
    if [ ! -d "$DOCKER_SSH_DIR" ]; then
        su - docker -c "cd /home/docker && tar xvzf /mnt/pub_keys.tar.gz"
    fi
}

function add_galaxy_user () {
    # Requires docker group
    add_docker_user

    # Galaxy user and group
    if ! groups "galaxy" >/dev/null 2>&1; then
        groupadd galaxy -g "$GALAXY_ID"
    fi
    if ! id "galaxy" >/dev/null 2>&1; then
        useradd galaxy -u "$GALAXY_ID" -G docker -g galaxy
    fi
}

function system_update () {
    # Update the system
    yum distro-sync -y
    yum install yum-utils curl -y
    #latest_kernel
}

function add_ceph () {
    # Update the system and install Ceph repos
    yum install https://download.ceph.com/rpm-jewel/el7/noarch/ceph-release-1-1.el7.noarch.rpm -y
    yum install ceph-common -y
}

function set_hostname () {
    # Set hostname
    yum install bind-utils -y
    hostnamectl set-hostname --static $(/sbin/ip -4 -o addr show to "$IP_RANGE" | /bin/sed "s#.*\(10\.[0-9]\+\.[0-9]\+\.[0-9]\+\)/[0-9].*#\1#" \
| /usr/bin/head -1 | xargs host | sed "s/.* //;s/\.$//")
}

function enable_unit () {
    local unit
    unit="$1"
    systemctl daemon-reload
    systemctl enable $unit
    if [ $NOW -eq 1 ]; then
        systemctl start $unit
    fi
}

function setup_ceph () {
    local unit
    add_ceph

    # mount Ceph
    if [ ! -d "$CEPH_MOUNT" ]; then
        mkdir -p "$CEPH_MOUNT"
    fi

    unit=ceph-vib.service
    sed "s#/CEPHMOUNT#$CEPH_MOUNT#g;s/CEPHNAME/$CEPH_NAME/g" /mnt/$unit > /etc/systemd/system/$unit

    if [ ! -z "$FORCE_NO_CONTEXT_DEP" ] || [ $NOW -eq 1 ]; then
        # for start during context only; not as standalone unit in eg galaxy VM
        sed -i 's/vmcontext.service//g' /etc/systemd/system/$unit
    fi

    enable_unit $unit
}

function add_docker () {
    local dockerdir
    add_docker_user

    # Install and enable Docker service
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum makecache fast
    yum install docker-ce -y

    # Enable Docker service
    enable_unit docker.service

    # prep etc dir
    dockerdir=/etc/docker
    if [ ! -d $dockerdir ]; then
        mkdir -p $dockerdir
        chmod 700 $dockerdir
    fi
}

function one_env () {
    # Get OpenNebula VM context variables
    source /tmp/one_env
}

function docker_config () {
    add_docker
    # Use local socket and VIB name; use overlay2
    echo '{"debug":true,"hosts":["tcp://'$(hostname -f)':'"$DOCKER_PORT"'","unix:///var/run/docker.sock"],"storage-driver":"overlay2","storage-opts":["overlay2.override_kernel_check=true"]}' > /etc/docker/daemon.json
    systemctl restart docker
}

function notify_onegate () {
    # Send READY message to ONE gate
    curl -X "PUT" "$ONEGATE_ENDPOINT/vm" --header "X-ONEGATE-TOKEN: $(cat /mnt/token.txt)" --header "X-ONEGATE-VMID: $VMID" -d "READY = YES"
}

function setup_swarmkit () {
    # Setup new-style swarm (aka swarmkit)
    docker_config

    docker swarm init --advertise-addr "$MASTER_IP"
    # Drain Master from workers list
    docker node update --availability drain $(hostname -f)
}

function join_swarmkit () {
    # Join new-style swarm (aka swarmkit)
    docker_config

    # The authorized keys only allows getting the swarm token
    SWARM_TOKEN=$(su - docker -c "ssh -q -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking no' $MASTER_IP")
    docker swarm join --token "$SWARM_TOKEN" "$MASTER_IP":2377
}

function get_legacy_swarm () {
    local mode version fn exe unit unitfn
    unit=swarm.service
    unitfn=/etc/systemd/system/$unit
    unitmode=${1:-join}

    # Download
    version=1.2.6
    fn=$ONEDIR/swarm
    exe=/usr/bin/swarm
    curl -L -o $fn.tgz https://github.com/docker/swarm/releases/download/v$version/swarm-$version-linux-x86_64.tgz

    # Unpack and install
    cd $ONEDIR
    tar xzf $fn.tgz
    mv $fn $exe
    chmod +x $exe
    cd -

    case $unitmode in
        manage)
            # create the swarm
            swarm create > /root/.swarmid
            cmd="manage -H $MASTER_IP:$REMOTE_API_PORT"
            ;;
        join)
            cmd="join --advertise=$(hostname -f):$DOCKER_PORT"
            ;;
        *)
            ;;
    esac

    # Setup unit
    if [ ! -z "$$cmd" ]; then
        cat > $unitfn <<EOF
[Install]
WantedBy=multi-user.target

[Service]
ExecStart=$exe $cmd etcd://$MASTER_IP:2379
Type=simple

[Unit]
After=network.target docker.service etcd.service vmcontext.service
Description=Docker (legacy) swarm
Requires=network.target etcd.service vmcontext.service

EOF

        if [ ! -z "$FORCE_NO_CONTEXT_DEP" ] || [ $NOW -eq 1 ]; then
            # for start during context only; not as standalone unit
            sed -i 's/vmcontext.service//g' $unitfn
        fi
        enable_unit $unit
    fi

}

function setup_ectd () {
    yum install etcd3 -y
    sed -i "s#ETCD_ADVERTISE_CLIENT_URLS=.*#ETCD_ADVERTISE_CLIENT_URLS='http://$MASTER_IP:2379'#" /etc/etcd/etcd.conf
    sed -i "s#ETCD_LISTEN_CLIENT_URLS=.*#ETCD_LISTEN_CLIENT_URLS='http://$MASTER_IP:2379'#" /etc/etcd/etcd.conf

    enable_unit etcd.service
}

function setup_legacy_swarm () {
    # No docker config required
    setup_etcd
    get_legacy_swarm manage
}

function join_legacy_swarm () {
    docker_config
    get_legacy_swarm join
}

function setup_master () {
    if [ "$SWARM" == "legacy" ]; then
        setup_legacy_swarm
    else
        setup_swarmkit
    fi
}

function setup_worker () {
    if [ "$SWARM" == "legacy" ]; then
        join_legacy_swarm
    else
        join_swarmkit
    fi
}

function set_ok () {
    date > $OKFN
}

if [ ! -f $OKFN ]; then
    add_galaxy_user
    system_update
    set_hostname
    setup_ceph

    one_env

    case ${ROLE_NAME:-NOROLE} in
        Master)
            MASTER_IP=$ETH0_IP
            setup_master
            ;;
        Worker)
            setup_worker
            ;;
        *)
            ;;
    esac

    set_ok

    if [ $NOW -ne 1 ]; then
        reboot
    fi
else
    notify_onegate
fi
