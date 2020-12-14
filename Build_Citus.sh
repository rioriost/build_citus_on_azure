#!/bin/bash

# Set your account & region you prefer
readonly AZURE_ACCT="rifujita"
readonly RES_LOC="japanwest"

# Resource Group
readonly PRJ_NAME="citus"
readonly RES_GRP="${AZURE_ACCT}-${PRJ_NAME}-rg"

# base OS
readonly OS_SKU="OpenLogic:CentOS:7_9-gen2:7.9.2020111901"

# Coordinator Sizing
readonly COORDINATOR_SIZE="Standard_D32s_v3"
readonly COORDINATOR_OS_DISK_SIZE="256"
readonly COORDINATOR_DATA_DISK_SIZE="2048"

# Worker Sizing
readonly WORKER_COUNT="3"
readonly WORKER_SIZE="Standard_D16s_v3"
readonly WORKER_OS_DISK_SIZE="256"
readonly WORKER_DATA_DISK_SIZE="2048"

# Networking
readonly VNET_NAME="${AZURE_ACCT}-${PRJ_NAME}-vnet"
readonly VNET_PREFIX="192.168.0.0/16"
readonly SUBNET_NAME="${AZURE_ACCT}-${PRJ_NAME}-subnet"
readonly SUBNET_PREFIX="192.168.1.0/24"
readonly NSG_NAME="${AZURE_ACCT}-${PRJ_NAME}-NSG"

# Prefixes for Citus nodes
# None of nodes require its own public IP for your production environment
readonly NODE_NAME="${AZURE_ACCT}-${PRJ_NAME}"
readonly PUBLIC_IP_NAME="${AZURE_ACCT}-${PRJ_NAME}-PubIP"
readonly NIC_NAME="${AZURE_ACCT}-${PRJ_NAME}-Nic"
readonly PG_ADMIN_USER="citus"
readonly PG_ADMIN_PASS=$(openssl rand -base64 16)

# 1. Create resource group
create_group () {
    # Checking if Resource Group exists
    echo -e "Creating Resource Group..."
    local st=$(date '+%s')
    local res=$(az group show -g ${RES_GRP} -o tsv --query "properties.provisioningState" 2>&1 | grep -o 'could not be found')
    if [ "${res}" != "could not be found" ]; then
        echo "Resource Group, ${RES_GRP} has already existed."
        exit
    fi

    # Create Resource Group
    res=$(az group create -l ${RES_LOC} -g ${RES_GRP} -o tsv --query "properties.provisioningState")
    if [ "$res" != "Succeeded" ]; then
        az group delete --yes --no-wait -g ${RES_GRP}
        echo "Failed to create resource group."
        exit
    fi
    show_elapsed_time $st
}

# 2. Create VNET
create_vnet () {
    echo -e "Creating VNET..."
    local st=$(date '+%s')
    local res=$(az network vnet create -g ${RES_GRP} \
        --name ${VNET_NAME} \
        --address-prefix ${VNET_PREFIX} \
        --subnet-name ${SUBNET_NAME} \
        --subnet-prefix ${SUBNET_PREFIX})
    res=$(az network nsg create -g ${RES_GRP} \
        --name ${NSG_NAME})
    res=$(az network nsg rule create -g ${RES_GRP} \
        --nsg-name ${NSG_NAME} --name Allow-SSH-Internet \
        --access Allow --protocol Tcp --direction Inbound --priority 100 \
        --source-address-prefix Internet --source-port-range "*" \
        --destination-address-prefix "*" --destination-port-range 22)
    res=$(az network nsg rule create -g ${RES_GRP} \
        --nsg-name ${NSG_NAME} --name Allow-Postgres-Internet \
        --access Allow --protocol Tcp --direction Inbound --priority 101 \
        --source-address-prefix Internet --source-port-range "*" \
        --destination-address-prefix "*" --destination-port-range 5432)

    show_elapsed_time $st
}


# 4. Write credential.inc
write_credential () {
    cat << EOF > credential.inc
    export PG_ADMIN_USER="${PG_ADMIN_USER}"
    export PG_ADMIN_PASS="${PG_ADMIN_PASS}"
EOF
}

