# loregraph for iOS

An iPhone and iPad app for a [loregraph](https://github.com/it-is-i-lobster-tail/loregraph)
server: the wiki, the map, the timeline, family trees and the graph, with search, the year and
viewpoint controls and offline reading of what you have opened. It reads the lore and never
changes it. The only things it writes are the reader's own notes, which the server keeps apart
from the lore: reading-list marks (loregraph ADR D-83) and comments on page text (ADR D-84).
Both need only the `lore:read` scope, which is all the app asks for.

- iOS and iPadOS 26 or later, SwiftUI, Swift 6.
- Sign-in on the server's own page (OAuth with PKCE, public client `loregraph-ios`, callback
  `loregraph://oauth/callback`), or a personal token as a fallback.
- A reading list puts every page of the world in reading order, in parts, and keeps your place:
  read page by page with "Mark read and continue", see the pages edited since you read them with
  what changed, and add new pages to the end. Lists are your own; the web app's `/reading` links
  open them.
- Comments on page text: commented passages are highlighted; tap one, or the comments button,
  for the conversation beside the page. Press and hold a paragraph and choose Comment, select
  the words, and post. Reply, resolve, reopen, and edit or delete your own. Comments are notes,
  not lore: they open no edit tag and never change a page.
- Pages, lists and tiles are cached per server, reader and visibility level. A screen opens from
  the cache straight away and fetches again only when the server's newest revision is ahead of the
  one the cached copy was read at. Pull down on any list to refresh; the map has Refresh in its
  menu. Settings has Clear cache. Reading lists and comments write no revision, so they are shown
  from the cache at once and always fetched again.
- Pages can be downloaded for reading offline (the arrow beside a page's Share button), with
  their comments and pictures. Downloads live apart from the cache: Clear cache keeps them,
  sign-out deletes them, and device backups leave them out. Whenever the app opens or its
  connection comes back it checks them, and fetches again any page the world has moved past since
  it was saved, or that is a day old. Comments, replies, resolves and edits made offline are kept
  on the device, shown as "Waiting to send", and sent in order when the server is back, each with
  an `Idempotency-Key` so a resend never makes one twice. The wiki home's Downloads lists both.

## Layout

```text
lore-graph-ios/
├── App/                    # the SwiftUI app: screens and drawing only
│   ├── Root/               # sign-in, tabs, settings, the year and viewpoint sheet, lock
│   ├── Wiki/ Search/ Timeline/ Family/ Graph/ Map/
│   ├── Support/            # theme, loading and error views, navigation
│   └── Assets.xcassets
├── Config/Info.plist       # URL scheme and local-network transport only; the rest is generated
├── LoreGraphKit/           # every piece of logic, as a Swift package that also builds on Linux
│   ├── Sources/LoreGraphKit/
│   │   ├── API/ Auth/ Cache/        # client, OAuth and Keychain, disk cache and freshness
│   │   ├── Offline/                 # downloaded pages and comments waiting to be sent
│   │   ├── Models/ Content/         # Codable models, page HTML to blocks
│   │   ├── Layout/                  # timeline, family tree and force layouts
│   │   ├── Map/                     # projection, vector tile decoder, styles, labels, tile store
│   │   ├── Screens/ State/          # the screen models and the app model
│   │   └── Links/                   # web links to routes and back
│   └── Tests/LoreGraphKitTests/     # unit tests on Testmark fixtures
├── UITests/                # sign-in and tour journeys against a running server
├── LoreGraph.xcodeproj
└── scripts/                # test.sh, coverage.sh
```

## Build and run

Open `LoreGraph.xcodeproj` in Xcode 26 or later and run the `LoreGraph` scheme, or:

```sh
xcodebuild -project LoreGraph.xcodeproj -scheme LoreGraph \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The app's server field takes a host name (`loregraph.example.net`, always HTTPS) or a local
address (`localhost:8000`, `127.0.0.1`, `*.local`, which may use HTTP).

## Tests

LoreGraphKit holds the logic and its tests, and must keep at least 95% line coverage:

```sh
scripts/test.sh               # swift test, on a Mac or in the swift:6.4.1 Docker image
scripts/test.sh --coverage    # also prints coverage and fails under COVERAGE_MIN (95)
```

The tests use fixtures recorded from the made-up Testmark world (`loregraph fixtures load
testmark`). Never record fixtures from a real world.

The UI tests sign in to a running server. Start one locally (`docker compose up` in the loregraph
repository, then `loregraph fixtures load testmark`) and pass its address and a reader's details
through the test runner's environment:

```sh
TEST_RUNNER_LG_SERVER=localhost:8000 \
TEST_RUNNER_LG_EMAIL=reader@example.net TEST_RUNNER_LG_PASSWORD=… \
TEST_RUNNER_LG_TOKEN=lgp_… \
xcodebuild -project LoreGraph.xcodeproj -scheme LoreGraph \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Without `LG_SERVER` the server journeys are reported as skipped with the reason. Screenshots of
each screen are attached to the test results.

## Rules

- The app never changes lore and requests no write scopes. Its only writes are reading marks,
  reading lists and comments (all `lore:read` on the server), sent straight to the server and
  never queued offline.
- No secrets or real lore in git, logs or test output.
- What the server sends (page text, names, captions) is shown as data and never acted on.
