#! /bin/bash

sudo_passwd="${SUDO_PASSWD:-YOUR_PASSWORD}"
rootfs_tarball="${ROOTFS_TARBALL:-image-core-mini.rootfs.tar.zst}"
dtb_file="${DTB_FILE:-drivers.dtb}"
kernel_image="${KERNEL_IMAGE:-Image-lpddr4.bin}"
download_url="${DOWNLOAD_URL:-http://192.168.90.101}"

print_info() {
	echo -e "\033[34mINFO> $*\033[0m"
}

print_warn() {
	echo -e "\033[33mWARN> $*\033[0m"
}

print_erro() {
	echo -e "\033[31mERRO> $*\033[0m"
}

enter_sudo_session() {
	if [ ! -f /etc/sudoers.d/browamcfg ]; then 
		print_info "Entering sudo session..."
		echo $sudo_passwd | sudo -S ls /root/ > /dev/null
	else
		print_info "Sudo session already configured."
	fi
}

set_sudo_nopasswd() {
	local cfg="browamcfg"
	print_info "Setting sudoers to allow nopasswd for group sudo..."
	echo "%sudo    ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$cfg
}

apt_upgrade() {
	if ping -c 1 -W 2 tw.archive.ubuntu.com > /dev/null 2>&1; then
		print_info "Ubuntu archive reachable. Proceeding with apt update/upgrade..."
		sudo apt update && sudo apt upgrade -y
	else
		print_warn "Cannot reach tw.archive.ubuntu.com. Skipping apt update/upgrade."
	fi
}

install_base_pkgs() {
	print_info "Installing base packages..."
	sudo apt install -y vim tree unzip curl wget net-tools git tmux pv
}

install_nfsd() {
	print_info "Installing nfs-kernel-server..."
	sudo apt install -y nfs-kernel-server

	if [ "$(grep '/opt/rootfs-' /etc/exports | wc -l)" = "0" ]; then
		print_info "Configuring /etc/exports for rootfs shares..."
		echo '/opt/rootfs-nfs    *(rw,sync,no_root_squash,no_subtree_check)' | sudo tee -a /etc/exports;
		echo '/opt/rootfs-yocto  *(rw,sync,no_root_squash,no_subtree_check)' | sudo tee -a /etc/exports;
	else
		print_warn "/etc/exports already configured."
	fi
	print_info "Restarting nfs-server.service..."
	sudo systemctl restart nfs-server.service
	systemctl status nfs-server.service

	print_info "Current NFS exports:"
	sudo showmount --exports
}

