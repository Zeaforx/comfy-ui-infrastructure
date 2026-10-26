# Agent instructions

## Project purpose

Maintain a disposable, private ComfyUI environment on a GCP Spot VM. Terraform
creates the VM; `scripts/startup.sh` installs and starts the software; Tailscale
provides access. The project intentionally has no separate persistent disk.

## Scope and safety

- Work only in this repository unless the user explicitly requests otherwise.
- When the user instructs you to run or carry out a task, proceed as quickly as
  safely possible without unnecessary confirmation or delay.
- Use `.codex/config.toml` for project-specific Codex configuration. Do not edit
  `~/.codex/config.toml` for repository requirements.
- Never commit secrets, real Tailscale keys, GCP credentials, signed model URLs,
  Terraform state, or `.tfvars` files.
- Treat `terraform apply` as an external infrastructure mutation and
  `terraform destroy` as destructive. State the expected target and inspect the
  plan before applying unless the user explicitly requests immediate execution.
- Before carrying out `terraform apply`, ask the user to create
  `plan/plan.md`. Keep this plan brief and execution-focused: record the exact
  task, required checks, completion condition, and immediate destroy/export
  steps. Its purpose is to prevent delay and keep expensive VM time as short as
  possible, not to add unnecessary planning overhead.
- Do not create a persistent disk unless the user reverses the current design
  decision explicitly.
- Preserve unrelated user changes in the working tree.
- VERY HIGH PRIORITY — COST CONTROL: After completing work that creates or uses
  the GCP VM, always remind the user to export any valuable outputs and run
  `terraform -chdir=terraform destroy`. The VM, GPU, and boot disk incur
  significant charges while retained, so this reminder must not be omitted.

## Source of truth

- Terraform resources: `terraform/`
- VM provisioning and service definitions: `scripts/startup.sh`
- Standalone downloader development copy: `scripts/model_downloader.py`
- Workflow assets: `workflows/`
- User-facing operating instructions: `README.md`

The downloader is currently embedded in `scripts/startup.sh` as well as stored
in `scripts/model_downloader.py`. If its behavior changes, keep both copies in
sync or deliberately refactor startup to install the standalone file.

## Common execution strategies

Use these strategies when applicable; skip them when their prerequisites or
resource costs outweigh the time saved.

### Parallel model staging during bootstrap

- Start large model downloads into a dedicated temporary staging directory as
  soon as networking and sufficient storage are available. Run them alongside
  independent work such as package installation, ComfyUI setup, driver checks,
  or workflow preparation instead of waiting for bootstrap to finish first.
- Check free disk space before staging. Account for both staged files and their
  final installed copies unless the final move stays on the same filesystem.
- Download to partial filenames, verify completion and expected size or
  checksum when one is available, and only then atomically move each file into
  its correct ComfyUI model directory. Never let ComfyUI consume an incomplete
  model.
- Keep concurrency bounded so downloads do not starve package installation,
  exhaust RAM or disk, or make failures harder to diagnose. Prefer parallelism
  across independent setup phases over launching every download at once.
- Treat the staging area as disposable. Remove partial files, temporary token
  copies, and other staging artifacts after successful installation or on
  failure. Do not print authentication tokens or signed URLs.
- Preserve idempotency: detect valid final files, resume or replace incomplete
  staged files safely, and make rerunning startup converge on the same result.

### Headless workflow preparation

- Determine whether each workflow is UI-format or API-format before paid GPU
  time starts whenever possible. ComfyUI's `/prompt` endpoint requires
  API-format workflow data.
- When conversion is necessary, create API-format execution copies while
  retaining the original UI workflows for editing. Temporary conversion tools
  may be installed on the disposable VM rather than added permanently to
  bootstrap when they are only needed for one run.
- Never assume converter output is correct. Inspect prompt and seed inputs,
  batch size, disabled or bypassed branches, model selections, output paths,
  and memory-sensitive settings before submission. In particular, ensure
  disabled prompt-enhancement branches do not remain active accidentally.

### Prove one job before batching

