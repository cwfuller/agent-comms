#!/usr/bin/env python3
"""List every `producer | grep -q` whose producer is not a bash builtin echo/printf of one variable.

The suite runs under `set -o pipefail`. `grep -q` exits at its first match; a producer that
writes again afterwards takes SIGPIPE and the pipeline fails, so a passing check fails and a
negated one passes. A command producer feeds grep through `grep_full` (tests/lib/harness.sh), a
captured value through a here-string. The one shape still allowed to pipe into `grep -q` is
`echo "$var"` / `printf '%s\\n' "$var"`: the builtin runs in a forked subshell that needs no exec,
so it finishes writing before grep can read.

Each file is scanned as ONE stream, not line by line: quotes, command substitutions, line
continuations and pipes that end a line all carry across newlines. A `<<` opens a heredoc only
in executable context (never inside quotes or a comment). A quoted-delimiter heredoc body is
data and is skipped; an unquoted one, and the inside of `$(( ))`, still EXPAND, so the command
substitutions in them are scanned like any other code. Options are judged as WRITTEN: a grep
option produced by an expansion (`grep $(echo -q)`, `grep "$opt"`) is out of scope.
The scanner FAILS CLOSED: a heredoc whose delimiter never appears, or quoting / substitution
still open at end of file, is reported as an offender, because either one means the rest of the
file was not really seen. A pipe on a line carrying the marker `grepq-lint: control` is skipped:
it is a deliberate old-shape control in the harness self-test.

Usage: grepq_lint.py <file>...   Prints `file:line: <producer>` per offender; exit 1 if any.
"""
import re
import sys

ALLOWED = re.compile(r"""(?:echo|printf\s+(?:--\s+)?'%s(?:\\n)?')\s+"\$(?:\{?[A-Za-z_][A-Za-z0-9_]*\}?|[0-9@])\"""")
KEYWORDS = re.compile(r'^(?:(?:!|if|then|elif|else|while|until|do)\s+)+')
ASSIGNMENT = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
REDIRECT = re.compile(r'^(?:[0-9]*(?:<<?|>>?|<>|>\||[<>]&)|&>>?)(.*)$', re.S)
GREPS = {'grep', 'egrep', 'fgrep'}
ARG_OPTIONS = set('efmABCdD')  # grep short options whose value may follow as the next word
# Prefix commands: (their options that take a separate value, positional words before the command).
WRAPPERS = {'env': (set('uCS'), 0), 'command': (set(), 0), 'builtin': (set(), 0), 'nice': (set('n'), 0),
            'nohup': (set(), 0), 'exec': (set('a'), 0), 'time': (set(), 0), 'stdbuf': (set('ioe'), 0),
            'timeout': (set('sk'), 1)}
BLANK = ' \t'
OPENERS = ('if', 'while', 'until', '!')  # compound openers whose first command reads the pipe
WORD_END = BLANK + '\n;&|()'
EXPANDING = 'H'  # quote state of text that is not parsed as commands but still expands $(...)
ARITHMETIC = 'A'  # inside $(( )) / (( )): parentheses nest, and $(...) still expands
DQ_ESCAPE = re.compile(r'\\(?:\n|([$`"\\]))')  # what bash removes inside "...": \<newline>, \$ \` \" \\
ANSI_ESCAPE = re.compile(r'\\(x[0-9A-Fa-f]{1,2}|[0-7]{1,3}|.)', re.S)
ANSI_CHARS = {'n': '\n', 't': '\t', 'r': '\r', 'a': '\a', 'b': '\b', 'e': '\x1b', 'E': '\x1b',
              'f': '\f', 'v': '\v', '\\': '\\', "'": "'", '"': '"', '?': '?'}
FRAME_END = object()  # marker a nested scan yields where its bottom frame closes


def skip_single(text, i):
    """Index after the `'` closing a single-quoted string whose body starts at text[i]."""
    end = text.find("'", i)
    return len(text) if end < 0 else end + 1


def skip_double(text, i):
    """Index after the `"` closing a double-quoted string whose body starts at text[i]."""
    n = len(text)
    while i < n:
        if text[i] == '\\':
            i += 2
        elif text[i] == '"':
            return i + 1
        else:  # `$'` inside double quotes is a literal `$` and quote, not ANSI-C quoting
            i = i + 1 if text.startswith("$'", i) else skip_expansion(text, i)
    return n


