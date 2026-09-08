#!/usr/bin/env python3
"""Require an existing release tag to identify the revision checked by this run."""
import os
import subprocess
from pathlib import Path

from check_repository import ROOT, validate_tag


def resolve_release(tag, expected_commit):
    validate_tag(tag)
    try:
        tagged_commit = subprocess.check_output(
            ['git', 'rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}'],
            cwd=ROOT, text=True, stderr=subprocess.DEVNULL).strip()
        checked_commit = subprocess.check_output(
            ['git', 'rev-parse', '--verify', f'{expected_commit}^{{commit}}'],
            cwd=ROOT, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        raise SystemExit('Release requires an existing tag and a valid checked commit.') from None
    if tagged_commit != checked_commit:
        raise SystemExit('Release tag differs from the checked revision. Dispatch the workflow on the existing tag.')
    return tagged_commit


def main():
    tag = os.environ.get('RELEASE_TAG', '')
    commit = resolve_release(tag, os.environ.get('CHECKED_COMMIT') or os.environ.get('GITHUB_SHA', 'HEAD'))
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with Path(output).open('a', encoding='utf-8') as stream:
            stream.write(f'tag={tag}\ncommit={commit}\n')
    print(f'Validated existing tag {tag} at {commit}.')


if __name__ == '__main__':
    main()
