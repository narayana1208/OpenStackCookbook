#!/bin/bash

# compute.sh

# Authors: Kevin Jackson (kevin@linuxservices.co.uk)
#          Cody Bunch (bunchc@gmail.com)
# There are lots of bits adapted from:
# https://github.com/mseknibilel/OpenStack-Grizzly-Install-Guide/blob/OVS_MultiNode/OpenStack_Grizzly_Install_Guide.rst

# Source in common env vars
. /vagrant/common.sh

# The routeable IP of the node is on our eth1 interface
MY_IP=$(ifconfig eth1 | awk '/inet addr/ {split ($2,A,":"); print A[2]}')

# Must define your environment
MYSQL_HOST=${CONTROLLER_HOST}
GLANCE_HOST=${CONTROLLER_HOST}

nova_compute_install() {

	# Install some packages:
	sudo apt-get -y install nova-api-metadata nova-compute nova-compute-qemu nova-doc
	sudo apt-get install -y vlan bridge-utils
	sudo apt-get install -y libvirt-bin pm-utils
	sudo service ntp restart
}

nova_configure() {

# Networking 
# ip forwarding
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
# To save you from rebooting, perform the following
sysctl net.ipv4.ip_forward=1
# Kill default bridge
virsh net-destroy default
virsh net-undefine default

# Enable Live migrate
#sudo sed -i 's/listen_tls = 0//g' /etc/libvirt/libvirt.conf
#listen_tcp = 1
#auth_tcp = "none"'

# Enable libvirtd_opts
# env libvirtd_opts="-d -l"
# /etc/default/libvirt-bin
#libvirtd_opts="-d -l"

# restart libvirt
sudo service libvirt-bin restart

# OpenVSwitch
sudo apt-get install -y linux-headers-`uname -r` build-essential
sudo apt-get install -y openvswitch-switch openvswitch-datapath-dkms

# Edit the /etc/network/interfaces file for eth2?
sudo ifconfig eth2 0.0.0.0 up
sudo ip link set eth2 promisc on

# OpenVSwitch Configuration
#br-int will be used for VM integration
sudo ovs-vsctl add-br br-int

sudo ovs-vsctl add-br br-eth2
sudo ovs-vsctl add-port br-eth2 eth2

# Quantum
sudo apt-get install -y quantum-plugin-openvswitch-agent python-cinderclient

# Configure Quantum
# /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
echo "
[DATABASE]
sql_connection=mysql://quantum:openstack@172.16.0.200/quantum
reconnect_interval = 2

[OVS]
tenant_network_type = vlan
integration_bridge = br-int
local_ip = ${MY-IP}

bridge_mappings = ph-eth2:br-eth2
network_vlan_ranges = ph-eth2:1:1000

[SECURITYGROUP]
firewall_driver = quantum.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver

[AGENT]
state_path = /var/run/quantum
debug = False
verbose = False
" | tee -a /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini

#sudo sed -i "s|sql_connection = sqlite:////var/lib/quantum/ovs.sqlite|sql_connection = mysql://quantum:openstack@${CONTROLLER_HOST}/quantum|g"  /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
#sudo sed -i 's/# Default: integration_bridge = br-int/integration_bridge = br-int/g' /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
#sudo sed -i 's/# Default: tunnel_bridge = br-tun/tunnel_bridge = br-tun/g' /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
#sudo sed -i 's/# Default: enable_tunneling = False/enable_tunneling = True/g' /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
#sudo sed -i 's/# Example: tenant_network_type = gre/tenant_network_type = gre/g' /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
#sudo sed -i 's/# Example: tunnel_id_ranges = 1:1000/tunnel_id_ranges = 1:1000/g' /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
#sudo sed -i "s/# Default: local_ip =/local_ip = ${MY_IP}/g" /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini

sudo sed -i "s/# rabbit_host = localhost/rabbit_host = ${CONTROLLER_HOST}/g" /etc/quantum/quantum.conf
#echo "bridge_mappings = eth2:br-eth2" | sudo tee -a /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
#echo "# When using tunneling this should be reset from the default "default:2000:3999" to empty list
#network_vlan_ranges = " | sudo tee -a /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.in

sudo sed -i 's/# auth_strategy = keystone/auth_strategy = keystone/g' /etc/quantum/quantum.conf
sudo sed -i "s/auth_host = 127.0.0.1/auth_host = ${CONTROLLER_HOST}/g" /etc/quantum/quantum.conf
sudo sed -i 's/admin_tenant_name = %SERVICE_TENANT_NAME%/admin_tenant_name = service/g' /etc/quantum/quantum.conf
sudo sed -i 's/admin_user = %SERVICE_USER%/admin_user = quantum/g' /etc/quantum/quantum.conf
sudo sed -i 's/admin_password = %SERVICE_PASSWORD%/admin_password = quantum/g' /etc/quantum/quantum.conf
sudo sed -i 's/^root_helper.*/root_helper = sudo/g' /etc/quantum/quantum.conf

echo "
Defaults !requiretty
quantum ALL=(ALL:ALL) NOPASSWD:ALL" | tee -a /etc/sudoers

# Restart Quantum Services
service quantum-plugin-openvswitch-agent restart


# Nova Conf
	# Clobber the nova.conf file with the following
	NOVA_CONF=/etc/nova/nova.conf
	NOVA_API_PASTE=/etc/nova/api-paste.ini
	cat > /tmp/nova.conf <<EOF
[DEFAULT]
dhcpbridge_flagfile=/etc/nova/nova.conf
dhcpbridge=/usr/bin/nova-dhcpbridge
logdir=/var/log/nova
state_path=/var/lib/nova
lock_path=/var/lock/nova
root_helper=sudo nova-rootwrap /etc/nova/rootwrap.conf
verbose=True
rabbit_host=${MYSQL_HOST}
nova_url=http://${MYSQL_HOST}:8774/v1.1/

api_paste_config=/etc/nova/api-paste.ini
enabled_apis=ec2,osapi_compute,metadata

# Libvirt and Virtualization
compute_driver=libvirt.LibvirtDriver
libvirt_use_virtio_for_bridges=True
connection_type=libvirt
libvirt_type=qemu

# Database
sql_connection=mysql://nova:openstack@${MYSQL_HOST}/nova

# Messaging
rabbit_host=${MYSQL_HOST}

# EC2 API Flags
ec2_host=${MYSQL_HOST}
ec2_dmz_host=${MYSQL_HOST}
ec2_private_dns_show_ip=True

# Network settings
network_api_class=nova.network.quantumv2.api.API
quantum_url=http://${CONTROLLER_HOST}:9696
quantum_auth_strategy=keystone
quantum_admin_tenant_name=service
quantum_admin_username=quantum
quantum_admin_password=quantum
quantum_admin_auth_url=http://${CONTROLLER_HOST}:35357/v2.0
libvirt_vif_driver=nova.virt.libvirt.vif.LibvirtHybridOVSBridgeDriver
linuxnet_interface_driver=nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver=nova.virt.libvirt.firewall.IptablesFirewallDriver

#Metadata
service_quantum_metadata_proxy = True
quantum_metadata_proxy_shared_secret = helloOpenStack
#metadata_host = ${CONTROLLER_HOST}
#metadata_listen = 172.16.0.200
#metadata_listen_port = 8775

# Cinder #
volume_driver=nova.volume.driver.ISCSIDriver
enabled_apis=ec2,osapi_compute,metadata
volume_api_class=nova.volume.cinder.API
iscsi_helper=tgtadm

# Images
image_service=nova.image.glance.GlanceImageService
glance_api_servers=${GLANCE_HOST}:9292

# Auth
auth_strategy=keystone
keystone_ec2_url=http://${KEYSTONE_ENDPOINT}:5000/v2.0/ec2tokens

# NoVNC
novnc_enabled=true
novncproxy_base_url=http://${CONTROLLER_HOST}:6080/vnc_auto.html
novncproxy_port=6080
vncserver_proxyclient_address=${CONTROLLER_HOST}
vncserver_listen=0.0.0.0


# NoVNC
novnc_enabled=true
novncproxy_host=${MY_IP}
novncproxy_base_url=http://${CONTROLLER_HOST}:6080/vnc_auto.html
novncproxy_port=6080

xvpvncproxy_port=6081
xvpvncproxy_host=${MY_IP}
xvpvncproxy_base_url=http://${CONTROLLER_HOST}:6081/console

vncserver_proxyclient_address=${MY_IP}
vncserver_listen=${MY_IP}

EOF

	sudo rm -f $NOVA_CONF
	sudo mv /tmp/nova.conf $NOVA_CONF
	sudo chmod 0640 $NOVA_CONF
	sudo chown nova:nova $NOVA_CONF

	# Paste file
        sudo sed -i "s/127.0.0.1/'$KEYSTONE_ENDPOINT'/g" $NOVA_API_PASTE
        sudo sed -i "s/%SERVICE_TENANT_NAME%/'service'/g" $NOVA_API_PASTE
        sudo sed -i "s/%SERVICE_USER%/nova/g" $NOVA_API_PASTE
        sudo sed -i "s/%SERVICE_PASSWORD%/'$SERVICE_PASS'/g" $NOVA_API_PASTE

	sudo nova-manage db sync
}

nova_restart() {
	for P in $(ls /etc/init/nova* | cut -d'/' -f4 | cut -d'.' -f1)
	do
		sudo stop ${P}
		sudo start ${P}
	done
}

# Main
nova_compute_install
nova_configure
nova_restart