def skip_expansion(text, i):
    """Index after the expansion starting at text[i] (`$(`, `$((`, `${`, backtick, `<(`, `>(`,
    `$'`), or i + 1 when none starts there. Command substitutions and arithmetic are closed by
    the SAME scanner `pipes()` uses, so the word reader cannot lex them differently."""
    n = len(text)
    if text.startswith("$'", i):
        return skip_ansi(text, i + 2)
    if text.startswith('$((', i):
        return frame_end(text, i + 3, ARITHMETIC, '((')
    if text.startswith(('$(', '<(', '>('), i):
        return frame_end(text, i + 2, None, '(')
    if text[i:i + 1] == '`':
        return frame_end(text, i + 1, None, '`')
    if text.startswith('${', i):
        i += 2
        while i < n and text[i] != '}':
            if text[i] == '\\':
                i += 2
            elif text[i] == "'":
                i = skip_single(text, i + 1)
            elif text[i] == '"':
                i = skip_double(text, i + 1)
            else:
                i = skip_expansion(text, i)
        return min(i + 1, n)
    return i + 1


def ansi_char(m):
    """Decode one `$'...'` escape as bash does; an unknown escape keeps its backslash."""
    e = m.group(1)
    if e[0] == 'x' and len(e) > 1:
        return chr(int(e[1:], 16))
    if e[0] in '01234567':
        return chr(int(e, 8) & 0xFF)
    return ANSI_CHARS.get(e, '\\' + e)


def skip_ansi(text, i):
    """Index after the `'` closing an ANSI-C `$'...'` string whose body starts at text[i]."""
    n = len(text)
    while i < n and text[i] != "'":
        i += 2 if text[i] == '\\' else 1
    return min(i + 1, n)


def frame_end(text, begin, quote, opener):
    """Index after the frame opened just before text[begin], as `pipes()` closes it."""
    for offset, producer in pipes(text, quote, begin=begin, bottom=opener):
        if producer is FRAME_END:
            return offset
    return len(text)


def read_word(text, i):
    """(word with quoting removed, its raw source, index after it) for the word at text[i].
    The RAW form decides whether it is a redirection: a quoted '>' is data, not an operator.
    An expansion (`$(...)`, `${...}`, backticks, `<(...)`) stays inside the word it is part of."""
    word, begin, n = '', i, len(text)
    while i < n:
        c = text[i]
        raw = text[begin:i]
        if c == "'":
            end = skip_single(text, i + 1)
            word += text[i + 1:end - 1]
            i = end
        elif c == '"':
            end = skip_double(text, i + 1)
            word += DQ_ESCAPE.sub(lambda m: m.group(1) or '', text[i + 1:end - 1])
            i = end
        elif text.startswith("$'", i):  # ANSI-C: the word is the decoded body
            end = skip_ansi(text, i + 2)
            word += ANSI_ESCAPE.sub(ansi_char, text[i + 2:end - 1]).split('\0', 1)[0]  # bash stops at NUL
            i = end
        elif text.startswith('$"', i):  # locale string: quoted like "..."
            end = skip_double(text, i + 2)
            word += DQ_ESCAPE.sub(lambda m: m.group(1) or '', text[i + 2:end - 1])
            i = end
        elif c in '$`' or (c in '<>' and text[i + 1:i + 2] == '('):
            end = skip_expansion(text, i)
            word += text[i:end]
            i = end
        elif c == '\\':
            word += text[i + 1:i + 2] if text[i + 1:i + 2] != '\n' else ''
            i += 2
        elif c == '&' and (raw.endswith(('<', '>')) or text[i + 1:i + 2] == '>'):
            word += c  # `2>&1`, `&>file`: part of a redirection, not a command separator
            i += 1
        elif c in WORD_END or (c in '<>' and raw and not REDIRECT.match(raw + c)):
            break
        else:
            word += c
            i += 1
    return word, text[begin:i], i


