# Proxmox Template Management Script

A comprehensive bash script for managing Proxmox VE templates and VMs with a user-friendly dialog interface.

## Features

### Template Creation
- Create templates from cloud images
- Configure VM settings:
  - VM ID and Name
  - Memory allocation
  - Network bridge
  - Storage location
  - Machine type (q35)
  - SCSI controller selection
  - CPU cores and sockets
  - Cloud-init username and password

### Storage Management
- Move VM storage between different storage locations
- Move template storage between different storage locations
- Support for all disk types (virtio, scsi, ide, sata)
- Safe handling of running VMs during migration
- Progress tracking during storage moves

### Cloud-init Support
- Automatic cloud-init drive configuration
- User credentials setup
- Network configuration (DHCP)
- QEMU guest agent enabled by default

## Default Variables

The script uses several default variables that can be modified at the top of the script:

```bash
# Default VM Settings
DEFAULT_VM_ID="100"           # Starting VM ID (100-999999)
DEFAULT_MEMORY="2048"         # Memory in MB (512-262144)
DEFAULT_BRIDGE="vmbr0"        # Default network bridge
DEFAULT_STORAGE="local-lvm"   # Default storage location
DEFAULT_MACHINE="q35"         # Machine type
DEFAULT_CORES="2"             # CPU cores (1-128)
DEFAULT_SOCKETS="1"           # CPU sockets (1-4)
DEFAULT_USERNAME="ubuntu"     # Default cloud-init username
DEFAULT_PASSWORD="ubuntu"     # Default cloud-init password
```

## Functions

### Template Management

#### `create_template()`
Creates a new template from a cloud image with specified configurations.
```bash
Parameters:
$1: vm_id      - VM ID (100-999999)
$2: vm_name    - Template name
$3: memory     - Memory in MB (512-262144)
$4: bridge     - Network bridge name
$5: storage    - Storage location
$6: machine    - Machine type
$7: cores      - CPU cores (1-128)
$8: sockets    - CPU sockets (1-4)
$9: username   - Cloud-init username
${10}: password - Cloud-init password
${11}: image_path - Path to cloud image
```

#### `delete_template()`
Lists and deletes selected templates with confirmation.
```bash
No parameters required. Interactive selection via dialog.
```

### Storage Management

#### `move_vm_storage()`
Move storage for existing VMs.
```bash
Parameters:
$1: vm_id    - VM ID to move
$2: storage  - Target storage location
```

#### `move_template_storage()`
Move template storage between different storage locations.
```bash
Parameters:
$1: template_id - Template ID to move
$2: storage     - Target storage location
```

### Utility Functions

#### `select_file()`
Interactive file selection from specified directory.
```bash
Parameters:
$1: directory - Directory to browse
Returns: Selected file path
```

#### `list_templates()`
List all available templates.
```bash
No parameters. Returns formatted list of templates.
```

#### `list_vms()`
List all available VMs.
```bash
No parameters. Returns formatted list of VMs.
```

#### `list_storages()`
List all available storage locations.
```bash
No parameters. Returns formatted list of storage locations.
```

#### `get_storage_free_space()`
Get available space in bytes for a storage location.
```bash
Parameters:
$1: storage - Storage location to check
Returns: Available space in bytes
```

## Value Ranges and Limitations

### VM Configuration
- VM ID: 100-999999
- Memory: 512MB - 256GB
- Cores: 1-128
- Sockets: 1-4
- Storage: Must be active and available in Proxmox
- Machine Type: Typically 'q35' for modern VMs

### Storage Requirements
- Storage must be active in Proxmox
- Sufficient space available for VM disk
- Support for the VM disk format (raw, qcow2)

## Usage Examples

### Create a Template
1. Select option 1 from the main menu
2. Choose the cloud image file
3. Select storage location
4. Fill in VM configuration:
   - VM ID (e.g., 100)
   - VM Name (e.g., ubuntu-template)
   - Memory (e.g., 2048)
   - Bridge (e.g., vmbr0)
   - Machine (e.g., q35)
   - Cores (e.g., 2)
   - Sockets (e.g., 1)
   - Username and Password

### Move VM Storage
1. Select option 4 from the main menu
2. Choose the VM to move
3. Select target storage location
4. Confirm the move

## Error Handling

The script includes comprehensive error handling:
- Validates all input parameters
- Checks storage availability
- Verifies disk attachments
- Monitors template conversion
- Provides detailed error messages
- Safely handles running VMs during operations

## Requirements

- Proxmox VE 7.0 or higher
- Dialog package installed
- Sufficient permissions (root access)
- Active storage locations
- Cloud images for template creation

## Installation

1. Copy the script to your Proxmox server
2. Make it executable: `chmod +x Deploy_Script.sh`
3. Ensure dialog is installed: `apt-get install dialog`

## Usage

Run the script:
```bash
./Deploy_Script.sh
```
```

The script will present a dialog-based interface for:
1. Creating new templates
2. Moving VM storage
3. Moving template storage
4. Managing existing templates

## Safety Features

- Validation before storage migration
- Safe handling of running VMs
- Storage space verification
- Compatibility checks
- Error handling and reporting
- Progress tracking during operations

## Notes

- Storage migration can be performed on both running and stopped VMs
- Running VMs will be safely stopped before migration and restarted afterward
- All operations are performed with proper error handling and user confirmation
- The script supports all Proxmox storage types and disk formats
