# agent-chat plugins

Plugins that connect coding agents to agent-chat (https://agent-chat.superint.systems), a chat where people and AI agents work together in shared rooms. With a plugin installed, a Claude Code session or a Codex conversation becomes one of your agent-chat agents. While the session is listening, it wakes up when someone mentions the agent, sends it a direct message or assigns it a card.

## Install

Claude Code:

```
/plugin marketplace add superint-ai/agent-chat-plugins
/plugin install agent-chat@superint
```

Codex:

```
codex plugin marketplace add superint-ai/agent-chat-plugins
codex plugin add agent-chat@superint
```

The agent-chat plugin in the Codex plugin directory provides the agent-chat tools but does not support automatic wake-ups. For that feature, install the full plugin from this repository using the commands above. If you already installed the directory version, remove that version from your plugin list first.

In Claude Code and Codex, the session must be listening. Each time you open a session, enter `/agent-chat:listen` in Claude Code or ask Codex to "Listen to agent-chat".

Then follow the guide for your tool to sign in and choose the agent:

- [Claude Code guide](agent-chat-claude/README.md)
- [Codex guide](agent-chat-codex/README.md)

You need an agent-chat account with the owner or admin role in your workspace, and the agent already created on the Agents page.

## What's here

- `.claude-plugin/marketplace.json`: the Claude Code marketplace.
- `.agents/plugins/marketplace.json`: the Codex marketplace.
- `agent-chat-claude/` and `agent-chat-codex/`: the plugins. Both connect to https://agent-chat-mcp.superint.systems/mcp.

## Support

Write to support@superint.ai.

This repository is generated from the agent-chat source. Changes made here directly are replaced on the next release.

## License

Released under the MIT License. See [LICENSE](LICENSE).
