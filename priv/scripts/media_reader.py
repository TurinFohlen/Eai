#!/usr/bin/env python3
"""
media_reader.py — EAI 多媒体提取后端
用法: python3 media_reader.py <file_path> [--max-dim N] [--frame-time S] [--type auto|image|video]
输出: JSON (stdout)，错误时 ok=false
"""

import sys
import json
import base64
import io
import os
import mimetypes
import subprocess
import argparse

# ── Pillow 依赖检查 ────────────────────────────────────────────────────────
try:
    from PIL import Image
    HAS_PILLOW = True
except ImportError:
    HAS_PILLOW = False

# ── 大小上限 ───────────────────────────────────────────────────────────────
IMAGE_SIZE_LIMIT = 5  * 1024 * 1024   # 5 MB
VIDEO_SIZE_LIMIT = 200 * 1024 * 1024  # 200 MB

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tiff", ".tif", ".ico", ".svg"}
VIDEO_EXTS = {".mp4", ".mov", ".avi", ".mkv", ".webm", ".flv", ".wmv", ".m4v", ".ts", ".mpeg", ".mpg"}


def err(reason: str) -> None:
    print(json.dumps({"ok": False, "reason": reason}))
    sys.exit(0)


def detect_type(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    if ext in IMAGE_EXTS:
        return "image"
    if ext in VIDEO_EXTS:
        return "video"
    # fallback: libmagic via `file` command
    try:
        out = subprocess.check_output(["file", "--mime-type", "-b", path], timeout=5).decode().strip()
        if out.startswith("image/"):
            return "image"
        if out.startswith("video/"):
            return "video"
    except Exception:
        pass
    return "unknown"


# ── 图片处理 ───────────────────────────────────────────────────────────────

def handle_image(path: str, max_dim: int) -> dict:
    if not HAS_PILLOW:
        return {"ok": False, "reason": "Pillow not installed; run: pip install Pillow"}

    file_size = os.path.getsize(path)
    if file_size > IMAGE_SIZE_LIMIT:
        return {"ok": False, "reason": f"image too large ({file_size} bytes > 5 MB limit); use execute_script to process first"}

    img = Image.open(path)
    orig_w, orig_h = img.width, img.height
    fmt = img.format or "PNG"
    mime = Image.MIME.get(fmt, "image/png")

    compression = "original"
    if max_dim and max_dim > 0:
        ratio = min(max_dim / orig_w, max_dim / orig_h, 1.0)
        if ratio < 1.0:
            new_w = int(orig_w * ratio)
            new_h = int(orig_h * ratio)
            img = img.resize((new_w, new_h), Image.LANCZOS)
            compression = f"resized {orig_w}x{orig_h} → {new_w}x{new_h}"

    # 强制 RGB/RGBA（GIF 可能是 P mode）
    if img.mode not in ("RGB", "RGBA", "L"):
        img = img.convert("RGBA")

    buf = io.BytesIO()
    save_fmt = fmt if fmt in ("PNG", "JPEG", "WEBP", "GIF") else "PNG"
    img.save(buf, format=save_fmt)
    raw = buf.getvalue()

    return {
        "ok": True,
        "type": "image",
        "mime": mime,
        "file_size": file_size,
        "metadata": {
            "width": img.width,
            "height": img.height,
            "original_width": orig_w,
            "original_height": orig_h,
            "format": fmt,
            "mode": img.mode
        },
        "base64": base64.b64encode(raw).decode(),
        "compression": compression
    }


# ── 视频处理 ───────────────────────────────────────────────────────────────

def check_ffmpeg() -> bool:
    try:
        subprocess.check_output(["ffprobe", "-version"], stderr=subprocess.DEVNULL, timeout=5)
        return True
    except Exception:
        return False


def handle_video(path: str, max_dim: int, frame_time: float) -> dict:
    file_size = os.path.getsize(path)
    if file_size > VIDEO_SIZE_LIMIT:
        return {"ok": False, "reason": f"video too large ({file_size} bytes > 200 MB limit)"}

    if not check_ffmpeg():
        return {"ok": False, "reason": "ffmpeg/ffprobe not found; install with: sudo apt install ffmpeg"}

    # ── 元数据 ──
    probe_cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_format", "-show_streams",
        path
    ]
    try:
        probe_out = subprocess.check_output(probe_cmd, timeout=15)
        probe_data = json.loads(probe_out)
    except Exception as e:
        return {"ok": False, "reason": f"ffprobe failed: {e}"}

    video_stream = next(
        (s for s in probe_data.get("streams", []) if s.get("codec_type") == "video"),
        None
    )
    if not video_stream:
        return {"ok": False, "reason": "no video stream found"}

    # fps 是 "30000/1001" 形式
    def safe_eval_fps(s):
        try:
            num, den = s.split("/")
            return round(int(num) / int(den), 3)
        except Exception:
            return 0.0

    duration = float(
        video_stream.get("duration")
        or probe_data.get("format", {}).get("duration", 0)
    )

    metadata = {
        "width":        video_stream.get("width"),
        "height":       video_stream.get("height"),
        "duration_sec": round(duration, 3),
        "fps":          safe_eval_fps(video_stream.get("avg_frame_rate", "0/1")),
        "codec":        video_stream.get("codec_name", "unknown"),
        "bit_rate":     probe_data.get("format", {}).get("bit_rate")
    }

    # ── 帧提取 ──
    vf = f"scale='min({max_dim},iw)':'min({max_dim},ih)':force_original_aspect_ratio=decrease" \
         if max_dim and max_dim > 0 else "copy"

    ffmpeg_cmd = [
        "ffmpeg", "-y",
        "-ss", str(frame_time),
        "-i", path,
        "-frames:v", "1",
        "-vf", vf,
        "-f", "image2pipe",
        "-vcodec", "png",
        "pipe:1"
    ]
    try:
        proc = subprocess.run(
            ffmpeg_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30
        )
        frame_bytes = proc.stdout
        if proc.returncode != 0 or not frame_bytes:
            return {"ok": False, "reason": f"frame extraction failed: {proc.stderr.decode()[:200]}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "reason": "frame extraction timed out"}

    # 可选：再用 Pillow 确认尺寸
    actual_w, actual_h = metadata["width"], metadata["height"]
    if HAS_PILLOW:
        try:
            frame_img = Image.open(io.BytesIO(frame_bytes))
            actual_w, actual_h = frame_img.width, frame_img.height
        except Exception:
            pass

    compression = f"frame at {frame_time}s"
    if max_dim and max_dim > 0:
        compression += f", scaled to max {max_dim}px ({actual_w}x{actual_h})"

    return {
        "ok": True,
        "type": "video",
        "mime": "image/png",        # 返回的是帧图像
        "file_size": file_size,
        "metadata": metadata,
        "base64": base64.b64encode(frame_bytes).decode(),
        "compression": compression
    }


# ── 入口 ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("file_path")
    parser.add_argument("--max-dim",    type=int,   default=1024)
    parser.add_argument("--frame-time", type=float, default=0.0)
    parser.add_argument("--type",       default="auto", choices=["auto", "image", "video"])
    args = parser.parse_args()

    path = os.path.abspath(args.file_path)

    if not os.path.isfile(path):
        err(f"file not found: {path}")

    media_type = args.type if args.type != "auto" else detect_type(path)

    if media_type == "image":
        result = handle_image(path, args.max_dim)
    elif media_type == "video":
        result = handle_video(path, args.max_dim, args.frame_time)
    else:
        err(f"unsupported or undetected media type for: {path}")

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
