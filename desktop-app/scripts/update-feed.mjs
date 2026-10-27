// Keeps the GUI update feed file (electron-builder's latest-mac.yml) in step with the files a
// release publishes, and checks it before anything is uploaded (release-desktop.yml).
//
//   node scripts/update-feed.mjs restamp <latest-mac.yml> <file>
//     Rewrites <file>'s sha512 and size: the DMG is signed and stapled after the build wrote them.
//   node scripts/update-feed.mjs check <latest-mac.yml> <version> <zip>
//     Fails unless the feed is for <version>, offers <zip>, and every entry matches its file.
import { createHash } from 'node:crypto';
import { readFileSync, statSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function describe(file) {
  return {
    sha512: createHash('sha512').update(readFileSync(file)).digest('base64'),
    size: statSync(file).size,
  };
}

// electron-builder writes each file as `- url:` (and the first again as the top-level `path:`),
// followed by its `sha512:` and `size:`. Only those of `name` change.
export function restamp(feed, name, { sha512, size }) {
  let current;
  return feed
    .split('\n')
    .map((line) => {
      const file = /^\s*(?:- )?(?:url|path): ['"]?(.+?)['"]?$/.exec(line);
      if (file) current = file[1];
      const field = /^(\s*(?:- )?)(sha512|size): /.exec(line);
      if (!field || current !== name) return line;
      return `${field[1]}${field[2]}: ${field[2] === 'sha512' ? sha512 : size}`;
    })
    .join('\n');
}

export function entries(feed) {
  return [...feed.matchAll(/^\s*- url: ['"]?(.+?)['"]?\n\s+sha512: (\S+)\n\s+size: (\d+)$/gm)].map(
    ([, name, sha512, size]) => ({ name, sha512, size: Number(size) }),
  );
}

export function check(feed, version, zip, read = describe) {
  if (!new RegExp(`^version: ${version.replaceAll('.', '\\.')}$`, 'm').test(feed))
    throw new Error(`The feed is not for version ${version}`);
  const files = entries(feed);
  if (!files.some((file) => file.name === zip)) throw new Error(`The feed does not offer ${zip}`);
  for (const file of files) {
    const actual = read(file.name);
    if (actual.sha512 !== file.sha512 || actual.size !== file.size)
      throw new Error(`The feed's entry for ${file.name} does not match the file`);
  }
  return files.map((file) => file.name);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [command, feedPath, ...args] = process.argv.slice(2);
  const feed = readFileSync(feedPath, 'utf8');
  if (command === 'restamp') {
    writeFileSync(feedPath, restamp(feed, args[0], describe(args[0])));
  } else if (command === 'check') {
    console.log(`Feed ${args[0]} offers: ${check(feed, args[0], args[1]).join(', ')}`);
  } else {
    console.error('usage: update-feed.mjs restamp <feed> <file> | check <feed> <version> <zip>');
    process.exit(2);
  }
}
