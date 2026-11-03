# dotfiles

Keychain-backed, iCloud-synced macOS dotfiles.

> [!IMPORTANT]
> This is a personal setup. Fork it freely, but expect macOS-only assumptions and opinionated defaults.

## Features

- 🪨 **Foundation:** Links dotfiles with [chezmoi](https://chezmoi.io) in symlink mode and renders templates at apply time.
- 🔐 **Keychain secrets:** Stores every secret in a dedicated macOS keychain, backed up to iCloud Drive.
- ☁️ **iCloud sync:** Shares SSH, GPG, kubeconfig, and `config.toml` across Macs.
- 🌱 **Auto-activating runtimes:** Switches Node, Python, Ruby, and Java to the pinned version on `cd`.
- ⚡ **Fast startup:** Caches completions and plugins, and runs the mise, brew, and plugin checks once a day.
- 🧠 **Agent Skills:** Declares 400+ skills in one file for Claude Code, Codex, Copilot, and Gemini.
- 🛠️ **Shell toolkit:** Adds 70+ functions for Docker, secrets, toolchains, and Git, plus 125+ aliases.
- ♻️ **Idempotent bootstrap:** Sets up Homebrew, packages, tools, and secrets, and is safe to re-run.

## 📋 Prerequisites

> [!CAUTION]
> Turn on [Advanced Data Protection](https://support.apple.com/en-us/108756) before you bootstrap. Without it, Apple can decrypt everything this setup stores on iCloud Drive, including your SSH and GPG keys and the tokens file that holds every managed secret.

- macOS with Xcode Command Line Tools (`xcode-select --install`)
- [chezmoi](https://chezmoi.io/install/) (`sh -c "$(curl -fsLS get.chezmoi.io)"`)
- iCloud Drive signed in (for keys, config, and the tokens file)
- The App Store signed in (the Brewfile installs App Store apps through `mas`)

## 🚀 Quick Start

Clone over HTTPS, because your SSH keys only arrive once chezmoi links `~/.ssh`:

```bash
git clone https://github.com/JonathanXDR/Dotfiles.git ~/Developer/Git/GitHub/Dotfiles

chezmoi init --source ~/Developer/Git/GitHub/Dotfiles --apply
```

`chezmoi init` asks for your email, name, and GPG key, then an optional keychain password. Every answer except the keychain password comes from `config.toml` on iCloud Drive when that file has the key. Your answers are cached, so later runs stay quiet.

From there, chezmoi does the rest:

1. Installs Homebrew if it is missing, asking for your password once
2. Imports your tokens from iCloud Drive into the `dotfiles` keychain
3. Links `~/.ssh`, `~/.gnupg`, and `~/.kube` to their iCloud Drive copies, and the shell config into `$HOME`
4. Installs everything in the Brewfile
5. Installs language runtimes and global CLI packages with mise
6. Installs `/etc/hosts` from `dot_config/hosts`, asking for your password whenever it changes
7. Downloads the declared Agent Skills and links them into every agent that needs a link

Finish by starting daily Homebrew upgrades, which the setup counts on to keep mise current:

```bash
brew autoupdate start --upgrade --sudo
```

## 🧪 Usage

Three chezmoi commands cover most changes:

```bash
chezmoi apply          # Apply changes to $HOME
chezmoi diff           # Preview what would change
chezmoi edit ~/.zshrc  # Edit through chezmoi (or open the file directly)
```

In symlink mode, `~/.zshrc` and the other dotfiles point straight at this repo, so editing them in `$HOME` edits the source. The `chezmoi edit` command is there out of habit, not because you need it.

Shortcut aliases:

| Alias    | Command                   |
| -------- | ------------------------- |
| `es`     | `chezmoi edit ~/.zshrc`   |
| `ev`     | `chezmoi edit ~/.exports` |
| `reload` | `exec $SHELL -l`          |

## 🔐 Managing Secrets

Secrets live in a dedicated **`dotfiles` keychain**, separate from `login` and with its own entry in the Keychain Access sidebar. The keychain is the source of truth, and the tokens file on iCloud Drive mirrors it so a fresh machine has something to import from.

The first `chezmoi apply` creates the keychain, and `run_before_00-unlock-keychain` unlocks it once per run, so every template that reads a secret renders in one pass without prompting you again. The keychain locks on system sleep and has no idle timeout (`security set-keychain-settings -l`).

The `secret:` functions act on a single entry, while the `secrets:` functions act on the whole set:

```bash
secret:set <id> <account> <where> <kind> [comment]   # Add a new entry (prompts for password)
secret:get <id> <account>                            # Read raw value to stdout
secret:copy <id> <account>                           # Copy to clipboard, auto-clears in 30s
secret:rename <old_id> <old_account> <new_id> <new_account> [new_where] [new_kind] [new_comment]
                                                     # Move/relabel atomically
secret:remove <id> <account>                         # Remove from keychain + iCloud
secrets:list                                         # Sorted table of all keychain entries
secrets:import                                       # Import tokens-file entries missing from the keychain, report drift
secrets:export                                       # Rewrite the tokens file from the keychain (auto-runs on apply)
```

Each entry uses five native Keychain Access fields, and the `(id, account)` pair is its unique lookup key. The `id` argument fills the Label (Name) field and the URL goes into Service (Where), which keeps URLs out of committed templates:

| Field        | Holds                                                    |
| ------------ | -------------------------------------------------------- |
| **Where**    | URL of the provider (Service, kept out of the repo)      |
| **Account**  | Identity at that provider                                |
| **Name**     | Friendly identifier (the `<id>` arg, default lookup key) |
| **Kind**     | Secret type (e.g. Personal Access Token)                 |
| **Comments** | Consumer (what reads this secret)                        |

Run `secrets:list` to see what the keychain holds. It prints the metadata for every entry and never the secrets themselves.

macOS stores generic passwords under `(Where, Account)`, so two entries cannot share that pair even when their names differ. `secret:set` and `secret:rename` refuse such a collision rather than overwrite the entry that already holds it, and `secrets:list` shows the other entry.

**Configuration** (`.chezmoidata.toml`):

| Key                     | Default      | Purpose                                                                                                                         |
| ----------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `keychain_name`         | `"dotfiles"` | Name of the keychain file (`~/Library/Keychains/<name>.keychain-db`)                                                            |
| `keychain_lookup_field` | `"name"`     | Which field templates and the `secret:*` functions match on (only `name` works today, see [ARCHITECTURE.md](./ARCHITECTURE.md)) |

You can also give the keychain a **master password** during `chezmoi init`. It is cached in the machine-local `~/.config/chezmoi/chezmoi.toml` and never committed. Leave it empty (the default) and the keychain follows your login session's unlock state instead.

> [!CAUTION]
> Managed entries are created with the `-A` flag, so any process running as your user can read them without a confirmation prompt. The chezmoi templates need this to render at apply time. The usual protections still matter here: FileVault, screen auto-lock, a strong account password, and two-factor authentication on your Apple ID.

## 🧠 Agent Skills

[Agent Skills](https://agentskills.io/specification) are `SKILL.md` directories an AI coding agent loads on demand. Every skill this machine should have is listed in [`.chezmoidata/skills.toml`](./.chezmoidata/skills.toml), together with where it comes from. That file is the only place the set is decided.

Each entry names one source:

```toml
[agent_skills.tdd]                       # a directory in a public repository
repo = "mattpocock/skills"
path = "skills/engineering/tdd"

[agent_skills.heroui-react-pro]          # a licensed tarball, its token read from the keychain
url = "https://docs.heroui.pro/docs/skills/heroui-react-pro.tar.gz"
token = "HeroUI Pro"
account = "you"
header = "x-heroui-personal-token"

[agent_skills.some-private-skill]        # a private repository, cloned over SSH
git = "git@github.com:you/some-private-skill.git"
```

`chezmoi apply` keeps one shallow, sparse git clone per source repository in `~/.local/share/agent-skills`, holding only the declared skill folders, and links each skill from there into `~/.agents/skills`. Any apply updates the clones fetched more than a week ago, so skills stay current with nothing copied by hand. No skill contents are committed here, except a skill this repository owns, which goes in `dot_agents/skills/<name>/` and is symlinked into the same directory.

| Task                                   | Do this                                                                                        |
| -------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Add a skill                            | Add an entry, run `chezmoi apply`                                                              |
| Remove a skill                         | Delete its entry, run `chezmoi apply`                                                          |
| Update every skill                     | Nothing. Any apply updates what is due, `AGENT_SKILLS_REFRESH=1 chezmoi apply` updates all now |
| Add a repo-owned skill                 | Drop the directory in `dot_agents/skills/<name>/`, run `chezmoi apply`                         |
| Support another agent                  | Add its skills directory to `agent_skills_link_dirs`, if it needs one at all                   |
| Follow everything one person publishes | Add them to `agent_skill_owners`, run `skills:sync`, commit the diff                           |

OpenAI Codex, GitHub Copilot CLI, and Gemini CLI read `~/.agents/skills` natively. Claude Code reads only `~/.claude/skills`, so it gets one symlink per skill. A skill that needs a license key names a keychain entry instead of carrying the key, so nothing licensed and nothing secret is committed.

When an upstream repository disappears or moves its skill, the apply still installs everything else, and every apply prints the skill and the source it could not reach until the entry is fixed:

```text
Error:   Failed to install the some-skill skill from someone/their-repo (skills/some-skill)
Info:    Fix or drop each entry above in .chezmoidata/skills.toml, or run skills:sync if it comes from a watched owner
```

See [ARCHITECTURE.md](./ARCHITECTURE.md#agent-skills) for the full picture.

## 🐚 Shell Loading Order

Every new terminal runs these files and hooks in this order:

```text
~/.zshenv ───────── mise shims, locale (every zsh, including non-interactive)
        │
/etc/zprofile ───── macOS path_helper rebuilds PATH (login shells only)
        │
~/.zprofile ─────── Restores the mise shims to the front of PATH
        │
~/.exports ──────── Env vars, history, zsh options
        │
~/.functions ────── Utility functions
        │
PATH setup ──────── Homebrew first, then tool paths, then mise activation (last)
        │
plugins:load ────── Oh My Zsh plugins, compiled by antidote from ~/.plugins
        │
~/.aliases ──────── Command aliases (override the bundle where the two collide)
        │
~/.completions ──── Completions, zsh plugins, autosuggestions, syntax highlighting
        │
Runtime hooks ───── SSH agent, runaway alerts, daily mise, brew, and plugin checks
```

Homebrew runs before the tool paths because `brew shellenv` prepends its own `bin` and `sbin`, and the tool paths have to land in front of them.

## 📦 Project Structure

The source maps onto `$HOME` like this:

```text
├── .chezmoi.toml.tmpl                       # User config (iCloud config.toml or prompts)
├── .chezmoidata.toml                        # Shared non-secret defaults
├── .chezmoidata/                            # Agent Skills inventory, Zed extension list
├── .chezmoiignore                           # Files excluded from $HOME
├── .chezmoitemplates/                       # Reusable templates: keychain lookup, shell helpers
├── .chezmoiscripts/                         # Numbered run scripts (run_before_*, run_once_*, run_onchange_*, run_after_*)
│
├── symlink_dot_ssh.tmpl                     # ~/.ssh → iCloud
├── private_dot_gnupg/                       # ~/.gnupg/* → iCloud (6 symlinks)
├── private_dot_kube/                        # ~/.kube/config → iCloud
│
├── dot_zshenv                               # PATH for non-interactive shells (mise shims, locale)
├── dot_zprofile                             # Restores the mise shims after macOS path_helper (login shells)
├── dot_zshrc                                # Shell orchestrator
├── private_dot_exports.tmpl                 # Env vars, history, zsh options (0600, reads the keychain)
├── dot_functions                            # Shell functions
├── dot_aliases                              # Command aliases
├── dot_plugins                              # Oh My Zsh plugin list, compiled by antidote
├── dot_completions                          # Completions & zsh plugins
│
├── dot_gitconfig.tmpl                       # Git user, GPG signing, LFS
├── dot_gitignore_global                     # Global gitignore
├── private_dot_npmrc.tmpl                   # npm registry tokens (0600, from keychain)
├── private_dot_wakatime.cfg.tmpl            # WakaTime API key (0600, from keychain)
├── dot_local/bin/executable_runaway-watch   # Flags stuck processes, busy GPU (every 2 min, launchd)
├── dot_config/                              # ~/.config
│   ├── hosts                                # /etc/hosts source
│   ├── mise/config.toml                     # Language runtimes + global CLI packages
│   ├── runaway-watch/ignore                 # Heavy work the runaway watcher leaves alone
│   └── zed/private_settings.json.tmpl       # Zed editor settings (0600, from keychain)
├── private_dot_claude/                      # ~/.claude/ (0700)
│   ├── private_CLAUDE.md                    # Global Claude Code instructions (all projects)
│   ├── private_settings.json.tmpl           # Claude Code user settings (plugins, permissions, hooks)
│   ├── private_hooks/                       # Claude Code guard hooks and session notices
│   └── private_plugins/                     # Claude Code plugin and marketplace state
├── private_Library/                         # ~/Library (0700)
│   ├── Application Support/
│   │   └── Code/User/                       # VS Code settings & keybindings
│   └── LaunchAgents/                        # Runaway watcher agent
│
└── Brewfile                                 # Homebrew packages
```

## ⛰️ Next Steps

1. 📖 Read [ARCHITECTURE.md](./ARCHITECTURE.md) for a walkthrough of how the pieces fit together.
2. 🔀 Fork this repo and adapt `config.toml` and the Brewfile to your setup.
3. 🔐 Move your secrets into the macOS Keychain with `secret:set`.
4. 🐛 Hit a bug or have an idea? [Open an issue](https://github.com/JonathanXDR/Dotfiles/issues).

## ⚖️ License

Licensed under the [MIT license](./LICENSE) © Jonathan Russ.
