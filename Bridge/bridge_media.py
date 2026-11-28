"""Validate user-selected media and stage it for the installed Hermes runtime."""
import base64
import hashlib
from functools import lru_cache
import importlib.util
from io import BytesIO
import os
from pathlib import Path
import re
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
        # Voice memos, screen recordings and phone videos are routinely 5 to 50 MB. The bridge is the phone's
        # door into Hermes, so it takes what Telegram would and more. HERMES_MOBILE_MEDIA_MAX_BYTES overrides.
        return 50 * 1024 * 1024
    return max(256 * 1024, min(128 * 1024 * 1024, configured))


MAX_BYTES = _max_bytes()
JPEG = "image/jpeg"
MP4 = "video/mp4"
MAX_ITEMS = 20  # twice a Telegram album
# The largest photo accepted, in pixels. An iPhone's 48 MP mode is 8064 x 6048 (48.8 MP); its default 12 MP
# photo (4032 x 3024) is 12.19 MP, which the old 12,000,000 cap refused outright.
MAX_PIXELS = 50_000_000


def native_image_limit():
    """How many images Hermes takes as native attachments in one message (gateway/session_ingress_media.py,
    10 in Hermes 0.23). Past it, Hermes refuses the WHOLE message as invalid_params, so the rest go by path."""
    try:
        from gateway.session_ingress_media import _ATTACHMENT_LIMIT
        return max(1, int(_ATTACHMENT_LIMIT))
    except Exception:
        return 10


def message_limit():
    """Hermes's own cap on all media in one message (gateway.max_inbound_media_bytes, 128 MB by default).
    The phone sizes a photo batch to fit it instead of having the whole message refused."""
    try:
        from gateway.platforms.base import get_inbound_media_max_bytes
        return max(0, int(get_inbound_media_max_bytes()))
    except Exception:
        return 128 * 1024 * 1024


