#!/usr/bin/env bash

set -e
set -o pipefail

# consts
MOUNTS_PATH=$AZ_BATCH_NODE_ROOT_DIR/mounts

# globals
azurefile=0
blobxferversion=latest
block=
cascadecontainer=0
encrypted=
hpnssh=0
gluster_on_compute=0
gpu=
networkopt=0
offer=
p2p=
p2penabled=0
prefix=
sku=
sc_args=
version=

# process command line options
while getopts "h?abde:fg:m:no:p:s:t:v:wx:" opt; do
    case "$opt" in
        h|\?)
            echo "shipyard_nodeprep.sh parameters"
            echo ""
            echo "-a mount azurefile shares"
            echo "-b block until resources loaded"
            echo "-d use docker container for cascade"
            echo "-e [thumbprint] encrypted credentials with cert"
            echo "-f set up glusterfs on compute"
            echo "-g [nv-series:driver file:nvidia docker pkg] gpu support"
            echo "-m [type:scid] mount storage cluster"
            echo "-n optimize network TCP settings"
            echo "-o [offer] VM offer"
            echo "-p [prefix] storage container prefix"
            echo "-s [sku] VM sku"
            echo "-t [enabled:non-p2p concurrent download:seed bias:compression] p2p sharing"
            echo "-v [version] batch-shipyard version"
            echo "-w install openssh-hpn"
            echo "-x [blobxfer version] blobxfer version"
            echo ""
            exit 1
            ;;
        a)
            azurefile=1
            ;;
        b)
            block=${SHIPYARD_CONTAINER_IMAGES_PRELOAD}
            ;;
        d)
            cascadecontainer=1
            ;;
        e)
            encrypted=${OPTARG,,}
            ;;
        f)
            gluster_on_compute=1
            ;;
        g)
            gpu=$OPTARG
            ;;
        m)
            IFS=',' read -ra sc_args <<< "${OPTARG,,}"
            ;;
        n)
            networkopt=1
            ;;
        o)
            offer=${OPTARG,,}
            ;;
        p)
            prefix="--prefix $OPTARG"
            ;;
        s)
            sku=${OPTARG,,}
            ;;
        t)
            p2p=${OPTARG,,}
            IFS=':' read -ra p2pflags <<< "$p2p"
            if [ ${p2pflags[0]} == "true" ]; then
                p2penabled=1
            else
                p2penabled=0
            fi
            ;;
        v)
            version=$OPTARG
            ;;
        w)
            hpnssh=1
            ;;
        x)
            blobxferversion=$OPTARG
            ;;
    esac
done
shift $((OPTIND-1))
[ "$1" = "--" ] && shift
# check args
if [ -z $offer ]; then
    echo "ERROR: vm offer not specified"
    exit 1
fi
if [ -z $sku ]; then
    echo "ERROR: vm sku not specified"
    exit 1
fi
if [ -z $version ]; then
    echo "ERROR: batch-shipyard version not specified"
    exit 1
fi

# try to get /etc/lsb-release
if [ -e /etc/lsb-release ]; then
    . /etc/lsb-release
else
    if [ -e /etc/os-release ]; then
        . /etc/os-release
        DISTRIB_ID=$ID
        DISTRIB_RELEASE=$VERSION_ID
    fi
fi

if [ -z ${DISTRIB_ID+x} ] || [ -z ${DISTRIB_RELEASE+x} ]; then
    echo "Unknown DISTRIB_ID or DISTRIB_RELEASE."
    exit 1
fi

# lowercase vars
DISTRIB_ID=${DISTRIB_ID,,}
DISTRIB_RELEASE=${DISTRIB_RELEASE,,}

check_for_buggy_ntfs_mount() {
    # Check to ensure sdb1 mount is not mounted as ntfs
    set +e
    mount | grep /dev/sdb1 | grep fuseblk
    rc=$?
    set -e
    if [ $rc -eq 0 ]; then
        echo "ERROR: /dev/sdb1 temp disk is mounted as fuseblk/ntfs"
        exit 1
    fi
}

check_for_nvidia_card() {
    set +e
    out=$(lspci)
    echo "$out" | grep -i nvidia > /dev/null
    rc=$?
    set -e
    echo "$out"
    if [ $rc -ne 0 ]; then
        echo "ERROR: No Nvidia card(s) detected!"
        exit 1
    fi
}

