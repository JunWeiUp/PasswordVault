# Repository agent guidance

Follow [AGENTS.md](AGENTS.md) for this repository's development and security rules.

Git 提交时去掉用户敏感数据，把敏感数据放到 `.gitignore` 中。

Only add sensitive file or directory paths to `.gitignore`, never the sensitive contents. If a private file is already tracked, remove it from the Git index while preserving the local copy. Review staged changes before every commit.