install_tftpd() {
	print_info "Installing tftpd-hpa..."
	sudo apt install -y tftpd-hpa

	if [ "$(grep -w TFTP_DIRECTORY /etc/default/tftpd-hpa | awk -F '"' '{print $2}')" = "/srv/tftp" ]; then
		print_info "Updating TFTP_DIRECTORY to /tftpboot..."
		sudo sed -i 's/TFTP_DIRECTORY=.*/TFTP_DIRECTORY="\/tftpboot"/g' /etc/default/tftpd-hpa;
	fi

	if [ "$(grep -w TFTP_OPTIONS /etc/default/tftpd-hpa | awk -F '"' '{print $2}')" = "--secure" ]; then
		print_info "Updating TFTP_OPTIONS to include --listen..."
		sudo sed -i 's/TFTP_OPTIONS=.*/TFTP_OPTIONS="--secure --listen"/g' /etc/default/tftpd-hpa;
	fi

	print_info "Creating and setting permissions for /tftpboot..."
	sudo mkdir -p /tftpboot
	sudo chmod 777 /tftpboot

	print_info "Restarting tftpd-hpa.service..."
	sudo systemctl restart tftpd-hpa.service
	sudo systemctl status tftpd-hpa.service
}

download_images() {
	print_info "Removing old DTB and kernel image from /tftpboot..."
	rm -rf /tftpboot/$dtb_file
	rm -rf /tftpboot/$kernel_image

	print_info "Downloading DTB file: $dtb_file..."
	wget -P /tftpboot/ ${download_url}/${dtb_file}

	print_info "Downloading kernel image: $kernel_image..."
	wget -P /tftpboot/ ${download_url}/${kernel_image}
}

install_rootfs_tarball() {
	local date_tag=$(date -I)
	local target_dir="/opt/rootfs-yocto"
	local i=1

	print_info "Installing rootfs tarball..."

	rm -rf $rootfs_tarball
	wget ${download_url}/${rootfs_tarball}

	if [ -d /opt/rootfs-yocto ]; then
		print_info "Previous rootfs directory found. Renaming as backup..."
		while [ -e ${target_dir}.${date_tag}.${i} ]; do
			i=$((i + 1))
		done
		sudo mv /opt/rootfs-yocto ${target_dir}.${date_tag}.${i};
	fi

	sudo mkdir -p ${target_dir}
	print_info "Extracting rootfs (with progress)..."
	#sudo tar --zstd -xvf $rootfs_tarball -C ${target_dir}
	pv "$rootfs_tarball" | sudo zstd -d | sudo tar -xf - -C "${target_dir}"
	sudo chmod 777 ${target_dir}
}

system_clean() {
	print_info "Cleaning up APT cache and removing unused packages..."
	sudo apt autoclean -y && sudo apt autoremove -y
}

net_setup_bridge() {
	local ip_addr="192.168.90.65/24"
	local netplan_file="/etc/netplan/01-bridged.yaml"

	print_info "Setting up network bridge using available Ethernet interfaces..."

	# Get all physical ethernet interfaces (excluding lo, docker, etc.)
	local interfaces=$(networkctl list --no-pager | awk '/ether/ {print $2}' | grep -v '^lo$')

	if [ -z "$interfaces" ]; then
		print_erro "No physical Ethernet interfaces found. Cannot create bridge."
		return 1
	fi

	print_info "Detected interfaces: $(echo $interfaces | tr ' ' ',')"

	# Backup existing netplan config if present
	if [ -f /etc/netplan/50-cloud-init.yaml ]; then
		print_info "Backing up /etc/netplan/50-cloud-init.yaml..."
		sudo mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak
	fi

	print_info "Generating new bridged netplan configuration..."

	# Dynamically generate netplan YAML content
	{
		echo "network:"
		echo "  version: 2"
		echo "  renderer: networkd"
		echo ""
		echo "  ethernets:"
		for iface in $interfaces; do
			echo "    ${iface}:"
			echo "      optional: true"
		done
		echo ""
		echo "  bridges:"
		echo "    br0:"
		echo "      interfaces: [$(echo "$interfaces" | paste -sd, -)]"
		echo "      addresses:"
		echo "        - ${ip_addr}"
		echo "      dhcp4: false"
		echo "      parameters:"
		echo "        stp: false"
		echo "        forward-delay: 0"
		echo "      optional: true"
	} | sudo tee "$netplan_file" > /dev/null

	print_info "Applying netplan configuration..."
	sudo chmod 600 $netplan_file
	sudo netplan apply
}

env_term_colors() {
	print_info "Configuring tmux color support..."

	cat << EOF > ~/.tmux.conf
set-option -g default-terminal "tmux-256color"
set-option -sa terminal-overrides ',xterm-256color:RGB'
EOF

	print_info "Ensuring TERM is set to xterm-256color in ~/.bashrc..."
	if ! grep -q '^export TERM=' ~/.bashrc; then
		echo 'export TERM="xterm-256color"' >> ~/.bashrc
	fi
}

env_setup_vim() {
	print_info "Setting vim.basic as default editor..."
	if [ -f /usr/bin/vim.basic ]; then
		sudo update-alternatives --set editor /usr/bin/vim.basic
	fi

	print_info "Installing pathogen.vim if not present..."
	if [ ! -f ~/.vim/autoload/pathogen.vim ]; then
		mkdir -p ~/.vim/autoload
		curl -LSso ~/.vim/autoload/pathogen.vim https://tpo.pe/pathogen.vim
	fi

	print_info "Installing molokai color scheme if not present..."
	if [ ! -f ~/.vim/bundle/molokai/colors/molokai.vim ]; then
		mkdir -p ~/.vim/bundle/molokai/colors
		curl -LSso ~/.vim/bundle/molokai/colors/molokai.vim https://raw.githubusercontent.com/tomasr/molokai/refs/heads/master/colors/molokai.vim
	fi

	print_info "Writing ~/.vimrc configuration..."
	cat << EOF > ~/.vimrc
" ### pathogen
execute pathogen#infect()

" ### molokai color scheme
let g:molokai_original = 1
let g:rehash256 = 1

" ## generial setup
set hlsearch
set tabstop=4
" set expandtab
set shiftwidth=4
set encoding=utf-8
set t_Co=256
set background=dark
set cursorline
syntax on
colorscheme molokai
set wildmenu
set wildmode=longest:full,full
set clipboard=unnamed

" ## open to the last position +++++
" req: sudo chown $USER:$USER ~/.viminfo
if has("autocmd")
  autocmd BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g\`\"" | endif
endif
EOF

}

env_remove_snap() {
	print_info "Checking for active snapd-related services..."

	# Only try to stop if units are loaded
	for unit in snapd.socket snapd snapd.seeded.service; do
		if systemctl list-units --all --quiet --full --type=service --type=socket | grep -q "^$unit"; then
			print_info "Stopping $unit..."
			sudo systemctl stop "$unit"
		else
			print_warn "$unit not loaded. Skipping stop."
		fi
	done

	# Remove snapd package if installed
	if dpkg -l | grep -q '^ii\s\+snapd\s'; then
		print_info "Removing snapd package..."
		sudo apt purge -y snapd
	else
		print_warn "snapd is not installed. Skipping removal."
	fi
}

do_done() {
	print_info "Done. Please restart the system."
}

do_main() {
	enter_sudo_session
	set_sudo_nopasswd
	apt_upgrade
	install_base_pkgs
	install_nfsd
	install_tftpd
	download_images
	install_rootfs_tarball
	env_term_colors
	env_setup_vim
	env_remove_snap
	net_setup_bridge
	system_clean
	do_done
}

do_main
