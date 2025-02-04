package config

import (
    "strings"

    "github.com/mattermost/mattermost-server/v6/plugin"
    "github.com/pkg/errors"
)

type Configuration struct {
    Enabled          bool
    BlockedDomains   string
    AdminsExempt     bool
    AdminOnly        bool   // If true, only admins can send DMs. If false, anyone not in BlockedDomains can send DMs.
    ExemptedUsers    string // Comma-separated list of usernames to exempt from restrictions (e.g., user1,user2)
    RejectionMessage string
}

var Mattermost plugin.API
var configuration *Configuration

func GetConfig() *Configuration {
    return configuration
}

func SetConfig(config *Configuration) {
    configuration = config
}

func (c *Configuration) ProcessConfiguration() error {
    c.BlockedDomains = strings.TrimSpace(c.BlockedDomains)
    c.ExemptedUsers = strings.TrimSpace(c.ExemptedUsers)
    c.RejectionMessage = strings.TrimSpace(c.RejectionMessage)

    if c.RejectionMessage == "" {
        c.RejectionMessage = "You are not allowed to send direct messages."
    }

    return nil
}

func (c *Configuration) IsValid() error {
    if c.BlockedDomains == "" && !c.AdminOnly {
        return errors.New("either blocked domains must be specified or admin only mode must be enabled")
    }

    return nil
}

func (c *Configuration) ToMap() map[string]interface{} {
    return map[string]interface{}{
        "enabled":          c.Enabled,
        "blockedDomains":   c.BlockedDomains,
        "adminsExempt":     c.AdminsExempt,
        "adminOnly":        c.AdminOnly,
        "exemptedUsers":    c.ExemptedUsers,
        "rejectionMessage": c.RejectionMessage,
    }
}
