# Custom Groups Plugin

## Build and Upload Instructions

1. **Build the Plugin**:
   - Run the `build.ps1` script to compile the plugin.
   - This will generate a `custom-groups-plugin.tar.gz` file in the root directory.

2. **Upload to Mattermost**:
   - Log in to your Mattermost server as an administrator.
   - Navigate to **System Console > Plugins > Plugin Management**.
   - Click **Upload Plugin** and select the `custom-groups-plugin.tar.gz` file.
   - Enable the plugin after upload.

3. **Rebuild the Plugin**:
   - If you make changes to the plugin, run the `rebuild.ps1` script to recompile and regenerate the `.tar.gz` file.