install_nvidia_software() {
    offer=$1
    shift
    sku=$1
    shift
    # check for nvidia card
    check_for_nvidia_card
    # split arg into two
    IFS=':' read -ra GPUARGS <<< "$gpu"
    nvdriver=${GPUARGS[1]}
    nvdocker=${GPUARGS[2]}
    # remove nouveau
    set +e
    rmmod nouveau
    set -e
    # purge nouveau off system
    if [ $offer == "ubuntuserver" ]; then
        apt-get --purge remove xserver-xorg-video-nouveau xserver-xorg-video-nouveau-hwe-16.04
    elif [[ $offer == centos* ]]; then
        yum erase -y xorg-x11-drv-nouveau
    else
        echo "ERROR: unsupported distribution for nvidia/GPU, offer: $offer"
        exit 1
    fi
    # blacklist nouveau from being loaded if rebooted
cat > /etc/modprobe.d/blacklist-nouveau.conf << EOF
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF
    # get development essentials for nvidia driver
    if [ $offer == "ubuntuserver" ]; then
        install_packages $offer build-essential
    elif [[ $offer == centos* ]]; then
        kernel_devel_package="kernel-devel-$(uname -r)"
        if [[ $offer == "centos-hpc" ]] || [[ $sku == "7.4" ]]; then
            install_packages $offer $kernel_devel_package
        elif [ $sku == "7.3" ]; then
            curl -fSsLO http://vault.centos.org/7.3.1611/updates/x86_64/Packages/$kernel_devel_package.rpm
            rpm -Uvh $kernel_devel_package.rpm
        else
            echo "ERROR: CentOS $sku not supported for GPU"
            exit 1
        fi
        install_packages $offer gcc binutils make
    fi
    # get additional dependency if NV-series VMs
    if [ ${GPUARGS[0]} == "True" ]; then
        if [ $offer == "ubuntuserver" ]; then
            install_packages $offer xserver-xorg-dev
        elif [[ $offer == centos* ]]; then
            install_packages $offer xorg-x11-server-devel
        fi
    fi
    # install driver
    ./$nvdriver -s
    # add flag to config for GRID driver
    if [ ${GPUARGS[0]} == "True" ]; then
        cp /etc/nvidia/gridd.conf.template /etc/nvidia/gridd.conf
        echo "IgnoreSP=TRUE" >> /etc/nvidia/gridd.conf
    fi
    # enable persistence daemon (and mode)
    nvidia-persistenced --user root
    nvidia-smi -pm 1
    # install nvidia-docker
    install_local_packages $offer $nvdocker
    # enable and start nvidia docker service
    systemctl enable nvidia-docker.service
    systemctl start nvidia-docker.service
    systemctl status nvidia-docker.service
    # get driver version
    nvdriverver=`cat /proc/driver/nvidia/version | grep "Kernel Module" | cut -d ' ' -f 9`
    echo nvidia driver version $nvdriverver detected
    # create the docker volume now to avoid volume driver conflicts for
    # tasks. run this in a loop as it can fail if triggered too quickly
    # after start
    NV_START=$(date -u +"%s")
    set +e
    while :
    do
        echo "INFO: Attempting to create nvidia-docker volume with version $nvdriverver"
        docker volume create -d nvidia-docker --name nvidia_driver_$nvdriverver
        if [ $? -eq 0 ]; then
            docker volume inspect nvidia_driver_$nvdriverver
            if [ $? -eq 0 ]; then
                docker volume list
                break
            fi
        else
            NV_NOW=$(date -u +"%s")
            NV_DIFF=$((($NV_NOW-$NV_START)/60))
            # fail after 5 minutes of attempts
            if [ $NV_DIFF -ge 5 ]; then
                echo "ERROR: could not create nvidia-docker volume"
                exit 1
            fi
            sleep 1
        fi
    done
    set -e
}

mount_azurefile_share() {
    chmod +x azurefile-mount.sh
    ./azurefile-mount.sh
    chmod 700 azurefile-mount.sh
    chown root:root azurefile-mount.sh
}

refresh_package_index() {
    offer=$1
    set +e
    retries=120
    while [ $retries -gt 0 ]; do
        if [[ $offer == "ubuntuserver" ]] || [[ $offer == "debian" ]]; then
            apt-get update
        elif [[ $offer == centos* ]] || [[ $offer == "rhel" ]] || [[ $offer == "oracle-linux" ]]; then
            yum makecache -y fast
        elif [[ $offer == opensuse* ]] || [[ $offer == sles* ]]; then
            zypper -n --gpg-auto-import-keys ref
        fi
        if [ $? -eq 0 ]; then
            break
        fi
        let retries=retries-1
        if [ $retries -eq 0 ]; then
            echo "ERROR: Could not update package index"
            exit 1
        fi
        sleep 1
    done
    set -e
}

install_packages() {
    offer=$1
    shift
    set +e
    retries=120
    while [ $retries -gt 0 ]; do
        if [[ $offer == "ubuntuserver" ]] || [[ $offer == "debian" ]]; then
            apt-get install -y -q -o Dpkg::Options::="--force-confnew" --no-install-recommends $*
        elif [[ $offer == centos* ]] || [[ $offer == "rhel" ]] || [[ $offer == "oracle-linux" ]]; then
            yum install -y $*
        elif [[ $offer == opensuse* ]] || [[ $offer == sles* ]]; then
            zypper -n in $*
        fi
        if [ $? -eq 0 ]; then
            break
        fi
        let retries=retries-1
        if [ $retries -eq 0 ]; then
            echo "ERROR: Could not install packages: $*"
            exit 1
        fi
        sleep 1
    done
    set -e
}

