# AD Management Tool

A Python-based Active Directory management tool that allows you to manage users, computers, and execute remote commands in an Active Directory environment.

## Features

- Active Directory User Management
  - Create, modify, and delete users
  - Reset passwords
  - Manage group memberships
  - Search and filter users
  
- Computer Management
  - List and search computers
  - Execute remote commands on computers
  - Get system information
  - DNS resolution and validation

- Remote Command Execution
  - Run commands on remote computers using WinRM
  - Support for both domain and local credentials
  - Secure credential handling
  - Detailed error reporting and troubleshooting

## Requirements

### Python Dependencies
```
ldap3>=2.9
rich>=10.0
pandas>=1.3
pywinrm>=0.4.3
```

### System Requirements

1. Windows operating system
2. Domain-joined computer for AD operations
3. Python 3.7 or higher
4. PowerShell 5.1 or higher
5. Administrative rights on the domain

### WinRM Configuration

For remote command execution to work, you need to configure WinRM on both the source computer (where you run the script) and target computers:

#### On Source Computer (Your Computer)

Run these commands in PowerShell as Administrator:

```powershell
# Enable PowerShell remoting
Enable-PSRemoting -Force

# Enable CredSSP as client
Enable-WSManCredSSP -Role Client -DelegateComputer "*" -Force

# Configure TrustedHosts
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force

# Restart WinRM service
Restart-Service WinRM
```

#### On Target Computers

Run these commands in PowerShell as Administrator:

```powershell
# Enable PowerShell remoting
Enable-PSRemoting -Force

# Enable CredSSP as server
Enable-WSManCredSSP -Role Server -Force

# Configure TrustedHosts
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force

# Restart WinRM service
Restart-Service WinRM
```

#### Group Policy Configuration

Configure these settings in Group Policy:

1. Open Group Policy Editor
2. Navigate to: Computer Configuration > Administrative Templates > System > Credentials Delegation
3. Enable "Allow Delegating Fresh Credentials with NTLM-only Server Authentication"
4. Add "WSMAN/*" to the server list

## Installation

1. Clone the repository:
```bash
git clone https://github.com/your-username/ad-management.git
cd ad-management
```

2. Install required packages:
```bash
pip install -r requirements.txt
```

3. Configure your environment:
   - Copy `.env.example` to `.env`
   - Update the values with your AD server details

## Usage

### Basic Usage

```python
from ad_manager import ADManager

# Initialize the manager
manager = ADManager()

# List all users in an OU
users = manager.list_users_in_ou("OU=Users,DC=domain,DC=com")

# Execute a command on a remote computer
manager.run_command_on_computer("COMPUTER-NAME", "ipconfig /all")
```

### Remote Command Execution

```python
# Using domain credentials
manager.run_command_on_computer("COMPUTER-NAME", "hostname")

# Using local admin credentials
manager.run_command_on_computer("COMPUTER-NAME", "hostname", use_different_creds=True)
```

## Troubleshooting

### Common Issues

1. "Access Denied" errors:
   - Verify you have administrative rights
   - Check WinRM configuration on both computers
   - Ensure CredSSP is properly configured

2. "Could not connect" errors:
   - Verify the computer is online
   - Check DNS resolution
   - Ensure WinRM service is running

3. "TrustedHosts" errors:
   - Run the WinRM configuration commands above
   - Verify Group Policy settings

### Logging

The tool uses rich for console output and provides detailed error messages. Check the console output for troubleshooting information.

## Security Notes

1. Always use secure credentials
2. Avoid storing passwords in plain text
3. Use environment variables for sensitive information
4. Regularly rotate credentials
5. Monitor and audit command execution

## Contributing

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.
