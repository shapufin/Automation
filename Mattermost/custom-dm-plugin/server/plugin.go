package main

import (
    "fmt"
    "io/ioutil"
    "strings"
    "github.com/mattermost/mattermost-server/v6/model"
    "github.com/mattermost/mattermost-server/v6/plugin"
    "github.com/pkg/errors"
    
    "github.com/mattermost/mattermost-plugin-custom-dm/server/config"
)

type Plugin struct {
    plugin.MattermostPlugin
}

func (p *Plugin) OnActivate() error {
    config.Mattermost = p.API

    if err := p.OnConfigurationChange(); err != nil {
        return err
    }

    return nil
}

func (p *Plugin) ExecuteCommand(c *plugin.Context, args *model.CommandArgs) (*model.CommandResponse, *model.AppError) {
    split := strings.Fields(args.Command)
    command := split[0]
    parameters := []string{}
    if len(split) > 1 {
        parameters = split[1:]
    }

    if command != "/custom-dm" {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        fmt.Sprintf("Unknown command: %s", command),
        }, nil
    }

    if len(parameters) == 0 {
        return p.helpCommand(), nil
    }

    isAdmin := false
    teams, err := p.API.GetTeamsForUser(args.UserId)
    if err != nil {
        return nil, model.NewAppError("ExecuteCommand", "Failed to get teams", nil, err.Error(), 500)
    }

    for _, team := range teams {
        member, err := p.API.GetTeamMember(team.Id, args.UserId)
        if err != nil {
            continue
        }
        if member.SchemeAdmin {
            isAdmin = true
            break
        }
    }

    if !isAdmin {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        "Only administrators can use these commands.",
        }, nil
    }

    switch parameters[0] {
    case "help":
        return p.helpCommand(), nil
    case "export-exempt":
        return p.exportExemptCommand(), nil
    case "import-exempt":
        if len(parameters) < 2 {
            return &model.CommandResponse{
                ResponseType: model.CommandResponseTypeEphemeral,
                Text:        "Please provide a filename to import from.",
            }, nil
        }
        return p.importExemptCommand(parameters[1]), nil
    case "exempt":
        if len(parameters) < 2 {
            return &model.CommandResponse{
                ResponseType: model.CommandResponseTypeEphemeral,
                Text:        "Please provide a username to exempt.",
            }, nil
        }
        return p.exemptUserCommand(parameters[1]), nil
    case "unexempt":
        if len(parameters) < 2 {
            return &model.CommandResponse{
                ResponseType: model.CommandResponseTypeEphemeral,
                Text:        "Please provide a username to unexempt.",
            }, nil
        }
        return p.unexemptUserCommand(parameters[1]), nil
    case "list-exempt":
        return p.listExemptCommand(), nil
    default:
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        fmt.Sprintf("Unknown subcommand: %s. Use '/custom-dm help' for usage.", parameters[0]),
        }, nil
    }
}

func (p *Plugin) helpCommand() *model.CommandResponse {
    text := `Custom DM Plugin Commands:
* /custom-dm help - Show this help text
* /custom-dm export-exempt - Export current exempted users to exempt-users.txt
* /custom-dm import-exempt [filename] - Import exempted users from a file
* /custom-dm exempt [username] - Add a user to exempted list
* /custom-dm unexempt [username] - Remove a user from exempted list
* /custom-dm list-exempt - List all currently exempted users

Note: Only administrators can use these commands.`

    return &model.CommandResponse{
        ResponseType: model.CommandResponseTypeEphemeral,
        Text:        text,
    }
}

func (p *Plugin) exportExemptCommand() *model.CommandResponse {
    conf := config.GetConfig()
    filename := "exempt-users.txt"
    
    err := ioutil.WriteFile(filename, []byte(conf.ExemptedUsers), 0644)
    if err != nil {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        fmt.Sprintf("Failed to export users: %v", err),
        }
    }

    return &model.CommandResponse{
        ResponseType: model.CommandResponseTypeEphemeral,
        Text:        fmt.Sprintf("Exempted users exported to %s", filename),
    }
}

func (p *Plugin) importExemptCommand(filename string) *model.CommandResponse {
    data, err := ioutil.ReadFile(filename)
    if err != nil {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        fmt.Sprintf("Failed to read file: %v", err),
        }
    }

    conf := config.GetConfig()
    conf.ExemptedUsers = string(data)

    if err := p.API.SavePluginConfig(conf.ToMap()); err != nil {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        fmt.Sprintf("Failed to save configuration: %v", err),
        }
    }

    return &model.CommandResponse{
        ResponseType: model.CommandResponseTypeEphemeral,
        Text:        "Exempted users imported successfully.",
    }
}

func (p *Plugin) exemptUserCommand(username string) *model.CommandResponse {
    conf := config.GetConfig()
    users := strings.Split(conf.ExemptedUsers, ",")
    
    // Check if user already exists
    for _, user := range users {
        if strings.EqualFold(strings.TrimSpace(user), username) {
            return &model.CommandResponse{
                ResponseType: model.CommandResponseTypeEphemeral,
                Text:        fmt.Sprintf("User %s is already exempted.", username),
            }
        }
    }

    // Add the new user
    if conf.ExemptedUsers == "" {
        conf.ExemptedUsers = username
    } else {
        conf.ExemptedUsers += "," + username
    }

    if err := p.API.SavePluginConfig(conf.ToMap()); err != nil {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        fmt.Sprintf("Failed to save configuration: %v", err),
        }
    }

    return &model.CommandResponse{
        ResponseType: model.CommandResponseTypeEphemeral,
        Text:        fmt.Sprintf("User %s added to exempted list.", username),
    }
}