install_local_packages() {
    offer=$1
    shift
    set +e
    retries=120
    while [ $retries -gt 0 ]; do
        if [[ $offer == "ubuntuserver" ]] || [[ $offer == "debian" ]]; then
            dpkg -i $*
        else
            rpm -Uvh --nodeps $*
        fi
        if [ $? -eq 0 ]; then
            break
        fi
        let retries=retries-1
        if [ $retries -eq 0 ]; then
            echo "ERROR: Could not install local packages: $*"
            exit 1
        fi
        sleep 1
    done
    set -e
}

docker_pull_image() {
    image=$1
    set +e
    retries=60
    while [ $retries -gt 0 ]; do
        pull_out=$(docker pull $image 2>&1)
        rc=$?
        if [ $rc -eq 0 ]; then
            echo "$pull_out"
            break
        fi
        # non-zero exit code: check if pull output has toomanyrequests,
        # connection resets, or image config error
        if [[ ! -z "$(grep 'toomanyrequests' <<<$pull_out)" ]] || [[ ! -z "$(grep 'connection reset by peer' <<<$pull_out)" ]] || [[ ! -z "$(grep 'error pulling image configuration' <<<$pull_out)" ]]; then
            echo "WARNING: will retry: $pull_out"
        else
            echo "ERROR: $pull_out"
            exit $rc
        fi
        let retries=retries-1
        if [ $retries -le 0 ]; then
            echo "ERROR: Could not pull docker image: $image"
            exit $rc
        fi
        sleep $[($RANDOM % 5) + 1]s
    done
    set -e
}

