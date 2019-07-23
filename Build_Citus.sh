#!/bin/bash
# How to validate Citus on Azure

# Set your account & region you prefer
readonly admin="rifujita"
readonly location="japaneast"

# Citus Sizing
readonly citusNodeSize="Standard_D16s_v3"
# The 1st node will be setup as 'Coordinator'
readonly citusNodeCount="9"
readonly citusNodeOSImage="OpenLogic:CentOS:7.6:7.6.20190708"
#readonly citusNodeOSImage="RedHat:RHEL:7.5:7.5.2018081519"
readonly citusNodeOSDiskSize="256"
readonly citusNodeDataDiskSize="4095"

# Resource Group & Networking
readonly citusGroup="${admin}-citus-rg"
readonly citusVnet="citusvnet"
readonly citusVnetPrefix="192.168.0.0/16"
readonly citusSubnet="citussubnet"
readonly citusSubnetPrefix="192.168.1.0/24"
readonly citusNSG="citusNSG"

# Prefixes for Citus nodes
# None of nodes require its own public IP for your production environment
readonly citusName="${citusGroup}-citus-node"
readonly citusPubIP="citusPubIP"
readonly citusNIC="citusNic"

# 1. Create Citus Nodes
create_nodes () {
    # On Local
    echo "Creating Citus Resource Group..."

    # Group Creation
    az group create -g $citusGroup -l $location

    echo "Creating Citus Network..."
    az network vnet create -g $citusGroup --name $citusVnet \
        --address-prefix $citusVnetPrefix --subnet-name $citusSubnet --subnet-prefix $citusSubnetPrefix
    az network nsg create -g $citusGroup --name $citusNSG
    az network nsg rule create -g $citusGroup --nsg-name $citusNSG --name Allow-SSH-Internet \
        --access Allow --protocol Tcp --direction Inbound --priority 100 \
        --source-address-prefix Internet --source-port-range "*" \
        --destination-address-prefix "*" --destination-port-range 22

    for node_no in `seq -w 1 $citusNodeCount`; do
        echo "Creating Citus Node ${node_no}..."
        az network public-ip create -g $citusGroup --name "${citusPubIP}${node_no}" --allocation-method Static --dns-name "${citusName}${node_no}"

        az network nic create -g $citusGroup --name "${citusNIC}${node_no}" --vnet-name $citusVnet \
            --subnet $citusSubnet --accelerated-networking true --public-ip-address "${citusPubIP}${node_no}" --network-security-group $citusNSG

        az vm create -g $citusGroup -n "${citusName}${node_no}" \
            --size $citusNodeSize --nics "${citusNIC}${node_no}" --admin-username $admin \
            --image $citusNodeOSImage \
            --data-disk-sizes-gb $citusNodeDataDiskSize --data-disk-caching ReadWrite \
            --os-disk-size-gb $citusNodeOSDiskSize

        sleep 60

        echo "Configuring Citus Node ${node_no}..."
        citusPubIPAddr=$(az vm list-ip-addresses -n "${citusName}${node_no}" -o tsv --query "[].virtualMachine[].{PublicIp:network.publicIpAddresses[0].ipAddress}")
        ssh -o "StrictHostKeyChecking no" $admin@$citusPubIPAddr <<-'EOF'

        # On Remote
        # Set up a Data Disk (1st data disk is always attached as /dev/sdc on Azure)
        sudo sh -c "parted -s -a optimal /dev/sdc mklabel gpt; parted -s -a optimal /dev/sdc -- mkpart primary xfs 1 -1; mkfs.xfs -f /dev/sdc1"
        # sudo sh -c "echo \"$(sudo blkid /dev/sdc1|awk '{print $2}') /var/lib/pgsql xfs defaults 0 0\" >> /etc/fstab"
        sudo sh -c "echo \"/dev/sdc1 /var/lib/pgsql xfs defaults 0 0\" >> /etc/fstab"
        sudo sh -c "mkdir /var/lib/pgsql; mount /var/lib/pgsql"
        
	# Install PGroonga
	sudo -H yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -qf --queryformat="%{VERSION}" /etc/redhat-release)-$(rpm -qf --queryformat="%{ARCH}" /etc/redhat-release)/pgdg-redhat-repo-latest.noarch.rpm
	sudo -H yum install -y https://packages.groonga.org/centos/groonga-release-latest.noarch.rpm
	sudo -H yum install -y postgresql11-pgroonga groonga-tokenizer-mecab

        # Install Citus
        # See https://docs.citusdata.com/en/stable/installation/multi_machine_rhel.html
        sudo sh -c "curl https://install.citusdata.com/community/rpm.sh | bash"
        sudo yum install -y citus81_11
        
        # Initialize system database
        sudo /usr/pgsql-11/bin/postgresql-11-setup initdb

        # Configure to preload citus extension
        sudo sh -c "sed -i.org 's/^#listen_addresses = '\'localhost\''/listen_addresses = '\'*\''/' /var/lib/pgsql/11/data/postgresql.conf"
        sudo sh -c "echo \"shared_preload_libraries = 'citus'\" >> /var/lib/pgsql/11/data/postgresql.conf"

        # Configure for access control
        sudo sh -c "sed -i.org 's/^\(host *all *all *127.0.0.1\/32 *\)ident/\1trust/' /var/lib/pgsql/11/data/pg_hba.conf"
        sudo sh -c "sed -i 's/^\(host *all *all *::1\/128 *\)ident/\1trust/' /var/lib/pgsql/11/data/pg_hba.conf"
        sudo sh -c "echo \"host    all             all             192.168.1.0/24          trust\" >> /var/lib/pgsql/11/data/pg_hba.conf"

        # Restart PostgreSQL
        sudo sh -c "systemctl restart postgresql-11; systemctl enable postgresql-11"
        sudo sh -c "firewall-cmd --permanent --zone=public --add-service=postgresql; systemctl restart firewalld"

        # Load Citus extension
        sudo -i -u postgres psql -c "CREATE EXTENSION citus;"

EOF
    done
}

# 2. Configure Coordinator
configure_coodinator () {
    # On Local
    echo "Configuring Citus Coodinator..."

    citusPubIPAddr=$(az vm list-ip-addresses -n "${citusName}1" -o tsv --query "[].virtualMachine[].{PublicIp:network.publicIpAddresses[0].ipAddress}")
    # 1st node may have 192.168.1.4, 2nd and others will be workers and 2nd node may have 192.168.1.5
    for last_octet in `seq 5 $(($citusNodeCount + 3))`; do
        ssh -o "StrictHostKeyChecking no" $admin@$citusPubIPAddr "sudo -i -u postgres psql -c \"SELECT * from master_add_node('192.168.1.${last_octet}', 5432);\""
    done
}

create_nodes
configure_coodinator
