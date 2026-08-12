#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""Mirror container images from source registries to target registries.

Groups are defined in mirrors.json, or via SOURCE/TARGET/IMAGES env vars.
Requires the regctl CLI (https://github.com/regclient/regclient/releases).

Run with:  uv run --script container-mirror.py   (or ./container-mirror.py)
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# ── config ──────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).resolve().parent

MIRRORS_FILE = os.environ.get("MIRRORS_FILE", str(SCRIPT_DIR / "mirrors.json"))
TAG_FILTER = os.environ.get("TAG_FILTER", ".*")
TAG_IGNORE = os.environ.get("TAG_IGNORE", "")
MAX_JOBS_STR = os.environ.get("MAX_JOBS", "4")
MAX_JOBS = 4
TAG_JOBS_STR = os.environ.get("TAG_JOBS", "4")
TAG_JOBS = 4
MIRROR_CACHE = os.environ.get("MIRROR_CACHE", str(SCRIPT_DIR / ".mirror-cache.json"))
CACHE_TTL_STR = os.environ.get("CACHE_TTL", "0")  # hours; 0 = always re-verify source digests
CACHE_TTL = 0
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"
ONLY_IMAGES = os.environ.get("ONLY_IMAGES", "")
PLATFORM = os.environ.get("PLATFORM", "")
VERBOSE = os.environ.get("VERBOSE", "false") == "true"
GITHUB_ACTIONS = bool(os.environ.get("GITHUB_ACTIONS"))
GITHUB_STEP_SUMMARY = os.environ.get("GITHUB_STEP_SUMMARY", "")

STARTED_AT = time.time()
CREDS_JSON = {}
GROUP_COUNT = 0
IMAGE_COUNT = 0
STATS = {}  # (group_id, image) -> {tags, copied, current, failed, skipped, elapsed}
CACHE = {}  # source/repo -> {tag: {"d": src_digest, "t": unix_ts}}
CACHE_LOCK = threading.Lock()

# ── colors ──────────────────────────────────────────────────────────────

if not os.environ.get("NO_COLOR") and (sys.stdout.isatty() or GITHUB_ACTIONS):
    C_CYAN, C_GREEN, C_MAGENTA = "\033[36m", "\033[32m", "\033[35m"
    C_RED, C_GRAY, C_RESET = "\033[31m", "\033[90m", "\033[0m"
else:
    C_CYAN = C_GREEN = C_MAGENTA = C_RED = C_GRAY = C_RESET = ""

# ── helpers ─────────────────────────────────────────────────────────────

PRINT_LOCK = threading.Lock()
LOGIN_LOCK = threading.Lock()  # regctl login writes a shared config file
LOG_CONTEXT = threading.local()


def _active_log_buffer():
    return getattr(LOG_CONTEXT, "messages", None)


def log(*args):
    line = " ".join(str(arg) for arg in args)
    messages = _active_log_buffer()
    if messages is not None:
        messages.append(line)
        return
    with PRINT_LOCK:
        print(line, flush=True)


def event(name: str, color: str) -> str:
    return f"{color}{name}{C_RESET}"


def notice(msg: str):
    log(msg)


def warn(msg: str):
    log(f"{event('WARNING', C_RED)} {msg}")


def error(msg: str):
    log(f"{event('ERROR', C_RED)} {msg}")


def elapsed_str(s: int) -> str:
    if s >= 60:
        return f"{s // 60}m {s % 60}s"
    return f"{s}s"


# Suppress regctl stderr noise (login-user-change WARNs) unless VERBOSE=true.
def _regctl_stderr(args, input_text=None) -> int:
    p = subprocess.run(
        ["regctl", *args],
        input=input_text,
        text=True,
        check=False,
        stdout=subprocess.PIPE if VERBOSE else subprocess.DEVNULL,
        stderr=subprocess.PIPE if VERBOSE else subprocess.DEVNULL,
    )
    if VERBOSE:
        for line in ((p.stdout or "") + (p.stderr or "")).splitlines():
            log(f"  {event('REGISTRY', C_GRAY)} {line}")
    return p.returncode


# ── stats & summary ─────────────────────────────────────────────────────

def stat_sum(field: str) -> int:
    return sum(s[field] for s in STATS.values())


def write_summary():
    if not GITHUB_STEP_SUMMARY:
        return
    total_failed = stat_sum("failed")
    status = "success" if total_failed == 0 else "failed"
    lines = ["## Mirror summary\n\n```text"]
    lines.append(f"status        {status}")
    if DRY_RUN:
        lines.append("mode          dry-run (no changes made)")
    lines.append(f"duration      {elapsed_str(int(time.time() - STARTED_AT))}")
    lines.append(f"groups        {GROUP_COUNT}")
    lines.append(f"images        {IMAGE_COUNT}")
    lines.append(f"tags checked  {stat_sum('tags')}")
    lines.append(f"copied        {stat_sum('copied')}")
    lines.append(f"current       {stat_sum('current')}")
    lines.append(f"skipped       {stat_sum('skipped')}")
    lines.append(f"failed        {total_failed}")
    if STATS:
        lines.append("\nimages")
        prev_group = None
        for (grp, img), s in sorted(STATS.items()):
            if grp != prev_group:
                lines.append(f"  [{grp}]")
                prev_group = grp
            lines.append(
                f"    {img:<14} tags={s['tags']} copied={s['copied']} "
                f"current={s['current']} skipped={s['skipped']} "
                f"failed={s['failed']} duration={s['elapsed']}"
            )
    lines.append("```")
    with open(GITHUB_STEP_SUMMARY, "a") as f:
        f.write("\n".join(lines) + "\n")


def _signal_handler(_signum, _frame):
    raise KeyboardInterrupt


def _exit_on_interrupt():
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    try:
        log(f"{event('INTERRUPTED', C_RED)} stopping mirror; cancelling queued work")
        save_cache()
        write_summary()
    finally:
        os._exit(130)  # match the old trap INT/TERM behavior: kill jobs, exit 130


# ── cache ────────────────────────────────────────────────────────────────

# ponytail: the expensive steady-state cost is one registry HEAD per tag.
# The cache remembers the last confirmed source digest per tag. With CACHE_TTL
# set, fresh entries skip the source HEAD when the destination still matches
# the cached digest. A changed or missing destination falls through to a full
# source check and copy.

def load_cache():
    global CACHE
    if not MIRROR_CACHE:
        return
    try:
        CACHE = json.loads(Path(MIRROR_CACHE).read_text())
    except (OSError, json.JSONDecodeError):
        CACHE = {}


def save_cache():
    if not MIRROR_CACHE:
        return
    tmp = MIRROR_CACHE + ".tmp"
    Path(tmp).write_text(json.dumps(CACHE))
    os.replace(tmp, MIRROR_CACHE)  # atomic


# ── dependencies ────────────────────────────────────────────────────────

def check_deps():
    global MAX_JOBS, TAG_JOBS, CACHE_TTL
    if shutil.which("regctl") is None:
        error("regctl required — https://github.com/regclient/regclient/releases")
        sys.exit(1)
    if re.fullmatch(r"[1-9][0-9]*", MAX_JOBS_STR) is None:
        error("MAX_JOBS must be positive int")
        sys.exit(1)
    if re.fullmatch(r"[1-9][0-9]*", TAG_JOBS_STR) is None:
        error("TAG_JOBS must be positive int")
        sys.exit(1)
    if re.fullmatch(r"[0-9]*", CACHE_TTL_STR) is None:
        error("CACHE_TTL must be a non-negative int (hours)")
        sys.exit(1)
    MAX_JOBS = int(MAX_JOBS_STR)
    TAG_JOBS = int(TAG_JOBS_STR)
    CACHE_TTL = int(CACHE_TTL_STR or "0")


# ── registry auth ───────────────────────────────────────────────────────

def regctl_login(host: str, user: str, password: str, required: bool, scope: str = ""):
    prefix = f"[{scope}] " if scope else ""
    with LOGIN_LOCK:  # registry login writes ~/.config/regctl/regctl.config
        if not user and not password:
            if required:
                error(f"{event('AUTH', C_CYAN)} {prefix}no credentials for {host}")
                sys.exit(1)
            log(f"  {event('AUTH', C_CYAN)} {prefix}anonymous access for {host}")
            return
        if not user or not password:
            error(f"{event('AUTH', C_CYAN)} {prefix}incomplete credentials for {host}")
            sys.exit(1)
        rc = _regctl_stderr(
            ["registry", "login", host, "-u", user, "--pass-stdin"], input_text=password + "\n"
        )
        if rc != 0:
            error(f"{event('AUTH', C_CYAN)} {prefix}regctl login failed for {host}")
            sys.exit(1)
        log(f"  {event('AUTH', C_CYAN)} {prefix}logged in to {host}")


# ── image operations ────────────────────────────────────────────────────

def tag_list(repo: str):
    """Return (ok, tags) for a repo. ok is False on registry errors (e.g. 404)."""
    p = subprocess.run(["regctl", "tag", "ls", repo], capture_output=True, text=True, check=False)
    return p.returncode == 0, [t for t in p.stdout.splitlines() if t]


def image_digest(ref: str):
    """Return (rc, digest), recording command output in the active log."""
    p = subprocess.run(["regctl", "image", "digest", ref], capture_output=True, text=True, check=False)
    if p.returncode == 0:
        return 0, p.stdout.strip()
    output = (p.stdout + p.stderr).strip()
    if output:
        log(f"{event('DIGEST', C_RED)} failed: {ref}")
        for line in output.splitlines():
            log(f"  {event('REGISTRY', C_GRAY)} {line}")
    return p.returncode, None


def retry(max_attempts: int, label: str, attempt):
    """attempt() -> int rc; 0 = success, 66 = permanent skip. Returns rc after retries."""
    rc = 1
    for i in range(1, max_attempts + 1):
        rc = attempt()
        if rc == 0 or rc == 66:
            return rc
        if i < max_attempts:
            log(f"{event('RETRY', C_MAGENTA)} attempt={i}/{max_attempts}: {label}")
            time.sleep(i * 5)
        else:
            log(f"{event('FAILED', C_RED)} attempts={max_attempts}: {label}")
    return rc


def _run_copy(args, src: str, dst: str) -> int:
    p = subprocess.run(["regctl", "image", "copy", *args, src, dst], capture_output=True, text=True, check=False)
    if p.returncode == 0:
        return 0
    output = p.stdout + p.stderr
    if "MANIFEST_UNKNOWN" in output:
        log(f"{event('SKIP', C_GRAY)} {src} -> {dst} (source 404)")
        return 66
    log(f"{event('COPY', C_RED)} failed: {src} -> {dst}")
    for line in output.splitlines():
        log(f"  {event('REGISTRY', C_GRAY)} {line}")
    return 1


def _copy_single(src: str, dst: str, platform: str) -> int:
    return _run_copy(["--platform", platform], src, dst)


def copy_image(src: str, dst: str, group_platform: str) -> int:
    platform_list = group_platform or PLATFORM
    if DRY_RUN:
        log(f"{event('COPY', C_GREEN)} planned (dry-run): {src} -> {dst}")
        return 0

    if not platform_list:
        return _run_copy([], src, dst)

    platforms = [p.strip() for p in platform_list.split(",") if p.strip()]
    if len(platforms) == 1:
        return _copy_single(src, dst, platforms[0])

    # Multiple platforms: copy each to a temp tag, then build an index.
    tmp_base = f"{dst}-tmp"
    refs, tags = [], []
    rc = 0
    try:
        for p in platforms:
            tmp = f"{tmp_base}-{p.replace('/', '_')}"
            r = _copy_single(src, tmp, p)
            if r != 0:
                return r
            refs.append(tmp)
            tags.append(tmp)
        index_args = [dst]
        for ref, p in zip(refs, platforms):
            index_args += ["--ref", ref, "--platform", p]
        p = subprocess.run(["regctl", "index", "create", *index_args], capture_output=True, text=True, check=False)
        if p.returncode != 0:
            log(f"{event('INDEX', C_RED)} failed: {dst}")
            for line in (p.stdout + p.stderr).splitlines():
                log(f"  {event('REGISTRY', C_GRAY)} {line}")
            rc = 1
    finally:
        for t in tags:
            subprocess.run(["regctl", "tag", "delete", t], capture_output=True, text=True, check=False)
    return rc


def copy_if_changed(src: str, dst: str, group_platform: str):
    """Return (rc, src_digest). rc: 0 copied, 10 current, 66 skipped, else failed."""
    digest_box = {}

    def fetch_src():
        rc, digest = image_digest(src)
        digest_box["digest"] = digest
        return rc

    # ponytail: transient registry errors (e.g. ghcr.io 429) shouldn't fail the run;
    # retry 3, then skip the tag instead of hard-failing.
    if retry(3, f"image digest {src}", fetch_src) != 0:
        warn(f"cannot read source digest (skipped): {src}")
        return 66, None
    src_digest = digest_box["digest"]

    rc, dst_digest = image_digest(dst)
    if rc == 0 and src_digest == dst_digest:
        return 10, src_digest
    rc = retry(5, f"copy {src} -> {dst}", lambda: copy_image(src, dst, group_platform))
    return rc, src_digest if rc == 0 else None


# ── tag ignore helpers ──────────────────────────────────────────────────

def _tag_ignored(tag: str, group_ignore: str) -> bool:
    if not group_ignore and not TAG_IGNORE:
        return False
    # mirrors.json ignore_tags: pipe-delimited exact matches
    if group_ignore:
        for ign in group_ignore.split("|"):
            if tag == ign:
                return True
    # TAG_IGNORE env: comma/pipe list or regex
    if not TAG_IGNORE:
        return False
    if "," in TAG_IGNORE or "|" in TAG_IGNORE:
        for ign in re.split(r"[,|]", TAG_IGNORE):
            if tag == ign.strip():
                return True
        return False
    try:
        return re.search(TAG_IGNORE, tag) is not None
    except re.error:
        warn(f"invalid TAG_IGNORE regex: {TAG_IGNORE}")
        return False


# ── mirror single image ─────────────────────────────────────────────────

# ponytail: fetch tag lists (source + destination) in parallel, then check all
# tags concurrently. Tags missing on the destination skip the digest comparison
# and go straight to copy — the serial per-tag scan was the runtime bottleneck.
def mirror_image(image: str, source: str, target: str, group_id: str,
                 group_ignore: str, group_filter: str, group_platform: str) -> int:
    copied = current = failed = skipped = 0
    start = time.time()

    ls_pool = ThreadPoolExecutor(max_workers=2)
    interrupted = False
    try:
        src_fut = ls_pool.submit(tag_list, f"{source}/{image}")
        dst_fut = ls_pool.submit(tag_list, f"{target}/{image}")
        source_ok, all_tags = src_fut.result()
        dest_ok, dest_tags = dst_fut.result()
    except KeyboardInterrupt:
        interrupted = True
        raise
    finally:
        ls_pool.shutdown(wait=not interrupted, cancel_futures=interrupted)
    if not source_ok:
        log(f"  {event('FAIL', C_RED)} [{group_id}/{image}] unable to list source tags")
        STATS[(group_id, image)] = {
            "tags": 0, "copied": 0, "current": 0,
            "failed": 1, "skipped": 0, "elapsed": elapsed_str(int(time.time() - start)),
        }
        return 1
    if not dest_ok:
        log(f"  {event('WARNING', C_RED)} [{group_id}/{image}] unable to list destination tags; "
            "treating destination as empty")
    dest_tags = set(dest_tags) if dest_ok else set()
    repo_key = f"{source}/{image}"

    try:
        re_filter = re.compile(group_filter or TAG_FILTER)
    except re.error:
        warn(f"invalid tag filter regex: {group_filter or TAG_FILTER}")
        re_filter = re.compile(".*")
    tags = [t for t in all_tags if re_filter.search(t)]
    filtered = len(all_tags) - len(tags)

    log(f"  {event('START', C_GREEN)} [{group_id}/{image}] checking {len(tags)} tags "
        f"({len(all_tags)} total, {filtered} filtered)")

    def process_tag(tag: str):
        messages = []
        LOG_CONTEXT.messages = messages
        try:
            if _tag_ignored(tag, group_ignore):
                return tag, 66, None, messages
            src = f"{source}/{image}:{tag}"
            dst = f"{target}/{image}:{tag}"
            if dest_ok and tag not in dest_tags:
                # New tag: copy directly, no digest comparison needed.
                rc = retry(5, f"copy {src} -> {dst}",
                           lambda: copy_image(src, dst, group_platform))
                if rc != 0:
                    return tag, rc, None, messages
                if DRY_RUN:
                    return tag, 0, None, messages
                _, digest = image_digest(src)  # remember the digest we just mirrored
                return tag, 0, (tag, digest) if digest else None, messages
            cached = CACHE.get(repo_key, {}).get(tag) or {}
            if cached.get("d") and CACHE_TTL and time.time() - cached.get("t", 0) < CACHE_TTL * 3600:
                # The cached source digest is only useful if the destination still
                # has that digest. Otherwise fetch the source and repair drift.
                rc, dst_digest = image_digest(dst)
                if rc == 0 and dst_digest == cached["d"]:
                    return tag, 10, None, messages
            rc, src_digest = copy_if_changed(src, dst, group_platform)
            hint = (tag, src_digest) if rc in (0, 10) and src_digest else None
            return tag, rc, hint, messages
        except (OSError, RuntimeError, ValueError) as exc:
            log(f"{event('ERROR', C_RED)} unexpected error: {exc!r}")
            return tag, 1, None, messages
        finally:
            del LOG_CONTEXT.messages

    hints = []
    results = {}
    total = len(tags)
    progress_every = max(10, min(50, total // 10 or 1))
    completed = 0
    pool = ThreadPoolExecutor(max_workers=TAG_JOBS, thread_name_prefix="tag")
    interrupted = False
    try:
        futures = [pool.submit(process_tag, tag) for tag in tags]
        for fut in as_completed(futures):
            tag, rc, hint, messages = fut.result()
            results[tag] = (rc, messages)
            completed += 1
            if hint:
                hints.append(hint)
            if rc == 0:
                copied += 1
            elif rc == 10:
                current += 1
            elif rc == 66:
                skipped += 1
            else:
                failed += 1
            if completed < total and completed % progress_every == 0:
                log(f"    {event('PROGRESS', C_GRAY)} [{group_id}/{image}] {completed}/{total} checked "
                    f"copied={copied} current={current} skipped={skipped} failed={failed}")
    except KeyboardInterrupt:
        interrupted = True
        raise
    finally:
        pool.shutdown(wait=not interrupted, cancel_futures=interrupted)

    if hints and not DRY_RUN:
        with CACHE_LOCK:
            repo_cache = CACHE.setdefault(repo_key, {})
            now = int(time.time())
            for tag, digest in hints:
                repo_cache[tag] = {"d": digest, "t": now}
            # prune tags that no longer exist upstream (or are filtered out)
            for t in list(repo_cache):
                if t not in tags:
                    del repo_cache[t]

    elapsed = elapsed_str(int(time.time() - start))
    report = []
    if copied > 0:
        report.append(f"  {event('DONE', C_MAGENTA)} [{group_id}/{image}] copied={copied} current={current} "
                      f"skipped={skipped} failed={failed} ({elapsed})")
    else:
        report.append(f"  {event('DONE', C_MAGENTA)} [{group_id}/{image}] no changes, current={current} "
                      f"skipped={skipped} failed={failed} ({elapsed})")
    for tag in sorted(results):
        rc, messages = results[tag]
        if rc == 0:
            report.append(f"    {event('COPY', C_GREEN)} {image}:{tag}")
        if messages:
            report.append(f"    {event('DETAIL', C_GRAY)} [{tag}]")
            report.extend(f"      {message}" for message in messages)
        elif rc not in (0, 10, 66):
            report.append(f"    {event('FAILED', C_RED)} {image}:{tag}")
    with PRINT_LOCK:
        print("\n".join(report), flush=True)

    STATS[(group_id, image)] = {
        "tags": len(tags), "copied": copied, "current": current,
        "failed": failed, "skipped": skipped, "elapsed": elapsed,
    }
    return 0 if failed == 0 else 1


# ── parallel runner ─────────────────────────────────────────────────────

def run_parallel(group_id: str, source: str, target: str, images: list[str],
                 group_ignore: str, group_filter: str, group_platform: str) -> int:
    failed = 0
    pool = ThreadPoolExecutor(max_workers=MAX_JOBS, thread_name_prefix="mirror")
    interrupted = False
    try:
        futures = [
            pool.submit(mirror_image, img, source, target, group_id,
                        group_ignore, group_filter, group_platform)
            for img in images
        ]
        for fut in as_completed(futures):
            if fut.result() != 0:
                failed = 1
    except KeyboardInterrupt:
        interrupted = True
        raise
    finally:
        pool.shutdown(wait=not interrupted, cancel_futures=interrupted)
    return failed


# ── credentials ─────────────────────────────────────────────────────────

def cred_field(host: str, direction: str, field: str) -> str:
    if not CREDS_JSON:
        return ""
    value = CREDS_JSON.get(direction, {}).get(host, {}).get(field, "")
    return "" if value is None else str(value)


def load_creds():
    global CREDS_JSON
    creds_file = os.environ.get("REGISTRY_CREDENTIALS_FILE", str(SCRIPT_DIR / ".creds.json"))
    data = ""
    if os.path.isfile(creds_file):
        data = Path(creds_file).read_text()
    if os.environ.get("REGISTRY_CREDENTIALS"):
        data = os.environ["REGISTRY_CREDENTIALS"]
    if not data.strip():
        return

    try:
        parsed = json.loads(data)
    except json.JSONDecodeError as e:
        error(f"invalid credentials JSON: {e}")
        sys.exit(1)
    if not isinstance(parsed, dict) or "source" not in parsed or "destination" not in parsed:
        error("creds must have 'source' and 'destination' keys")
        sys.exit(1)
    CREDS_JSON = parsed


# ── mirror group ────────────────────────────────────────────────────────

def mirror_group(source: str, target: str, group_id: str, images: list[str],
                 group_ignore: str = "", group_filter: str = "", group_platform: str = "") -> int:
    src_host = source.split("/", 1)[0]
    tgt_host = target.split("/", 1)[0]

    src_user = os.environ.get("SOURCE_REGISTRY_USERNAME", "")
    src_pass = os.environ.get("SOURCE_REGISTRY_PASSWORD", "")
    tgt_user = os.environ.get("TARGET_REGISTRY_USERNAME", "")
    tgt_pass = os.environ.get("TARGET_REGISTRY_PASSWORD", "")

    if CREDS_JSON:
        if not src_user:
            src_user = cred_field(src_host, "source", "user")
        if not src_pass:
            src_pass = cred_field(src_host, "source", "password")
        if not tgt_user:
            tgt_user = cred_field(tgt_host, "destination", "user")
        if not tgt_pass:
            tgt_pass = cred_field(tgt_host, "destination", "password")

    notice(f"{event('GROUP', C_CYAN)} [{group_id}] {source} -> {target} ({len(images)} images)")

    regctl_login(src_host, src_user, src_pass, False, group_id)
    regctl_login(tgt_host, tgt_user, tgt_pass, True, group_id)

    return run_parallel(group_id, source, target, images,
                        group_ignore, group_filter, group_platform)


# ── load mirror groups ──────────────────────────────────────────────────

def basename_of(ref: str) -> str:
    return ref.split("/")[-1]


def load_mirrors() -> int:
    global GROUP_COUNT, IMAGE_COUNT

    source = os.environ.get("SOURCE", "")
    target = os.environ.get("TARGET", "")
    images_env = os.environ.get("IMAGES", "")
    if source or target or images_env:
        imgs = images_env.split()
        GROUP_COUNT = 1
        IMAGE_COUNT = len(imgs)
        return mirror_group(source, target, basename_of(target), imgs)

    if not os.path.isfile(MIRRORS_FILE):
        error(f"MIRRORS_FILE not found: {MIRRORS_FILE}")
        error("Set SOURCE/TARGET/IMAGES env vars for single-group mode")
        sys.exit(1)
    try:
        groups = json.loads(Path(MIRRORS_FILE).read_text())
    except json.JSONDecodeError as e:
        error(f"invalid {MIRRORS_FILE}: {e}")
        sys.exit(1)
    if not isinstance(groups, list):
        error(f"{MIRRORS_FILE} must be a JSON array of mirror groups")
        sys.exit(1)

    GROUP_COUNT = len(groups)
    IMAGE_COUNT = sum(len(g.get("images", [])) for g in groups)
    wanted = [w.strip() for w in ONLY_IMAGES.split(",")] if ONLY_IMAGES else []
    rc = 0
    group_counts = {}

    # ponytail: mirror groups hit different source registries, so run them
    # concurrently instead of sequentially (this was another serial bottleneck).
    jobs = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        source = str(group.get("source", ""))
        target = str(group.get("target", ""))
        base_group_id = basename_of(target)
        imgs = [str(i) for i in group.get("images", [])]
        if wanted:
            imgs = [img for img in imgs if img in wanted]
            if not imgs:
                continue
        group_counts[base_group_id] = group_counts.get(base_group_id, 0) + 1
        occurrence = group_counts[base_group_id]
        group_id = base_group_id if occurrence == 1 else f"{base_group_id}#{occurrence}"
        group_ignore = "|".join(str(t) for t in group.get("ignore_tags", []) if t)
        group_filter = str(group.get("tag_filter", "") or "")
        group_platform = str(group.get("platform", "") or "")
        jobs.append((source, target, group_id, imgs,
                     group_ignore, group_filter, group_platform))

    if jobs:
        pool = ThreadPoolExecutor(max_workers=min(len(jobs), 4), thread_name_prefix="group")
        interrupted = False
        try:
            futures = [
                pool.submit(mirror_group, source, target, group_id, images,
                            group_ignore, group_filter, group_platform)
                for source, target, group_id, images, group_ignore, group_filter, group_platform in jobs
            ]
            for fut in as_completed(futures):
                if fut.result() != 0:
                    rc = 1
        except KeyboardInterrupt:
            interrupted = True
            raise
        finally:
            pool.shutdown(wait=not interrupted, cancel_futures=interrupted)
    return rc


# ── main ────────────────────────────────────────────────────────────────

def main() -> int:
    check_deps()
    if DRY_RUN:
        warn("DRY_RUN=true — no images will be copied")

    load_cache()
    load_creds()
    run_status = load_mirrors()

    notice(f"{event('SUMMARY', C_MAGENTA)} mirror complete: copied={stat_sum('copied')} current={stat_sum('current')} "
           f"skipped={stat_sum('skipped')} failed={stat_sum('failed')}")
    save_cache()  # bash ran this from its EXIT trap; persisted for CI via actions/cache
    write_summary()
    return run_status


if __name__ == "__main__":
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        _exit_on_interrupt()
