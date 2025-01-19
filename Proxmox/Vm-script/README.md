# Proxmox VM Manager

A user-friendly script to manage Proxmox VMs with automatic IP assignment and template management.

## Features

- **Template Management**
  - Create new templates
  - Clone from existing templates
  - List all templates
  - Delete templates
  - Move templates between storages
- **Automatic Network Configuration**
  - Smart IP assignment
  - Automatic gateway detection
  - Network bridge selection
  - Prevents IP conflicts
- **SSH Key Management**
  - Automatic SSH key setup
  - Secure VM access
  - Cloud-init integration
- **Package Management**
  - Examine installed packages
  - Search for specific packages
  - View common package categories
  - Filter and sort package lists
- **Storage Management**
  - Move templates between storages
  - Move VMs between storages
  - Shows available space per storage
  - Supports different storage types
  - Safe migration process
- **Interactive Dialog-Based Interface**
  - User-friendly menu-driven interface
  - Easy navigation and selection
- **Detailed Logging**
  - Logs all operations for troubleshooting
  - Error handling and recovery
- **Error Handling and Recovery**
  - Automatic error detection and handling
  - Safe recovery from errors

## Storage Movement Features

### Template Storage Movement
- Move templates between different storage locations
- Handles all disk types (scsi, virtio, ide, sata)
- Automatic disk detection from config
- Safe movement with error handling
- Progress tracking and logging

### VM Storage Movement
- Move running or stopped VMs between storages
- Safe handling of running VMs with stop/start
- Multi-disk support
- Progress tracking
- Automatic restart of running VMs after move
- Error recovery with VM state restoration

## Requirements

- Proxmox VE 7.0 or higher
- `dialog` package
- `virt-customize`
- `cloud-init` enabled templates
- Root access
- Sufficient storage space on target location

## Installation

1. Clone this repository:
```bash
git clone https://github.com/yourusername/proxmox-vm-manager.git
cd proxmox-vm-manager
```

2. Make the script executable:
```bash
chmod +x create_ubuntu_vm_simple.sh
```

## Usage

Run the script as root:
```bash
sudo ./create_ubuntu_vm_simple.sh
```

The script will present a menu with the following options:

1. **Create New Template**
   - Select an ISO image
   - Set VM ID and name
   - Configure disk size
   - Set username and password
   - Choose network bridge

2. **List Templates**
   - View all available templates
   - See template details

3. **Delete Template**
   - Select template to delete
   - Confirmation required

4. **Clone from Template**
   - Choose source template
   - Set new VM ID and name
   - Optionally resize disk
   - Automatic IP assignment
   - SSH key configuration

5. **Examine Image Packages**
   - View all installed packages
   - Search for specific packages
   - Filter by categories
   - See package versions

6. **Move Template Storage**
   - Select template to move
   - View current storage location
   - Choose target storage
   - See available space
   - Safe migration process

7. **Move VM Storage**
   - Select VM to move
   - View current storage location
   - Choose target storage
   - See available space
   - Safe migration process

8. **Exit**

### Network Configuration

The script automatically:
- Detects available network bridges
- Finds the next available IP address
- Sets appropriate gateway
- Configures network interfaces

### SSH Access

VMs are automatically configured with:
- Proxmox host's SSH key
- Cloud-init integration
- Secure key-based authentication

### Storage Management

When moving templates or VMs:
1. Shows current storage location
2. Lists compatible storage targets
3. Displays storage type and free space
4. Safely migrates the template or VM
5. Verifies successful move

## Notes

- Always ensure sufficient storage space before moving VMs or templates
- For running VMs, the script will ask permission to stop before moving
- All operations are logged to syslog for troubleshooting
- The script automatically handles disk detection and movement

## Tips

1. **Template Creation**
   - Use cloud-init enabled images
   - Set appropriate disk size
   - Configure default credentials

2. **Cloning**
   - Templates remain unchanged
   - New VMs get unique IPs
   - SSH keys are automatically configured

3. **Package Management**
   - Use the search function for specific packages
   - View common packages by category
   - Check versions before deployment

4. **Storage Management**
   - Move templates to optimize space
   - Check free space before moving
   - Consider storage type compatibility
   - Wait for migrations to complete

## Troubleshooting

1. **IP Assignment Issues**
   - Check network bridge configuration
   - Verify IP range availability
   - Ensure no IP conflicts

2. **SSH Access Problems**
   - Verify SSH key generation
   - Check cloud-init status
   - Confirm network connectivity

3. **Template Issues**
   - Ensure template is cloud-init enabled
   - Verify disk space
   - Check VM permissions

4. **Storage Move Issues**
   - Ensure enough space on target
   - Check storage type compatibility
   - Wait for move to complete
   - Verify template or VM accessibility after move

## Contributing

Feel free to:
- Report issues
- Submit pull requests
- Suggest improvements
- Share your use cases

## License

This project is licensed under the MIT License - see the LICENSE file for details.
