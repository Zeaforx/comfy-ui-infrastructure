# Project skills and operating workflows

This file describes the capabilities an engineer or coding agent needs when
working in this repository. It is project documentation, not an installable
Codex skill package. A reusable Codex skill would instead live in a directory
such as `.agents/skills/<skill-name>/SKILL.md`.

## 1. Terraform infrastructure

Relevant files: `terraform/*.tf`

Capabilities:

- plan, create, inspect, and destroy the GCP Spot VM;
- understand GCE GPU quotas, zones, Spot scheduling, and boot-disk lifecycle;
- keep secrets in ignored variables rather than committed configuration; and
- distinguish Terraform configuration, state, and live GCP resources.

Standard commands:

```bash
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform plan
terraform -chdir=terraform apply
terraform -chdir=terraform destroy
```

## 2. VM bootstrap and service operations

Relevant file: `scripts/startup.sh`

Capabilities:

- maintain an idempotent Debian bootstrap script;
- install the NVIDIA driver and CUDA-enabled PyTorch;
- run ComfyUI and the downloader as dedicated-user systemd services;
- diagnose first-boot reboots and failed startup scripts; and
- preserve fast recovery after an ordinary reboot or Spot stop/start.

Useful remote checks:

```bash
sudo nvidia-smi
sudo systemctl status comfyui comfyui-downloader tailscaled --no-pager
sudo journalctl -u comfyui -n 100 --no-pager
sudo journalctl -u comfyui-downloader -n 100 --no-pager
sudo journalctl -u google-startup-scripts.service -n 100 --no-pager
```

## 3. Private Tailscale access

Relevant configuration: Tailscale metadata in `terraform/main.tf` and Serve
setup in `scripts/startup.sh`.

Capabilities:

- enroll a recreated VM with a reusable auth key;
- resolve the machine through MagicDNS or its `100.x.y.z` address;
- inspect `tailscale status` and `tailscale serve status`; and
- keep ComfyUI bound to loopback rather than opening a public firewall port.

## 4. Direct model downloads

Relevant files: `scripts/model_downloader.py` and its embedded copy in
`scripts/startup.sh`.

Capabilities:

- map a model type to its correct `ComfyUI/models/` subdirectory;
- percent-encode only the nested source URL;
- recognize expired signed URLs, redirects, and misleading filenames; and
- monitor partial downloads without treating a `.part` file as complete.

Downloader request shape:

```text
http://<tailscale-ip>:8189/?token=<token>&url=<encoded-url>&path=models/<folder>
```

## 5. ComfyUI workflow analysis

Relevant files: `workflows/**/*.json`

Capabilities:

- distinguish UI workflow JSON from API prompt JSON;
- identify missing models and custom nodes;
- map model loaders to expected filesystem paths;
- identify cloud/API-backed workflows that are not local inference;
- assess T4 16 GB VRAM compatibility; and
- preserve editable workflows before destroying the VM.

A compatibility review should report one of:

- runnable as-is;
- runnable after installing named models or nodes;
- runnable with quantization/offloading and slower performance;
- incompatible with the current T4 VM; or
- dependent on a paid or authenticated external API.

## 6. Workflow automation

Relevant file: `scripts/generate_workflow_images.py`

Capabilities:

- submit API-format prompts to ComfyUI;
- vary seeds and other selected node inputs;
- poll generation history and surface execution errors; and
- download output files to the local repository.

The existing script is specialized for the Family Guy image workflow. Before
using it with another workflow, inspect and update its hard-coded node IDs,
input names, output-node handling, filename prefix, and output extension.

## 7. Cost and lifecycle control

Capabilities:

- confirm the live instance status before assuming charges have stopped;
- understand that stopped compute avoids VM/GPU runtime charges while retained
  disks and other resources may still incur charges;
- understand that Terraform destroy removes the disposable boot disk; and
- export wanted workflows and outputs before destruction.

The safe operating loop is:

```text
plan -> apply -> wait for bootstrap -> verify -> generate -> export -> destroy
```
