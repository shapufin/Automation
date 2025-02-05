package main

import (
    "encoding/json"
    "fmt"
    "net/http"
    "strings"
    "sync"

    "github.com/mattermost/mattermost-server/v6/model"
    "github.com/mattermost/mattermost-server/v6/plugin"
)

type Plugin struct {
    plugin.MattermostPlugin
    groups     map[string][]string // map[groupName][]userIDs
    groupMutex sync.RWMutex
}

const (
    // Key for storing groups data in KV store
    groupsKey = "custom_groups"
)

func (p *Plugin) OnActivate() error {
    p.groups = make(map[string][]string)
    
    // Load existing groups from KV store
    data, err := p.API.KVGet(groupsKey)
    if err != nil {
        return err
    }
    
    if data != nil {
        if err := json.Unmarshal(data, &p.groups); err != nil {
            return err
        }
    }
    
    if err := p.API.RegisterCommand(&model.Command{
        Trigger:          "group",
        AutoComplete:     true,
        AutoCompleteDesc: "Manage user groups",
        AutoCompleteHint: "[create|add|list|delete|export|import] [group_name] [username]",
    }); err != nil {
        return err
    }

    return nil
}

// GetMentionKeywords returns the mention keywords for the plugin
func (p *Plugin) GetMentionKeywords() []string {
    p.groupMutex.RLock()
    defer p.groupMutex.RUnlock()

    keywords := make([]string, 0, len(p.groups))
    for groupName := range p.groups {
        keywords = append(keywords, "@"+groupName)
    }
    return keywords
}

// GetMentionsData returns the mention data for the plugin
func (p *Plugin) GetMentionsData(channelID string) []string {
    p.groupMutex.RLock()
    defer p.groupMutex.RUnlock()

    keywords := make([]string, 0, len(p.groups))
    for groupName := range p.groups {
        keywords = append(keywords, "@"+groupName)
    }
    return keywords
}

func (p *Plugin) ServeHTTP(c *plugin.Context, w http.ResponseWriter, r *http.Request) {
    switch r.URL.Path {
    case "/api/v4/groups":
        p.handleGroups(w, r)
    case "/api/v4/groups/members":
        p.handleGroupMembers(w, r)
    default:
        http.NotFound(w, r)
    }
}

func (p *Plugin) handleGroups(w http.ResponseWriter, r *http.Request) {
    switch r.Method {
    case http.MethodGet:
        p.getGroups(w, r)
    case http.MethodPost:
        p.createGroup(w, r)
    case http.MethodDelete:
        p.deleteGroup(w, r)
    default:
        http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
    }
}

func (p *Plugin) handleGroupMembers(w http.ResponseWriter, r *http.Request) {
    switch r.Method {
    case http.MethodPost:
        p.addGroupMember(w, r)
    case http.MethodDelete:
        p.removeGroupMember(w, r)
    default:
        http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
    }
}

func (p *Plugin) getGroups(w http.ResponseWriter, r *http.Request) {
    p.groupMutex.RLock()
    defer p.groupMutex.RUnlock()

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(p.groups)
}

