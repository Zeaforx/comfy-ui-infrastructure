# Private ComfyUI on a GCP Spot VM

This repository creates a disposable ComfyUI server on Google Cloud:

- one GCE Spot VM with an NVIDIA T4 GPU;
- a 100 GB balanced boot disk;
- ComfyUI and ComfyUI-Manager installed at boot;
- private access through Tailscale;
- a small HTTP service for downloading models directly onto the VM; and
- systemd services that restart ComfyUI after a normal VM reboot.

The infrastructure is intended to be created for a generation session and
destroyed afterward. There is no separate persistent model disk. Destroying the
VM deletes its boot disk, installed models, generated files stored only on the
VM, and ComfyUI configuration.

## Repository layout

```text
.
├── .codex/config.toml              # Project-only Codex settings
├── AGENTS.md                       # Instructions for coding agents
├── SKILLS.md                       # Project capability and workflow guide
├── scripts/
│   ├── startup.sh                  # GCE startup/bootstrap script
│   ├── model_downloader.py         # Standalone source for the downloader
│   └── generate_workflow_images.py # Submit an API workflow repeatedly
├── terraform/                      # GCP infrastructure
└── workflows/                      # Saved ComfyUI and API workflows
```

## Prerequisites

- A GCP project with billing enabled and sufficient GPU quota.
- `gcloud` and Terraform 1.5 or newer installed locally.
- A Tailscale account and Tailscale installed and signed in on every laptop or
  phone that needs to open ComfyUI.
- A reusable Tailscale auth key for the VM. Do not use an ephemeral key if the
  machine must reconnect after a reboot.

Authenticate for Terraform:

```bash
gcloud auth application-default login
```

Create the local variables file:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` and provide the GCP project ID and Tailscale
auth key. The file is ignored by Git, but the key can still be recorded in
Terraform state and GCE instance metadata. Keep both private.

## Deploy

Run Terraform from the repository root:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

The first boot installs system packages, the NVIDIA driver, Tailscale, ComfyUI,
PyTorch, and ComfyUI-Manager. It may reboot once to load the NVIDIA kernel
module. Do not expect the UI to be ready immediately after `terraform apply`
returns.

Check the VM and startup progress with:

```bash
gcloud compute instances describe comfy-ui-server \
  --zone=us-central1-a \
  --format='get(status)'

gcloud compute ssh comfy-ui-server \
  --zone=us-central1-a \
  --command='sudo journalctl -u google-startup-scripts.service -n 100 --no-pager'
```

If `zone` was changed in `terraform.tfvars`, use that zone in the commands.

## Open ComfyUI

Connect the client device to the same Tailscale network as the VM. Find the
machine name or MagicDNS name in the Tailscale admin console, then open:

```text
http://<tailscale-name>:8188
```

For example:

```text
http://comfyui.<your-tailnet>.ts.net:8188
```

ComfyUI listens only on `127.0.0.1` inside the VM. Tailscale Serve publishes it
privately to the tailnet; it is not intentionally exposed by a public GCP
firewall rule. The current Terraform `comfy_ui_url` output contains the VM's
public IP and is not the URL to use.

To inspect the services:

```bash
gcloud compute ssh comfy-ui-server \
  --zone=us-central1-a \
  --command='sudo systemctl status comfyui comfyui-downloader --no-pager; sudo tailscale serve status'
```

## Download models directly to the VM

The downloader listens on port `8189` and saves files below
`/home/comfyui/ComfyUI`. Its current token is configured in
`scripts/startup.sh`. Treat that token as a password and change it before using
the service beyond a private personal tailnet.

The request format is:

```text
http://<tailscale-ip>:8189/?token=<token>&url=<ENCODED_SOURCE_URL>&path=models/<model-folder>
```

Only the value of `url=` should be percent-encoded. Do not encode the entire
downloader URL. This matters for signed Hugging Face URLs because their `&`
characters would otherwise be interpreted as parameters belonging to the
downloader.

Example using a browser console:

```javascript
const source = "https://example.com/model.safetensors?key=value&signature=abc";
const downloader =
  "http://100.x.y.z:8189/?token=comfyui_secret_123" +
  "&url=" + encodeURIComponent(source) +
  "&path=models/checkpoints";
console.log(downloader);
```

Common model destinations include:

- `models/checkpoints`
- `models/diffusion_models`
- `models/text_encoders`
- `models/vae`
- `models/loras`
- `models/clip_vision`

Signed download links can expire. Copy a fresh source URL if the remote server
returns an authorization error.

## Workflows

Keep reusable workflow files under `workflows/`. ComfyUI has two related JSON
formats:

- the UI workflow format preserves the graph and is used to reopen and edit a
  workflow in the browser;
- the API format is submitted to `/prompt` for automation.

Export the appropriate format from ComfyUI before running a workflow from a
script. A valid JSON file is not necessarily runnable on this VM: its models,
custom nodes, VRAM requirements, and API credentials must also be available.

`scripts/generate_workflow_images.py` is a workflow-specific helper. It assumes
that node `5` has a `seed` input and node `7` is the image-saving output. It is
not a generic runner for every JSON file.

Example through an SSH tunnel or from the VM:

```bash
python3 scripts/generate_workflow_images.py \
  workflows/family-guy/family_guy_style_api.json \
  workflows/family-guy/outputs \
  --server http://127.0.0.1:8188 \
  --count 5
```

## Spot VM behavior and storage

Google may stop or reclaim a Spot VM at any time. A stop/start or ordinary
reboot preserves the boot disk, so the startup script detects the completed
bootstrap and restarts the existing services. If Terraform replaces the VM, or
you destroy the infrastructure, its boot disk and everything stored on it are
lost.

Export valuable workflows and copy generated output to your local machine
before destruction. Do not use the VM as permanent storage.

## Destroy

When finished, destroy the VM to stop compute, GPU, and boot-disk charges:

```bash
terraform -chdir=terraform destroy
```

Review the destroy plan before confirming. Terraform state remains locally so
Terraform can track whether any managed resources still exist.

## Security notes

- Never commit `terraform.tfvars`, Terraform state, credentials, auth keys, or
  private signed model URLs.
- Tailscale is the access boundary. Keep the tailnet account secured and remove
  stale machines from its admin console.
- The downloader performs server-side downloads from supplied URLs. Keep it
  private and rotate its default token.
- ComfyUI-Manager allows Git URL installation only because ComfyUI is bound to
  loopback. Review third-party custom-node code before installing it.