singularity_basedir=
singularity_setup() {
    offer=$1
    shift
    sku=$1
    shift
    if [ $offer == "ubuntu" ]; then
        if [[ $sku != 16.04* ]]; then
            echo "Singularity not supported on $offer $sku"
        fi
        singularity_basedir=/mnt/singularity
    elif [[ $offer == "centos" ]] || [[ $offer == "rhel" ]]; then
        if [[ $sku != 7* ]]; then
            echo "Singularity not supported on $offer $sku"
            return
        fi
        singularity_basedir=/mnt/resource/singularity
        offer=centos
        sku=7
    else
        echo "Singularity not supported on $offer $sku"
        return
    fi
    # fetch docker image for singularity bits
    di=alfpark/singularity:2.4-${offer}-${sku}
    docker_pull_image $di
    mkdir -p /opt/singularity
    docker run --rm -v /opt/singularity:/opt/singularity $di \
        /bin/sh -c 'cp -r /singularity/* /opt/singularity'
    # symlink for global exec
    ln -sf /opt/singularity/bin/singularity /usr/bin/singularity
    # fix perms
    chown root.root /opt/singularity/libexec/singularity/bin/*
    chmod 4755 /opt/singularity/libexec/singularity/bin/*-suid
    # prep singularity root/container dir
    mkdir -p $singularity_basedir/mnt/container
    mkdir -p $singularity_basedir/mnt/final
    mkdir -p $singularity_basedir/mnt/overlay
    mkdir -p $singularity_basedir/mnt/session
    chmod 755 $singularity_basedir
    chmod 755 $singularity_basedir/mnt
    chmod 755 $singularity_basedir/mnt/container
    chmod 755 $singularity_basedir/mnt/final
    chmod 755 $singularity_basedir/mnt/overlay
    chmod 755 $singularity_basedir/mnt/session
    # create singularity tmp/cache paths
    mkdir -p $singularity_basedir/tmp
    mkdir -p $singularity_basedir/cache/docker
    mkdir -p $singularity_basedir/cache/metadata
    chmod 775 $singularity_basedir/tmp
    chmod 775 $singularity_basedir/cache
    chmod 775 $singularity_basedir/cache/docker
    chmod 775 $singularity_basedir/cache/metadata
    # set proper ownership
    chown -R _azbatch:_azbatchgrp $singularity_basedir/tmp
    chown -R _azbatch:_azbatchgrp $singularity_basedir/cache
    # selftest
    singularity selftest
    # remove docker image
    docker rmi $di
}

echo "Configuration [Non-Native Docker]:"
echo "----------------------------------"
echo "Batch Shipyard version: $version"
echo "Blobxfer version: $blobxferversion"
echo "Offer/Sku: $offer $sku"
echo "Network optimization: $networkopt"
echo "Encrypted: $encrypted"
echo "Cascade on container: $cascadecontainer"
echo "Storage cluster mount: ${sc_args[*]}"
echo "GPU: $gpu"
echo "P2P: $p2penabled"
echo "Azure File: $azurefile"
echo "GlusterFS on compute: $gluster_on_compute"
echo "HPN-SSH: $hpnssh"
echo "Block on images: $block"
echo ""

# check sdb1 mount
check_for_buggy_ntfs_mount

# set python env vars
LC_ALL=en_US.UTF-8
PYTHONASYNCIODEBUG=1

# store node prep start
if command -v python3 > /dev/null 2>&1; then
    npstart=`python3 -c 'import datetime;print(datetime.datetime.utcnow().timestamp())'`
else
    npstart=`python -c 'import datetime;import time;print(time.mktime(datetime.datetime.utcnow().timetuple()))'`
fi

# create shared mount points
mkdir -p $MOUNTS_PATH

# mount azure file shares (this must be done every boot)
if [ $azurefile -eq 1 ]; then
    mount_azurefile_share $offer $sku
fi

# set node prep status files
nodeprepfinished=$AZ_BATCH_NODE_SHARED_DIR/.node_prep_finished
cascadefailed=$AZ_BATCH_NODE_SHARED_DIR/.cascade_failed

# get ip address of eth0
ipaddress=`ip addr list eth0 | grep "inet " | cut -d' ' -f6 | cut -d/ -f1`

# decrypt encrypted creds
if [ ! -z $encrypted ]; then
    # convert pfx to pem
    pfxfile=$AZ_BATCH_CERTIFICATES_DIR/sha1-$encrypted.pfx
    privatekey=$AZ_BATCH_CERTIFICATES_DIR/key.pem
    openssl pkcs12 -in $pfxfile -out $privatekey -nodes -password file:$pfxfile.pw
    # remove pfx-related files
    rm -f $pfxfile $pfxfile.pw
    # decrypt creds
    SHIPYARD_STORAGE_ENV=`echo $SHIPYARD_STORAGE_ENV | base64 -d | openssl rsautl -decrypt -inkey $privatekey`
    if [ ! -z ${DOCKER_LOGIN_USERNAME+x} ]; then
        DOCKER_LOGIN_PASSWORD=`echo $DOCKER_LOGIN_PASSWORD | base64 -d | openssl rsautl -decrypt -inkey $privatekey`
    fi
fi

# set iptables rules
if [ $p2penabled -eq 1 ]; then
    # disable DHT connection tracking
    iptables -t raw -I PREROUTING -p udp --dport 6881 -j CT --notrack
    iptables -t raw -I OUTPUT -p udp --sport 6881 -j CT --notrack
fi

# check if we're coming up from a reboot
if [ -f $cascadefailed ]; then
    echo "ERROR: $cascadefailed file exists, assuming cascade failure during node prep"
    exit 1
elif [ -f $nodeprepfinished ]; then
    echo "INFO: $nodeprepfinished file exists, assuming successful completion of node prep"
    exit 0
fi

# one-time setup
if [ ! -f $nodeprepfinished ]; then
    # set up hpn-ssh
    if [ $hpnssh -eq 1 ]; then
        ./shipyard_hpnssh.sh $offer $sku
    fi
    # optimize network TCP settings
    if [ $networkopt -eq 1 ]; then
        sysctlfile=/etc/sysctl.d/60-azure-batch-shipyard.conf
        if [ ! -e $sysctlfile ] || [ ! -s $sysctlfile ]; then
cat > $sysctlfile << EOF
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=30000
net.ipv4.tcp_max_syn_backlog=80960
net.ipv4.tcp_mem=16777216 16777216 16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_abort_on_overflow=1
net.ipv4.route.flush=1
EOF
        fi
    fi
fi

# install docker host engine
if [ $offer == "ubuntuserver" ] || [ $offer == "debian" ]; then
    DEBIAN_FRONTEND=noninteractive
    # name will be appended to dockerversion
    dockerversion=17.09.0~ce-0~
    name=
    if [[ $sku == 14.04.* ]]; then
        name=ubuntu-trusty
        srvstart="initctl start docker"
        srvstop="initctl stop docker"
        srvstatus="initctl status docker"
        gfsstart="initctl start glusterfs-server"
        gpgkey=https://download.docker.com/linux/ubuntu/gpg
        repo=https://download.docker.com/linux/ubuntu
        dockerversion=${dockerversion}ubuntu
    elif [[ $sku == 16.04* ]]; then
        name=ubuntu-xenial
        srvstart="systemctl start docker.service"
        srvstop="systemctl stop docker.service"
        srvenable="systemctl enable docker.service"
        srvstatus="systemctl status docker.service"
        gfsstart="systemctl start glusterfs-server"
        gfsenable="systemctl enable glusterfs-server"
        gpgkey=https://download.docker.com/linux/ubuntu/gpg
        repo=https://download.docker.com/linux/ubuntu
        dockerversion=${dockerversion}ubuntu
    elif [[ $sku == "8" ]]; then
        name=debian-jessie
        srvstart="systemctl start docker.service"
        srvstop="systemctl stop docker.service"
        srvenable="systemctl enable docker.service"
        srvstatus="systemctl status docker.service"
        gfsstart="systemctl start glusterfs-server"
        gfsenable="systemctl enable glusterfs-server"
        gpgkey=https://download.docker.com/linux/debian/gpg
        repo=https://download.docker.com/linux/debian
        dockerversion=${dockerversion}debian
    else
        echo "ERROR: unsupported sku: $sku for offer: $offer"
        exit 1
    fi
    if [ ! -z $gpu ] && [ $name != "ubuntu-xenial" ]; then
        echo "ERROR: gpu unsupported on this sku: $sku for offer $offer"
        exit 1
    fi
    # reload network settings
    if [ $networkopt -eq 1 ]; then
        if [ $name == "ubuntu-trusty" ]; then
            service procps start
        else
            service procps reload
        fi
    fi
    # refresh package index
    refresh_package_index $offer
    # install required software first
    install_packages $offer apt-transport-https ca-certificates curl software-properties-common
    if [ $name == "ubuntu-trusty" ]; then
        install_packages $offer linux-image-extra-$(uname -r) linux-image-extra-virtual
    fi
    # add gpgkey for repo
    set +e
    retries=100
    while [ $retries -gt 0 ]; do
        curl -fsSL $gpgkey | apt-key add -
        if [ $? -eq 0 ]; then
            break
        fi
        let retries=retries-1
        if [ $retries -eq 0 ]; then
            echo "ERROR: Could not add key for docker repo"
            exit 1
        fi
        sleep 1
    done
    set -e
    # add repo
    add-apt-repository "deb [arch=amd64] $repo $(lsb_release -cs) stable"
    # refresh index
    refresh_package_index $offer
    # ensure docker opts service modifications are idempotent
    set +e
    grep '^DOCKER_OPTS=' /etc/default/docker
    if [ $? -ne 0 ]; then
        # install docker engine
        install_packages $offer docker-ce=$dockerversion
        set -e
        $srvstop
        set +e
        rm -f /var/lib/docker/network/files/local-kv.db
        if [ $name == "debian-jessie" ]; then
            mkdir -p /mnt/resource/docker-tmp
            sed -i -e 's,.*export DOCKER_TMPDIR=.*,export DOCKER_TMPDIR="/mnt/resource/docker-tmp",g' /etc/default/docker || echo export DOCKER_TMPDIR=\"/mnt/resource/docker-tmp\" >> /etc/default/docker
            sed -i -e '/^DOCKER_OPTS=.*/,${s||DOCKER_OPTS=\"-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -g /mnt/resource/docker\"|;b};$q1' /etc/default/docker || echo DOCKER_OPTS=\"-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -g /mnt/resource/docker\" >> /etc/default/docker
        else
            mkdir -p /mnt/docker-tmp
            sed -i -e 's,.*export DOCKER_TMPDIR=.*,export DOCKER_TMPDIR="/mnt/docker-tmp",g' /etc/default/docker || echo export DOCKER_TMPDIR=\"/mnt/docker-tmp\" >> /etc/default/docker
            sed -i -e '/^DOCKER_OPTS=.*/,${s||DOCKER_OPTS=\"-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -g /mnt/docker\"|;b};$q1' /etc/default/docker || echo DOCKER_OPTS=\"-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -g /mnt/docker\" >> /etc/default/docker
        fi
        if [[ $name == "ubuntu-xenial" ]] || [[ $name == "debian-jessie" ]]; then
            sed -i '/^\[Service\]/a EnvironmentFile=/etc/default/docker' /lib/systemd/system/docker.service
            sed -i '/^ExecStart=/ s/$/ $DOCKER_OPTS/' /lib/systemd/system/docker.service
            set -e
            systemctl daemon-reload
            $srvenable
            set +e
        fi
        set -e
        $srvstart
        set +e
    fi
    set -e
    # ensure docker daemon is running
    $srvstatus
    # install gpu related items
    if [ ! -z $gpu ] && [ ! -f $nodeprepfinished ]; then
        install_nvidia_software $offer $sku
    fi
    # set up glusterfs
    if [ $gluster_on_compute -eq 1 ] && [ ! -f $nodeprepfinished ]; then
        install_packages $offer glusterfs-server
        if [[ ! -z $gfsenable ]]; then
            $gfsenable
        fi
        $gfsstart
        # create brick directory
        mkdir -p /mnt/gluster
    fi
    # install dependencies for storage cluster mount
    if [ ! -z $sc_args ]; then
        for sc_arg in ${sc_args[@]}; do
            IFS=':' read -ra sc <<< "$sc_arg"
            server_type=${sc[0]}
            if [ $server_type == "nfs" ]; then
                install_packages $offer nfs-common nfs4-acl-tools
            elif [ $server_type == "glusterfs" ]; then
                install_packages $offer glusterfs-client acl
            else
                echo "ERROR: Unknown file server type ${sc[0]} for ${sc[1]}"
                exit 1
            fi
        done
    fi
    # install dependencies if not using cascade container
    if [ $cascadecontainer -eq 0 ]; then
        # install azure storage python dependency
        install_packages $offer build-essential libssl-dev libffi-dev libpython3-dev python3-dev python3-pip
        pip3 install --no-cache-dir --upgrade pip
        pip3 install --no-cache-dir --upgrade wheel setuptools
        pip3 install --no-cache-dir azure-cosmosdb-table==0.37.1 azure-storage-blob==0.37.1
        # install cascade dependencies
        if [ $p2penabled -eq 1 ]; then
            install_packages $offer python3-libtorrent pigz
        fi
    fi
elif [[ $offer == centos* ]] || [[ $offer == "rhel" ]] || [[ $offer == "oracle-linux" ]]; then
    # ensure container only support
    if [ $cascadecontainer -eq 0 ]; then
        echo "ERROR: only supported through shipyard container"
        exit 1
    fi
    # gpu is not supported on these offers
    if [[ ! -z $gpu ]] && [[ $offer != centos* ]]; then
        echo "ERROR: gpu unsupported on this sku: $sku for offer $offer"
        exit 1
    fi
    if [[ $sku == 7.* ]]; then
        dockerversion=17.09.0.ce-1.el7.centos
        if [[ $offer == "oracle-linux" ]]; then
            srvenable="systemctl enable docker.service"
            srvstart="systemctl start docker.service"
            srvstatus="systemctl status docker.service"
            gfsenable="systemctl enable glusterd"
            rpcbindenable="systemctl enable rpcbind"
            # TODO, in order to support docker > 1.9, need to upgrade to UEKR4
            echo "ERROR: oracle linux is not supported at this time"
            exit 1
        else
            srvenable="chkconfig docker on"
            srvstart="systemctl start docker.service"
            srvstatus="systemctl status docker.service"
            gfsenable="chkconfig glusterd on"
            rpcbindenable="chkconfig rpcbind on"
        fi
    else
        echo "ERROR: unsupported sku: $sku for offer: $offer"
        exit 1
    fi
    # reload network settings
    if [ $networkopt -eq 1 ]; then
        sysctl -p
    fi
    # add docker repo to yum
    install_packages $offer yum-utils device-mapper-persistent-data lvm2
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    refresh_package_index $offer
    install_packages $offer docker-ce-$dockerversion
    # modify docker opts
    mkdir -p /mnt/resource/docker-tmp
    sed -i -e 's,.*export DOCKER_TMPDIR=.*,export DOCKER_TMPDIR="/mnt/resource/docker-tmp",g' /etc/default/docker || echo export DOCKER_TMPDIR=\"/mnt/resource/docker-tmp\" >> /etc/default/docker
    sed -i -e '/^DOCKER_OPTS=.*/,${s||DOCKER_OPTS=\"-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -g /mnt/resource/docker\"|;b};$q1' /etc/default/docker || echo DOCKER_OPTS=\"-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -g /mnt/resource/docker\" >> /etc/default/docker
    sed -i '/^\[Service\]/a EnvironmentFile=/etc/default/docker' /lib/systemd/system/docker.service
    sed -i '/^ExecStart=/ s/$/ $DOCKER_OPTS/' /lib/systemd/system/docker.service
    systemctl daemon-reload
    # start docker service and enable docker daemon on boot
    $srvenable
    $srvstart
    $srvstatus
    # install gpu related items
    if [ ! -z $gpu ] && [ ! -f $nodeprepfinished ]; then
        install_nvidia_software $offer $sku
    fi
    # set up glusterfs
    if [ $gluster_on_compute -eq 1 ] && [ ! -f $nodeprepfinished ]; then
        install_packages $offer epel-release centos-release-gluster38
        sed -i -e "s/enabled=1/enabled=0/g" /etc/yum.repos.d/CentOS-Gluster-3.8.repo
        install_packages $offer --enablerepo=centos-gluster38,epel glusterfs-server
        systemctl daemon-reload
        $gfsenable
        systemctl start glusterd
        # create brick directory
        mkdir -p /mnt/resource/gluster
    fi
    # install dependencies for storage cluster mount
    if [ ! -z $sc_args ]; then
        for sc_arg in ${sc_args[@]}; do
            IFS=':' read -ra sc <<< "$sc_arg"
            server_type=${sc[0]}
            if [ $server_type == "nfs" ]; then
                install_packages $offer nfs-utils nfs4-acl-tools
                systemctl daemon-reload
                $rpcbindenable
                systemctl start rpcbind
            elif [ $server_type == "glusterfs" ]; then
                install_packages $offer epel-release centos-release-gluster38
                sed -i -e "s/enabled=1/enabled=0/g" /etc/yum.repos.d/CentOS-Gluster-3.8.repo
                install_packages $offer --enablerepo=centos-gluster38,epel glusterfs-server acl
            else
                echo "ERROR: Unknown file server type ${sc[0]} for ${sc[1]}"
                exit 1
            fi
        done
    fi
elif [[ $offer == opensuse* ]] || [[ $offer == sles* ]]; then
    # ensure container only support
    if [ $cascadecontainer -eq 0 ]; then
        echo "ERROR: only supported through shipyard container"
        exit 1
    fi
    # gpu is not supported on these offers
    if [ ! -z $gpu ]; then
        echo "ERROR: gpu unsupported on this sku: $sku for offer $offer"
        exit 1
    fi
    # reload network settings
    if [ $networkopt -eq 1 ]; then
        sysctl -p
    fi
    if [ ! -f $nodeprepfinished ]; then
        # add Virtualization:containers repo for recent docker builds
        repodir=
        if [[ $offer == opensuse* ]]; then
            dockerversion=1.12.6-30.2
            if [[ $sku == "42.1" ]]; then
                repodir=openSUSE_Leap_42.1
            elif [[ $sku == "42.2" ]]; then
                repodir=openSUSE_Leap_42.2
            fi
            # add container repo for zypper
            zypper addrepo http://download.opensuse.org/repositories/Virtualization:containers/$repodir/Virtualization:containers.repo
        elif [[ $offer == sles* ]]; then
            dockerversion=1.12.6-90.1
            if [[ $sku == "12-sp1" ]]; then
                repodir=SLE_12_SP1
            elif [[ $sku == "12-sp2" ]]; then
                repodir=SLE_12_SP2
            fi
            # enable container module
            SUSEConnect -p sle-module-containers/12/x86_64 -r ''
        fi
        if [ -z $repodir ]; then
            echo "ERROR: unsupported sku: $sku for offer: $offer"
            exit 1
        fi
        # update index
        refresh_package_index $offer
        # install docker engine
        install_packages $offer docker-$dockerversion
        # modify docker opts, docker opts in /etc/sysconfig/docker
        mkdir -p /mnt/resource/docker-tmp
        sed -i -e 's,.*export DOCKER_TMPDIR=.*,export DOCKER_TMPDIR="/mnt/resource/docker-tmp",g' /etc/default/docker || echo export DOCKER_TMPDIR=\"/mnt/resource/docker-tmp\" >> /etc/default/docker
        sed -i -e '/^DOCKER_OPTS=.*/,${s||DOCKER_OPTS=\"-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -g /mnt/resource/docker\"|;b};$q1' /etc/sysconfig/docker || echo DOCKER_OPTS=\"-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -g /mnt/resource/docker\" >> /etc/sysconfig/docker
        systemctl daemon-reload
        # start docker service and enable docker daemon on boot
        systemctl enable docker
        systemctl start docker
        systemctl status docker
        # set up glusterfs
        if [ $gluster_on_compute -eq 1 ]; then
            zypper addrepo http://download.opensuse.org/repositories/filesystems/$repodir/filesystems.repo
            zypper -n --gpg-auto-import-keys ref
            install_packages $offer glusterfs
            systemctl daemon-reload
            systemctl enable glusterd
            systemctl start glusterd
            # create brick directory
            mkdir -p /mnt/resource/gluster
        fi
        # install dependencies for storage cluster mount
        if [ ! -z $sc_args ]; then
            for sc_arg in ${sc_args[@]}; do
                IFS=':' read -ra sc <<< "$sc_arg"
                server_type=${sc[0]}
                if [ $server_type == "nfs" ]; then
                    install_packages $offer nfs-client nfs4-acl-tools
                    systemctl daemon-reload
                    systemctl enable rpcbind
                    systemctl start rpcbind
                elif [ $server_type == "glusterfs" ]; then
                    zypper addrepo http://download.opensuse.org/repositories/filesystems/$repodir/filesystems.repo
                    zypper -n --gpg-auto-import-keys ref
                    install_packages $offer glusterfs acl
                else
                    echo "ERROR: Unknown file server type ${sc[0]} for ${sc[1]}"
                    exit 1
                fi
            done
        fi
        # if hpc sku, set up intel mpi
        if [[ $offer == sles-hpc* ]]; then
            if [ $sku != "12-sp1" ]; then
                echo "ERROR: unsupported sku for intel mpi setup on SLES"
                exit 1
            fi
            install_packages $offer lsb
            install_local_packages $offer /opt/intelMPI/intel_mpi_packages/*.rpm
            mkdir -p /opt/intel/compilers_and_libraries/linux
            ln -sf /opt/intel/impi/5.0.3.048 /opt/intel/compilers_and_libraries/linux/mpi
        fi
    fi
else
    echo "ERROR: unsupported offer: $offer (sku: $sku)"
    exit 1
fi

# set up singularity
singularity_setup $DISTRIB_ID $DISTRIB_RELEASE

# retrieve docker images related to data movement
docker_pull_image alfpark/blobxfer:$blobxferversion
docker_pull_image alfpark/batch-shipyard:${version}-cargo

# login to registry servers (do not specify -e as creds have been decrypted)
./registry_login.sh
if [ -f singularity-registry-login ]; then
    . singularity-registry-login
fi

# mount any storage clusters
if [ ! -z $sc_args ]; then
    # eval and split fstab var to expand vars (this is ok since it is set by shipyard)
    fstab_mounts=$(eval echo "$SHIPYARD_STORAGE_CLUSTER_FSTAB")
    IFS='#' read -ra fstabs <<< "$fstab_mounts"
    i=0
    for sc_arg in ${sc_args[@]}; do
        IFS=':' read -ra sc <<< "$sc_arg"
        mountpoint=$MOUNTS_PATH/${sc[1]}
        echo "INFO: Creating host directory for storage cluster $sc_arg at $mountpoint"
        mkdir -p $mountpoint
        chmod 777 $mountpoint
        echo "INFO: Adding $mountpoint to fstab"
        # eval fstab var to expand vars (this is ok since it is set by shipyard)
        fstab_entry="${fstabs[$i]}"
        echo $fstab_entry >> /etc/fstab
        tail -n1 /etc/fstab
        echo "INFO: Mounting $mountpoint"
        START=$(date -u +"%s")
        set +e
        while :
        do
            mount $mountpoint
            if [ $? -eq 0 ]; then
                break
            else
                NOW=$(date -u +"%s")
                DIFF=$((($NOW-$START)/60))
                # fail after 5 minutes of attempts
                if [ $DIFF -ge 5 ]; then
                    echo "ERROR: Could not mount storage cluster $sc_arg on: $mountpoint"
                    exit 1
                fi
                sleep 1
            fi
        done
        set -e
        echo "INFO: $mountpoint mounted."
        i=$(($i + 1))
    done
fi

# touch node prep finished file to preserve idempotency
touch $nodeprepfinished
# touch cascade failed file, this will be removed once cascade is successful
touch $cascadefailed

# execute cascade
set +e
cascadepid=
envfile=
if [ $cascadecontainer -eq 1 ]; then
    detached=
    if [ $p2penabled -eq 1 ]; then
        detached="-d"
    else
        detached="--rm"
    fi
    # store docker cascade start
    if command -v python3 > /dev/null 2>&1; then
        drpstart=`python3 -c 'import datetime;print(datetime.datetime.utcnow().timestamp())'`
    else
        drpstart=`python -c 'import datetime;import time;print(time.mktime(datetime.datetime.utcnow().timetuple()))'`
    fi
    # create env file
    envfile=.cascade_envfile
cat > $envfile << EOF
prefix=$prefix
ipaddress=$ipaddress
offer=$offer
sku=$sku
npstart=$npstart
drpstart=$drpstart
p2p=$p2p
`env | grep SHIPYARD_`
`env | grep AZ_BATCH_`
`env | grep DOCKER_LOGIN_`
`env | grep SINGULARITY_`
EOF
    chmod 600 $envfile
    # pull image
    docker_pull_image alfpark/batch-shipyard:${version}-cascade
    # set singularity options
    singularity_binds=
    if [ ! -z $singularity_basedir ]; then
        singularity_binds="\
            -v $singularity_basedir:$singularity_basedir \
            -v $singularity_basedir/mnt:/var/lib/singularity/mnt"
    fi
    # launch container
    docker run $detached --net=host --env-file $envfile \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        $singularity_binds \
        -v $AZ_BATCH_NODE_ROOT_DIR:$AZ_BATCH_NODE_ROOT_DIR \
        -w $AZ_BATCH_TASK_WORKING_DIR \
        -p 6881-6891:6881-6891 -p 6881-6891:6881-6891/udp \
        alfpark/batch-shipyard:${version}-cascade &
    cascadepid=$!
else
    # add timings
    if [ ! -z ${SHIPYARD_TIMING+x} ]; then
        # backfill node prep start
        ./perf.py nodeprep start $prefix --ts $npstart --message "offer=$offer,sku=$sku"
        # mark node prep finished
        ./perf.py nodeprep end $prefix
        # mark start cascade
        ./perf.py cascade start $prefix
    fi
    ./cascade.py $p2p --ipaddress $ipaddress $prefix &
    cascadepid=$!
fi

# if not in p2p mode, then wait for cascade exit
if [ $p2penabled -eq 0 ]; then
    wait $cascadepid
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "ERROR: cascade exited with non-zero exit code: $rc"
        rm -f $nodeprepfinished
        exit $rc
    fi
fi
set -e

# remove cascade failed file
rm -f $cascadefailed

# block for images if necessary
$AZ_BATCH_TASK_WORKING_DIR/wait_for_images.sh $block

# clean up cascade env file if block
if [ ! -z $block ]; then
    if [ $cascadecontainer -eq 1 ]; then
        rm -f $envfile
    fi
fi
