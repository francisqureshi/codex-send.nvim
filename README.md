# codex-send.nvim

Send prompts, visual selections, and buffer contents from Neovim to an existing
Codex conversation. Keep using Codex in your external terminal or connected
client; this plugin queues messages for the thread you choose.

Adapted from [carderne/pi-nvim](https://github.com/carderne/pi-nvim), preserving
its floating prompt and buffer toggle workflow. Unofficial community plugin.

## Requirements

- Neovim 0.10+
- Codex CLI with `codex queue` support (verified with 0.166.0)
- An existing Codex conversation to target

## Installation

With lazy.nvim:

```lua
{
  'francisqureshi/codex-send.nvim',
  main = 'codex-send',
  cmd = { 'Codex', 'CodexSendSelection', 'CodexSessions', 'CodexTarget' },
  keys = {
    { '<leader>ci', '<cmd>Codex<CR>', mode = 'n', desc = 'Send to Codex' },
    { '<leader>ci', ':Codex<CR>', mode = 'x', desc = 'Send selection to Codex' },
    { '<leader>cs', ':CodexSendSelection<CR>', mode = 'x', desc = 'Send selection to Codex' },
    { '<leader>ct', '<cmd>CodexSessions<CR>', desc = 'Choose Codex thread' },
  },
  opts = {},
}
```

With another plugin manager, install the repository and call:

```lua
require('codex-send').setup({})
```

Mappings are provided by the lazy.nvim example; `setup()` registers commands
without creating global mappings. The `:Codex` command overlaps with other
Codex plugins, so enable only one provider for that command.

## Usage

| Key / command | Action |
| --- | --- |
| `<leader>ci` / `:Codex` | Open prompt with the current file path |
| Visual `<leader>ci` or `<leader>cs` | Open prompt with the selected text |
| `<leader>ct` / `:CodexSessions` | Choose the target thread |
| `:CodexTarget UUID-or-exact-name` | Set the target explicitly |
| `:CodexTarget` | Show the current target |
| `:CodexTarget auto` | Clear a pinned target and return to automatic selection |

By default, the plugin queries Codex's app-server for non-archived conversations
whose working directory matches Neovim's current directory (`:pwd`). It tries
the exact directory first, then each parent, stopping at the nearest directory
with sessions. This handles Codex launched from `~/` while Neovim is editing
`~/Projects/my-project`.

Within the nearest matching directory, it prefers the last successfully used
session for Neovim's current directory in this instance, then the most recently
active matching session. Symbolic links are resolved when comparing paths.
Subagent and batch-execution sessions are excluded. If no directory matches, or
metadata lookup fails, it opens the picker. Sibling directories aren't matched.
The dialog shows the session's directory for automatic targets; review the name
and directory, particularly when several conversations share a broad parent.

Choosing a thread with the picker or `:CodexTarget` pins it until you run
`:CodexTarget auto` or restart Neovim. Automatic targets are recalculated each
time the dialog opens, and stay fixed while you compose the prompt. A
directory match is a heuristic, not a guarantee that a conversation is live.
Automatic lookup examines up to 50 recent conversations in the nearest matching
directory and uses
`codex app-server` to read metadata only; it never resumes a thread or starts
a model turn. Remote targets use manual selection.

The picker reads the local
`$CODEX_HOME/session_index.jsonl` title index (default `~/.codex`), most recently
updated first. This lists **saved threads**, not only live ones; it is not a
complete server inventory. Enter a UUID or exact name manually if missing.

The dialog shows the session name (falling back to its ID when unavailable) and
source file. **Ctrl-T changes the target session inside the dialog**, preserving
your prompt, selection, and buffer toggle. Canceling the picker keeps the previous
target. A manual choice pins the session; use `:CodexTarget auto` to unpin it.
You can also choose a session before opening the dialog with `<leader>ct` or
`:CodexSessions`. Enter or Ctrl-S queues the prompt;
Shift-Enter inserts a newline when supported by your terminal. Tab toggles sending
the entire buffer, including unsaved edits. Visual selections include the exact
selected text with absolute file path and line numbers. Escape cancels. Failed
queue submissions leave the prompt open for retry.

Queueing submits a message; it does not insert an unsent draft into the other UI.
The plugin does not start a second interactive conversation or terminal. A queue
receipt does not guarantee that a thread has already consumed the message.
Queue semantics and remote support are documented in the
[official CLI reference](https://learn.chatgpt.com/docs/developer-commands#codex-queue).

## Configuration

Use the lazy.nvim spec's `opts`, or pass this table to `setup()`:

```lua
{
  cmd = { 'codex' },
  -- thread = 'session-uuid',
  -- codex_home = '/path/to/.codex',
  -- profile = 'work',
  -- remote = 'unix:///path/to/server.sock',
  resume = false, -- true adds --resume to try waking the selected thread
  auto_target = true, -- false always asks you to choose unless a target is pinned
}
```

Remote targets use manual entry rather than the local title index. The command
inherits the environment, including any remote authentication configuration
supplied through `cmd` arguments. File references always refer to this machine;
for a remote host use selections or the buffer toggle to include actual text.

## Attribution

The prompt UI is adapted from Chris Arderne's
[pi-nvim](https://github.com/carderne/pi-nvim) under the MIT license. The original
copyright and permission notice are preserved in [LICENSE](LICENSE).

## Development

Run checks without sending to a real conversation:

```sh
nvim --headless -u NONE -l tests/check.lua
```

The checks require Python 3 for a fake Codex executable. They never send a message
to a real conversation.
