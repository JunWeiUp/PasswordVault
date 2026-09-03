# Publishing the repository

The original repository is private. Its history contains Android signing material and local development journals. Removing a file from the current tree is not sufficient to make those earlier commits safe to publish.

## Prepared approach

1. Keep an access-restricted backup outside this repository. Do not upload the original bundle or working-tree patch.
2. Clone every remote branch and tag into a separate review repository. Translate commit titles and bodies into English Conventional Commits while retaining authors, dates, and merge topology.
3. Remove historical signing configuration, keystores, local agent journals, and generated source-map/dependency files that contain local paths. Add the cleaned current source and public documentation.
4. Scan the resulting full history with Gitleaks and independently inspect every historical filename for signing material. Compare the final source tree with the reviewed working tree and run CI from a clean checkout.
5. Review the rewritten commit map, affected branches/tags, old releases, and signing migration. History rewriting changes commit IDs and invalidates signatures and old links.
6. After explicit authorization, replace affected remote refs using their recorded old values as force-with-lease expectations. Do not use an unrestricted force push or publish the private backup.
7. Remove or archive obsolete debug releases and artifacts before changing visibility. Previously published download assets are separate from Git history and need their own review.
8. Coordinate clean re-clones with existing collaborators; retained clones can reintroduce old history. Follow GitHub's sensitive-data removal guidance for cached commits and pull-request references.
9. Rotate the old signing credentials, configure the release environment, enable private vulnerability reporting, and verify checks on the final refs.
10. Change visibility only after the review, then use the [launch kit](LAUNCH.md) for announcements approved by the maintainer.

## Signing continuity

A new Android signing key changes the application's signing identity. Existing installations may require a data export and reinstall, or an appropriate platform-supported signing migration. The choice must be made before publishing the first public APK. Do not silently replace the user's local key or claim an upgrade path without testing it.

## References

- [GitHub: removing sensitive repository data](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
- [Git filter-repo](https://github.com/newren/git-filter-repo)

Current publication approval and audit outputs are kept outside the public source tree. This guide is procedural; it is not evidence that the remote history has already been rewritten.
