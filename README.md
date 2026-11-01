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

Choose a thread on first use; the target stays selected for this Neovim
instance. No thread is chosen automatically. The picker reads the local
`$CODEX_HOME/session_index.jsonl` title index (default `~/.codex`), most recently
updated first. This lists **saved threads**, not only live ones; it is not a
complete server inventory. Enter a UUID or exact name manually if missing.

The dialog shows the session name (falling back to its ID when unavailable) and
source file. Enter or Ctrl-S queues the prompt;
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
