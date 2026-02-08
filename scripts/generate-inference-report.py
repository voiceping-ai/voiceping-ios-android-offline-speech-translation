#!/usr/bin/env python3
"""
Build cross-platform inference throughput report from E2E result.json files.

Outputs:
  - artifacts/benchmarks/ios_tokens_per_second.svg
  - artifacts/benchmarks/android_tokens_per_second.svg
  - artifacts/benchmarks/inference_results.json
  - artifacts/benchmarks/inference_report.md

Optional:
  - update README.md between BENCHMARK_RESULTS markers
"""

from __future__ import annotations

import argparse
import html
import json
import re
import wave
from pathlib import Path
from typing import Any


IOS_MODELS = [
    "whisper-tiny",
    "whisper-base",
    "whisper-small",
    "whisper-large-v3-turbo",
    "whisper-large-v3-turbo-compressed",
    "moonshine-tiny",
    "moonshine-base",
    "sensevoice-small",
    "zipformer-20m",
    "omnilingual-300m",
    "parakeet-tdt-v3",
]

ANDROID_MODELS = [
    "whisper-tiny",
    "whisper-base",
    "whisper-base-en",
    "whisper-small",
    "whisper-large-v3-turbo",
    "whisper-large-v3-turbo-compressed",
    "moonshine-tiny",
    "moonshine-base",
    "sensevoice-small",
    "omnilingual-300m",
    "zipformer-20m",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ios-dir", default="artifacts/e2e/ios")
    parser.add_argument("--android-dir", default="artifacts/e2e/android")
    parser.add_argument("--audio", default="artifacts/benchmarks/long_en_eval.wav")
    parser.add_argument("--out-dir", default="artifacts/benchmarks")
    parser.add_argument("--readme", default="README.md")
    parser.add_argument("--update-readme", action="store_true")
    return parser.parse_args()


def audio_duration_seconds(path: Path) -> float | None:
    if not path.exists():
        return None
    try:
        with wave.open(str(path), "rb") as wav:
            frames = wav.getnframes()
            rate = wav.getframerate()
            if rate <= 0:
                return None
            return frames / float(rate)
    except Exception:
        return None


def count_words(text: str) -> int:
    return len(re.findall(r"[A-Za-z0-9']+", text))


def _entry_from_payload(
    model_id: str,
    payload: dict[str, Any] | None,
    audio_duration: float | None,
) -> dict[str, Any]:
    if payload is None:
        return {
            "model_id": model_id,
            "engine": "",
            "pass": False,
            "error": "missing result.json",
            "transcript": "",
            "word_count": 0,
            "duration_ms": 0.0,
            "duration_sec": 0.0,
            "tokens_per_second": 0.0,
            "realtime_factor": None,
        }

    transcript = str(payload.get("transcript", "") or "")
    duration_ms = float(payload.get("duration_ms", 0.0) or 0.0)
    duration_sec = duration_ms / 1000.0 if duration_ms > 0 else 0.0
    words = count_words(transcript)
    tps = (words / duration_sec) if duration_sec > 0 else 0.0
    rtf = (audio_duration / duration_sec) if (audio_duration and duration_sec > 0) else None

    return {
        "model_id": str(payload.get("model_id", model_id) or model_id),
        "engine": str(payload.get("engine", "") or ""),
        "pass": bool(payload.get("pass", False)),
        "error": payload.get("error"),
        "transcript": transcript,
        "word_count": words,
        "duration_ms": duration_ms,
        "duration_sec": duration_sec,
        "tokens_per_second": tps,
        "realtime_factor": rtf,
    }


def _load_result(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def collect_platform_results(
    base_dir: Path,
    model_order: list[str],
    audio_duration: float | None,
) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for model_id in model_order:
        payload = _load_result(base_dir / model_id / "result.json")
        entries.append(_entry_from_payload(model_id, payload, audio_duration))
    return entries


def fmt_float(value: float | None, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}"


def write_svg_chart(path: Path, title: str, entries: list[dict[str, Any]]) -> None:
    measured = [e for e in entries if e["duration_sec"] > 0 and e["tokens_per_second"] > 0]
    measured.sort(key=lambda e: e["tokens_per_second"], reverse=True)

    width = 1280
    left = 320
    right = 180
    top = 90
    bar_h = 24
    gap = 10
    chart_w = width - left - right
    height = top + max(1, len(measured)) * (bar_h + gap) + 80

    if measured:
        max_tps = max(e["tokens_per_second"] for e in measured)
    else:
        max_tps = 1.0

    lines = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>",
        "<style>",
        "text { font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif; }",
        ".title { font-size: 28px; font-weight: 700; fill: #1f2937; }",
        ".axis { font-size: 13px; fill: #4b5563; }",
        ".label { font-size: 13px; fill: #111827; }",
        ".value { font-size: 12px; fill: #111827; font-weight: 600; }",
        "</style>",
        "<rect x='0' y='0' width='100%' height='100%' fill='#ffffff' />",
        f"<text x='40' y='48' class='title'>{html.escape(title)}</text>",
    ]

    lines.append(f"<line x1='{left}' y1='{top - 12}' x2='{left}' y2='{height - 42}' stroke='#d1d5db' />")
    lines.append(f"<line x1='{left}' y1='{height - 42}' x2='{width - right + 12}' y2='{height - 42}' stroke='#d1d5db' />")

    ticks = 5
    for i in range(ticks + 1):
        value = max_tps * (i / ticks)
        x = left + chart_w * (i / ticks)
        lines.append(f"<line x1='{x:.1f}' y1='{height - 42}' x2='{x:.1f}' y2='{height - 36}' stroke='#9ca3af' />")
        lines.append(
            f"<text x='{x:.1f}' y='{height - 14}' text-anchor='middle' class='axis'>{value:.1f}</text>"
        )

    if not measured:
        lines.append(f"<text x='{left}' y='{top + 20}' class='label'>No measured results found.</text>")
    else:
        for idx, entry in enumerate(measured):
            y = top + idx * (bar_h + gap)
            bar_w = chart_w * (entry["tokens_per_second"] / max_tps)
            color = "#2563eb" if entry["pass"] else "#9ca3af"
            label = f"{entry['model_id']}"
            value = f"{entry['tokens_per_second']:.2f} tok/s"

            lines.append(
                f"<text x='{left - 14}' y='{y + bar_h - 6}' text-anchor='end' class='label'>{html.escape(label)}</text>"
            )
            lines.append(
                f"<rect x='{left}' y='{y}' width='{bar_w:.2f}' height='{bar_h}' rx='4' fill='{color}' />"
            )
            lines.append(
                f"<text x='{left + bar_w + 8:.2f}' y='{y + bar_h - 6}' class='value'>{html.escape(value)}</text>"
            )

    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def platform_table_md(title: str, entries: list[dict[str, Any]]) -> str:
    lines = [f"#### {title}", "", "| Model | Engine | Words | Duration (s) | Tok/s | RTF | Pass |", "|---|---|---:|---:|---:|---:|---|"]
    for e in entries:
        pass_label = "PASS" if e["pass"] else "FAIL"
        if e["duration_sec"] <= 0:
            lines.append(f"| `{e['model_id']}` | {e['engine'] or '-'} | 0 | n/a | n/a | n/a | {pass_label} |")
            continue
        lines.append(
            f"| `{e['model_id']}` | {e['engine'] or '-'} | {e['word_count']} | "
            f"{fmt_float(e['duration_sec'], 2)} | {fmt_float(e['tokens_per_second'], 2)} | "
            f"{fmt_float(e['realtime_factor'], 2)} | {pass_label} |"
        )
    lines.append("")
    return "\n".join(lines)


def build_report_markdown(
    audio_path: Path,
    audio_duration: float | None,
    out_dir: Path,
    ios_entries: list[dict[str, Any]],
    android_entries: list[dict[str, Any]],
) -> str:
    audio_line = (
        f"`{audio_path}` ({audio_duration:.2f}s, 16kHz mono WAV)"
        if audio_duration
        else f"`{audio_path}` (duration unknown)"
    )
    lines = [
        "### Inference Token Speed Benchmarks",
        "",
        "Measured from E2E `result.json` files using a longer English fixture.",
        "",
        f"Fixture: {audio_line}",
        "",
        "#### Evaluation Method",
        "",
        "- Per-model E2E runs with the same English fixture on each platform.",
        "- `duration_sec = duration_ms / 1000` from each model `result.json`.",
        "- `token_count` is computed from transcript words: `[A-Za-z0-9']+`.",
        "- `tok/s = token_count / duration_sec`.",
        "- `RTF = audio_duration_sec / duration_sec`.",
        "",
        "#### iOS Graph",
        "",
        f"![iOS tokens/sec]({(out_dir / 'ios_tokens_per_second.svg').as_posix()})",
        "",
        platform_table_md("iOS Results", ios_entries),
        "#### Android Graph",
        "",
        f"![Android tokens/sec]({(out_dir / 'android_tokens_per_second.svg').as_posix()})",
        "",
        platform_table_md("Android Results", android_entries),
        "#### Reproduce",
        "",
        "1. `rm -rf artifacts/e2e/ios/* artifacts/e2e/android/*`",
        "2. `TARGET_SECONDS=30 scripts/prepare-long-eval-audio.sh`",
        "3. `EVAL_WAV_PATH=artifacts/benchmarks/long_en_eval.wav scripts/ios-e2e-test.sh`",
        "4. `INSTRUMENT_TIMEOUT_SEC=300 EVAL_WAV_PATH=artifacts/benchmarks/long_en_eval.wav scripts/android-e2e-test.sh`",
        "5. `python3 scripts/generate-inference-report.py --audio artifacts/benchmarks/long_en_eval.wav --update-readme`",
        "",
        "One-command runner: `TARGET_SECONDS=30 scripts/run-inference-benchmarks.sh`",
        "",
    ]
    return "\n".join(lines)


def update_readme_section(readme_path: Path, block: str) -> None:
    start = "<!-- BENCHMARK_RESULTS_START -->"
    end = "<!-- BENCHMARK_RESULTS_END -->"
    wrapped = f"{start}\n{block}\n{end}\n"

    text = readme_path.read_text(encoding="utf-8") if readme_path.exists() else ""
    if start in text and end in text:
        prefix = text.split(start)[0]
        suffix = text.split(end, 1)[1]
        updated = prefix + wrapped + suffix.lstrip("\n")
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        updated = text + "\n" + wrapped

    readme_path.write_text(updated, encoding="utf-8")


def main() -> None:
    args = parse_args()

    ios_dir = Path(args.ios_dir)
    android_dir = Path(args.android_dir)
    out_dir = Path(args.out_dir)
    audio_path = Path(args.audio)
    readme_path = Path(args.readme)

    out_dir.mkdir(parents=True, exist_ok=True)
    audio_duration = audio_duration_seconds(audio_path)

    ios_entries = collect_platform_results(ios_dir, IOS_MODELS, audio_duration)
    android_entries = collect_platform_results(android_dir, ANDROID_MODELS, audio_duration)

    write_svg_chart(out_dir / "ios_tokens_per_second.svg", "iOS Inference Throughput (tokens/sec)", ios_entries)
    write_svg_chart(
        out_dir / "android_tokens_per_second.svg",
        "Android Inference Throughput (tokens/sec)",
        android_entries,
    )

    combined = {
        "audio_fixture": str(audio_path),
        "audio_duration_sec": audio_duration,
        "ios": ios_entries,
        "android": android_entries,
    }
    (out_dir / "inference_results.json").write_text(
        json.dumps(combined, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    report_md = build_report_markdown(audio_path, audio_duration, out_dir, ios_entries, android_entries)
    (out_dir / "inference_report.md").write_text(report_md, encoding="utf-8")

    if args.update_readme:
        update_readme_section(readme_path, report_md)

    print(f"Wrote: {(out_dir / 'ios_tokens_per_second.svg').as_posix()}")
    print(f"Wrote: {(out_dir / 'android_tokens_per_second.svg').as_posix()}")
    print(f"Wrote: {(out_dir / 'inference_results.json').as_posix()}")
    print(f"Wrote: {(out_dir / 'inference_report.md').as_posix()}")
    if args.update_readme:
        print(f"Updated README: {readme_path.as_posix()}")


if __name__ == "__main__":
    main()
