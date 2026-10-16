#!/usr/bin/env bash
# Archives the repo's GitHub traffic before GitHub forgets it. Views, clones,
# referrers and popular paths are kept for 14 days only, and release download
# counts have no history at all, so every launch post is unmeasurable a fortnight
# later unless something writes them down. This does, once a day.
#
#   Scripts/dev/traffic-snapshot.sh              # append (or replace) today's line
#   Scripts/dev/traffic-snapshot.sh --summary    # one screen from the archive, no network
#
# Options (each also has an environment variable):
#   --archive PATH   AGENTBAR_TRAFFIC_ARCHIVE   default ~/.agentbar-metrics/traffic.jsonl
#   --repo O/N       AGENTBAR_TRAFFIC_REPO      default michalstrnadel/AgentBar
#
# One JSON line per UTC day. Running twice on one day replaces that day's line, so
# it is safe from cron or launchd (Scripts/dev/traffic-launchd.plist). The daily
# views and clones in the newest line are the whole history seen so far: each run
# merges GitHub's 14-day window into what earlier lines recorded, a newer reading of
# a day replacing an older one. Read-only GitHub calls through `gh api`; the traffic
# endpoints need push access, so run it as the owner. Docs: docs/metrics.md.
set -euo pipefail

archive="${AGENTBAR_TRAFFIC_ARCHIVE:-$HOME/.agentbar-metrics/traffic.jsonl}"
repo="${AGENTBAR_TRAFFIC_REPO:-michalstrnadel/AgentBar}"
mode=snapshot
while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary) mode=summary; shift ;;
    --archive) archive="${2:?--archive needs a path}"; shift 2 ;;
    --repo) repo="${2:?--repo needs owner/name}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "traffic-snapshot: unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$repo" == */* ]] || { echo "traffic-snapshot: --repo must be owner/name" >&2; exit 2; }
command -v node >/dev/null || { echo "traffic-snapshot: needs node" >&2; exit 1; }

# The JSON work is node, the runtime the hooks and the CLI already require; jq is
# not something every Mac with AgentBar has.
summary() {
  [[ -s "$archive" ]] || { echo "traffic-snapshot: no archive at $archive — run it without --summary first" >&2; exit 1; }
  node - "$archive" <<'JS'
const fs = require('fs');
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
lines.sort((a, b) => a.date.localeCompare(b.date));
const now = lines[lines.length - 1];
const shift = (d, n) => { const t = new Date(d + 'T00:00:00Z'); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); };
const weekAgo = shift(now.date, -7);
const then = [...lines].reverse().find(l => l.date <= weekAgo);
const delta = (a, b) => then ? `  (${a - b >= 0 ? '+' : ''}${a - b} vs ${then.date})` : '';
const latest = now.releases.find(r => !r.draft && !r.prerelease) || now.releases[0];
const dl = r => r ? r.assets.reduce((s, a) => s + a.downloads, 0) : 0;
const sumDays = (daily, from, to) => daily.filter(d => d.date > from && d.date <= to).reduce((s, d) => s + d.uniques, 0);
const out = [];
out.push(`${now.repo} · ${now.date}  (${lines.length} day${lines.length === 1 ? '' : 's'} archived)`);
out.push(`stars        ${now.stars}${then ? delta(now.stars, then.stars) : ''}   forks ${now.forks}   watchers ${now.watchers}`);
out.push(`visitors     ${now.views.uniques} unique / ${now.views.count} views (14 d)   clones ${now.clones.uniques} unique (14 d)`);
if (then) out.push(`last 7 d     ${sumDays(now.views.daily, weekAgo, now.date)} daily-unique visitors   vs ${sumDays(now.views.daily, shift(weekAgo, -7), weekAgo)} the week before`);
if (latest) {
  const prev = then && then.releases.find(r => r.tag === latest.tag);
  out.push(`latest       ${latest.tag}: ${dl(latest)} downloads${prev ? delta(dl(latest), dl(prev)) : ''}   ` +
           latest.assets.map(a => `${a.name} ${a.downloads}`).join(', '));
}
out.push(`all releases ${now.downloads_total} downloads${delta(now.downloads_total, then ? then.downloads_total : 0)}`);
const refs = now.referrers.slice(0, 6).map(r => `${r.referrer} ${r.uniques}/${r.count}`);
out.push(`referrers    ${refs.length ? refs.join(' · ') : '—'}   (unique/views, 14 d)`);
const paths = now.paths.slice(0, 3).map(p => `${p.path.replace('/' + now.repo, '') || '/'} ${p.uniques}`);
if (paths.length) out.push(`paths        ${paths.join(' · ')}`);
const iss = now.outside_issues;
out.push(`issues       ${iss.count} open by others${iss.items.length ? ': ' + iss.items.slice(0, 3).map(i => `#${i.number} @${i.author}`).join(', ') : ''}`);
console.log(out.join('\n'));
JS
}

