#!/usr/bin/env python3
"""
filter-stream.py — Data-block-aware git fast-export stream filter.

Processes a git fast-export stream on stdin and writes filtered output to stdout.
Three responsibilities:
  1. Rewrite author/committer emails using a mailmap file.
     Fails loudly if an unmapped internal email is encountered.
  2. Drop file operations (M/D/R/C) whose path falls under any --exclude-path
     prefix. This is the include-set filter for the sync pipeline — it replaces
     `git fast-export <pathspec>` filtering, which forces `--full-tree` mode
     and produces commits that DELETE excluded paths relative to the marks-
     anchored parent (the failure mode behind ADO 5347427). Filtering in the
     delta-mode stream instead keeps parent-tree inheritance intact, so
     excluded paths that exist on the marks-anchored parent (e.g. `.github/`
     on a public commit used as a seed-marks anchor) flow through to the new
     sync-branch commit unmodified.
  3. Strip empty commits (commits with no file operations). When all file
     operations in a commit are excluded by (2), this naturally drops the
     entire commit from the stream.

The fast-export format uses 'data <N>' directives followed by N raw bytes.
This filter is aware of that structure — it only rewrites author/committer
lines and acts on file-op command lines; data blocks pass through untouched.
"""

import sys
import re
import argparse
from pathlib import Path


