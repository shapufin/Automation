#!/usr/bin/env python3
import ldap3
from ldap3 import Server, Connection, ALL, SUBTREE, NTLM
import pandas as pd
from rich.console import Console
from rich.prompt import Prompt, IntPrompt, Confirm
from rich import print as rprint
from rich.table import Table
import winrm
from base64 import b64encode
import sys
import json
from datetime import datetime
import os
from typing import Dict, List, Tuple
import threading
import queue
import time
import ldap3.utils.conv

class ADManager:
    def __init__(self):
        self.console = Console()
        self.ldap_conn = None
        self.server = None
        self.base_dn = None
        self.current_target = None
        # Store connection details for reconnection
        self.conn_details = None
        self.domain = None

    def get_connection_details(self) -> Dict:
        """Get connection details from user input"""
        details = {}
        
        # Get server details
        details['server'] = Prompt.ask("Enter AD server hostname/IP")
        details['port'] = IntPrompt.ask("Enter port number", default=389)
        
        # Get domain and username
        self.domain = Prompt.ask("Enter domain (e.g., DOMAIN.LOCAL)")
        username = Prompt.ask("Enter username (e.g., Administrator)")
        
        # Format username and create base_dn
        details['username'] = f"{self.domain}\\{username}"
        
        # Create base DN from full domain name
        self.base_dn = ','.join([f"DC={x}" for x in self.domain.split('.')])
        
        # Get password
        details['password'] = Prompt.ask("Enter password", password=True)
        
        self.console.print(f"[dim]Using domain: {self.domain}[/dim]")
        self.console.print(f"[dim]Using base DN: {self.base_dn}[/dim]")
        
        return details

    def ensure_connected(self) -> bool:
        """Ensure we have a valid LDAP connection"""
        try:
            # Try a simple search to test connection
            if self.ldap_conn and self.ldap_conn.bound:
                try:
                    # Test the connection with a simple search
                    self.ldap_conn.search(
                        self.base_dn,
                        '(objectClass=computer)',
                        search_scope=SUBTREE,
                        size_limit=1,
                        time_limit=10  # Add timeout
                    )
                    return True
                except Exception as e:
                    self.console.print(f"[yellow]Connection test failed: {str(e)}[/yellow]")
                    self.console.print("[yellow]Attempting to reconnect...[/yellow]")
            
            # No connection or connection lost, try to reconnect
            if self.conn_details:
                if self.ldap_conn:
                    try:
                        self.ldap_conn.unbind()
                    except:
                        pass
                return self.connect(self.conn_details)
            else:
                self.console.print("[bold red]No connection details available. Please reconnect manually.[/bold red]")
                return False
                
        except Exception as e:
            self.console.print(f"[bold red]Connection error: {str(e)}[/bold red]")
            return False

    def connect(self, details: Dict) -> bool:
        """Connect to AD server"""
        try:
            # Store credentials for later use
            self.domain_username = details['username']
            self.domain_password = details['password']
            self.conn_details = details
            
            # Print connection details for debugging
            self.console.print(f"[dim]Connecting to server: {details['server']}:{details['port']}[/dim]")
            self.console.print(f"[dim]Using username: {self.domain_username}[/dim]")
            self.console.print(f"[dim]Using base DN: {self.base_dn}[/dim]")
            
            # Create server object with proper settings
            server = Server(
                details['server'],
                port=details['port'],
                get_info=ALL,
                connect_timeout=10
            )
            
            # Create connection with proper settings
            self.ldap_conn = Connection(
                server,
                user=self.domain_username,
                password=self.domain_password,
                authentication=NTLM,
                auto_bind=False,
                receive_timeout=30
            )
            
            # Try to bind
            if not self.ldap_conn.bind():
                self.console.print("[bold red]Failed to connect to AD server[/bold red]")
                self.console.print(f"[dim]Error: {self.ldap_conn.result}[/dim]")
                return False
            
            # Test the connection with a simple search
            self.ldap_conn.search(
                self.base_dn,
                '(objectClass=computer)',
                search_scope=SUBTREE,
                size_limit=1,
                time_limit=10
            )
            
            self.console.print("[bold green]Successfully connected to AD server[/bold green]")
            return True
            
        except Exception as e:
            self.console.print(f"[bold red]Error connecting to AD server: {str(e)}[/bold red]")
            return False

    def query_users(self) -> pd.DataFrame:
        """Query and return all users from AD"""
        if not self.ensure_connected():
            self.console.print("[bold red]Not connected to AD server. Please reconnect.[/bold red]")
            return pd.DataFrame()
        
        search_filter = "(&(objectClass=user)(objectCategory=person))"
        attributes = ['cn', 'mail', 'userPrincipalName', 'sAMAccountName', 
                     'whenCreated', 'whenChanged', 'distinguishedName']
        
        try:
            self.ldap_conn.search(
                self.base_dn,
                search_filter,
                search_scope=SUBTREE,
                attributes=attributes
            )
            
            users_data = []
            for entry in self.ldap_conn.entries:
                user = {
                    'DistinguishedName': str(entry.entry_dn),
                    'CommonName': str(entry.cn.value) if hasattr(entry, 'cn') else '',
                    'Email': str(entry.mail.value) if hasattr(entry, 'mail') else '',
                    'UserPrincipalName': str(entry.userPrincipalName.value) if hasattr(entry, 'userPrincipalName') else '',
                    'SAMAccountName': str(entry.sAMAccountName.value) if hasattr(entry, 'sAMAccountName') else '',
                    'WhenCreated': str(entry.whenCreated.value) if hasattr(entry, 'whenCreated') else '',
                    'WhenChanged': str(entry.whenChanged.value) if hasattr(entry, 'whenChanged') else ''
                }
                users_data.append(user)
            
            return pd.DataFrame(users_data)
            
        except Exception as e:
            self.console.print(f"[bold red]Error querying users: {str(e)}[/bold red]")
            return pd.DataFrame()
    
    def query_computers(self) -> pd.DataFrame:
        """Query and return all computers from AD"""
        if not self.ensure_connected():
            self.console.print("[bold red]Not connected to AD server. Please reconnect.[/bold red]")
            return pd.DataFrame()
        
        search_filter = "(objectClass=computer)"
        attributes = ['cn', 'dNSHostName', 'operatingSystem', 
                     'operatingSystemVersion', 'whenCreated', 'whenChanged',
                     'distinguishedName']
        
        try:
            self.ldap_conn.search(
                self.base_dn,
                search_filter,
                search_scope=SUBTREE,
                attributes=attributes
            )
            
            computers_data = []
            for entry in self.ldap_conn.entries:
                computer = {
                    'DistinguishedName': str(entry.entry_dn),
                    'ComputerName': str(entry.cn.value) if hasattr(entry, 'cn') else '',
                    'DNSHostName': str(entry.dNSHostName.value) if hasattr(entry, 'dNSHostName') else '',
                    'OperatingSystem': str(entry.operatingSystem.value) if hasattr(entry, 'operatingSystem') else '',
                    'OSVersion': str(entry.operatingSystemVersion.value) if hasattr(entry, 'operatingSystemVersion') else '',
                    'WhenCreated': str(entry.whenCreated.value) if hasattr(entry, 'whenCreated') else '',
                    'WhenChanged': str(entry.whenChanged.value) if hasattr(entry, 'whenChanged') else ''
                }
                computers_data.append(computer)
            
            return pd.DataFrame(computers_data)
            
        except Exception as e:
            self.console.print(f"[bold red]Error querying computers: {str(e)}[/bold red]")
            return pd.DataFrame()
    
    def test_connections(self) -> None:
        """Test AD connections between Domain Controllers"""
        if not self.ensure_connected():
            self.console.print("[bold red]Not connected to AD server. Please reconnect.[/bold red]")
            return
        
        # Search specifically for Domain Controllers
        search_filter = "(&(objectClass=computer)(userAccountControl:1.2.840.113556.1.4.803:=8192))"
        attributes = ['cn', 'dNSHostName', 'distinguishedName']
        
        try:
            self.ldap_conn.search(
                self.base_dn,
                search_filter,
                search_scope=SUBTREE,
                attributes=attributes
            )
            
            if len(self.ldap_conn.entries) == 0:
                self.console.print("[bold red]No Domain Controllers found[/bold red]")
                return
            
            results = []
            total = len(self.ldap_conn.entries)
            
            with self.console.status("[bold green]Testing connections between Domain Controllers...") as status:
                for idx, dc in enumerate(self.ldap_conn.entries):
                    hostname = str(dc.dNSHostName.value) if hasattr(dc, 'dNSHostName') else None
                    dc_name = str(dc.cn.value) if hasattr(dc, 'cn') else 'Unknown DC'
                    
                    if not hostname:
                        continue
                    
                    # Test LDAP connection to each Domain Controller
                    try:
                        test_server = Server(
                            host=hostname,
                            port=self.conn_details['port'],
                            use_ssl=self.conn_details['protocol'] == 'ldaps',
                            get_info=ALL
                        )
                        
                        # Try to establish a connection
                        test_conn = Connection(test_server, auto_bind=True)
                        status = "Success"
                        test_conn.unbind()
                    except Exception as e:
                        status = f"Failed: {str(e)}"
                    
                    results.append({
                        'DomainController': dc_name,
                        'DNSHostName': hostname,
                        'ConnectionStatus': status
                    })
                    
                    self.console.print(f"Tested DC {idx + 1}/{total}: {hostname} - {status}")
            
            # Export results
            if results:
                results_df = pd.DataFrame(results)
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                filename = f"dc_connection_test_results_{timestamp}.csv"
                results_df.to_csv(filename, index=False)
                self.console.print(f"[bold green]Domain Controller connection test results exported to {filename}[/bold green]")
            else:
                self.console.print("[bold yellow]No Domain Controller connection tests were performed[/bold yellow]")
                
        except Exception as e:
            self.console.print(f"[bold red]Error testing Domain Controller connections: {str(e)}[/bold red]")
    
    def export_to_csv(self, df: pd.DataFrame, prefix: str) -> None:
        """Export DataFrame to CSV with timestamp"""
        if df.empty:
            self.console.print("[bold red]No data to export[/bold red]")
            return
            
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{prefix}_{timestamp}.csv"
        df.to_csv(filename, index=False)
        self.console.print(f"[bold green]Data exported to {filename}[/bold green]")

    def get_organizational_units(self) -> List[Dict]:
        """Get list of OUs from AD"""
        if not self.ensure_connected():
            self.console.print("[bold red]Not connected to AD server. Please reconnect.[/bold red]")
            return []
        
        search_filter = "(objectClass=organizationalUnit)"
        attributes = ['ou', 'distinguishedName']
        
        try:
            self.ldap_conn.search(
                self.base_dn,
                search_filter,
                search_scope=SUBTREE,
                attributes=attributes
            )
            
            ous = []
            for entry in self.ldap_conn.entries:
                ou = {
                    'name': str(entry.ou.value) if hasattr(entry, 'ou') else 'Unknown',
                    'dn': str(entry.entry_dn)
                }
                ous.append(ou)
            
            return ous
        except Exception as e:
            self.console.print(f"[bold red]Error querying OUs: {str(e)}[/bold red]")
            return []

    def select_ou(self) -> str:
        """Interactive OU selection"""
        ous = self.get_organizational_units()
        
        if not ous:
            self.console.print("[bold red]No OUs found[/bold red]")
            return None
            
        table = Table(title="Available Organizational Units")
        table.add_column("Index", justify="right", style="cyan")
        table.add_column("OU Name", style="green")
        table.add_column("Distinguished Name", style="blue")
        
        for idx, ou in enumerate(ous, 1):
            table.add_row(str(idx), ou['name'], ou['dn'])
        
        self.console.print(table)
        
        choice = IntPrompt.ask(
            "Select OU by index (0 to cancel)",
            choices=[str(i) for i in range(len(ous) + 1)]
        )
        
        if choice == 0:
            return None
            
        return ous[choice - 1]['dn']

    def get_computers_in_ou(self, ou_dn: str) -> List[Dict]:
        """Get computers from specific OU"""
        if not self.ensure_connected():
            self.console.print("[bold red]Not connected to AD server. Please reconnect.[/bold red]")
            return []
        
        search_filter = "(objectClass=computer)"
        attributes = ['cn', 'dNSHostName', 'distinguishedName']
        
        try:
            self.ldap_conn.search(
                ou_dn,
                search_filter,
                search_scope=SUBTREE,
                attributes=attributes
            )
            
            computers = []
            for entry in self.ldap_conn.entries:
                computer = {
                    'name': str(entry.cn.value) if hasattr(entry, 'cn') else 'Unknown',
                    'hostname': str(entry.dNSHostName.value) if hasattr(entry, 'dNSHostName') else None,
                    'dn': str(entry.entry_dn)
                }
                computers.append(computer)
            
            return computers
        except Exception as e:
            self.console.print(f"[bold red]Error querying computers in OU: {str(e)}[/bold red]")
            return []

    def execute_remote_command(self, computer: Dict, command: str, results_queue: queue.Queue):
        """Execute command on remote computer"""
        try:
            if not computer['hostname']:
                results_queue.put({
                    'computer': computer['name'],
                    'status': 'Failed',
                    'output': 'No hostname available'
                })
                return

            # Use the same format as the LDAP connection
            formatted_username = self.domain_username  # Already in DOMAIN\username format
            
            self.console.print(f"[dim]Attempting connection to {computer['hostname']} with username: {formatted_username}[/dim]")
            
            try:
                # Create WinRM session
                session = winrm.Session(
                    computer['hostname'],
                    auth=(formatted_username, self.domain_password),
                    transport='ntlm',
                    server_cert_validation='ignore'
                )
                
                # Format the command to run in a CMD shell
                encoded_cmd = b64encode(command.encode('utf-16le')).decode('ascii')
                powershell_cmd = f"powershell -encodedcommand {encoded_cmd}"
                
                # Execute the command
                self.console.print(f"[dim]Executing command: {command}[/dim]")
                result = session.run_cmd(powershell_cmd)
                
                # Print the output
                if result.status_code == 0:
                    results_queue.put({
                        'computer': computer['name'],
                        'status': 'Success',
                        'output': result.std_out.decode('utf-8', errors='replace')
                    })
                else:
                    results_queue.put({
                        'computer': computer['name'],
                        'status': 'Failed',
                        'output': result.std_err.decode('utf-8', errors='replace')
                    })
                    
            except Exception as e:
                error_msg = str(e)
                self.console.print(f"[dim]Connection failed to {computer['hostname']}[/dim]")
                self.console.print(f"[dim]Error details: {error_msg}[/dim]")
                results_queue.put({
                    'computer': computer['name'],
                    'status': 'Failed',
                    'output': error_msg
                })

        except Exception as e:
            error_msg = str(e)
            self.console.print(f"[dim]Connection failed to {computer['hostname']}[/dim]")
            self.console.print(f"[dim]Error details: {error_msg}[/dim]")
            results_queue.put({
                'computer': computer['name'],
                'status': 'Failed',
                'output': error_msg
            })

    def convert_pattern_to_ldap(self, pattern: str) -> str:
        """Convert user-friendly pattern to LDAP filter pattern"""
        # Handle special patterns like "0**" or "00*"
        parts = pattern.split('-')
        if len(parts) > 1:
            # Handle the numeric part (last part)
            base = parts[:-1]  # All parts except the last
            number_part = parts[-1]  # Last part
            
            # Convert patterns like "0**" to match all numbers starting with 0
            if '**' in number_part:
                prefix = number_part.replace('**', '')
                # In LDAP, * matches any number of characters
                pattern = f"{'-'.join(base)}-{prefix}*"
                self.console.print(f"[dim]Converted pattern '**' to: {pattern}[/dim]")
                return pattern
            
            # Convert patterns like "00*" to match specific prefixes
            if '*' in number_part:
                pattern = f"{'-'.join(base)}-{number_part}"
                self.console.print(f"[dim]Using pattern as is: {pattern}[/dim]")
                return pattern
            
            # No special pattern, return as is
            return pattern
        
        return pattern

    def find_computers_by_pattern(self, pattern: str) -> List[Dict]:
        """Find computers matching a pattern"""
        if not self.ensure_connected():
            self.console.print("[bold red]Not connected to AD server. Please reconnect.[/bold red]")
            return []
            
        try:
            # First, try exact name match
            search_filter = f"(&(objectClass=computer)(|(name={pattern})(sAMAccountName={pattern})))"
            self.console.print(f"[dim]Searching in {self.base_dn}[/dim]")
            self.console.print(f"[dim]Using filter: {search_filter}[/dim]")
            
            self.ldap_conn.search(
                self.base_dn,
                search_filter,
                search_scope=SUBTREE,
                attributes=['cn', 'dNSHostName', 'name', 'sAMAccountName'],
                time_limit=30
            )
            
            computers = []
            for entry in self.ldap_conn.entries:
                self.console.print(f"[dim]Debug - Found computer:[/dim]")
                self.console.print(f"[dim]  CN: {entry.cn.value if hasattr(entry, 'cn') else 'N/A'}[/dim]")
                self.console.print(f"[dim]  DNS: {entry.dNSHostName.value if hasattr(entry, 'dNSHostName') else 'N/A'}[/dim]")
                self.console.print(f"[dim]  Name: {entry.name.value if hasattr(entry, 'name') else 'N/A'}[/dim]")
                self.console.print(f"[dim]  SAM: {entry.sAMAccountName.value if hasattr(entry, 'sAMAccountName') else 'N/A'}[/dim]")
                
                computer = {
                    'name': str(entry.cn.value) if hasattr(entry, 'cn') else 'N/A',
                    'hostname': str(entry.dNSHostName.value) if hasattr(entry, 'dNSHostName') else None
                }
                computers.append(computer)
            
            if not computers:
                # Try with $ suffix if not already present
                if not pattern.endswith('$'):
                    pattern_with_dollar = f"{pattern}$"
                    search_filter = f"(&(objectClass=computer)(|(name={pattern_with_dollar})(sAMAccountName={pattern_with_dollar})))"
                    self.console.print(f"[dim]Trying with $ suffix: {search_filter}[/dim]")
                    
                    self.ldap_conn.search(
                        self.base_dn,
                        search_filter,
                        search_scope=SUBTREE,
                        attributes=['cn', 'dNSHostName', 'name', 'sAMAccountName'],
                        time_limit=30
                    )
                    
                    for entry in self.ldap_conn.entries:
                        self.console.print(f"[dim]Debug - Found computer:[/dim]")
                        self.console.print(f"[dim]  CN: {entry.cn.value if hasattr(entry, 'cn') else 'N/A'}[/dim]")
                        self.console.print(f"[dim]  DNS: {entry.dNSHostName.value if hasattr(entry, 'dNSHostName') else 'N/A'}[/dim]")
                        self.console.print(f"[dim]  Name: {entry.name.value if hasattr(entry, 'name') else 'N/A'}[/dim]")
                        self.console.print(f"[dim]  SAM: {entry.sAMAccountName.value if hasattr(entry, 'sAMAccountName') else 'N/A'}[/dim]")
                        
                        computer = {
                            'name': str(entry.cn.value) if hasattr(entry, 'cn') else 'N/A',
                            'hostname': str(entry.dNSHostName.value) if hasattr(entry, 'dNSHostName') else None
                        }
                        computers.append(computer)
            
            # Sort computers by name
            computers.sort(key=lambda x: x['name'])
            
            if computers:
                self.console.print(f"[green]Found {len(computers)} matching computers[/green]")
            else:
                self.console.print("[yellow]No computers found. Try a different pattern.[/yellow]")
                self.console.print("Tips:")
                self.console.print("- Current search was for: " + pattern)
                self.console.print("- Try the computer name exactly as shown in Active Directory")
                self.console.print("- Try with and without the $ suffix")
                self.console.print(f"- Make sure the computer exists in: {self.base_dn}")
            
            return computers
            
        except Exception as e:
            self.console.print(f"[bold red]Error searching computers: {str(e)}[/bold red]")
            if "invalid server address" in str(e):
                self.console.print("[yellow]Connection may be lost. Try reconnecting.[/yellow]")
            return []

    def verify_hostname(self, hostname: str) -> bool:
        """Verify if a hostname exists in AD"""
        if not self.ensure_connected():
            self.console.print("[bold red]Not connected to AD server. Please reconnect.[/bold red]")
            return False
        
        try:
            # First try exact hostname
            computers = self.find_computers_by_pattern(hostname)
            if computers:
                computer = computers[0]
                self.current_target = computer
                return True
                
            # If that fails, try with $ suffix (common in AD)
            computers = self.find_computers_by_pattern(f"{hostname}$")
            if computers:
                computer = computers[0]
                self.current_target = computer
                return True
            
            return False
            
        except Exception as e:
            self.console.print(f"[bold red]Error verifying hostname: {str(e)}[/bold red]")
            return False

    def get_remote_credentials(self, computer_name: str) -> Dict:
        """Get credentials for remote command execution"""
        creds = {}
        
        use_different = Confirm.ask("Use different credentials for remote access?", default=False)
        if use_different:
            # Extract computer name without domain
            computer_base = computer_name.split('.')[0]
            
            # Get username, automatically add computer name as domain
            username = Prompt.ask("Enter username (without domain)")
            creds['username'] = f"{computer_base}\\{username}"
            
            # Get password
            creds['password'] = Prompt.ask("Enter password", password=True)
            
            self.console.print(f"[dim]Using credentials: {creds['username']}[/dim]")
        else:
            # Use AD credentials
            creds['username'] = self.domain_username
            creds['password'] = self.domain_password
            self.console.print("[dim]Using AD credentials[/dim]")
        
        return creds

    def resolve_computer_name(self, computer_name: str) -> str:
        """Resolve computer name to IP or FQDN"""
        try:
            # First try to get the DNS hostname from AD
            search_filter = f"(&(objectClass=computer)(|(name={computer_name})(sAMAccountName={computer_name})))"
            self.ldap_conn.search(
                self.base_dn,
                search_filter,
                search_scope=SUBTREE,
                attributes=['dNSHostName', 'name']
            )
            
            for entry in self.ldap_conn.entries:
                if hasattr(entry, 'dNSHostName') and entry.dNSHostName.value:
                    self.console.print(f"[dim]Found DNS hostname: {entry.dNSHostName.value}[/dim]")
                    return str(entry.dNSHostName.value)
                elif hasattr(entry, 'name'):
                    self.console.print(f"[dim]Using computer name: {entry.name.value}[/dim]")
                    return str(entry.name.value)
            
            # If we get here, just return the original name
            return computer_name
            
        except Exception as e:
            self.console.print(f"[yellow]Warning during name resolution: {str(e)}[/yellow]")
            return computer_name

    def run_command_on_computer(self, computer_name: str, command: str) -> bool:
        """Run a command on a remote computer through AD server using PowerShell remoting"""
        try:
            # Resolve the computer name first
            resolved_name = self.resolve_computer_name(computer_name)
            self.console.print(f"[dim]Attempting to connect to {resolved_name}...[/dim]")
            
            # Get credentials for remote access
            creds = self.get_remote_credentials(computer_name)
            
            try:
                # Create WinRM session to AD server
                self.console.print("[dim]Establishing connection through AD server...[/dim]")
                
                # Create a simple PowerShell command that directly invokes the command
                if creds['username'] != self.domain_username:
                    ps_script = f"""
                    $ErrorActionPreference = 'Continue'
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "{resolved_name}" -Force
                    $securePass = ConvertTo-SecureString "{creds['password']}" -AsPlainText -Force
                    $cred = New-Object System.Management.Automation.PSCredential("{creds['username']}", $securePass)
                    $opt = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
                    Invoke-Command -ComputerName {resolved_name} -Credential $cred -SessionOption $opt -Authentication Credssp -ScriptBlock {{ {command} }}
                    """
                else:
                    ps_script = f"""
                    $ErrorActionPreference = 'Continue'
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "{resolved_name}" -Force
                    $opt = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
                    Enable-WSManCredSSP -Role Client -DelegateComputer "{resolved_name}" -Force
                    Invoke-Command -ComputerName {resolved_name} -Authentication Credssp -SessionOption $opt -ScriptBlock {{ {command} }}
                    """
                
                # Create session to AD server
                session = winrm.Session(
                    self.conn_details['server'],  # AD server
                    auth=(self.domain_username, self.domain_password),
                    transport='ntlm',
                    server_cert_validation='ignore'
                )
                
                # Execute through AD server
                self.console.print(f"[dim]Executing command on {resolved_name} through AD server...[/dim]")
                result = session.run_ps(ps_script)
                
                # Print the output
                if result.status_code == 0:
                    self.console.print("[green]Command executed successfully[/green]")
                    if result.std_out:
                        self.console.print("[dim]Output:[/dim]")
                        self.console.print(result.std_out.decode('utf-8', errors='replace'))
                    return True
                else:
                    self.console.print("[red]Command failed[/red]")
                    if result.std_err:
                        error_output = result.std_err.decode('utf-8', errors='replace')
                        self.console.print("[dim]Error output:[/dim]")
                        self.console.print(error_output)
                        
                        if "CredSSP" in error_output:
                            self.console.print("\n[yellow]CredSSP Configuration Required:[/yellow]")
                            self.console.print("Run on target computer:")
                            self.console.print("1. Enable-PSRemoting -Force")
                            self.console.print("2. Enable-WSManCredSSP -Role Server -Force")
                            self.console.print("3. Set-Item WSMan:\\localhost\\Client\\TrustedHosts -Value '*' -Force")
                            self.console.print("\nRun on your computer:")
                            self.console.print("1. Enable-PSRemoting -Force")
                            self.console.print("2. Enable-WSManCredSSP -Role Client -DelegateComputer '*' -Force")
                            self.console.print("3. Set-Item WSMan:\\localhost\\Client\\TrustedHosts -Value '*' -Force")
                            self.console.print("\nThen enable in Group Policy:")
                            self.console.print("1. Computer Configuration > Administrative Templates > System > Credentials Delegation")
                            self.console.print("2. Enable 'Allow Delegating Fresh Credentials with NTLM-only Server Authentication'")
                            self.console.print("3. Add 'WSMAN/*' to the server list")
                    return False
                
            except Exception as e:
                error_msg = str(e)
                self.console.print(f"[bold red]Error: {error_msg}[/bold red]")
                return False
            
        except Exception as e:
            self.console.print(f"[bold red]Error running command on {computer_name}[/bold red]")
            self.console.print(f"[dim]Error details: {str(e)}[/dim]")
            return False

    def run_command_on_host(self):
        """Run command on a specific hostname"""
        while True:
            hostname = Prompt.ask("Enter hostname (or 'q' to quit)")
            if hostname.lower() == 'q':
                break
                
            if not self.verify_hostname(hostname):
                self.console.print("[yellow]Hostname not found in AD. Try again.[/yellow]")
                continue
            
            command = Prompt.ask("Enter command to run")
            if command.lower() == 'q':
                break
            
            self.run_command_on_computer(hostname, command)
        
    def run_command_on_ou(self):
        """Run command on computers in selected OU"""
        # Select OU
        ou_dn = self.select_ou()
        if not ou_dn:
            return
            
        # Get computers in OU
        computers = self.get_computers_in_ou(ou_dn)
        if not computers:
            self.console.print("[bold red]No computers found in selected OU[/bold red]")
            return
            
        # Get command to execute
        command = Prompt.ask("Enter command to execute")
        
        # Create results queue and threads list
        results_queue = queue.Queue()
        threads = []
        
        # Create and start threads for each computer
        for computer in computers:
            thread = threading.Thread(
                target=self.execute_remote_command,
                args=(computer, command, results_queue)
            )
            threads.append(thread)
            thread.start()
        
        # Show progress
        with self.console.status("[bold green]Executing command on computers...") as status:
            while any(t.is_alive() for t in threads):
                time.sleep(0.1)
        
        # Collect all results
        results = []
        while not results_queue.empty():
            results.append(results_queue.get())
        
        # Display results in table format
        table = Table(title=f"Command Execution Results: {command}")
        table.add_column("Computer", style="cyan")
        table.add_column("Status", style="green")
        table.add_column("Output", style="white")  # Removed wrap parameter
        
        for result in results:
            status_style = "green" if result['status'] == 'Success' else "red"
            output_text = result['output'][:200] + ('...' if len(result['output']) > 200 else '')
            table.add_row(
                result['computer'],
                f"[{status_style}]{result['status']}[/{status_style}]",
                output_text
            )
        
        self.console.print(table)
        
        # Export results to CSV
        results_df = pd.DataFrame(results)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"command_results_{timestamp}.csv"
        results_df.to_csv(filename, index=False)
        self.console.print(f"[bold green]Command execution results exported to {filename}[/bold green]")

    def run_command_by_pattern(self):
        """Run command on computers matching a pattern"""
        self.console.print("[bold cyan]Pattern Examples:[/bold cyan]")
        self.console.print("- DB-OP1-0** (matches all numbers starting with 0)")
        self.console.print("- DB-OP1-00* (matches all numbers starting with 00)")
        self.console.print("- DB-OP1-* (matches all numbers)")
        pattern = Prompt.ask("Enter computer name pattern")
        
        # Find matching computers
        self.console.print(f"[bold blue]Searching for computers matching pattern: {pattern}[/bold blue]")
        computers = self.find_computers_by_pattern(pattern)
        
        if not computers:
            self.console.print("[bold red]No computers found matching the pattern[/bold red]")
            return
            
        # Display found computers
        table = Table(title=f"Found Computers Matching '{pattern}'")
        table.add_column("Computer Name", style="cyan")
        table.add_column("DNS Hostname", style="green")
        
        for computer in computers:
            table.add_row(computer['name'], computer['hostname'] or 'N/A')
        
        self.console.print(table)
        
        # Confirm execution
        total = len(computers)
        if not Prompt.ask(
            f"Execute command on {total} computer{'s' if total > 1 else ''}?",
            choices=["y", "n"],
            default="n"
        ) == "y":
            return
            
        # Get command to execute
        command = Prompt.ask("Enter command to execute")
        
        # Create results queue and threads list
        results_queue = queue.Queue()
        threads = []
        
        # Create and start threads for each computer
        for computer in computers:
            thread = threading.Thread(
                target=self.execute_remote_command,
                args=(computer, command, results_queue)
            )
            threads.append(thread)
            thread.start()
        
        # Show progress
        with self.console.status(f"[bold green]Executing command on {total} computers...") as status:
            completed = 0
            while any(t.is_alive() for t in threads):
                new_completed = sum(1 for t in threads if not t.is_alive())
                if new_completed != completed:
                    completed = new_completed
                    self.console.print(f"Progress: {completed}/{total} computers completed")
                time.sleep(0.1)
        
        # Collect all results
        results = []
        while not results_queue.empty():
            results.append(results_queue.get())
        
        # Display results in table format
        table = Table(title=f"Command Execution Results: {command}")
        table.add_column("Computer", style="cyan")
        table.add_column("Status", style="green")
        table.add_column("Output", style="white")
        
        success_count = 0
        for result in results:
            status_style = "green" if result['status'] == 'Success' else "red"
            if result['status'] == 'Success':
                success_count += 1
                
            table.add_row(
                result['computer'],
                f"[{status_style}]{result['status']}[/{status_style}]",
                result['output'][:200] + ('...' if len(result['output']) > 200 else '')
            )
        
        self.console.print(table)
        self.console.print(f"[bold]Summary: {success_count}/{total} computers completed successfully[/bold]")
        
        # Export results to CSV
        results_df = pd.DataFrame(results)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"pattern_command_results_{timestamp}.csv"
        results_df.to_csv(filename, index=False)
        self.console.print(f"[bold green]Command execution results exported to {filename}[/bold green]")

