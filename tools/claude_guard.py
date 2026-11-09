#!/usr/bin/env python3
"""Claude Code PreToolUse hook for the Bash tool (.claude/settings.json). Reads the call as JSON on stdin and exits 2, with the reason
on stderr, for a `git push` to main or master, for `--no-verify` on `git commit` and `git push`, and for anything else that turns
the hooks off: `git -c core.hooksPath=<other>` on a commit or push, and `git config core.hooksPath <other>` or its --unset. Exit 0
lets the call go on. The body of a heredoc is text (a file being written, a commit message), not commands, unless a shell reads it.
"""
import json
import os
import re
import shlex
import subprocess
import sys

PROTECTED = ('main', 'master')
WRAPPERS = ('sudo', 'env', 'command', 'time', 'nohup', 'exec')
PUSH_ARG_FLAGS = ('-o', '--push-option', '--receive-pack', '--exec', '--repo')   # options that take the next word as their value
GIT_ARG_FLAGS = ('-C', '-c', '--git-dir', '--work-tree', '--namespace')
SHELLS = ('sh', 'bash', 'zsh')
HOOKS_DIR = '.githooks'
# git commit's short options that take a value, attached (-uno, -mmsg) or as the next word (-m msg)
COMMIT_VALUE_SHORT = set('mFCctuS')
COMMIT_VALUE_LONG = ('--message', '--file', '--reuse-message', '--reedit-message', '--fixup', '--squash', '--author', '--date',
                     '--template', '--cleanup', '--trailer', '--pathspec-from-file', '--gpg-sign')
PIPE_TO_SHELL = re.compile(r'\|\s*(?:sudo\s+)?(?:\S*/)?(?:sh|bash|zsh)\b')
HEREDOC = re.compile(r"""<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2""")

NO_PR = 'Patches and code go through a PR: push a branch and open a pull request. Nothing is pushed to main or master directly.'
NO_VERIFY = 'The pre-commit and pre-push hooks stay on. Fix what they report instead of using --no-verify.'
NO_HOOKS_PATH = 'The hooks stay on: core.hooksPath stays .githooks (AGENTS.md). Fix what the hooks report instead of turning them off.'


def without_heredocs(command):
    """The command line without the bodies of its heredocs, which are text, not commands: a file being written, a commit
    message. A heredoc fed to a shell (bash <<EOF) is kept, since the shell runs it."""
    lines, out, pending = command.split('\n'), [], []
    for line in lines:
        if pending:
            strip_tabs, word, keep = pending[0]
            if (line.lstrip('\t') if strip_tabs else line) == word:
                pending.pop(0)
            elif keep:
                out.append(line)
            continue
        out.append(line)
        for m in HEREDOC.finditer(line):
            head = line[:m.start()].split('|')[-1].split()
            # a shell reads the body: `bash <<EOF`, or `cat <<EOF | bash`
            runs = (bool(head) and os.path.basename(head[0]) in SHELLS) or bool(PIPE_TO_SHELL.search(line[m.end():]))
            pending.append((m.group(1) == '-', m.group(3), runs))
    return '\n'.join(out)


def commit_skips_hooks(args):
    """Whether `git commit` arguments ask for --no-verify, as -n alone or in a cluster (-nm), reading clusters as git does:
    in -uno or -mfix the letters after u or m are that option's value, not more options."""
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a == '--':
            break
        if a == '--no-verify':
            return True
        if a.startswith('--'):
            skip = a in COMMIT_VALUE_LONG
            continue
        if a.startswith('-') and len(a) > 1:
            for i, ch in enumerate(a[1:], 1):
                if ch == 'n':
                    return True
                if ch in COMMIT_VALUE_SHORT:
                    skip = i == len(a) - 1      # -m alone: the next word is its value
                    break
    return False


