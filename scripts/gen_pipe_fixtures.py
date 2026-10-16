#!/usr/bin/env python3
"""Generates the pipe-reference request bodies (IMPLEMENTATION_PLAN.md section 2.3).

    python3 -I scripts/gen_pipe_fixtures.py --pipe doc/openwebui_gemini_filter.py \
        --out ImageGenTests/Fixtures/PipeReference

Imports the pipe with stub `pydantic` and `requests` modules (no third-party packages needed),
calls Pipe().pipe(body) for each case, captures the payload and URL from the stubbed
requests.post, and writes <case>.payload.json and <case>.url.txt with the key as <KEY>.
"""
import argparse
import base64
import json
import os
import sys
import types

KEY = "<KEY>"


def install_stubs(captured):
    pydantic = types.ModuleType("pydantic")

    class BaseModel:
        pass

    def Field(default=None, **_):
        return default

    pydantic.BaseModel = BaseModel
    pydantic.Field = Field

    requests = types.ModuleType("requests")
    exceptions = types.ModuleType("requests.exceptions")

    class RequestException(Exception):
        pass

    class Timeout(RequestException):
        pass

    exceptions.RequestException = RequestException
    exceptions.Timeout = Timeout

    class Response:
        status_code = 200
        text = ""

        def json(self):
            return {"candidates": [{"content": {"parts": [{"text": "ok"}]}}]}

    def post(url, headers=None, json=None, timeout=None):
        captured.append({"url": url, "headers": headers, "payload": json, "timeout": timeout})
        return Response()

    requests.post = post
    requests.exceptions = exceptions
    sys.modules["pydantic"] = pydantic
    sys.modules["requests"] = requests
    sys.modules["requests.exceptions"] = exceptions


def load_pipe(path):
    with open(path, encoding="utf-8") as f:
        source = f.read()
    module = types.ModuleType("openwebui_gemini_filter")
    module.__file__ = path
    # The pipe annotates with `dict | None`, which Python 3.9 can't evaluate at def time;
    # postponed annotations make it importable there without changing behavior.
    code = compile("from __future__ import annotations\n" + source, path, "exec")
    exec(code, module.__dict__)
    return module.Pipe


def data_url(mime, b64):
    return f"data:{mime};base64,{b64}"


def markdown_image(mime, b64):
    return f"\n\n![Generated Image](data:{mime};base64,{b64})\n\n"


def cases(png, jpg):
    """name -> (messages, valves)."""
    png_part = {"type": "image_url", "image_url": {"url": data_url("image/png", png)}}
    jpg_part = {"type": "image_url", "image_url": {"url": data_url("image/jpeg", jpg)}}

    def text(t):
        return {"type": "text", "text": t}

    return {
        "p1_text_only": ([{"role": "user", "content": "a lighthouse at dusk"}], {}),
        "p2_upload_and_text": ([{"role": "user", "content": [png_part, text("make it night")]}], {}),
        "p3_edit_latest": (
            [
                {"role": "user", "content": "a lighthouse at dusk"},
                {"role": "assistant", "content": "Here it is." + markdown_image("image/png", png)},
                {"role": "user", "content": "add a full moon"},
            ],
            {},
        ),
        "p4_image_only": ([{"role": "user", "content": [jpg_part]}], {}),
        "p5_threshold_only_high": (
            [{"role": "user", "content": "a lighthouse at dusk"}],
            {"SAFETY_THRESHOLD": "BLOCK_ONLY_HIGH"},
        ),
        "p6_latest_is_user_upload": (
            [
                {"role": "user", "content": [png_part, text("describe this")]},
                {"role": "assistant", "content": "It is a gradient."},
                {"role": "user", "content": "now make it blue"},
            ],
            {},
        ),
        "p7_latest_of_two_outputs": (
            [
                {"role": "user", "content": "two variations"},
                {
                    "role": "assistant",
                    "content": markdown_image("image/png", png) + "and" + markdown_image("image/jpeg", jpg),
                },
                {"role": "user", "content": "use the second one"},
            ],
            {},
        ),
        "p8_latest_of_two_uploads": (
            [
                {"role": "user", "content": [png_part, jpg_part, text("compare these")]},
                {"role": "assistant", "content": "The second is square."},
                {"role": "user", "content": "edit the last one"},
            ],
            {},
        ),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pipe", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--images", default=None, help="defaults to <out>/../Images")
    args = parser.parse_args()

    images = args.images or os.path.join(os.path.dirname(os.path.abspath(args.out)), "Images")
    with open(os.path.join(images, "tiny_16x9.png"), "rb") as f:
        png = base64.b64encode(f.read()).decode("ascii")
    with open(os.path.join(images, "tiny_square.jpg"), "rb") as f:
        jpg = base64.b64encode(f.read()).decode("ascii")

    captured = []
    install_stubs(captured)
    Pipe = load_pipe(args.pipe)
    os.makedirs(args.out, exist_ok=True)

    for name, (messages, valves) in cases(png, jpg).items():
        pipe = Pipe()
        pipe.valves.GOOGLE_API_KEY = KEY
        for k, v in valves.items():
            setattr(pipe.valves, k, v)
        captured.clear()
        result = pipe.pipe({"model": "gemini-3.1-flash-image", "messages": messages})
        if len(captured) != 1:
            sys.exit(f"{name}: pipe made {len(captured)} requests; result: {result!r}")
        call = captured[0]
        with open(os.path.join(args.out, f"{name}.payload.json"), "w", encoding="utf-8") as f:
            json.dump(call["payload"], f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        with open(os.path.join(args.out, f"{name}.url.txt"), "w", encoding="utf-8") as f:
            f.write(call["url"] + "\n")
        print(f"{name}: {len(call['payload']['contents'][0]['parts'])} part(s)")


if __name__ == "__main__":
    main()