def main():
    ad_manager = ADManager()
    
    # Get connection details and establish connection
    conn_details = ad_manager.get_connection_details()
    if not ad_manager.connect(conn_details):
        sys.exit(1)
    
    while True:
        rprint("\n[bold cyan]Available Operations:[/bold cyan]")
        rprint("1. Query Users and Export to CSV")
        rprint("2. Query Computers and Export to CSV")
        rprint("3. Test AD Connections")
        rprint("4. Run Command on OU")
        rprint("5. Run Command on Specific Host")
        rprint("6. Run Command by Pattern")
        rprint("7. Exit")
        
        choice = IntPrompt.ask("Select operation", choices=["1", "2", "3", "4", "5", "6", "7"])
        
        if choice == 1:
            df = ad_manager.query_users()
            ad_manager.export_to_csv(df, "users")
        elif choice == 2:
            df = ad_manager.query_computers()
            ad_manager.export_to_csv(df, "computers")
        elif choice == 3:
            ad_manager.test_connections()
        elif choice == 4:
            ad_manager.run_command_on_ou()
        elif choice == 5:
            ad_manager.run_command_on_host()
        elif choice == 6:
            ad_manager.run_command_by_pattern()
        elif choice == 7:
            rprint("[bold green]Goodbye![/bold green]")
            break

if __name__ == "__main__":
    main()
