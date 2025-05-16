# Ubuntu Bootstrap Scripts

This repository contains automated scripts for quickly bootstrapping and configuring  
Ubuntu Server environments. It installs essential packages, sets up networking,  
and configures common services like NFS and TFTP, along with development tools.

## Features

- System update and upgrade (only if network is reachable)
- Installation of base utilities (vim, git, curl, pv, tmux, etc.)
- Setup and configuration of NFS and TFTP servers
- Download and deploy kernel images, device tree blobs, and root filesystem
- Dynamic detection of Ethernet interfaces for network bridging
- Development environment setup with vim and tmux customization
- Removal of snapd to minimize system interference
- System cleanup with apt autoclean and autoremove

## Tested Environment

- Verified on Ubuntu Server 24.04 LTS

## Usage

1. Clone the repository:

```bash
git clone https://github.com/yourusername/ubuntu-bootstrap-scripts.git
cd ubuntu-bootstrap-scripts
```

2. Edit the script variables to fit your environment, such as `download_url` and `sudo_passwd`.

3. Run the install script with sudo privileges:

```bash
./ubuntu-bootstrap.sh
```

## Requirements

* Ubuntu Server 24.04 LTS or compatible
* Network connectivity for downloading packages and images
* Uses systemd-networkd for network management by default

## Notes

* The script configures sudo for passwordless execution; use with caution in secure environments.
* Removing snapd may affect some default packages; assess your needs before removal.
* Network bridge configuration may require adjustment based on your hardware.

## License

MIT License

## Contributing

Feel free to submit issues or pull requests to improve the scripts.