def load_mailmap(mailmap_path: str) -> dict[str, tuple[str, str]]:
    """Load a mailmap file and return a dict mapping internal emails to (name, safe_email).

    Mailmap format (one per line):
        Canonical Name <safe-email> <internal-email>

    Returns:
        { "internal@example.com": ("Canonical Name", "safe@example.com"), ... }
    """
    mapping = {}
    mailmap = Path(mailmap_path)
    if not mailmap.exists():
        print(f"ERROR: Mailmap file not found: {mailmap_path}", file=sys.stderr)
        sys.exit(1)

    for line_num, line in enumerate(mailmap.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        # Parse: Name <safe-email> <internal-email>
        match = re.match(r"^(.+?)\s+<([^>]+)>\s+<([^>]+)>$", line)
        if not match:
            print(f"WARNING: Skipping malformed mailmap line {line_num}: {line}", file=sys.stderr)
            continue

        name, safe_email, internal_email = match.groups()
        mapping[internal_email.lower()] = (name.strip(), safe_email.strip())

    return mapping


# Domains considered internal — any author/committer email matching these
# must be in the mailmap or the filter aborts.
INTERNAL_DOMAINS = {"microsoft.com"}


def is_internal_email(email: str) -> bool:
    """Check if an email belongs to an internal domain."""
    parts = email.lower().rsplit("@", 1)
    return len(parts) == 2 and parts[1] in INTERNAL_DOMAINS


def rewrite_identity_line(
    line: str,
    mailmap: dict[str, tuple[str, str]],
    line_type: str,
    collect_unmapped: set | None = None,
) -> str:
    """Rewrite an author or committer line if the email is in the mailmap.

    Line format: 'author Name <email> timestamp timezone'
    or:          'committer Name <email> timestamp timezone'

    Returns the rewritten line, or exits with error if internal email is unmapped
    (unless collect_unmapped is provided, in which case it records the email and
    passes the line through unchanged).
    """
    # Match: type Name <email> timestamp timezone
    pattern = rf"^({line_type}) (.+?) <([^>]+)> (.+)$"
    m = re.match(pattern, line)
    if not m:
        return line  # Malformed — pass through unchanged

    prefix, name, email, timestamp_tz = m.groups()
    email_lower = email.lower()

    if email_lower in mailmap:
        mapped_name, mapped_email = mailmap[email_lower]
        return f"{prefix} {mapped_name} <{mapped_email}> {timestamp_tz}"
    elif is_internal_email(email):
        if collect_unmapped is not None:
            collect_unmapped.add(f"{name} <{email}>")
            return line  # Pass through — we're collecting, not aborting
        print(
            f"ERROR: Unmapped internal email found in {line_type} line: {name} <{email}>",
            file=sys.stderr,
        )
        print("Add this email to the sync-mailmap file before syncing.", file=sys.stderr)
        sys.exit(1)
    else:
        return line  # External email, no rewrite needed


def read_data_block(stream) -> bytes:
    """Read a 'data <N>' block from the stream and return 'data <N>\\n' + N bytes.

    The 'data <N>' line has already been read; this reads the N content bytes.
    """
    # The line has already been consumed by the caller; we just need the byte count.
    # Actually, this function receives the full line and stream.
    raise NotImplementedError("Use read_data_block_from_line instead")


def normalize_exclude_prefix(raw: str) -> str:
    """Normalize a single --exclude-path value.

    Accepts plain repo-relative paths (e.g. ``internal/`` or ``.github``) and
    git pathspec ``:!`` / ``:(exclude)`` magic (so callers can pass the raw
    ``exclude_pathspecs`` config values without pre-stripping). Trailing
    slashes are stripped so prefix matching uniformly uses ``prefix`` and
    ``prefix + '/'``.
    """
    prefix = raw
    if prefix.startswith(":!"):
        prefix = prefix[2:]
    elif prefix.startswith(":(exclude)"):
        prefix = prefix[len(":(exclude)") :]
    # Defensive: also tolerate accidental leading "./".
    if prefix.startswith("./"):
        prefix = prefix[2:]
    prefix = prefix.rstrip("/")
    return prefix


def dequote_fastimport_path(token: str) -> str:
    r"""Decode a fast-import quoted path token to its literal path.

    Per ``git help fast-import`` (PATH section), paths containing LF or other
    "unusual" characters are emitted as a C-style double-quoted string with
    backslash escapes. Unquoted paths are passed back verbatim. This mirrors
    the small subset of C escapes that fast-import actually emits: ``\\`` ``\"``
    ``\a`` ``\b`` ``\t`` ``\n`` ``\v`` ``\f`` ``\r`` and ``\NNN`` (octal).
    Anything outside the quoted form is returned as-is, since fast-export only
    quotes when it must.
    """
    if len(token) < 2 or not token.startswith('"') or not token.endswith('"'):
        return token

    body = token[1:-1]
    out = []
    i = 0
    n = len(body)
    simple = {
        "\\": "\\",
        '"': '"',
        "a": "\a",
        "b": "\b",
        "t": "\t",
        "n": "\n",
        "v": "\v",
        "f": "\f",
        "r": "\r",
    }
    while i < n:
        ch = body[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        # Escape sequence.
        if i + 1 >= n:
            out.append(ch)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
            continue
        # Octal: up to three octal digits.
        if "0" <= nxt <= "7":
            j = i + 1
            end = min(n, j + 3)
            while j < end and "0" <= body[j] <= "7":
                j += 1
            out.append(chr(int(body[i + 1 : j], 8)))
            i = j
            continue
        # Unknown escape — keep verbatim.
        out.append(nxt)
        i += 2
    return "".join(out)


def split_fileop_path_fields(stripped: str) -> tuple[str, list[str]] | None:
    """Split a file-op command line and extract its path field(s).

    Returns ``(op, [path, ...])`` where ``op`` is one of ``M``/``D``/``R``/``C``,
    or ``None`` if the line is not a recognized file-op shape. Paths are
    returned in their decoded (un-quoted) form so prefix matching can be done
    directly against repository paths.

    Format (per git fast-import docs):
      * ``M <mode> <dataref> <path>``
      * ``D <path>``
      * ``R <src> <dst>``  (only when ``--no-renames`` is OFF)
      * ``C <src> <dst>``

    For M/D the path is the trailing field. For R/C both source and
    destination are quoted-or-bare path fields. Quoted paths are bracketed by
    ``"`` and may contain escaped spaces, so we cannot naively split on
    whitespace; we walk the line to honor quoting.
    """
    if not stripped:
        return None
    op = stripped[0]
    if op not in ("M", "D", "R", "C") or len(stripped) < 2 or stripped[1] != " ":
        return None

    rest = stripped[2:]

    def take_token(s: str) -> tuple[str, str]:
        """Take the next whitespace-delimited token, honoring leading-quoted form."""
        if not s:
            return "", ""
        if s.startswith('"'):
            # Find the matching closing quote (skip escaped quotes).
            i = 1
            while i < len(s):
                if s[i] == "\\" and i + 1 < len(s):
                    i += 2
                    continue
                if s[i] == '"':
                    end = i + 1
                    rest_after = s[end:].lstrip(" ")
                    return s[:end], rest_after
                i += 1
            # Unterminated — treat whole remainder as one token.
            return s, ""
        # Bare token.
        sp = s.find(" ")
        if sp == -1:
            return s, ""
        return s[:sp], s[sp + 1 :]

    if op == "M":
        # M <mode> <dataref> <path>  — path is the trailing field; mode/dataref
        # never contain spaces, so simple split works for the first two.
        parts = rest.split(" ", 2)
        if len(parts) < 3:
            return None
        return op, [dequote_fastimport_path(parts[2])]
    if op == "D":
        # D <path> — entire remainder is the path field (possibly quoted).
        return op, [dequote_fastimport_path(rest)]
    # R / C — two path tokens.
    src, rest2 = take_token(rest)
    dst, _ = take_token(rest2)
    if not src or not dst:
        return None
    return op, [dequote_fastimport_path(src), dequote_fastimport_path(dst)]


def path_is_excluded(path: str, exclude_prefixes: list[str]) -> bool:
    """True if ``path`` falls under any normalized exclude prefix.

    A prefix matches when the path equals it exactly OR starts with
    ``prefix + '/'``. Empty prefixes never match (defensive — caller should
    have filtered them already).
    """
    for prefix in exclude_prefixes:
        if not prefix:
            continue
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


def path_is_included(
    path: str, include_prefixes: list[str], include_files: list[str]
) -> bool:
    """True when a path is explicitly allowed by an exact file or directory prefix."""
    if path in include_files:
        return True
    for prefix in include_prefixes:
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


def basename_is_excluded(path: str, exclude_basenames: list[str]) -> bool:
    """True if ``path``'s final component matches any excluded basename.

    Unlike ``path_is_excluded`` (a directory/file *prefix* match), this matches
    a bare filename anywhere in the tree — e.g. ``.ci-skip`` matches
    ``samples/python/foo/.ci-skip``. fast-import paths always use ``/`` as the
    separator, so the basename is the segment after the last ``/``.
    """
    if not exclude_basenames:
        return False
    basename = path.rsplit("/", 1)[-1]
    return basename in exclude_basenames


def rewrite_ref_line(line: str, command: str, source_ref: str, target_ref: str) -> str:
    """Rewrite the ref on a 'commit <ref>' or 'reset <ref>' line.

    Only rewrites if the ref exactly matches source_ref. Returns the line unchanged
    otherwise. This is data-block-aware because it only operates on parsed command
    lines, never inside a 'data N' block.
    """
    expected = f"{command} {source_ref}"
    if line == expected:
        return f"{command} {target_ref}"
    return line


def filter_stream(
    input_stream,
    output_stream,
    mailmap: dict[str, tuple[str, str]],
    source_ref: str | None = None,
    target_ref: str | None = None,
    collect_unmapped: set | None = None,
    exclude_prefixes: list[str] | None = None,
    exclude_basenames: list[str] | None = None,
    include_prefixes: list[str] | None = None,
    include_files: list[str] | None = None,
) -> None:
    """Process a fast-export stream, rewriting emails and stripping empty commits.

    Reads from input_stream (binary mode), writes to output_stream (binary mode).

    If source_ref and target_ref are provided, also rewrites 'commit <source_ref>'
    and 'reset <source_ref>' lines to point to target_ref. This is safer than a
    post-filter sed pass because it only touches command lines, not data blocks.

    If include_prefixes or include_files is provided, only matching file
    operations are retained. Prefixes use component-boundary matching; files
    match exactly.

    If exclude_prefixes is provided, file-op lines (M/D/R/C) whose path falls
    under any prefix are dropped from the stream. This replaces the older
    pathspec-based filtering at fast-export time (which forces --full-tree mode
    and emits commits whose trees DELETE excluded paths relative to the marks-
    anchored parent — the failure mode behind ADO 5347427). Filtering deltas
    here lets the next fast-import inherit excluded-path content from the
    marks-anchored parent unchanged. Commits whose every file op is dropped
    become empty and are stripped by the existing has_file_ops accounting.

    If exclude_basenames is provided, file-op lines whose path's final
    component matches a listed basename are dropped the same way — used for
    scattered internal marker files (e.g. ``.ci-skip``/``.code-ci-skip``) that
    have no common path prefix.
    """
    do_ref_rewrite = source_ref is not None and target_ref is not None
    do_include_filter = bool(include_prefixes) or bool(include_files)
    do_path_filter = do_include_filter or bool(exclude_prefixes) or bool(exclude_basenames)
    # We need byte-level control for data blocks, so work in binary mode.
    # But most lines are text. Strategy: read line by line in binary, decode
    # text lines as UTF-8, and handle data blocks as raw bytes.

    # Commit accumulator: we buffer each commit and only emit it if it has
    # file operations (M/D/R/C lines). When a commit is dropped (no file
    # ops survive filtering), we must also rewrite any subsequent `from
    # :N` / `merge :N` references that pointed at the dropped commit's
    # mark — otherwise fast-import aborts with "mark :N not declared".
    # Under the legacy pathspec+--full-tree mode this never happened
    # because fast-export itself omitted commits with no surviving tree
    # change; under Option B (delta-mode export + filter-stream excludes)
    # we see every commit and must handle the mark chain ourselves.
    #
    # Buffer entries are either raw `bytes` (passed through verbatim) or
    # a tuple ("from"|"merge", mark_int) that gets resolved to a kept
    # ancestor at flush time.
    in_commit = False
    commit_buffer = []
    has_file_ops = False
    current_mark = None  # this commit's `mark :N`, parsed as int, or None
    # mark_int -> resolved-ancestor mark_int OR None (no kept ancestor).
    dropped_mark_to_parent: dict[int, int | None] = {}

    def resolve_mark(mark):
        """Follow the dropped-mark chain to its first kept ancestor.

        Returns the resolved int, or None if every ancestor was dropped
        (in which case a `from` reference should be omitted entirely so the
        resulting commit imports as a new root commit).
        """
        seen = set()
        while mark in dropped_mark_to_parent:
            if mark in seen:
                # Defensive: should never cycle, but don't loop forever.
                return None
            seen.add(mark)
            mark = dropped_mark_to_parent[mark]
            if mark is None:
                return None
        return mark

    def emit_parent_line(kind, mark):
        """Encode a from/merge line with the given resolved mark.

        Returns the bytes to write, or None if the line should be omitted .
        Merge lines pointing at a fully-dropped ancestor are omitted (a
        merge commit losing one parent gracefully degrades; losing the
        only side becomes a no-op the caller treats as drop-the-line).
        From lines pointing at a fully-dropped ancestor are also omitted,
        which makes the new commit a root commit per fast-import rules.
        """
        resolved = resolve_mark(mark)
        if resolved is None:
            return None
        return f"{kind} :{resolved}\n".encode("utf-8")

    def flush_commit():
        """Write buffered commit to output if it has file operations.

        When the commit is dropped, record its mark in
        `dropped_mark_to_parent` pointing at the resolved ancestor of its
        first `from` parent. Subsequent commits referencing this mark
        will skip transparently through it.
        """
        nonlocal in_commit, commit_buffer, has_file_ops, current_mark
        if in_commit and has_file_ops:
            for chunk in commit_buffer:
                if isinstance(chunk, tuple):
                    kind, mark = chunk
                    encoded = emit_parent_line(kind, mark)
                    if encoded is None:
                        # Omit this line. For `from`, the commit becomes
                        # a root (fast-import handles that). For `merge`,
                        # we drop one side of a merge.
                        continue
                    output_stream.write(encoded)
                else:
                    output_stream.write(chunk)
        elif in_commit and current_mark is not None:
            # Dropping this commit — splice it out of the mark chain.
            parent_mark = None
            for chunk in commit_buffer:
                if isinstance(chunk, tuple) and chunk[0] == "from":
                    parent_mark = resolve_mark(chunk[1])
                    break
            dropped_mark_to_parent[current_mark] = parent_mark
        in_commit = False
        commit_buffer = []
        has_file_ops = False
        current_mark = None

    while True:
        raw_line = input_stream.readline()
        if not raw_line:
            # End of stream — flush any pending commit
            flush_commit()
            break

        # Try to decode as UTF-8 text for line parsing
        try:
            line = raw_line.decode("utf-8")
        except UnicodeDecodeError:
            # Binary data outside a data block — shouldn't happen, but pass through
            if in_commit:
                commit_buffer.append(raw_line)
            else:
                output_stream.write(raw_line)
            continue

        stripped = line.rstrip("\n")

        # Detect start of a new commit
        if stripped.startswith("commit "):
            # Flush previous commit (if any)
            flush_commit()
            in_commit = True
            if do_ref_rewrite:
                rewritten = rewrite_ref_line(stripped, "commit", source_ref, target_ref)
                commit_buffer.append((rewritten + "\n").encode("utf-8"))
            else:
                commit_buffer.append(raw_line)
            continue

        # Capture this commit's mark — needed so that, if we later drop
        # the commit, subsequent `from :N` references can be redirected
        # through `dropped_mark_to_parent`.
        if in_commit and stripped.startswith("mark :"):
            try:
                current_mark = int(stripped[len("mark :") :])
            except ValueError:
                # Unexpected shape — keep buffering verbatim and leave
                # current_mark unset so we don't risk corrupting the map.
                pass
            commit_buffer.append(raw_line)
            continue

        # Capture parent references (from / merge) as tuples so flush_commit
        # can rewrite the mark through the dropped-mark map. Non-mark forms
        # (`from <sha1>`) pass through verbatim — fast-export emits marks
        # when `--export-marks` is set, which is the sync pipeline's norm.
        if in_commit and stripped.startswith(("from :", "merge :")):
            kind, _, mark_tok = stripped.partition(" :")
            try:
                mark_int = int(mark_tok)
                commit_buffer.append((kind, mark_int))
                continue
            except ValueError:
                commit_buffer.append(raw_line)
                continue

        # Handle data blocks — read exactly N bytes and pass through
        data_match = re.match(r"^data (\d+)$", stripped)
        if data_match:
            byte_count = int(data_match.group(1))
            if in_commit:
                commit_buffer.append(raw_line)
                # Read exactly byte_count bytes
                data = input_stream.read(byte_count)
                commit_buffer.append(data)
            else:
                output_stream.write(raw_line)
                data = input_stream.read(byte_count)
                output_stream.write(data)
            continue

        # Rewrite author/committer lines
        if stripped.startswith("author "):
            rewritten = rewrite_identity_line(stripped, mailmap, "author", collect_unmapped)
            encoded = (rewritten + "\n").encode("utf-8")
            if in_commit:
                commit_buffer.append(encoded)
            else:
                output_stream.write(encoded)
            continue

        if stripped.startswith("committer "):
            rewritten = rewrite_identity_line(stripped, mailmap, "committer", collect_unmapped)
            encoded = (rewritten + "\n").encode("utf-8")
            if in_commit:
                commit_buffer.append(encoded)
            else:
                output_stream.write(encoded)
            continue

        # Track file operations for empty-commit detection. Under
        # --exclude-path, drop ops whose path falls under an exclude prefix
        # entirely BEFORE counting them: a dropped op must not keep the
        # commit alive, and a commit whose every op is dropped must be
        # stripped by flush_commit()'s has_file_ops check.
        if in_commit and stripped and stripped[0] in "MDRC" and len(stripped) >= 2 and stripped[1] == " ":
            fileop = split_fileop_path_fields(stripped)
            if fileop is not None:
                _op, paths = fileop
                if do_path_filter and (
                    (
                        do_include_filter
                        and any(
                            not path_is_included(
                                p, include_prefixes or [], include_files or []
                            )
                            for p in paths
                        )
                    )
                    or any(
                        path_is_excluded(p, exclude_prefixes or [])
                        or basename_is_excluded(p, exclude_basenames or [])
                        for p in paths
                    )
                ):
                    # Skip emission entirely. Renames (R/C, only seen when
                    # fast-export ran WITHOUT --no-renames) are dropped if
                    # either side touches an excluded path — the safe choice,
                    # since a half-applied rename would corrupt the tree.
                    # With --no-renames the export decomposes R into D+M
                    # which are filtered independently.
                    continue
                has_file_ops = True
                commit_buffer.append(raw_line)
                continue
            # Defensive: line starts with an op marker but didn't parse.
            # Preserve pre-Option-B behavior — count it and pass through
            # unchanged — rather than silently dropping a valid op variant
            # we don't recognize.
            has_file_ops = True
            commit_buffer.append(raw_line)
            continue

        # Handle 'reset', 'blob', 'tag', etc. — not inside a commit
        if stripped.startswith(("reset ", "blob", "tag ", "progress ", "feature ", "option ")):
            flush_commit()
            if do_ref_rewrite and stripped.startswith("reset "):
                rewritten = rewrite_ref_line(stripped, "reset", source_ref, target_ref)
                output_stream.write((rewritten + "\n").encode("utf-8"))
            else:
                output_stream.write(raw_line)
            continue

        # Everything else: buffer if in commit, pass through otherwise
        if in_commit:
            commit_buffer.append(raw_line)
        else:
            output_stream.write(raw_line)

    output_stream.flush()


def main():
    parser = argparse.ArgumentParser(
        description="Filter a git fast-export stream: rewrite emails and strip empty commits."
    )
    parser.add_argument(
        "--mailmap",
        required=True,
        help="Path to the sync-mailmap file for email rewriting.",
    )
    parser.add_argument(
        "--source-ref",
        default=None,
        help="Source ref name as it appears in the stream (e.g., refs/heads/main). "
        "If provided with --target-ref, rewrites commit/reset lines to point to target-ref.",
    )
    parser.add_argument(
        "--target-ref",
        default=None,
        help="Target ref name to rewrite to (e.g., refs/heads/sync/dry-run-XYZ).",
    )
    parser.add_argument(
        "--collect",
        action="store_true",
        default=False,
        help="Collect all unmapped emails instead of aborting on the first one. "
        "Prints all unmapped emails to stderr and exits with code 1 if any found.",
    )
    parser.add_argument(
        "--include-prefix",
        action="append",
        default=[],
        metavar="PATH",
        help="Keep file operations at PATH or below it. Repeatable.",
    )
    parser.add_argument(
        "--include-file",
        action="append",
        default=[],
        metavar="PATH",
        help="Keep file operations for exactly PATH. Repeatable.",
    )
    parser.add_argument(
        "--exclude-path",
        action="append",
        default=[],
        metavar="PATH",
        help="Drop fast-import file operations (M/D/R/C) whose path equals or "
        "starts with PATH (followed by '/'). Repeatable. Accepts plain repo-"
        "relative paths and git pathspec ':!' / ':(exclude)' magic — magic is "
        "stripped before matching. This replaces fast-export pathspec "
        "filtering, which forces --full-tree mode and breaks the marks-anchored "
        "parent-tree inheritance the protected-paths guard depends on. "
        "See ADO 5347427 for the failure mode.",
    )
    parser.add_argument(
        "--exclude-basename",
        action="append",
        default=[],
        metavar="NAME",
        help="Drop fast-import file operations (M/D/R/C) whose path's final "
        "component equals NAME, anywhere in the tree. Repeatable. Used for "
        "scattered internal marker files (e.g. '.ci-skip' / '.code-ci-skip') "
        "that share no common path prefix, so '--exclude-path' cannot match "
        "them. Like '--exclude-path', this filters deltas in delta mode so the "
        "next fast-import inherits content from the marks-anchored parent.",
    )
    args = parser.parse_args()

    if (args.source_ref is None) != (args.target_ref is None):
        print("ERROR: --source-ref and --target-ref must be provided together.", file=sys.stderr)
        sys.exit(1)

    mailmap = load_mailmap(args.mailmap)

    collect_unmapped = set() if args.collect else None

    exclude_prefixes = [
        p for p in (normalize_exclude_prefix(raw) for raw in args.exclude_path) if p
    ]

    exclude_basenames = [b for b in args.exclude_basename if b]
    include_prefixes = [
        normalize_exclude_prefix(raw) for raw in args.include_prefix if raw
    ]
    include_files = [raw.rstrip("/") for raw in args.include_file if raw]

    # Work in binary mode to handle data blocks correctly
    input_stream = sys.stdin.buffer
    output_stream = sys.stdout.buffer

    filter_stream(
        input_stream,
        output_stream,
        mailmap,
        args.source_ref,
        args.target_ref,
        collect_unmapped,
        exclude_prefixes,
        exclude_basenames,
        include_prefixes,
        include_files,
    )

    if collect_unmapped:
        print(f"\nERROR: Found {len(collect_unmapped)} unmapped internal email(s):", file=sys.stderr)
        for identity in sorted(collect_unmapped):
            print(f"  • {identity}", file=sys.stderr)
        print("\nAdd these emails to the sync-mailmap file before syncing.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