def _check_jpeg(source):
    """A real JPEG within MAX_PIXELS. verify() parses every marker without decoding the pixels, so fifteen
    48 MP photos don't need 2 GB of memory to admit."""
    from PIL import Image
    try:
        with Image.open(source, formats=("JPEG",)) as image:
            if image.width * image.height > MAX_PIXELS:
                raise ValueError
            image.verify()
        # verify() checks the structure, not the pixel data: a photo cut off mid-scan still passes. A complete JPEG
        # ends with the end-of-image marker (some cameras pad a few bytes after it).
        if hasattr(source, "seek"):
            source.seek(0, 2)
            end = source.tell()
            source.seek(max(0, end - 64))
            tail = source.read()
        else:
            with open(source, "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 64))
                tail = f.read()
        if b"\xff\xd9" not in tail:
            raise ValueError
    except (ValueError, OSError, SyntaxError, Image.DecompressionBombError):
        raise MediaError("An image is damaged, is larger than %d megapixels, or is not a JPEG." % (MAX_PIXELS // 1_000_000)) from None
MIME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}$")
EXT = re.compile(r"^[A-Za-z0-9]{1,10}$")


class MediaError(ValueError):
    pass


# Set by the bridge: where finished resumable uploads live (bridge_uploads). None = uploads unsupported.
UPLOADS = None


def valid_name(name):
    return (isinstance(name, str) and 0 < len(name) <= 140 and name.isprintable()
            and not any(c in name for c in "/\\:") and name not in (".", ".."))


def valid_mime(mime):
    # Any real media type, images included: an iPhone photo is HEIC, and it should arrive as HEIC.
    return isinstance(mime, str) and bool(MIME.match(mime))


def _open_any_image(source):
    """Pillow with HEIC/HEIF support when pillow-heif is installed (it ships with Hermes)."""
    from PIL import Image
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except Exception:
        pass
    return Image.open(source)


def _check_other_image(source):
    """A non-JPEG image is kept as its original file, so it only has to be within MAX_PIXELS when it can be read.
    An image Pillow can't parse (a format it doesn't know) still goes through as a plain file."""
    from PIL import Image
    try:
        with _open_any_image(source) as image:
            pixels = image.width * image.height
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError):
        return
    if pixels > MAX_PIXELS:
        raise MediaError("An image is larger than %d megapixels." % (MAX_PIXELS // 1_000_000))


def _uploaded(item):
    """A frame for a file sent through the resumable upload path: (name, sha256, Path, mime)."""
    import bridge_uploads
    if UPLOADS is None:
        raise MediaError("This bridge can't take large uploads yet. Update the bridge.")
    try:
        path, meta = bridge_uploads.resolve(UPLOADS, item["upload_id"])
    except bridge_uploads.UploadError as exc:
        raise MediaError(str(exc)) from None
    if (item["filename"], item["mime"]) != (meta["filename"], meta["mime"]):
        raise MediaError("The attachment doesn't match its upload.")
    return item["filename"], meta["sha256"], path, item["mime"]


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
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
        raise MediaError("Attach up to %d files, or one MP4 clip." % MAX_ITEMS)
    frames = []
    remaining = MAX_BYTES
    for item in items:
        if isinstance(item, dict) and set(item) == {"filename", "mime", "upload_id"}:
            # Uploaded ahead (bridge_uploads): verified by SHA-256 there, outside the inline budget.
            if not valid_name(item["filename"]) or not valid_mime(item["mime"]):
                raise MediaError("Invalid attachment name or type.")
            if item["mime"] == MP4 and len(items) != 1:
                raise MediaError("Attach one MP4 clip, or up to %d other files." % MAX_ITEMS)
            name, digest, path, mime = _uploaded(item)
            if mime == MP4:
                import mmap
                try:
                    with open(path, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as view:
                        _validate_clip(view)
                except (ValueError, OSError):
                    raise MediaError("The video must be a self-contained MP4 with a video track.") from None
            elif mime == JPEG:
                if not supported():
                    raise MediaError("This Hermes installation does not support native image attachments.")
                _check_jpeg(path)
            elif mime.startswith("image/"):
                _check_other_image(path)
            frames.append((name, digest, path, mime))
            continue
        if not isinstance(item, dict) or set(item) != {"filename", "mime", "base64"}:
            raise MediaError("Invalid attachment fields.")
        name, encoded, mime = item["filename"], item["base64"], item["mime"]
        if not isinstance(mime, str) or not MIME.match(mime):
            raise MediaError("Attach files with a valid media type.")
        if mime == MP4 and len(items) != 1:
            raise MediaError("Attach one MP4 clip, or up to %d other files." % MAX_ITEMS)
        if (not isinstance(name, str) or not 0 < len(name) <= 140 or not name.isprintable()
                or any(c in name for c in "/\\:") or name in (".", "..")):
            raise MediaError("Invalid attachment name.")
        if not isinstance(encoded, str) or len(encoded) > (remaining + 2) // 3 * 4:
            raise MediaError("Attachments must total %d MiB or less." % (MAX_BYTES // (1024 * 1024)))
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
        elif mime == JPEG:
            if not supported():
                raise MediaError("This Hermes installation does not support native image attachments.")
            _check_jpeg(BytesIO(raw))
        elif mime.startswith("image/"):
            _check_other_image(BytesIO(raw))
        remaining -= len(raw)
        frames.append((name, hashlib.sha256(raw).hexdigest(), raw, mime))
    return frames


def _private_dir(home, name, label):
    directory = Path(home).resolve() / name
    directory.mkdir(mode=0o700, exist_ok=True)
    st = directory.lstat()
    if not stat.S_ISDIR(st.st_mode) or getattr(st, "st_file_attributes", 0) & 0x400:
        raise MediaError("The profile cannot privately store %s." % label)
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
    prune(home)
    return directory


def _image_dir(home):
    """The image staging dir of the gateway that serves ``home``. The gateway only admits native images
    staged directly inside ITS image cache, which is per profile (<home>/cache/images). The bridge process
    runs under the default home, so its own get_image_cache_dir() is the wrong dir for every other bot
    (prompt.submit then fails with invalid_params)."""
    from gateway.platforms.base import get_image_cache_dir
    own = get_image_cache_dir().resolve()
    try:
        from hermes_constants import get_hermes_dir, get_hermes_home
        if Path(home).resolve() == Path(get_hermes_home()).resolve():
            return own
        directory = Path(get_hermes_dir("cache/images", "image_cache", home=Path(home).resolve()))
    except ImportError:
        return own
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    return directory.resolve()


def _clip_dir(home):
    return _private_dir(home, "mobile-video-inputs", "video")


def _file_dir(home):
    return _private_dir(home, "mobile-file-inputs", "files")


def _extension(name):
    ext = Path(name).suffix.lstrip(".")
    return "." + ext.lower() if EXT.match(ext) else ".bin"


def prune(home):
    cutoff = time.time() - 4 * 3600
    for name in ("mobile-video-inputs", "mobile-file-inputs"):
        directory = Path(home).resolve() / name
        if directory.resolve() != directory or not directory.is_dir():
            continue
        for staged in directory.glob("hm_send_*"):
            try:
                if staged.is_file() and staged.lstat().st_mtime < cutoff:
                    staged.unlink(missing_ok=True)
            except OSError:
                pass


def prune_clips(home):
    """Kept as the startup hook's name; files and clips share the same age-based sweep."""
    prune(home)


def _jpeg_copy(source, directory):
    """A full-resolution JPEG copy of a HEIC/PNG/WebP/... photo, only so a model can look at it (models read JPEG).
    Pillow first (with pillow-heif), macOS's own `sips` as a fallback. None if neither can read it."""
    import uuid
    target = Path(directory) / ("hm_send_%s.jpg" % uuid.uuid4().hex[:12])
    try:
        from PIL import ImageOps
        with _open_any_image(source) as image:
            ImageOps.exif_transpose(image).convert("RGB").save(target, "JPEG", quality=92)
    except Exception:
        target.unlink(missing_ok=True)
        import shutil
        import subprocess
        if not shutil.which("sips"):
            return None
        try:
            subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "92", str(source), "--out", str(target)],
                           check=True, capture_output=True, timeout=120)
        except Exception:
            target.unlink(missing_ok=True)
            return None
    if not target.exists() or target.stat().st_size == 0:
        target.unlink(missing_ok=True)
        return None
    target.chmod(0o600)
    return target


def stage(frames, home):
    paths = []
    try:
        for name, _, raw, mime in frames:
            if mime == MP4:
                directory, ext = _clip_dir(home), ".mp4"
            elif mime == JPEG:
                directory, ext = _image_dir(home), ".jpg"
            else:
                directory, ext = _file_dir(home), _extension(name)
            if isinstance(raw, Path):
                # An uploaded file. A photo is COPIED: Hermes refuses a native attachment that has a second name
                # (session_ingress_media._attachment_hashes, st_nlink != 1) as a bare invalid_params, so a hard
                # link to the upload made every uploaded photo batch fail. Other files go by path and can be
                # hard-linked (instant, no second copy), falling back to a copy across volumes.
                import shutil
                import uuid
                target = Path(directory) / ("hm_send_%s%s" % (uuid.uuid4().hex[:12], ext))
                if mime == JPEG:
                    shutil.copyfile(raw, target)
                else:
                    try:
                        os.link(raw, target)
                    except OSError:
                        shutil.copyfile(raw, target)
                target.chmod(0o600)
                paths.append({"path": str(target), "mime": mime, "name": name, "size": target.stat().st_size})
            else:
                with tempfile.NamedTemporaryFile(prefix="hm_send_", suffix=ext, dir=directory, delete=False) as f:
                    paths.append({"path": f.name, "mime": mime, "name": name, "size": len(raw)})
                    f.write(raw)
                    f.flush()
                    os.fsync(f.fileno())
            if mime.startswith("image/") and mime != JPEG:
                # The original stays as sent; the model gets a JPEG copy it can actually see.
                copy = _jpeg_copy(paths[-1]["path"], _image_dir(home))
                if copy is not None:
                    paths[-1]["jpeg_copy"] = str(copy)
                    paths.append({"path": str(copy), "mime": JPEG, "name": name, "size": copy.stat().st_size,
                                  "copy_of": paths[-1]["path"]})
        # The first images ride natively (the model sees them at once); the rest are named by path in the
        # message, so a 15-photo send arrives whole instead of being refused for having more than 10.
        room = native_image_limit()
        for item in paths:
            if item["mime"] == JPEG:
                item["native"] = room > 0
                room -= 1
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
