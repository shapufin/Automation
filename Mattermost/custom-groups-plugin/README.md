# Custom Groups Plugin for Mattermost

This plugin allows you to create and manage custom groups of users that can be tagged with @ mentions in Mattermost, similar to @all or @channel.

## Features

- Create custom groups of users
- Add/remove users from groups
- List all groups and group members
- Tag groups using @group-name in messages
- All group members will be notified when their group is mentioned
- Persistent storage (groups survive plugin restarts)
- Export group members to CSV
- Import group members from CSV

## Installation

1. Download the latest release
2. Go to System Console -> Plugin Management
3. Upload the plugin
4. Enable the plugin

## Usage

The plugin adds the following slash commands:

### Basic Group Management
- `/group create [group-name]` - Create a new group
- `/group add [group-name] [username]` - Add a user to a group
- `/group remove [group-name] [username]` - Remove a user from a group
- `/group list` - List all groups
- `/group list [group-name]` - List members of a specific group
- `/group delete [group-name]` - Delete a group

### Import/Export Features
- `/group export [group-name]` - Export group members to CSV
- `/group import [group-name] [csv-file]` - Import members from CSV file
  - CSV format should have one username per line
  - Example: `username1,username2,username3`

To mention a group in a message, simply use `@group-name` and all members of that group will be notified.

## Building

To build the plugin:

1. Make sure you have Go installed
2. Run `./build.ps1` on Windows
3. The plugin will be available in `./dist/custom-groups-plugin.tar.gz`

## Features in Detail

### Persistent Storage
- Groups and their members are now stored persistently using Mattermost's KV store
- Groups survive plugin deactivation/reactivation and server restarts
- No data loss when updating the plugin

### Special Mentions
- Groups appear in the special mentions category alongside @all and @channel
- Autocomplete suggestions show group members when typing @group-name
- Group mentions trigger notifications for all group members

### Import/Export
- Export feature creates a CSV file with all group members
- Import feature supports CSV files with usernames
- Validates usernames during import
- Skips already existing members during import

## Notes

- Groups are global across all teams and channels
- Invalid usernames are skipped during import
- Export files are created in the server's temporary directory

## Contributing

Feel free to submit issues and enhancement requests!