def hooks_path_changed(opts, sub, args):
    """`git -c core.hooksPath=<other> commit|push`, or `git config ... core.hooksPath <other>` / `--unset core.hooksPath`."""
    for i, o in enumerate(opts):
        if o == '-c' and i + 1 < len(opts):
            key, _, value = opts[i + 1].partition('=')
            if key.lower() == 'core.hookspath' and value.rstrip('/') != HOOKS_DIR and sub in ('commit', 'push'):
                return True
    if sub == 'config':
        words = [a for a in args if not a.startswith('--') or a in ('--unset', '--unset-all', '--replace-all')]
        lower = [w.lower() for w in words]
        if 'core.hookspath' in lower:
            at = lower.index('core.hookspath')
            if any(w in ('--unset', '--unset-all') for w in words):
                return True
            value = words[at + 1] if at + 1 < len(words) else None
            return value is not None and value.rstrip('/') != HOOKS_DIR      # reading it (no value) is fine
    return False


def segments(command):
    """The commands in a shell line as word lists, split at ; && || | & and newlines. None when the line does not parse."""
    lex = shlex.shlex(command, posix=True, punctuation_chars=';&|()\n')
    lex.whitespace_split, lex.whitespace = True, ' \t\r'
    try:
        words = list(lex)
    except ValueError:
        return None
    out, cur = [], []
    for w in words:
        if w and set(w) <= set(';&|()\n'):
            if cur: out.append(cur)
            cur = []
        else:
            cur.append(w)
    return out + ([cur] if cur else [])


def git_call(words):
    """(global options, subcommand, its arguments) for a segment that runs git, else None."""
    i = 0
    while i < len(words) and (words[i] in WRAPPERS or re.fullmatch(r'\w+=.*', words[i])): i += 1
    if i >= len(words) or os.path.basename(words[i]) != 'git': return None
    i += 1
    opts = []
    while i < len(words) and words[i].startswith('-'):
        opts.append(words[i])
        if words[i] in GIT_ARG_FLAGS and i + 1 < len(words):
            i += 1
            opts.append(words[i])
        i += 1
    return (opts, words[i], words[i + 1:]) if i < len(words) else None


def current_branch(cwd, opts):
    if '-C' in opts: cwd = os.path.join(cwd, opts[opts.index('-C') + 1])
    r = subprocess.run(['git', 'branch', '--show-current'], cwd=cwd, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ''


def pushes_to_protected(opts, args, cwd):
    flags = [a for a in args if a.startswith('-')]
    if '--all' in flags or '--mirror' in flags: return True
    pos, skip = [], False
    for a in args:
        if skip: skip = False
        elif a in PUSH_ARG_FLAGS: skip = True
        elif not a.startswith('-'): pos.append(a)
    refspecs = pos[1:]   # the first word is the remote
    if not refspecs: return current_branch(cwd, opts) in PROTECTED
    for r in refspecs:
        dest = r.lstrip('+').split(':')[-1]
        if dest == 'HEAD': dest = current_branch(cwd, opts)
        if dest.removeprefix('refs/heads/') in PROTECTED: return True
    return False


def verdict(command, cwd='.'):
    """The reason to stop this command, or None."""
    command = without_heredocs(command)
    segs = segments(command)
    if segs is None:   # unbalanced quotes: look at the raw text
        if re.search(r'\bgit\b.*\bpush\b.*\b(main|master)\b', command): return NO_PR
        return NO_VERIFY if re.search(r'\bgit\b.*\b(commit|push)\b.*--no-verify', command) else None
    for words in segs:
        if os.path.basename(words[0]) in SHELLS and '-c' in words and words.index('-c') + 1 < len(words):
            reason = verdict(words[words.index('-c') + 1], cwd)   # bash -c "git push origin main"
            if reason: return reason
        call = git_call(words)
        if not call: continue
        opts, sub, args = call
        if sub == 'push' and pushes_to_protected(opts, args, cwd): return NO_PR
        if sub == 'push' and '--no-verify' in args: return NO_VERIFY
        if sub == 'commit' and commit_skips_hooks(args): return NO_VERIFY
        if hooks_path_changed(opts, sub, args): return NO_HOOKS_PATH
    return None


def main():
    try:
        call = json.load(sys.stdin)
        command = call['tool_input']['command']
    except (ValueError, KeyError, TypeError):
        return 0   # not a call this guard understands: no decision
    reason = verdict(command, call.get('cwd') or os.getcwd())
    if reason:
        print(f'Blocked by tools/claude_guard.py: {reason}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
