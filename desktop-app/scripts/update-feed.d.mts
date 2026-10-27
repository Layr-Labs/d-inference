export type FeedFile = { sha512: string; size: number };

export function describe(file: string): FeedFile;
export function restamp(feed: string, name: string, file: FeedFile): string;
export function entries(feed: string): ({ name: string } & FeedFile)[];
export function check(
  feed: string,
  version: string,
  zip: string,
  read?: (name: string) => FeedFile,
): string[];