def command_words(text, i):
    """[(word, raw)] of the simple command starting at text[i]: blanks, newlines and whole-line
    comments before it are skipped (a pipe may end its line), redirections are kept as words."""
    words, n = [], len(text)
    while i < n:
        if text[i] in BLANK + '\n':
            i += 1
        elif text.startswith('\\\n', i):
            i += 2
        elif text[i] == '#':
            while i < n and text[i] != '\n':
                i += 1
        elif text[i] in '({' and not text.startswith('((', i):
            i += 1  # `| (grep -q x)`, `| { grep -q x; }`: the group's first command reads the pipe
        elif any(keyword_at(text, i, w) for w in OPENERS):
            i += len(next(w for w in OPENERS if keyword_at(text, i, w)))
        else:
            break
    while i < n:
        if text[i] in BLANK or text.startswith('\\\n', i):
            i += 2 if text[i] == '\\' else 1
            continue
        if text[i] in '\n;|()' or text[i] == '#' or (text[i] == '&' and text[i + 1:i + 2] != '>'):
            break
        word, raw, i = read_word(text, i)
        words.append((word, raw))
    return words


def drop_redirections(words):
    out, skip = [], False
    for word, raw in words:
        if skip:
            skip = False
            continue
        m = REDIRECT.match(raw)
        if m:
            skip = m.group(1) == ''  # `2> file`: the target is the next word
            continue
        out.append(word)
    return out


def quiet_grep(words):
    """True when the words are a grep command asked to stop at its first match."""
    words = drop_redirections(words)
    while words:
        head = words[0].rsplit('/', 1)[-1]
        if ASSIGNMENT.match(words[0]):
            words = words[1:]
        elif head in WRAPPERS:
            takes, positionals = WRAPPERS[head]
            words = words[1:]
            while words and (words[0].startswith('-') or (head == 'env' and ASSIGNMENT.match(words[0]))):
                opt, words = words[0], words[1:]
                if len(opt) == 2 and opt[1] in takes:
                    words = words[1:]
            words = words[positionals:]
        else:
            break
    if not words or words[0].rsplit('/', 1)[-1] not in GREPS:
        return False
    args = iter(words[1:])
    for word in args:
        if word == '--':
            return False
        if word in ('--quiet', '--silent'):
            return True
        if word.startswith('--') or not word.startswith('-') or word == '-':
            continue
        for k, letter in enumerate(word[1:]):
            if letter == 'q':
                return True
            if letter in ARG_OPTIONS:
                if k == len(word) - 2:
                    next(args, None)  # `-e PAT`: the pattern is the next word, never an option
                break
    return False


def keyword_at(text, i, word):
    """True when the shell reserved word `word` starts at text[i] (unquoted context assumed)."""
    before = text[i - 1] if i else '\n'
    after = text[i + len(word):i + len(word) + 1] or '\n'
    return text.startswith(word, i) and before in BLANK + '\n;&|(' and after in BLANK + '\n;)'


def shifted(found, base):
    for offset, producer in found:
        yield base + offset, producer