# 4. Create Citus Nodes
create_node () {
    local st=$(date '+%s')
    
    local node_no=$1
    local vm_size=$2
    local os_disk=$3
    local data_disk=$4

    if [ ${node_no} -eq -1 ]; then
        sub_name="c"
    else
        sub_name="w${node_no}"
    fi
    local res=$(az network public-ip create -g ${RES_GRP} \
        --name "${PUBLIC_IP_NAME}-${sub_name}" \
        --allocation-method Static \
        --dns-name "${NODE_NAME}-${sub_name}")

    res=$(az network nic create -g ${RES_GRP} \
        --name "${NIC_NAME}-${sub_name}" \
        --vnet-name ${VNET_NAME} \
        --subnet ${SUBNET_NAME} \
        --accelerated-networking true \
        --public-ip-address "${PUBLIC_IP_NAME}-${sub_name}" \
        --network-security-group ${NSG_NAME})

    res=$(az vm create -g ${RES_GRP} \
        -n "${NODE_NAME}-${sub_name}" \
        --size ${vm_size} \
        --nics "${NIC_NAME}-${sub_name}" \
        --admin-username ${AZURE_ACCT} \
        --image ${OS_SKU} \
        --data-disk-sizes-gb ${os_disk} \
        --data-disk-caching ReadWrite \
        --os-disk-size-gb ${data_disk})

    fqdn="${NODE_NAME}-${sub_name}.${RES_LOC}.cloudapp.azure.com"
    echo -e "Connecting $fqdn..."
    ssh-keygen -R $fqdn 2>&1
    trying=0
    sshres=$(ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" 'uname')
    while [ "$sshres" != "Linux" ]; do
        trying=$(expr $trying + 1)
        echo "Challenge: $trying"
        if [ $trying -eq 30 ]; then
            echo "Could not login $fqdn for 5 mins. Please check if 22/tcp is open."
            exit
        fi
        sleep 10
        sshres=$(ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" 'uname')
    done
    scp -o "StrictHostKeyChecking no" credential.inc ${AZURE_ACCT}@"$fqdn:~/"
    ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" <<-'EOF'

    # On Remote
    source credential.inc
    rm -f credential.inc

    # Set up a Data Disk (1st data disk is always attached as /dev/sdc on Azure)
    sudo sh -c "
        parted -s -a optimal /dev/sdc mklabel gpt
        parted -s -a optimal /dev/sdc -- mkpart primary xfs 1 -1
        mkfs.xfs -f /dev/sdc1
        echo \"/dev/sdc1 /var/lib/pgsql xfs defaults 0 0\" >> /etc/fstab
        mkdir /var/lib/pgsql; mount /var/lib/pgsql
        "

    # Install Citus
    # See https://docs.citusdata.com/en/stable/installation/multi_machine_rhel.html
    sudo sh -c "curl https://install.citusdata.com/community/rpm.sh | bash"
    sudo sh -c "
        yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
        yum -y install citus93_11 postgis25_11 hll_11 pg_cron_11 pg_partman11 pgaudit13_11 pglogical_11 tdigest11 topn_11
        "

    # Initialize system database
    sudo /usr/pgsql-11/bin/postgresql-11-setup initdb

    # Configure to preload citus extension
    sudo sh -c "
        sed -i.org 's/^#listen_addresses = '\'localhost\''/listen_addresses = '\'*\''/' /var/lib/pgsql/11/data/postgresql.conf
        echo \"shared_preload_libraries = 'citus'\" >> /var/lib/pgsql/11/data/postgresql.conf
        "

    # Configure for access control
    sudo sh -c "
        sed -i.org 's/^\(host *all *all *127.0.0.1\/32 *\)ident/\1trust/' /var/lib/pgsql/11/data/pg_hba.conf
        sed -i 's/^\(host *all *all *::1\/128 *\)ident/\1trust/' /var/lib/pgsql/11/data/pg_hba.conf
        echo \"host    all             all             192.168.1.0/24          trust\" >> /var/lib/pgsql/11/data/pg_hba.conf
        "

    # Restart PostgreSQL
    sudo sh -c "
        systemctl restart postgresql-11
        systemctl enable postgresql-11
        "

    # Load Citus extension
    sudo -i -u postgres psql -c "CREATE EXTENSION citus;"

EOF
    show_elapsed_time $st
}

# 5. Configure Coordinator
configure_coordinator () {
    local st=$(date '+%s')
    # On Local
    echo "Configuring Citus Coordinator..."
    # 1st node may have 192.168.1.4, 2nd and others will be workers and 2nd node may have 192.168.1.5
    for last_octet in `seq 5 $(expr ${WORKER_COUNT} + 3)`; do
        ssh -o "StrictHostKeyChecking no" ${AZURE_ACCT}@${NODE_NAME}-c.${RES_LOC}.cloudapp.azure.com \
            "sudo -i -u postgres psql -c \"SELECT * from master_add_node('192.168.1.${last_octet}', 5432);\""
    done
    show_elapsed_time $st
}

# 6. Show and write all settings
show_settings () {
    echo -e "Writing all settings to 'settings.txt'..."
    cat << EOF | tee settings.txt
Azure Region :
    ${RES_LOC}

Resource Group :
    ${RES_GRP}

Coordinator :
    ${NODE_NAME}-c.${RES_LOC}.cloudapp.azure.com

Passwords :
    PostgreSQL Admin User : ${PG_ADMIN_USER}, Admin Password : ${PG_ADMIN_PASS}

Connection String :
    psql "host=${NODE_NAME}-c.${RES_LOC}.cloudapp.azure.com port=5432 dbname=citus user=${PG_ADMIN_USER} password=${PG_ADMIN_PASS} sslmode=require"

EOF
}

show_elapsed_time () {
    st=$1
    echo "Elapsed time: $(expr $(date '+%s') - $st) secs"
}

##### MAIN
total_st=$(date '+%s')

create_group
create_vnet
write_credential
echo "Creating Coordinator Node..."
create_node -1 ${COORDINATOR_SIZE} ${COORDINATOR_OS_DISK_SIZE} ${COORDINATOR_DATA_DISK_SIZE}
for node_no in `seq -w 0 $(expr $WORKER_COUNT - 1)`; do
    echo "Creating Worker Node ${node_no}..."
    create_node ${node_no} ${WORKER_SIZE} ${WORKER_OS_DISK_SIZE} ${WORKER_DATA_DISK_SIZE}
done

configure_coordinator

show_settings

show_elapsed_time $total_st