func (p *Plugin) createGroup(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Name string   `json:"name"`
        Members []string `json:"members"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    p.groupMutex.Lock()
    defer p.groupMutex.Unlock()

    if _, exists := p.groups[req.Name]; exists {
        http.Error(w, "Group already exists", http.StatusBadRequest)
        return
    }

    p.groups[req.Name] = req.Members

    // Save to persistent storage
    if err := p.saveGroups(); err != nil {
        http.Error(w, "Failed to save group", http.StatusInternalServerError)
        return
    }

    w.WriteHeader(http.StatusCreated)
}

func (p *Plugin) deleteGroup(w http.ResponseWriter, r *http.Request) {
    groupName := r.URL.Query().Get("name")
    if groupName == "" {
        http.Error(w, "Group name is required", http.StatusBadRequest)
        return
    }

    p.groupMutex.Lock()
    defer p.groupMutex.Unlock()

    if _, exists := p.groups[groupName]; !exists {
        http.Error(w, "Group not found", http.StatusNotFound)
        return
    }

    delete(p.groups, groupName)

    // Save to persistent storage
    if err := p.saveGroups(); err != nil {
        http.Error(w, "Failed to save changes", http.StatusInternalServerError)
        return
    }

    w.WriteHeader(http.StatusOK)
}

func (p *Plugin) addGroupMember(w http.ResponseWriter, r *http.Request) {
    var req struct {
        GroupName string `json:"group_name"`
        UserID    string `json:"user_id"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    p.groupMutex.Lock()
    defer p.groupMutex.Unlock()

    members, exists := p.groups[req.GroupName]
    if !exists {
        http.Error(w, "Group not found", http.StatusNotFound)
        return
    }

    if contains(members, req.UserID) {
        http.Error(w, "User already in group", http.StatusBadRequest)
        return
    }

    p.groups[req.GroupName] = append(members, req.UserID)

    // Save to persistent storage
    if err := p.saveGroups(); err != nil {
        http.Error(w, "Failed to save changes", http.StatusInternalServerError)
        return
    }

    w.WriteHeader(http.StatusOK)
}

