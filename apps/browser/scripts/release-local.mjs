import { spawnSync } from 'node:child_process';

// Default to a patch bump; allow coordinated releases to choose a numeric version.
const version = process.env.PASSWORDVAULT_RELEASE_VERSION || 'patch';
if (version !== 'patch' && !/^\d+\.\d+\.\d+$/.test(version)) {
  throw new Error('Expected a numeric release version');
}
for (const args of [['version', version, '--no-git-tag-version'], ['run', 'check'], ['run', 'build'], ['test']]) {
  const result = spawnSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', args, { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