- For multiple similar and expensive generations, run one representative job
  first as an end-to-end compatibility test. Confirm its output before
  submitting the remainder with the validated configuration.
- Parallelize independent downloads and provisioning, but serialize GPU
  inference on memory-constrained hardware unless measured VRAM headroom shows
  that concurrency is safe. LTX video generation can use roughly 14–15 GB of a
  T4's 16 GB, so concurrent generations are likely to fail.
- Keep batches bounded and fail fast: if the representative job fails, fix the
  shared workflow or environment before spending money repeating that failure.

### Reliable unattended execution and monitoring

- Prefer a detached, sequential runner for long generation batches instead of
  relying on a persistent interactive SSH session. Have it submit each prompt,
  poll ComfyUI history for terminal status, report output metadata, enforce a
  timeout, and stop clearly on errors.
- Judge progress using queue or history state, service and process health,
  logs, and GPU memory together. Low GPU utilization alone does not imply a
  stalled job because prompt encoding and other CPU-heavy phases are expected.
- Capture enough completion metadata to locate and validate outputs: filename,
  subfolder, dimensions, frame count, frame rate, and duration where available.

### Export, validate, and tear down

- Treat verified local export as the teardown gate for valuable generated
  outputs. Use this order: generation, local download, local validation,
  `terraform destroy`, then absence verification.
- Before destroying the VM, verify local files independently of the remote
  copies. For video, check that expected audio and video streams exist and
  validate codec, dimensions, frame rate, duration, size, and optionally a
  checksum.
- When visual output quality matters, extract and inspect at least one
  representative frame from every resulting video. Structural media checks do
  not prove that the generated imagery is useful. Skip visual inspection only
  when the task has no visual output or the user requested structural checks
  alone.
- After Terraform reports successful destruction, verify that Terraform state
  no longer contains the resources and that GCP reports both the instance and
  its auto-deleted boot disk as absent. Do not rely solely on the destroy exit
  status when cost control is the reason for teardown.
- Keep one-run operational tooling disposable. Promote it into startup or the
  repository only when it is likely to be required again and its ongoing
  maintenance cost is justified.

## Implementation conventions

- Format Terraform with `terraform fmt -recursive`.
- Validate Terraform from the Terraform directory. Initialization without a
  backend is acceptable for syntax and provider validation.
- Keep the ComfyUI process bound to loopback. Private access should continue to
  flow through Tailscale Serve.
- Keep startup provisioning idempotent. GCE runs the metadata startup script on
  every boot, including recovery after Spot preemption.
- Preserve the bootstrap marker and one-time driver reboot behavior unless a
  replacement provides equivalent restart safety.
- Prefer systemd for long-running VM services.
- Quote shell variables that may contain paths or external values. Do not print
  secrets to logs.
- Treat workflow JSON as data. Do not reformat large workflow files unless the
  task requires it, because mechanical rewrites create noisy diffs.

## Verification

Use the smallest checks relevant to the change:

```bash
terraform fmt -recursive -check terraform
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
bash -n scripts/startup.sh
python3 -m py_compile scripts/model_downloader.py scripts/generate_workflow_images.py
```

For infrastructure checks, prefer read-only commands first:

```bash
terraform -chdir=terraform plan
gcloud compute instances describe comfy-ui-server --zone=<configured-zone>
```

After deployment, verify `nvidia-smi`, `tailscaled`, `comfyui`,
`comfyui-downloader`, port `8188` through Tailscale, and the startup journal.

## Workflow reviews

When asked whether a workflow can run, inspect more than JSON syntax:

1. Determine whether it is UI-format or API-format JSON.
2. List required node types and identify non-core custom nodes.
3. List model filenames and their expected ComfyUI directories.
4. Identify hosted/API-only nodes that cannot run solely on the local GPU.
5. Estimate whether a T4's 16 GB VRAM is sufficient, including likely
   quantization or offloading requirements.
6. Do not deploy, download models, or submit generations when the user asked
   only for a compatibility check.

## Documentation maintenance

Update `README.md` when access methods, ports, lifecycle, provisioning,
security, or operator commands change. Update `SKILLS.md` when project
capabilities or standard operating workflows change.

