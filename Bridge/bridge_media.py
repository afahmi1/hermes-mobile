"""Validate user-selected media and stage it for the installed Hermes runtime."""
import base64
import hashlib
from functools import lru_cache
import importlib.util
from io import BytesIO
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import time

# Total attachment budget per send. HERMES_MOBILE_MEDIA_MAX_BYTES can raise it (longer clips
# on gateways that accept them); it is clamped so a raised budget can never exceed the
# bridge's JSON body cap once base64-encoded: 8 MiB raw -> ~10.7 MiB encoded < 12 MiB body.
def _max_bytes():
    try:
        configured = int(os.environ.get("HERMES_MOBILE_MEDIA_MAX_BYTES", ""))
    except ValueError:
        configured = 0
    if configured <= 0:
        return 4 * 1024 * 1024
    return max(256 * 1024, min(8 * 1024 * 1024, configured))


MAX_BYTES = _max_bytes()
JPEG = "image/jpeg"
MP4 = "video/mp4"


class MediaError(ValueError):
    pass


@lru_cache(maxsize=1)
def supported():
    try:
        from gateway.session_ingress_media import admit_attachments
        from gateway.platforms.base import get_image_cache_dir
        from PIL import Image
        return callable(admit_attachments) and callable(get_image_cache_dir) and callable(Image.open)
    except ImportError:
        return False


def _probe_profile(home, root):
    # One interpreter per profile prevents Hermes's environment/config singletons from
    # resolving the previous profile's credentials. This probe never submits media.
    import socket
    def offline(*args, **kwargs):
        raise OSError("offline capability check")
    socket.socket.connect = socket.socket.connect_ex = offline
    sys.path.insert(0, root)
    from hermes_cli.config import load_config_readonly
    from hermes_cli.env_loader import load_hermes_dotenv
    from hermes_cli.tools_config import _get_platform_tools
    from tools.vision_tools import _configured_aux_model, check_video_requirements, video_analyze_tool
    from agent.auxiliary_client import aux_probe_mode, resolve_vision_provider_client
    from agent.models_dev import get_model_info
    from toolsets import resolve_toolset
    if os.name == "nt":
        import win32security
    load_hermes_dotenv(hermes_home=home, load_external_secrets=False)
    config = load_config_readonly()
    enabled = _get_platform_tools(config, "cli")
    disabled = (config.get("agent") or {}).get("disabled_toolsets") or []
    disabled = [disabled] if isinstance(disabled, str) else disabled
    if any(n == "video_analyze" or "video_analyze" in resolve_toolset(n) for n in disabled):
        return False
    if (not callable(video_analyze_tool) or not check_video_requirements()
            or not any("video_analyze" in resolve_toolset(n) for n in enabled)):
        return False
    # Hermes's tool check covers any visual client, including image-only models.
    # Its video handler uses the video-specific model override on the vision route.
    model = _configured_aux_model(("video", "vision"), ("AUXILIARY_VIDEO_MODEL", "AUXILIARY_VISION_MODEL"))
    with aux_probe_mode():
        for settings in ({}, {"provider": "auto"}):
            provider, client, routed = resolve_vision_provider_client(**settings, model=model)
            if client is not None:
                metadata = get_model_info(provider, routed, allow_network=False, config=config) if routed else None
                return bool(metadata and "video" in metadata.input_modalities)
    return False


@lru_cache(maxsize=64)
def _cached_video(home, generation):
    try:
        location = importlib.util.find_spec("hermes_cli").origin
        root = Path(location).parent.parent
        env = dict(os.environ, HERMES_HOME=str(home), HERMES_DISABLE_LAZY_INSTALLS="1")
        result = subprocess.run([sys.executable, str(Path(__file__).resolve()), str(home), str(root)],
                                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=12, check=False)
        return result.returncode == 0
    except (AttributeError, ImportError, OSError, subprocess.TimeoutExpired, TypeError):
        return False


@lru_cache(maxsize=64)
def _profile_lock(home):
    return threading.Lock()


