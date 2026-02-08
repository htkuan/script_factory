#!/usr/bin/env python3
"""Gemini Deep Research — 接收 instruction，透過 Deep Research API 產出研究報告。"""

import argparse
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

from google import genai

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
OUTPUT_DIR = SCRIPT_DIR / "gemini-deep-research_data"
MODEL = "deep-research-pro-preview-12-2025"


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


def run_deep_research(instruction: str, output_path: Path) -> None:
    config = load_config()
    client = genai.Client(api_key=config["api_key"])

    print(f"Starting deep research...")
    print(f"Instruction: {instruction}\n")

    stream = client.interactions.create(
        agent=MODEL,
        input=instruction,
        background=True,
        stream=True,
        agent_config={
            "type": "deep-research",
            "thinking_summaries": "auto",
        },
    )

    interaction_id = None
    report = ""

    for chunk in stream:
        if chunk.event_type == "interaction.start":
            interaction_id = chunk.interaction.id
            print(f"[Started] Interaction ID: {interaction_id}\n")

        elif chunk.event_type == "content.delta":
            if chunk.delta.type == "text":
                report += chunk.delta.text
                print(chunk.delta.text, end="", flush=True)
            elif chunk.delta.type == "thought_summary":
                print(f"[Thinking] {chunk.delta.content.text}", flush=True)

        elif chunk.event_type == "interaction.complete":
            print("\n\n[Complete] Research finished.")

        elif chunk.event_type == "error":
            print(f"\n[Error] Research failed.", file=sys.stderr)
            sys.exit(1)

    if not report:
        print("Error: No report content received.", file=sys.stderr)
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report, encoding="utf-8")
    print(f"\nReport saved to: {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Gemini Deep Research and save the report as Markdown.")
    parser.add_argument("-i", "--instruction", required=True, help="Research instruction / query")
    parser.add_argument("-o", "--output", default=None, help="Output filename (default: auto-generated from instruction)")
    args = parser.parse_args()

    if args.output:
        output_path = OUTPUT_DIR / args.output
    else:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        slug = slugify(args.instruction)
        output_path = OUTPUT_DIR / f"{timestamp}_{slug}.md"

    run_deep_research(args.instruction, output_path)


if __name__ == "__main__":
    main()
