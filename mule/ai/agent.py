"""
AI-assist failure handler.

When a stage fails, the orchestrator calls get_corrective_step() with context
about the failure. This module sends that context to Claude and returns a
suggested corrective command or explanation.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import anthropic

_CLAUDE_MD = (Path(__file__).resolve().parent.parent.parent / "CLAUDE.md").read_text()

SYSTEM_PROMPT = f"""You are an expert embedded-Linux hacker helping to remotely unlock an Expresso HD stationary bike.
The bike runs Ubuntu 12.04.5 LTS (32-bit), Unreal Engine 3 game software (Inca/Dispenser), and
stores content-lock data in MySQL and Lua files.

Here is the full reverse-engineering reference for the system:

<CLAUDE_MD>
{_CLAUDE_MD}
</CLAUDE_MD>

When given a JSON failure context, respond with:
1. A one-sentence diagnosis of what went wrong.
2. A corrective shell command to run over SSH on the bike (safe, idempotent), or a revised approach.
3. If the issue requires human judgment (e.g. unknown hardware variant), say so clearly.

Be concise. Output format:
DIAGNOSIS: <one sentence>
FIX: <shell command or "HUMAN REVIEW REQUIRED: <reason>">
"""


def get_corrective_step(context: dict) -> str:
    client = anthropic.Anthropic()
    msg = client.messages.create(
        model="claude-opus-4-7",
        max_tokens=512,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": json.dumps(context, indent=2)}],
    )
    return msg.content[0].text
