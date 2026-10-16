# Metrics — where people come from

GitHub keeps a repo's traffic (views, clones, referrers, popular paths) for 14 days
and keeps no history of release download counts. A launch post is unmeasurable a
fortnight later unless something wrote those numbers down. Two things do that: a
daily traffic archive, and UTM tags on every link we post.

Nothing here runs inside the app or touches users' machines. It is the maintainer's
own bookkeeping, from the GitHub API and the landing page's analytics.

## The traffic archive

```bash
Scripts/dev/traffic-snapshot.sh            # append (or replace) today's line
Scripts/dev/traffic-snapshot.sh --summary  # one screen from the archive, no network
```

- Archive: `~/.agentbar-metrics/traffic.jsonl`, outside the repo. Override with
  `--archive PATH` or `AGENTBAR_TRAFFIC_ARCHIVE`; the repo with `--repo owner/name`
  or `AGENTBAR_TRAFFIC_REPO`.
- One JSON line per UTC day: stars, forks, watchers, views and clones (14-day totals
  plus a daily breakdown), top referrers, popular paths, every release with each
  asset's download count, the downloads total, and open issues by anyone other than
  the owner.
- Idempotent per day: a second run the same day replaces that day's line.
- The daily breakdown in the newest line is the whole history seen so far: each run
  merges GitHub's 14-day window into what earlier lines recorded, one entry per day,
  a newer reading of a day replacing an older one. So a missed day costs nothing as
  long as some run happens within 14 days.
- Needs `gh` signed in with push access (the traffic endpoints require it) and
  `node`. Every call is a read.
- `--summary` shows stars, unique visitors (14 d), downloads of the latest release
  and of all releases, top referrers and paths, and — once a line from 7 or more
  days earlier exists — the change since then.

To run it daily, `Scripts/dev/traffic-launchd.plist` is an example launchd job
(09:15 every day). It is not installed by anything; the comment at its top says how.

## UTM links

GitHub links cannot carry UTM parameters, so posts link to the landing page,
https://michalstrnadel.com/agentbar, wherever the network allows, tagged:

```
https://michalstrnadel.com/agentbar?utm_source=<network>&utm_medium=social&utm_campaign=<yyyy-mm-slug>
```

- `utm_medium` is always `social`.
- `utm_campaign` is the month the post went out and a short slug for it, e.g.
  `2026-10-keep-awake` or `2026-11-phone-approvals`. One campaign per announcement,
  shared by every network it was posted to.
- `utm_source` is the network, from this table. Add a row rather than inventing a
  spelling in a post.

| `utm_source` | Where |
|---|---|
| `x` | X / Twitter |
| `bluesky` | Bluesky |
| `linkedin` | LinkedIn |
| `threads` | Threads |
| `mastodon` | Mastodon (any instance) |
| `reddit-<sub>` | Reddit, by subreddit in lowercase: `reddit-macapps`, `reddit-claudeai` |
| `hn` | Hacker News |
| `awesome-<list>` | An awesome list, by its repo name: `awesome-mac`, `awesome-claude-code` |

Example: `https://michalstrnadel.com/agentbar?utm_source=reddit-macapps&utm_medium=social&utm_campaign=2026-10-keep-awake`

Where a network only takes a GitHub link (an awesome list usually does), the
archive's referrers are the attribution: `reddit.com`, `news.ycombinator.com`,
`t.co` and so on show up there within a day.
