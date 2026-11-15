# Zeron home plugins

Four signed plugins for Zeron:

| Plugin | What it shows |
| --- | --- |
| [Home activity](home-activity/) | Recent Zeron chats and GitHub account events, with links to each. |
| [Home greeting](home-greeting/) | A greeting that follows the time of day and your profile name. |
| [Commit graph](commit-graph/) | A calendar of commits in the selected project's checkout. |
| [Pi tokens per second](pi-tps/) | The rate of pi's last reply in a chat, in the composer's toolbar. |

## Install

In Zeron, open **Settings → Plugins → Install** and paste the link for each plugin you want:

- [Home activity](https://github.com/suryavamsi6/zeron-home-plugins/tree/main/home-activity)
- [Home greeting](https://github.com/suryavamsi6/zeron-home-plugins/tree/main/home-greeting)
- [Commit graph](https://github.com/suryavamsi6/zeron-home-plugins/tree/main/commit-graph)
- [Pi tokens per second](https://github.com/suryavamsi6/zeron-home-plugins/tree/main/pi-tps)

Git is required to install from a repository. Zeron verifies each plugin's signature and asks you to review its permissions. Approve the plugins you want in Zeron. Updates can be reviewed and installed from Settings → Plugins.

Home activity also needs the [GitHub CLI](https://cli.github.com/), signed in with `gh auth login`. It runs `gh` as your user and can show private GitHub events accessible to that account. Commit graph runs `git` on the device that hosts the selected project. Pi tokens per second runs `find`, `tail` and `jq` to read pi's own session files. Zeron's permissions screen describes the access requested by each plugin.

The plugins use Zeron's plugin API and the current layout. They may need an update if that layout changes in a future version of Zeron.
