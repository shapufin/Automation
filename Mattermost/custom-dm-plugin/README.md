# Mattermost Custom DM Plugin

A Mattermost plugin to control Direct Message (DM) permissions based on user roles, email domains, and specific usernames.

## Features

- **Admin Only Mode**: Restrict DMs to admin users only
- **Email Domain Blocking**: Block users from specific email domains from sending DMs
- **User Exemptions**: Allow specific users to bypass restrictions
- **Admin Exemptions**: Option to let admins bypass email domain restrictions
- **Customizable Messages**: Set custom rejection messages

## Installation

1. Download the latest release from the releases page
2. Upload the plugin to your Mattermost instance:
   - Go to System Console > Plugins > Plugin Management
   - Upload the `custom-dm-plugin.tar.gz` file
   - Enable the plugin

## Configuration

### Plugin Settings

1. **Enable Plugin**: Turn the plugin on/off
2. **Admin Only Mode**: When enabled, only admins can send DMs
3. **Blocked Email Domains**: Comma-separated list of email domains to block (e.g., "domain1.com,domain2.com")
4. **Exempted Users**: Comma-separated list of usernames to exempt from restrictions
5. **Admins Exempt**: When enabled, admins can send DMs regardless of their email domain
6. **Rejection Message**: Custom message shown to users when they can't send DMs

### Managing Exempted Users

The plugin includes commands to manage exempted users more easily:

```bash
# Export current exempted users to a file
/custom-dm export-exempt

# Import exempted users from a file
/custom-dm import-exempt [filename]

# Add a single user to exempted list
/custom-dm exempt [username]

# Remove a single user from exempted list
/custom-dm unexempt [username]

# List all currently exempted users
/custom-dm list-exempt
```

## Examples

### Basic Setup

1. Block all DMs except for admins:
   ```
   Admin Only Mode: true
   ```

2. Block specific email domains:
   ```
   Admin Only Mode: false
   Blocked Email Domains: domain1.com,domain2.com
   ```

3. Allow specific users to bypass restrictions:
   ```
   Exempted Users: user1,user2,user3
   ```

### Export/Import Users

1. Export current exempted users:
   ```bash
   /custom-dm export-exempt
   # Creates exempt-users.txt with current list
   ```

2. Edit the exported file and import back:
   ```bash
   /custom-dm import-exempt exempt-users.txt
   ```

## Development

### Building the Plugin

1. Install Go 1.16 or higher
2. Run the build script:
   ```bash
   ./rebuild.ps1  # Windows
   ```

### Build and Upload Instructions

1. **Build the Plugin**:
   - Run the `build.ps1` script to compile the plugin.
   - This will generate a `custom-dm-plugin.tar.gz` file in the root directory.

2. **Upload to Mattermost**:
   - Log in to your Mattermost server as an administrator.
   - Navigate to **System Console > Plugins > Plugin Management**.
   - Click **Upload Plugin** and select the `custom-dm-plugin.tar.gz` file.
   - Enable the plugin after upload.

3. **Rebuild the Plugin**:
   - If you make changes to the plugin, run the `rebuild.ps1` script to recompile and regenerate the `.tar.gz` file.

### Testing

1. Build the plugin
2. Upload to your Mattermost instance
3. Configure the plugin settings
4. Test with different user types:
   - Admin users
   - Regular users with blocked domains
   - Regular users with unblocked domains
   - Exempted users

## Troubleshooting

1. **Plugin not working**:
   - Check if the plugin is enabled
   - Verify the configuration settings
   - Check system logs for errors

2. **Users not being blocked**:
   - Verify email domains are correctly formatted
   - Check if user is in exempted list
   - Verify if user is an admin and admin exemption is enabled

## Support

For issues and feature requests, please create an issue in the repository.