func (p *Plugin) unexemptUserCommand(username string) *model.CommandResponse {
    conf := config.GetConfig()
    users := strings.Split(conf.ExemptedUsers, ",")
    newUsers := []string{}
    found := false

    for _, user := range users {
        user = strings.TrimSpace(user)
        if !strings.EqualFold(user, username) && user != "" {
            newUsers = append(newUsers, user)
        } else {
            found = true
        }
    }

    if !found {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        fmt.Sprintf("User %s is not in the exempted list.", username),
        }
    }

    conf.ExemptedUsers = strings.Join(newUsers, ",")

    if err := p.API.SavePluginConfig(conf.ToMap()); err != nil {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        fmt.Sprintf("Failed to save configuration: %v", err),
        }
    }

    return &model.CommandResponse{
        ResponseType: model.CommandResponseTypeEphemeral,
        Text:        fmt.Sprintf("User %s removed from exempted list.", username),
    }
}

func (p *Plugin) listExemptCommand() *model.CommandResponse {
    conf := config.GetConfig()
    if conf.ExemptedUsers == "" {
        return &model.CommandResponse{
            ResponseType: model.CommandResponseTypeEphemeral,
            Text:        "No users are currently exempted.",
        }
    }

    users := strings.Split(conf.ExemptedUsers, ",")
    text := "Currently exempted users:\n"
    for _, user := range users {
        user = strings.TrimSpace(user)
        if user != "" {
            text += fmt.Sprintf("* %s\n", user)
        }
    }

    return &model.CommandResponse{
        ResponseType: model.CommandResponseTypeEphemeral,
        Text:        text,
    }
}

func (p *Plugin) OnConfigurationChange() error {
    if config.Mattermost != nil {
        var configuration config.Configuration

        if err := config.Mattermost.LoadPluginConfiguration(&configuration); err != nil {
            config.Mattermost.LogError("Error in LoadPluginConfiguration: " + err.Error())
            return errors.Wrap(err, "failed to load plugin configuration")
        }

        if err := configuration.ProcessConfiguration(); err != nil {
            config.Mattermost.LogError("Error in ProcessConfiguration: " + err.Error())
            return errors.Wrap(err, "failed to process configuration")
        }

        if err := configuration.IsValid(); err != nil {
            config.Mattermost.LogError("Error in Validating Configuration: " + err.Error())
            return errors.Wrap(err, "configuration is invalid")
        }

        config.SetConfig(&configuration)
    }
    return nil
}

func (p *Plugin) isEmailDomainBlocked(email string) bool {
    conf := config.GetConfig()
    if conf.BlockedDomains == "" {
        return false
    }

    domains := strings.Split(conf.BlockedDomains, ",")
    for _, domain := range domains {
        domain = strings.TrimSpace(domain)
        if domain != "" && strings.HasSuffix(strings.ToLower(email), strings.ToLower(domain)) {
            return true
        }
    }
    return false
}

func (p *Plugin) isUserExempted(username string) bool {
    conf := config.GetConfig()
    if conf.ExemptedUsers == "" {
        return false
    }

    users := strings.Split(conf.ExemptedUsers, ",")
    for _, user := range users {
        user = strings.TrimSpace(user)
        if user != "" && strings.EqualFold(username, user) {
            return true
        }
    }
    return false
}

func (p *Plugin) MessageWillBePosted(c *plugin.Context, post *model.Post) (*model.Post, string) {
    conf := config.GetConfig()
    if !conf.Enabled {
        return nil, ""
    }

    channel, err := p.API.GetChannel(post.ChannelId)
    if err != nil {
        p.API.LogError("Failed to get channel", "error", err.Error())
        return nil, ""
    }

    if channel.Type != model.ChannelTypeDirect && channel.Type != model.ChannelTypeGroup {
        return nil, ""
    }

    user, err := p.API.GetUser(post.UserId)
    if err != nil {
        p.API.LogError("Failed to get user", "error", err.Error())
        return nil, ""
    }

    // Check if user is in the exempted list
    if p.isUserExempted(user.Username) {
        return nil, ""
    }

    isAdmin := false
    teams, err := p.API.GetTeamsForUser(user.Id)
    if err != nil {
        p.API.LogError("Failed to get teams", "error", err.Error())
        return nil, ""
    }

    for _, team := range teams {
        member, err := p.API.GetTeamMember(team.Id, user.Id)
        if err != nil {
            continue
        }
        if member.SchemeAdmin {
            isAdmin = true
            break
        }
    }

    // If user is admin and admins are exempt, allow the message
    if isAdmin && conf.AdminsExempt {
        return nil, ""
    }

    // In AdminOnly mode, only admins can send DMs
    if conf.AdminOnly && !isAdmin {
        p.API.SendEphemeralPost(post.UserId, &model.Post{
            ChannelId: post.ChannelId,
            Message:   conf.RejectionMessage,
        })
        return nil, conf.RejectionMessage
    }

    // If not in AdminOnly mode, check if the user's email domain is blocked
    if !conf.AdminOnly && p.isEmailDomainBlocked(user.Email) {
        p.API.SendEphemeralPost(post.UserId, &model.Post{
            ChannelId: post.ChannelId,
            Message:   conf.RejectionMessage,
        })
        return nil, conf.RejectionMessage
    }

    return nil, ""
}

func main() {
    plugin.ClientMain(&Plugin{})
}
