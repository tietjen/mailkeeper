# mailkeeperd — the server of mailkeeper-server: fetches the configured mailboxes into one
# archive per person. Built by CI on Gitea for linux/amd64; mkctl comes along for maintenance
# with `kubectl exec` (search, verify, stats on the same archive).
#
#   docker build -f packaging/server/Dockerfile .
#
# Build context is the repository root; .dockerignore keeps build output and the app out.

FROM swift:6.4-noble@sha256:bca121f6eb59fd80340d1296887b2698ed8f3eb9eca7d80c181f8af769dc7ee0 AS build
RUN apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# The manifest names every target, so the test folders must be there for SwiftPM to load it.
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
# Static Swift runtime and Foundation: the image needs only the C libraries below. Exactly the
# pinned versions: Linux's manifest lacks Sparkle and would otherwise resolve anew.
RUN swift build -c release --static-swift-stdlib --force-resolved-versions --product mailkeeperd \
 && swift build -c release --static-swift-stdlib --force-resolved-versions --product mkctl \
 && install -D -m 0755 .build/release/mailkeeperd /out/mailkeeperd \
 && install -D -m 0755 .build/release/mkctl /out/mkctl \
 && strip /out/mailkeeperd /out/mkctl  # debug symbols are most of the 136 MB each

FROM ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5
# libsqlite3-0: the index (FTS5, 3.45 in noble); libcurl4t64: URLSession; ca-certificates: TLS
# to the mail servers; tzdata: dates in logs and status.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libsqlite3-0 libcurl4t64 ca-certificates tzdata >/dev/null \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --gid 0 --home-dir /data --no-create-home --shell /usr/sbin/nologin mailkeeper
COPY --from=build /out/ /usr/local/bin/
USER 10001
ENTRYPOINT ["/usr/local/bin/mailkeeperd"]
CMD ["--config", "/etc/mailkeeper/config.json"]
