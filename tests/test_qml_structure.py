#!/usr/bin/env python3
"""Structural checks that qmllint does not make.

A property or signal handler bound twice inside one object is accepted by
qmllint and rejected by the QML engine at load, which makes a bar widget
vanish from the bar with nothing in the log to say why. A brace-depth scan
catches it before it ships.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# A binding line: `name: value` at the start of a statement, not a JS object
# literal key and not a nested type declaration.
BINDING = re.compile(r'^\s*(?:readonly\s+)?(?:property\s+\S+\s+)?([A-Za-z_][\w.]*)\s*:(?!:)')
DECLARES = re.compile(r'^\s*(?:readonly\s+)?property\s+')
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
LINE_COMMENT = re.compile(r'//.*$')


def strip(line):
    return LINE_COMMENT.sub('', STRING.sub('""', line))


def duplicate_bindings(path):
    """Every `name:` bound more than once at the same brace depth in one object."""
    text = path.read_text(encoding='utf-8')
    depth = 0
    # depth -> {name: first line number}
    seen = {0: {}}
    in_block_comment = False
    in_function = []
    problems = []

    for number, raw in enumerate(text.split('\n'), start=1):
        line = raw
        if in_block_comment:
            if '*/' in line:
                line = line.split('*/', 1)[1]
                in_block_comment = False
            else:
                continue
        if '/*' in line:
            before, _, rest = line.partition('/*')
            if '*/' in rest:
                line = before + rest.split('*/', 1)[1]
            else:
                line = before
                in_block_comment = True

        code = strip(line)
        match = BINDING.match(code)
        # A binding inside a function body is JS, not a QML binding.
        inside_js = bool(in_function) and depth > in_function[-1]
        if match and not inside_js:
            name = match.group(1)
            # `property var x: ...` declares and binds once; only a second
            # mention of the same name at the same depth is the bug.
            bucket = seen.setdefault(depth, {})
            if name in bucket:
                # Both a property bound twice and a property declared twice
                # are rejected by the engine at load, silently.
                kind = 'declared again' if DECLARES.match(code) else 'bound again'
                problems.append('%s:%d: `%s` %s in the same object (first at line %d)'
                                % (path.name, number, name, kind, bucket[name]))
            else:
                bucket[name] = number

        if re.search(r'\bfunction\b', code):
            in_function.append(depth)

        for char in code:
            if char == '{':
                depth += 1
            elif char == '}':
                depth -= 1
                seen.pop(depth + 1, None)
                while in_function and in_function[-1] >= depth:
                    in_function.pop()
    return problems


def shadowed_members(path):
    """Item subclasses redeclaring a QQuickItem member."""
    reserved = {'state', 'z', 'data', 'children', 'parent', 'width', 'height',
                'opacity', 'visible', 'enabled', 'clip', 'rotation', 'scale'}
    problems = []
    for number, line in enumerate(path.read_text(encoding='utf-8').split('\n'), start=1):
        match = re.match(r'\s*(?:readonly\s+)?property\s+\w+\s+(\w+)\s*[:{]', line)
        if match and match.group(1) in reserved:
            problems.append('%s:%d: `property %s` shadows a QQuickItem member'
                            % (path.name, number, match.group(1)))
    return problems


def latched_visibility(path):
    """A `visible:` binding that reads a descendant's `visible`.

    Qt Quick's `visible` is effective visibility: a child of a hidden item
    reports false regardless of its own binding. An item whose `visible` reads
    its own child's `visible` therefore evaluates false once and can never
    recover, and the subtree silently never appears. Sibling references are
    fine and are the common, correct case, so only descendants are flagged.
    """
    lines = path.read_text(encoding='utf-8').split('\n')
    depth = 0
    ids = {}          # id -> (line number, brace depth)
    visibles = []     # (line number, depth, [referenced ids])
    for number, raw in enumerate(lines, start=1):
        code = strip(raw)
        match = re.match(r'\s*id:\s*([A-Za-z_]\w*)', code)
        if match:
            ids[match.group(1)] = (number, depth)
        if re.match(r'\s*visible\s*:', code):
            refs = re.findall(r'\b([A-Za-z_]\w*)\.visible\b', code)
            if refs:
                visibles.append((number, depth, refs))
        for char in code:
            if char == '{':
                depth += 1
            elif char == '}':
                depth -= 1

    problems = []
    for number, depth, refs in visibles:
        for name in refs:
            if name not in ids:
                continue
            declared_line, declared_depth = ids[name]
            if declared_line > number and declared_depth > depth:
                problems.append('%s:%d: `visible` reads `%s.visible`, a descendant '
                                '(declared line %d); this latches false forever'
                                % (path.name, number, name, declared_line))
    return problems



def duplicate_js_functions(path):
    """A function defined twice in one .js file.

    JavaScript keeps the last definition and says nothing, so a rename that
    matches in two places leaves the picker running the wrong half of its
    logic with every test still green.
    """
    seen = {}
    problems = []
    for number, line in enumerate(path.read_text(encoding='utf-8').split('\n'), start=1):
        match = re.match(r'\s*function\s+(\w+)\s*\(', strip(line))
        if not match:
            continue
        name = match.group(1)
        if name in seen:
            problems.append('%s:%d: function `%s` defined again (first at line %d)'
                            % (path.name, number, name, seen[name]))
        else:
            seen[name] = number
    return problems


def model_functions_exist(qml_path, js_path):
    """Every Model.<fn>() the QML calls has to exist in EmojiModel.js.

    A typo here is a TypeError at the moment someone presses a key, not at
    load, so nothing catches it until a user does.
    """
    js = js_path.read_text(encoding='utf-8')
    defined = set(re.findall(r'^\s*function\s+(\w+)\s*\(', js, re.M))
    used = set(re.findall(r'\bModel\.(\w+)\s*\(', qml_path.read_text(encoding='utf-8')))
    return ['%s: calls Model.%s(), which EmojiModel.js does not define' % (qml_path.name, name)
            for name in sorted(used - defined)]


def main():
    problems = []
    for path in sorted(ROOT.glob('*.qml')):
        problems += duplicate_bindings(path)
        problems += shadowed_members(path)
        problems += latched_visibility(path)
        problems += model_functions_exist(path, ROOT / 'EmojiModel.js')
    for path in sorted(ROOT.glob('*.js')):
        problems += duplicate_js_functions(path)
    if problems:
        print('\n'.join(problems))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
