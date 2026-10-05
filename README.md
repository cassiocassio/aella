# aella

A disposable amd64 box on AWS — Ubuntu, Fedora or Windows Server, up in a gust, gone on `down`.
No EC2 console, ever.

`aella` is a thin wrapper around the AWS CLI. It remembers your key pair, security group,
instance type, and the current box, so spinning one up (or killing it) is one word. Named
for the Amazon **Aella** — "whirlwind" — which is about the right lifespan for these boxes.

```
aella up                 # launch a fresh box (current LTS), print its IP + ssh line
aella up --fedora        # ... or a Fedora box instead
aella up --windows       # ... or Windows Server 2025 (then: aella rdp)
aella ssh                # ssh in
aella tunnel 8150        # forward a port to your local browser
aella ls                 # every box you've got running — what's costing you money
aella down               # terminate it — disk and all
```

## Install

Needs the AWS CLI, configured — plus `ssh`, `scp`, and `curl`, all standard on macOS and
every major Linux distro. Pure bash (3.2+), no other dependencies.

```sh
brew install awscli        # or your platform's package manager (apt, dnf, pacman, …)
aws configure              # set a default region + credentials
```

Then install `aella` onto your `PATH`. **With git** (recommended — `git pull` to update,
and you get the tests):

```sh
git clone https://github.com/cassiocassio/aella ~/.aella
ln -s ~/.aella/aella ~/.local/bin/aella      # or any dir on your PATH
```

**Or just grab the one file:**

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/cassiocassio/aella/main/aella -o ~/.local/bin/aella
chmod +x ~/.local/bin/aella
```

Make sure the target dir is on your `PATH` (`echo $PATH`; add `~/.local/bin` if missing).
Then `aella help`.

## Uninstall

It doesn't scatter — no PATH edits, no config dir, no launch agents. Actually removable,
which is rare for its genre:

```sh
aella down                                       # if a box is still running
rm -rf ~/.aella ~/.local/bin/aella               # the tool (adjust to where you put it)
rm -rf ~/.aella-instance ~/.aella-user ~/.aella-region ~/.aella-lock   # its only local state
rm -f  ~/.ssh/aella-key.pem                                             # ... and the key
```

And on the AWS side, if you want it fully gone:

```sh
aws ec2 delete-key-pair --key-name aella-key
aws ec2 delete-security-group --group-name aella-sg
aws ec2 delete-security-group --group-name aella-win-sg   # only exists if you ever ran up --windows
```

Key pairs and security groups are per-region: repeat with `--region` for any other
`AELLA_REGION` you've used.

## Commands

| command | what it does |
|---|---|
| `aella up [--latest] [--fedora \| --windows]` | launch a fresh box (Ubuntu LTS by default; `--latest` = newest release of the chosen distro; `--fedora` = Fedora instead; `--windows` = Windows Server 2025, [see below](#windows)), auto-provisions the shell, prints IP + ssh line |
| `aella ls` | list **every** aella box from AWS tags (`*` = the current one) with its platform and region — the "what am I paying for?" view, works across machines and sessions. Looks in `AELLA_REGION` (or the default) and the current box's region |
| `aella ssh` | ssh into the current box |
| `aella tunnel [port]` | `ssh -N -L port:localhost:port` (default 8150) — run a web server on the box, open `http://localhost:port` on your machine |
| `aella push <src> [dst]` | copy a local file/dir up to the box (remote dir auto-created; default is home) |
| `aella pull <src> [dst]` | copy a file/dir from the box back down (default: current dir) |
| `aella ip` | print the current public IP (clean stdout, script-friendly) |
| `aella rdp` | **Windows box:** copy the Administrator password to your clipboard and open a Remote Desktop session (re-allows your current IP first). **Linux box:** re-allow RDP (3389) from your *current* IP, for a GUI desktop you've set up yourself — run again after you roam |
| `aella status` | show the current box |
| `aella down [-y]` | **terminate** it — irreversible, deletes the box and its disk (`-y` skips the prompt) |
| `aella help` | this |

## A typical loop

```sh
aella up                              # spin up a box
aella push ./clip.mp4 work/           # send it something to chew on
aella ssh                             # ... do the work on the box ...
aella tunnel 8150                     # view a web server running on the box in your browser
aella pull work/output ./results      # bring the results back
aella down                            # stop the meter
```

## Ephemeral by design

`down` **terminates** (deletes the root disk); `up` launches a **brand-new** box from the
latest Ubuntu 24.04 AMI — or, with `--fedora`, the latest Fedora image. Every cycle is a fresh disk and a new public IP — so don't keep
state on the box. That's also why `up` bakes first-boot provisioning (coloured prompt, sane
history, ls/grep colours; and if you use [Ghostty](https://ghostty.org), its terminfo so
`nano`/`less` just work) into the machine via cloud-init — a fresh box comes up configured.

## Windows

