#!/usr/bin/env python3

import argparse
import json
import time
import urllib.request
import uuid
from pathlib import Path


def request_json(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("workflows", nargs="+", type=Path)
    parser.add_argument("--server", default="http://127.0.0.1:8188")
    parser.add_argument("--timeout", type=int, default=7200)
    args = parser.parse_args()
    client_id = str(uuid.uuid4())

    for index, workflow_path in enumerate(args.workflows, start=1):
        workflow = json.loads(workflow_path.read_text())
        queued = request_json(
            f"{args.server}/prompt", {"prompt": workflow, "client_id": client_id}
        )
        prompt_id = queued["prompt_id"]
        print(
            f"queued {index}/{len(args.workflows)}: {workflow_path.name} "
            f"prompt_id={prompt_id}",
            flush=True,
        )

        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            history = request_json(f"{args.server}/history/{prompt_id}")
            if prompt_id in history:
                result = history[prompt_id]
                status = result.get("status", {})
                if status.get("status_str") == "error":
                    raise RuntimeError(json.dumps(status, ensure_ascii=False))

                outputs = result.get("outputs", {})
                saved = []
                for node_output in outputs.values():
                    for key in ("videos", "gifs", "images"):
                        saved.extend(node_output.get(key, []))
                print(
                    f"completed {workflow_path.name}: {json.dumps(saved)}",
                    flush=True,
                )
                break
            time.sleep(5)
        else:
            raise TimeoutError(f"generation timed out: prompt_id={prompt_id}")


if __name__ == "__main__":
    main()