func (p *Plugin) removeGroupMember(w http.ResponseWriter, r *http.Request) {
    var req struct {
        GroupName string `json:"group_name"`
        UserID    string `json:"user_id"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    p.groupMutex.Lock()
    defer p.groupMutex.Unlock()

    members, exists := p.groups[req.GroupName]
    if !exists {
        http.Error(w, "Group not found", http.StatusNotFound)
        return
    }

    var newMembers []string
    for _, member := range members {
        if member != req.UserID {
            newMembers = append(newMembers, member)
        }
    }

    if len(newMembers) == len(members) {
        http.Error(w, "User not in group", http.StatusBadRequest)
        return
    }

    p.groups[req.GroupName] = newMembers

    // Save to persistent storage
    if err := p.saveGroups(); err != nil {
        http.Error(w, "Failed to save changes", http.StatusInternalServerError)
        return
    }

    w.WriteHeader(http.StatusOK)
}

func (p *Plugin) saveGroups() error {
    p.groupMutex.RLock()
    defer p.groupMutex.RUnlock()
    
    data, err := json.Marshal(p.groups)
    if err != nil {
        return err
    }
    
    if err := p.API.KVSet(groupsKey, data); err != nil {
        return err
    }
    
    return nil
}

func (p *Plugin) UserAutocompleteInChannel(c *plugin.Context, channelID string, teamID string, term string, limit int) ([]*model.User, *model.AppError) {
    if !strings.HasPrefix(term, "@") {
        return nil, nil
    }

    searchTerm := strings.TrimPrefix(term, "@")
    var suggestions []*model.User

    p.groupMutex.RLock()
    defer p.groupMutex.RUnlock()

    for groupName, members := range p.groups {
        if searchTerm == "" || strings.HasPrefix(strings.ToLower(groupName), strings.ToLower(searchTerm)) {
            // Get member usernames for display
            var memberNames []string
            for _, memberID := range members {
                if user, err := p.API.GetUser(memberID); err == nil {
                    memberNames = append(memberNames, "@"+user.Username)
                }
            }

            // Create a special user object for the group
            suggestion := &model.User{
                Username:    groupName,
                Id:         fmt.Sprintf("group_%s", groupName),
                Email:      fmt.Sprintf("%s@groups.local", groupName),
                FirstName:  "Group",
                LastName:   fmt.Sprintf("(%d members)", len(members)),
                Nickname:   strings.Join(memberNames, ", "),
                Position:   "Custom Group",
                Roles:      "custom_group",
            }
            suggestions = append(suggestions, suggestion)
        }
    }

    if len(suggestions) > limit {
        suggestions = suggestions[:limit]
    }

    return suggestions, nil
}

func (p *Plugin) MessageWillBePosted(c *plugin.Context, post *model.Post) (*model.Post, string) {
    p.groupMutex.RLock()
    defer p.groupMutex.RUnlock()

    if post.Props == nil {
        post.Props = make(model.StringInterface)
    }

    // Initialize mentions map
    mentions := map[string]interface{}{}
    if existingMentions, ok := post.Props["mentions"].(map[string]interface{}); ok {
        mentions = existingMentions
    }

    // Check for group mentions
    for groupName, members := range p.groups {
        mention := fmt.Sprintf("@%s", groupName)
        if strings.Contains(post.Message, mention) {
            // Add all group members to mentions
            for _, userID := range members {
                mentions[userID] = map[string]interface{}{
                    "type": "mention",
                    "group": groupName,
                    "group_mention": true,
                }
            }

            // Add special mention metadata
            post.Props["special_mention"] = true
            post.Props["system_mention"] = true
            post.Props["channel_mentions"] = true

            // Add group mention metadata
            if groupMentions, ok := post.Props["group_mentions"].([]interface{}); ok {
                post.Props["group_mentions"] = append(groupMentions, map[string]interface{}{
                    "group": groupName,
                    "members": members,
                })
            } else {
                post.Props["group_mentions"] = []interface{}{
                    map[string]interface{}{
                        "group": groupName,
                        "members": members,
                    },
                }
            }

            // Get member usernames for display
            var memberNames []string
            for _, memberID := range members {
                if user, err := p.API.GetUser(memberID); err == nil {
                    memberNames = append(memberNames, "@"+user.Username)
                }
            }

            // Update message with group indicator and members
            post.Message = strings.ReplaceAll(
                post.Message,
                mention,
                fmt.Sprintf("@%s (Group - %d members: %s)", 
                    groupName, 
                    len(members),
                    strings.Join(memberNames, ", "),
                ),
            )

            // Add special props for UI rendering
            post.Props["group_mention_highlight"] = true
            post.Props["override_icon_url"] = "https://www.mattermost.org/wp-content/uploads/2016/04/icon.png"
        }
    }

    // Update mentions in post props
    if len(mentions) > 0 {
        post.Props["mentions"] = mentions
    }

    return post, ""
}

func (p *Plugin) MessageHasBeenPosted(c *plugin.Context, post *model.Post) {
    p.groupMutex.RLock()
    defer p.groupMutex.RUnlock()

    // Get the post author's username
    postAuthor, err := p.API.GetUser(post.UserId)
    if err != nil {
        return
    }

    // Check if post has group mentions
    if groupMentions, ok := post.Props["group_mentions"].([]interface{}); ok {
        for _, mention := range groupMentions {
            if groupMention, ok := mention.(map[string]interface{}); ok {
                groupName, _ := groupMention["group"].(string)
                if members, ok := groupMention["members"].([]string); ok {
                    // Get member usernames for display
                    var memberNames []string
                    for _, memberID := range members {
                        if user, err := p.API.GetUser(memberID); err == nil {
                            memberNames = append(memberNames, "@"+user.Username)
                        }
                    }

                    // Send notifications to each member
                    for _, userID := range members {
                        // Skip if user is the post author
                        if userID == post.UserId {
                            continue
                        }

                        // Get the channel where the mention occurred
                        channel, err := p.API.GetChannel(post.ChannelId)
                        if err != nil {
                            continue
                        }

                        // Create mention notification
                        p.API.SendEphemeralPost(userID, &model.Post{
                            UserId:    post.UserId,
                            ChannelId: post.ChannelId,
                            Message: fmt.Sprintf("You were mentioned in group @%s by @%s in ~%s\nGroup members: %s", 
                                groupName,
                                postAuthor.Username,
                                channel.Name,
                                strings.Join(memberNames, ", "),
                            ),
                            Props: model.StringInterface{
                                "from_webhook": "true",
                                "override_username": "Group Mention",
                                "override_icon_url": "https://www.mattermost.org/wp-content/uploads/2016/04/icon.png",
                            },
                        })
                    }
                }
            }
        }
    }
}

func (p *Plugin) exportGroup(groupName string) ([]string, error) {
    p.groupMutex.RLock()
    defer p.groupMutex.RUnlock()

    members, exists := p.groups[groupName]
    if !exists {
        return nil, fmt.Errorf("group not found")
    }

    usernames := make([]string, 0, len(members))
    for _, memberID := range members {
        if user, err := p.API.GetUser(memberID); err == nil {
            usernames = append(usernames, user.Username)
        }
    }

    return usernames, nil
}

func (p *Plugin) importGroupMembers(groupName string, usernames []string) error {
    p.groupMutex.Lock()
    defer p.groupMutex.Unlock()

    members, exists := p.groups[groupName]
    if !exists {
        return fmt.Errorf("group not found")
    }

    existingMembers := make(map[string]bool)
    for _, memberID := range members {
        if user, err := p.API.GetUser(memberID); err == nil {
            existingMembers[user.Username] = true
        }
    }

    for _, username := range usernames {
        // Skip if user is already in group
        if existingMembers[username] {
            continue
        }

        // Get user by username
        user, appErr := p.API.GetUserByUsername(username)
        if appErr != nil {
            continue // Skip invalid usernames
        }

        members = append(members, user.Id)
    }

    p.groups[groupName] = members
    return p.saveGroups()
}

func (p *Plugin) ExecuteCommand(c *plugin.Context, args *model.CommandArgs) (*model.CommandResponse, *model.AppError) {
    split := strings.Fields(args.Command)
    if len(split) < 2 {
        return &model.CommandResponse{
            Text: "Available commands: create, add, remove, list, delete, export, import",
            ResponseType: model.CommandResponseTypeEphemeral,
        }, nil
    }

    command := split[1]
    switch command {
    case "create":
        if len(split) < 3 {
            return &model.CommandResponse{
                Text: "Please specify a group name: `/group create group_name`",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        groupName := split[2]
        
        p.groupMutex.Lock()
        if _, exists := p.groups[groupName]; exists {
            p.groupMutex.Unlock()
            return &model.CommandResponse{
                Text: fmt.Sprintf("Group %s already exists", groupName),
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        p.groups[groupName] = []string{}
        p.groupMutex.Unlock()
        
        // Save to persistent storage
        if err := p.saveGroups(); err != nil {
            return &model.CommandResponse{
                Text: "Failed to save group",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        
        return &model.CommandResponse{
            Text: fmt.Sprintf("Created group %s", groupName),
            ResponseType: model.CommandResponseTypeEphemeral,
        }, nil
        
    case "add":
        if len(split) < 4 {
            return &model.CommandResponse{
                Text: "Please specify a group name and username: `/group add group_name @username`",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        groupName := split[2]
        username := strings.TrimPrefix(split[3], "@")
        
        // Get user by username
        user, appErr := p.API.GetUserByUsername(username)
        if appErr != nil {
            return &model.CommandResponse{
                Text: fmt.Sprintf("User %s not found", username),
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        
        p.groupMutex.Lock()
        members, exists := p.groups[groupName]
        if !exists {
            p.groupMutex.Unlock()
            return &model.CommandResponse{
                Text: fmt.Sprintf("Group %s does not exist", groupName),
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        
        // Check if user is already in group
        for _, member := range members {
            if member == user.Id {
                p.groupMutex.Unlock()
                return &model.CommandResponse{
                    Text: fmt.Sprintf("User %s is already in group %s", username, groupName),
                    ResponseType: model.CommandResponseTypeEphemeral,
                }, nil
            }
        }
        
        p.groups[groupName] = append(members, user.Id)
        p.groupMutex.Unlock()
        
        // Save to persistent storage
        if err := p.saveGroups(); err != nil {
            return &model.CommandResponse{
                Text: "Failed to save changes",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        
        return &model.CommandResponse{
            Text: fmt.Sprintf("Added %s to group %s", username, groupName),
            ResponseType: model.CommandResponseTypeEphemeral,
        }, nil
        
    case "list":
        p.groupMutex.RLock()
        defer p.groupMutex.RUnlock()
        
        if len(p.groups) == 0 {
            return &model.CommandResponse{
                Text: "No groups exist",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        
        var text strings.Builder
        text.WriteString("Available groups:\n")
        
        for groupName, members := range p.groups {
            text.WriteString(fmt.Sprintf("\n**%s** (%d members):\n", groupName, len(members)))
            for _, userID := range members {
                user, err := p.API.GetUser(userID)
                if err == nil {
                    text.WriteString(fmt.Sprintf("- @%s\n", user.Username))
                }
            }
        }
        
        return &model.CommandResponse{
            Text: text.String(),
            ResponseType: model.CommandResponseTypeEphemeral,
        }, nil
        
    case "delete":
        if len(split) < 3 {
            return &model.CommandResponse{
                Text: "Please specify a group name: `/group delete group_name`",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        groupName := split[2]
        
        p.groupMutex.Lock()
        if _, exists := p.groups[groupName]; !exists {
            p.groupMutex.Unlock()
            return &model.CommandResponse{
                Text: fmt.Sprintf("Group %s does not exist", groupName),
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        
        delete(p.groups, groupName)
        p.groupMutex.Unlock()
        
        // Save to persistent storage
        if err := p.saveGroups(); err != nil {
            return &model.CommandResponse{
                Text: "Failed to save changes",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }
        
        return &model.CommandResponse{
            Text: fmt.Sprintf("Deleted group %s", groupName),
            ResponseType: model.CommandResponseTypeEphemeral,
        }, nil
        
    case "export":
        if len(split) != 3 {
            return &model.CommandResponse{
                Text: "Please specify a group name: /group export [group-name]",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }

        groupName := split[2]
        usernames, err := p.exportGroup(groupName)
        if err != nil {
            return &model.CommandResponse{
                Text: fmt.Sprintf("Error exporting group: %v", err),
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }

        csv := strings.Join(usernames, ",")
        return &model.CommandResponse{
            Text: fmt.Sprintf("Group members for %s:\n```\n%s\n```\nCopy this list to import into another group.", groupName, csv),
            ResponseType: model.CommandResponseTypeEphemeral,
        }, nil

    case "import":
        if len(split) < 4 {
            return &model.CommandResponse{
                Text: "Please specify a group name and CSV data: /group import [group-name] [username1,username2,...]",
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }

        groupName := split[2]
        csvData := strings.Join(split[3:], " ")
        usernames := strings.Split(csvData, ",")

        // Trim spaces from usernames
        for i, username := range usernames {
            usernames[i] = strings.TrimSpace(username)
        }

        if err := p.importGroupMembers(groupName, usernames); err != nil {
            return &model.CommandResponse{
                Text: fmt.Sprintf("Error importing members: %v", err),
                ResponseType: model.CommandResponseTypeEphemeral,
            }, nil
        }

        return &model.CommandResponse{
            Text: fmt.Sprintf("Successfully imported members into group %s", groupName),
            ResponseType: model.CommandResponseTypeEphemeral,
        }, nil

    default:
        return &model.CommandResponse{
            Text: "Unknown command. Available commands: create, add, remove, list, delete, export, import",
            ResponseType: model.CommandResponseTypeEphemeral,
        }, nil
    }
}

func contains(slice []string, item string) bool {
    for _, s := range slice {
        if s == item {
            return true
        }
    }
    return false
}

func main() {
    plugin.ClientMain(&Plugin{})
}