```sh
aella up --windows       # 1-3 min: boot, then wait for Windows to post its password
aella rdp                # password -> clipboard, opens a Remote Desktop session; paste at login
aella ssh                # PowerShell over OpenSSH, key-only, same aella key
aella down               # stop the meter (the licence is billed with the instance)
```

- **The image** is Windows Server 2025 English Full Base (x86_64), the newest Amazon
  publishes, looked up via the public SSM parameter
  `/aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base`. IAM users
  without `ssm:GetParameter` fall back to EC2's own image list (owner `amazon`).
- **The password wait.** Windows generates a random Administrator password on first boot
  and posts it, encrypted to your key, once boot finishes. AWS says to allow about 4
  minutes. Measured (Server 2025 on `m7i-flex.large`, eu-north-1, Oct 2026): 33–60 s after
  the instance reached `running`, and 1–2.5 min for the whole `up`. `up` polls
  `get-password-data` (decrypting locally with `~/.ssh/aella-key.pem`), printing a dot
  every 15 s, for up to 15 minutes (`AELLA_PW_TIMEOUT`). Ctrl-C during the wait is safe:
  the box is already tracked, and `aella rdp` picks the wait up again.
- **The password is never printed** or logged. It goes to your clipboard (`pbcopy`, or
  `wl-copy` / `xclip` on Linux). With no clipboard tool, it goes to a mode-600 temp file
  whose path is printed, and you should delete that file afterwards. `aella rdp` fetches it
  again each time. Clipboard history managers will keep a copy, so the box being disposable
  is the real protection.
- **RDP client.** `aella rdp` writes a two-line `.rdp` file (address + `Administrator`;
  no password) into a private temp dir and opens it. On macOS that needs Microsoft's free
  [Windows App](https://apps.apple.com/app/windows-app/id1295203466) (formerly Microsoft
  Remote Desktop). If nothing handles `.rdp` files, it tells you so. On Linux it tries
  `xdg-open`, else suggests `xfreerdp /v:IP /u:Administrator`.