def video_supported(home):
    directory = Path(home).resolve()
    def modified(name):
        try:
            return (directory / name).stat().st_mtime_ns
        except OSError:
            return None
    key = str(directory)
    generation = (int(time.monotonic() // 60), modified("config.yaml"), modified(".env"), modified("auth.json"))
    with _profile_lock(key):
        return _cached_video(key, generation)


def _boxes(data):
    index = 0
    while index < len(data):
        if len(data) - index < 8:
            raise ValueError
        size = int.from_bytes(data[index:index + 4], "big")
        kind = bytes(data[index + 4:index + 8])
        header = 8
        if size == 1:
            header = 16
            size = int.from_bytes(data[index + 8:index + 16], "big")
        elif size == 0:
            size = len(data) - index
        if size < header or size > len(data) - index:
            raise ValueError
        yield kind, data[index + header:index + size]
        index += size


def _validate_clip(raw):
    """Accept a standalone MP4 with local media data and an actual video track."""
    if raw[4:8] != b"ftyp":
        raise ValueError
    brand = media = video = False
    for kind, box in _boxes(memoryview(raw)):
        if kind == b"ftyp" and 8 <= len(box) <= 256 and len(box) % 4 == 0:
            known = {b"isom", b"iso2", b"mp41", b"mp42", b"avc1", b"iso5", b"iso6", b"M4V "}
            brand = any(bytes(box[i:i + 4]) in known for i in [0, *range(8, len(box), 4)])
        if kind == b"mdat" and len(box):
            media = True
        if kind != b"moov":
            continue
        for tk, track in _boxes(box):
            if tk != b"trak":
                continue
            for mk, mdia in _boxes(track):
                if mk != b"mdia":
                    continue
                for field, value in _boxes(mdia):
                    if field == b"hdlr" and bytes(value[8:12]) == b"vide":
                        video = True
                    if field == b"minf":
                        for ik, info in _boxes(value):
                            if ik == b"dinf":
                                for dk, ref in _boxes(info):
                                    if dk == b"dref":
                                        for rk, entry in _boxes(ref[8:]):
                                            if rk != b"url " or bytes(entry) != b"\x00\x00\x00\x01":
                                                raise ValueError
    if not (brand and media and video):
        raise ValueError


def decode(items):
    if items is None or items == []:
        return []
    if not isinstance(items, list) or not 1 <= len(items) <= 4:
        raise MediaError("Attach one MP4 or up to four JPEG images.")
    frames = []
    remaining = MAX_BYTES
    for item in items:
        if not isinstance(item, dict) or set(item) != {"filename", "mime", "base64"}:
            raise MediaError("Invalid attachment fields.")
        name, encoded, mime = item["filename"], item["base64"], item["mime"]
        if mime not in (JPEG, MP4) or (mime == MP4 and len(items) != 1):
            raise MediaError("Attach one MP4 or up to four JPEG images.")
        if (not isinstance(name, str) or not 0 < len(name) <= 140 or not name.isprintable()
                or any(c in name for c in "/\\:") or name in (".", "..")):
            raise MediaError("Invalid attachment name.")
        if not isinstance(encoded, str) or len(encoded) > (remaining + 2) // 3 * 4:
            raise MediaError("Attachments must total 4 MiB or less.")
        try:
            raw = base64.b64decode(encoded, validate=True)
            if not raw or len(raw) > remaining:
                raise ValueError
        except ValueError:
            raise MediaError("Invalid or oversized media data.") from None
        if mime == MP4:
            try:
                _validate_clip(raw)
            except ValueError:
                raise MediaError("The video must be a self-contained MP4 with a video track.") from None
        else:
            if not supported():
                raise MediaError("This Hermes installation does not support native image attachments.")
            from PIL import Image
            try:
                with Image.open(BytesIO(raw), formats=("JPEG",)) as image:
                    if image.width * image.height > 12_000_000:
                        raise ValueError
                    image.load()
            except (ValueError, OSError, Image.DecompressionBombError):
                raise MediaError("An attachment is damaged, is too large, or is not a JPEG.") from None
        remaining -= len(raw)
        frames.append((name, hashlib.sha256(raw).hexdigest(), raw, mime))
    return frames


def _clip_dir(home):
    directory = Path(home).resolve() / "mobile-video-inputs"
    directory.mkdir(mode=0o700, exist_ok=True)
    st = directory.lstat()
    if not stat.S_ISDIR(st.st_mode) or getattr(st, "st_file_attributes", 0) & 0x400:
        raise MediaError("The profile cannot privately store video.")
    if os.name == "nt":
        import win32api, win32con, win32security as ws, ntsecuritycon
        token = ws.OpenProcessToken(win32api.GetCurrentProcess(), win32con.TOKEN_QUERY)
        sid = ws.GetTokenInformation(token, ws.TokenUser)[0]
        acl = ws.ACL()
        for account in (sid, ws.CreateWellKnownSid(ws.WinLocalSystemSid)):
            acl.AddAccessAllowedAceEx(ws.ACL_REVISION, 3, ntsecuritycon.FILE_ALL_ACCESS, account)
        ws.SetNamedSecurityInfo(str(directory), ws.SE_FILE_OBJECT, ws.DACL_SECURITY_INFORMATION |
                                ws.PROTECTED_DACL_SECURITY_INFORMATION, None, None, acl, None)
    else:
        directory.chmod(0o700)
    prune_clips(home)
    return directory


def prune_clips(home):
    directory = Path(home).resolve() / "mobile-video-inputs"
    if directory.resolve() != directory or not directory.is_dir():
        return
    cutoff = time.time() - 4 * 3600
    for clip in directory.glob("hm_send_*.mp4"):
        try:
            if clip.lstat().st_mtime < cutoff:
                clip.unlink(missing_ok=True)
        except OSError:
            pass


def stage(frames, home):
    paths = []
    try:
        for _, _, raw, mime in frames:
            if mime == MP4:
                directory, ext = _clip_dir(home), ".mp4"
            else:
                from gateway.platforms.base import get_image_cache_dir
                directory, ext = get_image_cache_dir().resolve(), ".jpg"
            with tempfile.NamedTemporaryFile(prefix="hm_send_", suffix=ext, dir=directory, delete=False) as f:
                paths.append({"path": f.name, "mime": mime})
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
        return paths
    except BaseException:
        discard(paths)
        raise


def discard(paths):
    for item in paths or []:
        Path(item["path"]).unlink(missing_ok=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(1)
    raise SystemExit(0 if _probe_profile(*sys.argv[1:]) else 1)