snapshot() {
  command -v gh >/dev/null || { echo "traffic-snapshot: needs gh (GitHub CLI), signed in" >&2; exit 1; }
  work="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-traffic.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  gh api "repos/$repo" > "$work/repo.json"
  gh api "repos/$repo/traffic/views" > "$work/views.json"
  gh api "repos/$repo/traffic/clones" > "$work/clones.json"
  gh api "repos/$repo/traffic/popular/referrers" > "$work/referrers.json"
  gh api "repos/$repo/traffic/popular/paths" > "$work/paths.json"
  gh api --paginate "repos/$repo/releases?per_page=100" \
    --jq '.[] | {tag: .tag_name, published_at, draft, prerelease, assets: [.assets[] | {name, downloads: .download_count}]}' \
    > "$work/releases.ndjson"
  gh api --paginate "repos/$repo/issues?state=open&per_page=100" \
    --jq '.[] | select(.pull_request == null) | {number, title, author: .user.login, created_at}' \
    > "$work/issues.ndjson"

  mkdir -p "$(dirname "$archive")"
  touch "$archive"
  node - "$work" "$archive" "$repo" "$(date -u +%F)" > "$work/archive.new" <<'JS'
const fs = require('fs');
const [work, archive, repo, today] = process.argv.slice(2);
const read = f => JSON.parse(fs.readFileSync(`${work}/${f}`, 'utf8'));
const ndjson = f => fs.readFileSync(`${work}/${f}`, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
const old = fs.readFileSync(archive, 'utf8').split('\n').filter(Boolean).map((l, i) => {
  try { return JSON.parse(l); } catch { throw new Error(`${archive}:${i + 1} is not JSON; fix or move the file`); }
}).filter(l => l.date !== today);

// Merge a 14-day window into the history the earlier lines kept: one entry per day,
// a newer reading replacing an older one (GitHub's count for today grows all day).
const history = (key, window) => {
  const days = new Map();
  for (const l of old) for (const d of (l[key] && l[key].daily) || []) days.set(d.date, d);
  for (const d of window) days.set(d.timestamp.slice(0, 10), { date: d.timestamp.slice(0, 10), count: d.count, uniques: d.uniques });
  return [...days.values()].sort((a, b) => a.date.localeCompare(b.date));
};
const r = read('repo.json'), views = read('views.json'), clones = read('clones.json');
const releases = ndjson('releases.ndjson');
const owner = r.owner.login;
const issues = ndjson('issues.ndjson').filter(i => i.author !== owner);
const line = {
  date: today,
  taken_at: new Date().toISOString(),
  repo,
  stars: r.stargazers_count,
  forks: r.forks_count,
  watchers: r.subscribers_count,
  views: { count: views.count, uniques: views.uniques, daily: history('views', views.views) },
  clones: { count: clones.count, uniques: clones.uniques, daily: history('clones', clones.clones) },
  referrers: read('referrers.json'),
  paths: read('paths.json').map(p => ({ path: p.path, count: p.count, uniques: p.uniques })),
  releases,
  downloads_total: releases.reduce((s, rel) => s + rel.assets.reduce((t, a) => t + a.downloads, 0), 0),
  outside_issues: { count: issues.length, items: issues },
};
const all = [...old, line].sort((a, b) => a.date.localeCompare(b.date));
process.stdout.write(all.map(l => JSON.stringify(l)).join('\n') + '\n');
JS
  # Same directory, then rename: a run killed halfway never leaves half an archive.
  local tmp="$archive.tmp.$$"
  cp "$work/archive.new" "$tmp" && mv -f "$tmp" "$archive"
  echo "traffic-snapshot: $(date -u +%F) → $archive ($(wc -l < "$archive" | tr -d ' ') day(s) archived)"
}

case "$mode" in
  snapshot) snapshot ;;
  summary) summary ;;
esac
