#!/usr/bin/env python3

import argparse
import json
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


def request_json(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("workflow", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--server", default="http://127.0.0.1:8188")
    parser.add_argument("--count", type=int, default=5)
    parser.add_argument("--seed", type=int, default=123456789)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    workflow = json.loads(args.workflow.read_text())
    args.output_dir.mkdir(parents=True, exist_ok=True)
    client_id = str(uuid.uuid4())

    for index in range(args.count):
        seed = args.seed + index
        prompt = json.loads(json.dumps(workflow))
        prompt["5"]["inputs"]["seed"] = seed
        prompt["7"]["inputs"]["filename_prefix"] = f"FamilyGuyStyle_{index + 1:02d}"

        queued = request_json(
            f"{args.server}/prompt",
            {"prompt": prompt, "client_id": client_id},
        )
        prompt_id = queued["prompt_id"]
        print(f"queued {index + 1}/{args.count}: seed={seed} prompt_id={prompt_id}", flush=True)

        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            history = request_json(f"{args.server}/history/{prompt_id}")
            if prompt_id in history:
                result = history[prompt_id]
                status = result.get("status", {})
                if status.get("status_str") == "error":
                    raise RuntimeError(f"generation failed: {json.dumps(status)}")

                images = result.get("outputs", {}).get("7", {}).get("images", [])
                if images:
                    for image_number, image in enumerate(images, start=1):
                        query = urllib.parse.urlencode(
                            {
                                "filename": image["filename"],
                                "subfolder": image.get("subfolder", ""),
                                "type": image.get("type", "output"),
                            }
                        )
                        suffix = "" if len(images) == 1 else f"_{image_number}"
                        destination = args.output_dir / f"family_guy_{index + 1:02d}_seed_{seed}{suffix}.png"
                        urllib.request.urlretrieve(f"{args.server}/view?{query}", destination)
                        print(f"saved {destination}", flush=True)
                    break
            time.sleep(2)
        else:
            raise TimeoutError(f"generation timed out: prompt_id={prompt_id}")


if __name__ == "__main__":
    main()
