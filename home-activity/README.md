# Home activity

Shows recent Zeron chats and GitHub account events on the new-chat screen. Select a chat or GitHub event to open it. GitHub is read through the `gh` account signed in on this device. Refreshes while the new-chat screen is visible, at most once every five minutes, or on request.

GitHub's events API returns recent events rather than a complete contribution history; availability of private events depends on the account's authorization. If GitHub is unavailable, the chat list remains usable. Zeron asks once before allowing the plugin's access to chat metadata, navigation, links, and the `gh` command.