def pipes(text, mode=None, begin=0, bottom=None):
    """Yield (offset, producer text) for each unquoted `| grep -q` in shell text, and
    (offset, None) where the scanner lost its place and cannot vouch for the rest.
    mode=EXPANDING scans text that only EXPANDS — an unquoted heredoc body — for the command
    substitutions in it, which are ordinary executable code."""
    i, n, quote, start, pending = begin, len(text), mode, begin, []
    # frames: (quote, start, opener, cases, arithmetic depth) to restore when the frame closes
    stack, cases, depth = [], 0, 0
    if bottom:  # a nested scan for the word reader: report where this frame closes, then stop
        stack.append((FRAME_END, begin, bottom, 0, 0))
    while i < n:
        c = text[i]
        if quote in ("'", '$'):
            if quote == '$' and c == '\\':
                i += 2
                continue
            quote = None if c == "'" else quote
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if (text.startswith('$((', i) and quote in (None, '"', EXPANDING, ARITHMETIC)) or \
                (text.startswith('((', i) and quote is None):
            # Arithmetic is a FRAME, not a span: its end is found by the same scanner, so a
            # quoted `(` inside a nested `$(...)` cannot move it. It expands `$(...)` like `"`.
            stack.append((quote, start, '((', cases, depth))
            quote, depth = ARITHMETIC, 0
            i += 3 if c == '$' else 2
            continue
        if quote == ARITHMETIC:
            if text.startswith('$(', i) or c == '`':
                stack.append((quote, start, c, cases, depth))
                quote, cases = None, 0
                i = start = i + (1 if c == '`' else 2)
                continue
            if c == '(':
                depth += 1
            elif c == ')' and depth:
                depth -= 1
            elif c == ')' and text[i + 1:i + 2] == ')':
                quote, start, _, cases, depth = stack.pop()
                i += 2
                if quote is FRAME_END:
                    yield i, FRAME_END
                    return
                continue
            i += 1
            continue
        if quote in ('"', EXPANDING):
            if c == '"' and quote == '"':
                quote = None
            elif text.startswith('$(', i) or c == '`':
                stack.append((quote, start, c, cases, depth))
                quote, cases = None, 0
                i = start = i + (1 if c == '`' else 2)
                continue
            i += 1
            continue
        if text.startswith("$'", i):
            quote, i = '$', i + 2
            continue
        if c in '\'"':
            quote = c
        elif c == '#' and (i == 0 or text[i - 1] in BLANK + '\n;|&('):
            while i < n and text[i] != '\n':
                i += 1
            continue
        elif text.startswith('<<<', i):
            i += 3
            continue
        elif text.startswith('<<', i):
            j = i + 2 + (text[i + 2:i + 3] == '-')
            while text[j:j + 1] in (' ', '\t'):
                j += 1
            word, raw, j = read_word(text, j)
            if word:
                quoted = any(q in raw.replace('\\\n', '') for q in '\'"\\')  # `EO\<newline>F` is not quoting
                pending.append((word, text[i + 2] == '-', i, quoted))
            i = j
            continue
        elif keyword_at(text, i, 'case'):
            cases += 1
        elif keyword_at(text, i, 'esac'):
            cases = max(0, cases - 1)
        elif c == '`' and stack and stack[-1][2] == '`':
            quote, start, _, cases, depth = stack.pop()
            if quote is FRAME_END:
                yield i + 1, FRAME_END
                return
        elif c == '`' or text.startswith(('$(', '<(', '>('), i):
            stack.append((None, start, c, cases, depth))
            cases = 0
            i = start = i + (1 if c == '`' else 2)
            continue
        elif c == '(':
            stack.append((None, start, '(', cases, depth))
            cases = 0
            start = i + 1
        elif c == ')':
            if cases == 0 and stack and stack[-1][2] not in ('`', '(('):  # else: a `case` pattern's `)`
                quote, start, _, cases, depth = stack.pop()
                if quote is FRAME_END:
                    yield i + 1, FRAME_END
                    return
        elif text.startswith(('&&', '||'), i):
            i = start = i + 2
            continue
        elif c in ';{}' or (c == '&' and text[i - 1] not in '<>' and text[i + 1:i + 2] != '>'):
            start = i + 1
        elif c == '\n':
            while pending:
                word, strip, opened, quoted = pending.pop(0)
                body = i + 1
                while True:
                    if i >= n:
                        yield opened, None  # delimiter never found: the rest of the file is unseen
                        return
                    end = text.find('\n', i + 1)
                    end = n if end < 0 else end
                    line, line_start, i = text[i + 1:end], i + 1, end
                    if (line.lstrip('\t') if strip else line) == word:
                        break
                if not quoted:  # an unquoted delimiter: the body expands $(...), so scan it
                    yield from shifted(pipes(text[body:line_start], EXPANDING), body)
            start = i + 1
        elif c == '|':
            after = i + 1 + (text[i + 1:i + 2] == '&')
            if quiet_grep(command_words(text, after)):
                yield i, text[start:i]
            start = after
        i += 1
    if quote != mode or stack or pending:
        yield n - 1, None  # still inside a quote, substitution or heredoc at end of text


def offenders(path):
    text = open(path, encoding='utf-8', errors='replace').read()
    lines = text.split('\n')
    for offset, producer in pipes(text):
        number = text.count('\n', 0, offset) + 1
        if producer is None:
            yield '%s:%d: <scanner lost its place here; nothing after it was checked>' % (path, number)
            continue
        if 'grepq-lint: control' in lines[number - 1]:
            continue
        stage = KEYWORDS.sub('', ' '.join(producer.replace('\\\n', ' ').split()))
        if not ALLOWED.fullmatch(stage):
            yield '%s:%d: %s' % (path, number, stage or '<empty>')


def main(paths):
    found = [hit for path in paths for hit in offenders(path)]
    for hit in found:
        print(hit)
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
