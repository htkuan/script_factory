#!/usr/bin/env python3
"""OpenAI Deep Research — 接收 instruction，透過 Responses API 產出研究報告。"""

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

from openai import OpenAI

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
OUTPUT_DIR = SCRIPT_DIR / "openai-deep-research_data"
DEFAULT_MODEL = "o3-deep-research"


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        print(f"Error: {CONFIG_PATH} not found. Copy config.example.json and fill in your API key.", file=sys.stderr)
        sys.exit(1)
    with open(CONFIG_PATH) as f:
        return json.load(f)


def slugify(text: str, max_len: int = 60) -> str:
    slug = re.sub(r"[^\w\s-]", "", text.lower())
    slug = re.sub(r"[\s_]+", "-", slug).strip("-")
    return slug[:max_len]


def run_deep_research(instruction: str, output_path: Path, model: str) -> None:
    config = load_config()
    client = OpenAI(api_key=config["api_key"])

    print(f"Starting deep research with {model}...")
    print(f"Instruction: {instruction}\n")

    stream = client.responses.create(
        model=model,
        input=[{"role": "user", "content": instruction}],
        tools=[{"type": "web_search_preview"}],
        reasoning={"summary": "auto"},
        background=True,
        stream=True,
    )

    report = ""

    for event in stream:
        event_type = event.type

        if event_type == "response.created":
            print(f"[Started] Response ID: {event.response.id}\n")

        elif event_type == "response.output_item.added":
            item = event.item
            print(f"[+] Output item: {item.type}", flush=True)

        elif event_type == "response.output_text.delta":
            report += event.delta
            print(event.delta, end="", flush=True)

        elif event_type == "response.reasoning_summary_text.delta":
            print(f"[Thinking] {event.delta}", flush=True)

        elif event_type == "response.completed":
            print("\n\n[Complete] Research finished.")

        elif event_type == "error":
            print(f"\n[Error] {event}", file=sys.stderr)
            sys.exit(1)

    if not report:
        print("Error: No report content received.", file=sys.stderr)
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report, encoding="utf-8")
    print(f"\nReport saved to: {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run OpenAI Deep Research and save the report as Markdown.")
    parser.add_argument("-i", "--instruction", required=True, help="Research instruction / query")
    parser.add_argument("-o", "--output", default=None, help="Output filename (default: auto-generated from instruction)")
    parser.add_argument("-m", "--model", default=DEFAULT_MODEL, choices=["o3-deep-research", "o4-mini-deep-research"], help="Model to use (default: o3-deep-research)")
    args = parser.parse_args()

    if args.output:
        output_path = OUTPUT_DIR / args.output
    else:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        slug = slugify(args.instruction)
        output_path = OUTPUT_DIR / f"{timestamp}_{slug}.md"

    run_deep_research(args.instruction, output_path, args.model)


if __name__ == "__main__":
    main()