- **Network.** Windows boxes get their own security group, `aella-win-sg`, with RDP (3389)
  and SSH (22) open **only to your current public IP**. Every `up --windows` and `aella
  rdp` adds your current IP and revokes the old ones, so the group never trusts an address
  you've left. The flip side: using it from two networks at once means re-running `aella
  rdp` on whichever one you switch to. `aella-sg` (Linux) is untouched.
- **SSH.** First-boot user-data (PowerShell, via EC2Launch) enables the OpenSSH server
  that ships with Server 2025. It authorises the aella **public** key for Administrator in
  `C:\ProgramData\ssh\administrators_authorized_keys` (ACL: Administrators + SYSTEM
  only), turns password and keyboard-interactive logins off, opens 22 in Windows
  Firewall (the security group is what scopes it to your IP), and makes PowerShell the
  default shell. It reports `aella-sshd: ok` (or `failed: <why>`) on the serial console:
  `aws ec2 get-console-output --instance-id <id> --latest`. So `ssh`,
  `tunnel`, `push` and `pull` work too; remote paths are relative to
  `C:\Users\Administrator`. sshd was up within seconds of the password in testing.
- **Disk:** 60 GB by default. 30 GB is the image's own size and the floor (`AELLA_DISK`
  can't go below it), but it's tight: after Python, a pipx-installed app (~560 MB venv)
  and a 1.5 GB Whisper model, only ~2 GB was left.
- **Cost.** The Windows licence is billed per second on top of the instance, and only while
  the box exists. On-demand, Oct 2026, licence included:

  | region | `m7i-flex.large` (default) | `t3.large` |
  |---|---|---|
  | eu-north-1 (Stockholm, the default) | $0.189/hr | $0.114/hr |
  | eu-west-2 (London) | $0.198/hr | $0.122/hr |
  | eu-west-1 (Ireland) | $0.194/hr | $0.119/hr |
  | us-east-1 (N. Virginia) | $0.183/hr | $0.111/hr |

  Add ~$0.005/hr for the public IPv4 address, plus the 60 GB gp3 disk at ~$0.084/GB-month
  in eu-north-1: ~$5/month pro rata, under a cent an hour, billed only while the box
  exists. That comes to roughly $0.20/hr for the default.
  `AELLA_TYPE=t3.large` is about 40% cheaper because AWS licenses Windows on t3 more
  cheaply. But [free-plan AWS accounts](https://aws.amazon.com/free/) refuse it ("not
  eligible for Free Tier"), which is why it isn't the default. Being burstable, it also
  charges extra CPU credits if the box runs flat out for long.
- **Why not keep a Windows box around?** Stopped, it would cost only its disk, about
  $5–5.60 a month at 60 GB. But aella is built around terminate-and-relaunch, and a fresh box is
  ~2 minutes and about a cent of waiting. Even launched daily, disposable is cheaper, and each
  box starts clean from Amazon's latest monthly-patched image. What you trade is setup:
  anything you install is gone on `down`.

## Config

Override the defaults with env vars — handy for renting bigger or odd silicon:

| var | default | |
|---|---|---|
| `AELLA_REGION` | `eu-north-1` | AWS region `up` launches in (later commands follow the box; see below) |
| `AELLA_TYPE` | `m7i-flex.large` | instance type (amd64, 8 GB — **not** free tier) |
| `AELLA_DISTRO` | `ubuntu` | `ubuntu`, `fedora` or `windows` (per-run: `up --fedora` / `up --windows`) |
| `AELLA_FEDORA` | `42` | Fedora release to launch |
| `AELLA_DISK` | `20` | root disk, GB (Windows: `60`; `30` minimum) |
| `AELLA_LTS` | `24.04` | which LTS `up` uses by default |
| `AELLA_PW_TIMEOUT` | `900` | seconds to wait for a Windows box's password |

```sh
AELLA_TYPE=c7g.8xlarge AELLA_REGION=us-east-1 aella up   # a big Graviton box
```

`up` launches in `AELLA_REGION` and records it in `~/.aella-region`. Every later command
about that box (`ssh`, `tunnel`, `push`, `pull`, `ip`, `rdp`, `status`, `down`) goes to the
recorded region, so a one-off `AELLA_REGION=us-east-1 aella up` is followed by a plain
`aella down`. If `AELLA_REGION` is set *and disagrees* with the box's region, aella refuses
and tells you the region to use, rather than guessing which you meant. `ls` lists
`AELLA_REGION` (or the default) plus the current box's region, with a region column; boxes
in any other region need `AELLA_REGION=<there> aella ls`. A box launched before
`~/.aella-region` existed has no record, so it uses `AELLA_REGION` / the default as before.
On the first `up` in a new region, aella imports your existing key pair there.

## Notes

- **SSH on Linux boxes is open to `0.0.0.0/0`** but **key-only** (password auth off on both
  Ubuntu and Fedora cloud AMIs). The key pair is created on first `up` and saved to
  `~/.ssh/aella-key.pem`. RDP, if you use it, is scoped to your current IP only. Windows
  boxes are stricter: both RDP and SSH are open to your current IP only.
- **This costs money.** The default instance type is not free-tier and bills per second while
  running. `aella down` is what stops the meter. Spot pricing + a bigger `AELLA_TYPE` makes a
  good cheap-but-fast combo.
- State lives in `~/.aella-instance` (the current instance id), `~/.aella-user` (its login
  name, since Ubuntu, Fedora and Windows images differ; `Administrator` marks a Windows box)
  and `~/.aella-region` (where it was launched). Nothing else is stored; `down` clears all
  three. A box launched before `~/.aella-user` existed is assumed to be Ubuntu.
- **One `up`/`down` at a time.** Two sessions launching at once could each start a box and
  only one would be tracked, the other billing unseen. So `up` and `down` hold a lock
  (`~/.aella-lock`, a directory holding the owner's pid) and a second one fails straight
  away with the owner's pid. A lock left by a crashed or killed run is noticed (its pid is
  gone, or isn't aella any more) and cleared. If it ever blocks you wrongly,
  `rm -rf ~/.aella-lock`. `ssh`, `push`, `ls` and the rest don't take it.
- **`push`/`pull` remote paths are relative to the box's home** (`/home/ubuntu`,
  `/home/fedora`, or `C:\Users\Administrator`), so `aella push clip.mov work/` lands in `~/work/`. An absolute path like
  `/data` only works if the login user can write there — for a disposable box, stick to
  home-relative.
- **Fedora releases: only stable ones.** Fedora publishes ELN, Rawhide and Prerelease images
  into the same AWS account and rebuilds them nightly, so they always sort newest — `up
  --fedora --latest` filters them out and takes the highest numbered stable release.

## Tests

`bash test/aella.test.sh` — unit tests that mock the AWS CLI (`test/bin/aws`), so they
never touch AWS or spend a cent. They pin the parts where a regression would cost money or
lock you out: the orphan-billing guard (also across regions), the one-`up`/`down`-at-a-time
lock (including a real concurrent pair, and stale-lock recovery), that every command follows
the box's recorded region and refuses a conflicting `AELLA_REGION`, the `down` confirmation, the no-empty-host ssh guard,
the user-data heredocs, and — for Fedora — that the release picker skips the Rawhide/ELN
decoys and that every `ssh`/`push`/`pull` follows the box's real login name — and for
Windows that RDP/SSH ingress is your `/32` only and never touches `aella-sg`, that the
password reaches the clipboard (or a 0600 file) but never the terminal, the `.rdp` file or
any command line, that the user-data can't be broken out of, and the timeout, no-SSM and
no-AMI failure paths. Not an end-to-end test — for that, do one real `up`/`down` cycle.

## Licence

MIT — see [LICENSE](LICENSE).
