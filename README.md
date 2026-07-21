# aella

A disposable amd64 Ubuntu box on AWS — up in a gust, gone on `down`. No EC2 console, ever.

`aella` is a thin wrapper around the AWS CLI. It remembers your key pair, security group,
instance type, and the current box, so spinning one up (or killing it) is one word. Named
for the Amazon **Aella** — "whirlwind" — which is about the right lifespan for these boxes.

```
aella up                 # launch a fresh box (current LTS), print its IP + ssh line
aella ssh                # ssh in
aella tunnel 8150        # forward a port to your Mac's browser
aella ls                 # every box you've got running — what's costing you money
aella down               # terminate it — disk and all
```

## Install

Needs the AWS CLI, configured:

```sh
brew install awscli        # or your platform's package
aws configure              # set a default region + credentials
```

Then drop `aella` somewhere on your `PATH`:

```sh
curl -o ~/bin/aella https://raw.githubusercontent.com/cassiocassio/aella/main/aella
chmod +x ~/bin/aella
```

## Commands

| command | what it does |
|---|---|
| `aella up [--latest]` | launch a fresh box (current LTS by default; `--latest` = newest Ubuntu release), auto-provisions the shell, prints IP + ssh line |
| `aella ls` | list **every** aella box from AWS tags (`*` = the current one) — the "what am I paying for?" view, works across machines and sessions |
| `aella ssh` | ssh into the current box |
| `aella tunnel [port]` | `ssh -N -L port:localhost:port` (default 8150) — run a web server on the box, open `http://localhost:port` on your machine |
| `aella push <src> [dst]` | copy a local file/dir up to the box (remote dir auto-created; default is home) |
| `aella pull <src> [dst]` | copy a file/dir from the box back down (default: current dir) |
| `aella ip` | print the current public IP (clean stdout, script-friendly) |
| `aella rdp` | re-allow RDP (3389) from your *current* IP, for a GUI desktop — run again after you roam |
| `aella status` | show the current box |
| `aella down [-y]` | **terminate** it — irreversible, deletes the box and its disk (`-y` skips the prompt) |
| `aella help` | this |

## A typical loop

```sh
aella up                              # spin up a box
aella push ./clip.mp4 work/           # send it something to chew on
aella ssh                             # ... do the work on the box ...
aella tunnel 8150                     # view a local web server in your Mac browser
aella pull work/output ./results      # bring the results back
aella down                            # stop the meter
```

## Ephemeral by design

`down` **terminates** (deletes the root disk); `up` launches a **brand-new** box from the
latest Ubuntu 24.04 AMI. Every cycle is a fresh disk and a new public IP — so don't keep
state on the box. That's also why `up` bakes first-boot provisioning (coloured prompt, sane
history, ls/grep colours; and if you use [Ghostty](https://ghostty.org), its terminfo so
`nano`/`less` just work) into the machine via cloud-init — a fresh box comes up configured.

## Config

Override the defaults with env vars — handy for renting bigger or odd silicon:

| var | default | |
|---|---|---|
| `AELLA_REGION` | `eu-north-1` | AWS region |
| `AELLA_TYPE` | `m7i-flex.large` | instance type (amd64, 8 GB — **not** free tier) |
| `AELLA_DISK` | `20` | root disk, GB |
| `AELLA_LTS` | `24.04` | which LTS `up` uses by default |

```sh
AELLA_TYPE=c7g.8xlarge AELLA_REGION=us-east-1 aella up   # a big Graviton box
```

## Notes

- **SSH is open to `0.0.0.0/0`** but **key-only** (password auth off on Ubuntu AMIs). The key
  pair is created on first `up` and saved to `~/.ssh/aella-key.pem`. RDP, if you use it, is
  scoped to your current IP only.
- **This costs money.** The default instance type is not free-tier and bills per second while
  running. `aella down` is what stops the meter. Spot pricing + a bigger `AELLA_TYPE` makes a
  good cheap-but-fast combo.
- State lives in `~/.aella-instance` (just the current instance id). Nothing else is stored.

## Tests

`bash test/aella.test.sh` — unit tests that mock the AWS CLI (`test/bin/aws`), so they
never touch AWS or spend a cent. They pin the parts where a regression would cost money or
lock you out: the orphan-billing guard, the `down` confirmation, the no-empty-host ssh guard,
and the user-data heredocs. Not an end-to-end test — for that, do one real `up`/`down` cycle.

## Licence

MIT — see [LICENSE](LICENSE).
